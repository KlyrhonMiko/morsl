"""Authenticated, bounded HTTP ingress; GPU workers have no public URL."""
import asyncio
import time
from collections import deque

import httpx
from fastapi import FastAPI, HTTPException, Request
from starlette.datastructures import UploadFile
from starlette.responses import JSONResponse

from image_contract import MAX_IMAGE_BYTES, open_photo


class SupabaseAuthenticator:
    def __init__(self, url, publishable_key, transport=None):
        if not url.startswith("https://") or not publishable_key:
            raise ValueError("SUPABASE_URL and SUPABASE_ANON_KEY are required")
        self.url = url.rstrip("/") + "/auth/v1/user"
        self.key = publishable_key
        self.transport = transport

    async def __call__(self, token):
        try:
            async with httpx.AsyncClient(timeout=5, transport=self.transport) as client:
                response = await client.get(self.url, headers={
                    "Authorization": "Bearer " + token, "apikey": self.key,
                })
            if response.status_code in (400, 401, 403):
                raise HTTPException(401, "Sign in to use cloud extraction")
            if response.status_code != 200:
                raise HTTPException(503, "Authentication is unavailable")
            user = response.json()
        except (httpx.HTTPError, ValueError) as error:
            raise HTTPException(503, "Authentication is unavailable") from error
        if (not isinstance(user, dict) or not isinstance(user.get("id"), str)
                or not user["id"] or user.get("is_anonymous") is True
                or user.get("role") != "authenticated"):
            raise HTTPException(401, "A signed-in account is required")
        metadata = user.get("app_metadata", {})
        providers = metadata.get("providers") if isinstance(metadata, dict) else None
        if not isinstance(metadata, dict) or not (
            metadata.get("provider") == "google" or
            (isinstance(providers, list) and "google" in providers)
        ):
            raise HTTPException(403, "Sign in with Google to use extraction")
        return user["id"]


class BodyLimit:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST":
            return await self.app(scope, receive, send)
        limit = MAX_IMAGE_BYTES + 64 * 1024
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            body.extend(message.get("body", b""))
            if len(body) > limit:
                return await JSONResponse(
                    {"detail": "Photo upload is too large"}, status_code=413,
                )(scope, receive, send)
            if not message.get("more_body", False):
                break
        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        return await self.app(scope, replay, send)


def create_api(segment, authenticate, *, requests_per_minute=10, now=time.monotonic,
               inference_timeout=110):
    api = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    api.add_middleware(BodyLimit)
    # Modal ingress is capped at one container. Use shared quota storage before scaling out.
    recent, in_flight = {}, set()

    async def user_id(request):
        scheme, _, token = request.headers.get("authorization", "").partition(" ")
        if scheme.lower() != "bearer" or not token or len(token) > 8192:
            raise HTTPException(401, "Sign in to use cloud extraction")
        return await authenticate(token)

    @api.get("/health")
    async def health(request: Request):
        await user_id(request)
        return {"version": 1, "model": "sam3", "ready": True}

    @api.post("/")
    async def extract(request: Request):
        account = await user_id(request)
        timestamp = now()
        for key in list(recent):
            while recent[key] and recent[key][0] <= timestamp - 60:
                recent[key].popleft()
            if not recent[key]:
                del recent[key]
        history = recent.setdefault(account, deque())
        if len(history) >= requests_per_minute:
            raise HTTPException(429, "Extraction quota reached", headers={"Retry-After": "60"})
        if account in in_flight or len(in_flight) >= 4:
            raise HTTPException(429, "Extraction is busy", headers={"Retry-After": "5"})
        history.append(timestamp)
        in_flight.add(account)
        try:
            async with request.form(max_files=1, max_fields=0) as form:
                photo = form.get("image")
                if not isinstance(photo, UploadFile) or len(form) != 1:
                    raise HTTPException(422, "Upload one image field")
                data = await photo.read(MAX_IMAGE_BYTES + 1)
                if len(data) > MAX_IMAGE_BYTES:
                    raise HTTPException(413, "Photo upload is too large")
            try:
                await asyncio.to_thread(open_photo, data)
            except ValueError as error:
                raise HTTPException(422, str(error)) from error
            try:
                return await asyncio.wait_for(segment(data), timeout=inference_timeout)
            except TimeoutError as error:
                raise HTTPException(504, "Cloud extraction timed out") from error
            except Exception as error:
                raise HTTPException(503, "Cloud extraction is unavailable") from error
        finally:
            in_flight.discard(account)

    return api
