import asyncio
import base64
import io
import json
import unittest
from pathlib import Path

import httpx
import numpy as np
from PIL import Image

from cloud_api import SupabaseAuthenticator, create_api
from image_contract import encode_plates, open_photo, MAX_IMAGE_BYTES


def photo_bytes(width=10, height=20):
    output = io.BytesIO()
    Image.new("RGB", (width, height), (120, 80, 60)).save(output, "PNG")
    return output.getvalue()


def response_fixture():
    mask = np.zeros((20, 10), dtype=bool)
    mask[5:15, 2:7] = True
    mask[8:10, 3:5] = False
    return encode_plates([(mask, 0.9)], 10, 20)


def auth_response(request):
    token = request.headers["authorization"]
    if token == "Bearer invalid":
        return httpx.Response(401)
    if token == "Bearer malformed-provider":
        return httpx.Response(200, json={
            "id": token, "role": "authenticated", "app_metadata": {"providers": None},
        })
    return httpx.Response(200, json={
        "id": token, "role": "authenticated", "is_anonymous": token == "Bearer anonymous",
        "app_metadata": {"provider": "email" if token == "Bearer email" else "google"},
    })


class ContractTests(unittest.TestCase):
    def test_crop_alpha_and_shared_flutter_fixture(self):
        result = response_fixture()
        mask = Image.open(io.BytesIO(base64.b64decode(result["plates"][0]["mask"])))
        self.assertEqual(mask.mode, "RGBA")
        self.assertEqual(mask.size, (5, 10))
        self.assertEqual(mask.getpixel((1, 3))[3], 0)
        self.assertEqual(mask.getpixel((0, 0))[3], 255)
        self.assertEqual(result["plates"][0]["bounds"], [0.2, 0.25, 0.5, 0.5])
        fixture = Path(__file__).parents[1] / "test/fixtures/cloud_plates.json"
        self.assertEqual(json.loads(fixture.read_text()), result)

    def test_duplicates_removed_without_merging_distinct_plates(self):
        a, b = np.zeros((20, 10), bool), np.zeros((20, 10), bool)
        a[0:5, 0:5], b[10:15, 5:10] = True, True
        result = encode_plates([(a, .9), (a.copy(), .8), (b, .7)], 10, 20)
        self.assertEqual(len(result["plates"]), 2)

    def test_mask_normalization_and_image_limits(self):
        result = encode_plates([(np.ones((1000, 1600), bool), .9)], 1600, 1000)
        mask = Image.open(io.BytesIO(base64.b64decode(result["plates"][0]["mask"])))
        self.assertEqual(mask.size, (768, 480))
        with self.assertRaises(ValueError):
            open_photo(photo_bytes(1601, 1))
        with self.assertRaises(ValueError):
            open_photo(b"not a photo")


class ApiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = 0
        self.auth = SupabaseAuthenticator("https://example.supabase.co", "publishable",
                                         httpx.MockTransport(auth_response))

        async def segment(data):
            self.calls += 1
            self.assertEqual(open_photo(data).size, (10, 20))
            return response_fixture()

        self.segment = segment
        self.api = create_api(segment, self.auth)
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.api),
                                       base_url="https://test")

    async def asyncTearDown(self):
        await self.client.aclose()

    async def upload(self, token="google"):
        return await self.client.post("/", headers={"Authorization": "Bearer " + token},
                                      files={"image": ("image.png", photo_bytes(), "image/png")})

    async def test_multipart_contract_and_health(self):
        response = await self.upload()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), response_fixture())
        health = await self.client.get("/health", headers={"Authorization": "Bearer google"})
        self.assertEqual(health.json(), {"version": 1, "model": "sam3", "ready": True})
        self.assertEqual(self.calls, 1)

    async def test_authentication_precedes_inference(self):
        response = await self.client.post("/", files={"image": photo_bytes()})
        self.assertEqual(response.status_code, 401)
        for token, expected in [("invalid", 401), ("anonymous", 401), ("email", 403),
                                ("malformed-provider", 403)]:
            self.assertEqual((await self.upload(token)).status_code, expected)
        self.assertEqual(self.calls, 0)

    async def test_bad_uploads_and_oversized_bodies_never_reach_gpu(self):
        headers = {"Authorization": "Bearer google"}
        self.assertEqual((await self.client.post("/", headers=headers,
                         content=photo_bytes())).status_code, 422)
        self.assertEqual((await self.client.post("/", headers=headers,
                         files={"image": b"not an image"})).status_code, 422)
        self.assertEqual((await self.client.post("/", headers=headers,
                         content=b"x" * (MAX_IMAGE_BYTES + 65537))).status_code, 413)
        self.assertEqual(self.calls, 0)

    async def test_quota_is_per_verified_account(self):
        self.api = create_api(self.segment, self.auth, requests_per_minute=1)
        await self.client.aclose()
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.api), base_url="https://test")
        self.assertEqual((await self.upload()).status_code, 200)
        self.assertEqual((await self.upload()).status_code, 429)
        self.assertEqual((await self.upload("another-google-account")).status_code, 200)

    async def test_inference_timeout_releases_request_slot(self):
        async def stalled(data):
            await asyncio.sleep(1)
        api = create_api(stalled, self.auth, inference_timeout=.01)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=api), base_url="https://test") as client:
            for _ in range(2):
                response = await client.post("/", headers={"Authorization": "Bearer google"},
                                             files={"image": photo_bytes()})
                self.assertEqual(response.status_code, 504)


if __name__ == "__main__":
    unittest.main()
