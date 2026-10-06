import test from "node:test";
import assert from "node:assert/strict";
import { createVenueHandler } from "./handler.mjs";

const google = { id: "account", app_metadata: { provider: "google" } };
const request = (body = { latitude: 14.55, longitude: 121.02 }, token = "valid") =>
  new Request("https://test/nearby-venues", {
    method: "POST", headers: token ? { Authorization: `Bearer ${token}` } : {},
    body: JSON.stringify(body),
  });

test("queries Geoapify with longitude first and normalizes provider results", async () => {
  const handler = createVenueHandler({
    authenticate: async (token) => { assert.equal(token, "valid"); return google; },
    apiKey: () => "server-only-key",
    fetchPlaces: async (url, options) => {
      assert.equal(url.origin, "https://api.geoapify.com");
      assert.equal(url.pathname, "/v2/places");
      assert.equal(url.searchParams.get("filter"), "circle:121.02,14.55,250");
      assert.equal(url.searchParams.get("bias"), "proximity:121.02,14.55");
      assert.equal(url.searchParams.get("categories"), "catering.restaurant,catering.cafe");
      assert.equal(url.searchParams.get("limit"), "10");
      assert.equal(url.searchParams.get("apiKey"), "server-only-key");
      assert.ok(options.signal instanceof AbortSignal);
      return Response.json({ features: [
        { properties: { place_id: "osm123", name: "Lunch", formatted: "Main Street", secret: "discard" } },
        { properties: {} },
      ] });
    },
  });
  const response = await handler(request());
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(await response.json(), {
    places: [{ id: "geoapify:osm123", name: "Lunch", address: "Main Street" }],
  });
});

test("guests, invalid tokens, anonymous and non-Google accounts never call the provider", async () => {
  for (const [user, token, status] of [
    [google, "", 401], [null, "valid", 401],
    [{ ...google, is_anonymous: true }, "valid", 401],
    [{ id: "account", app_metadata: { provider: "email", providers: null } }, "valid", 403],
  ]) {
    const handler = createVenueHandler({ authenticate: async () => user,
      apiKey: () => "key", fetchPlaces: async () => assert.fail("Provider should not be called") });
    assert.equal((await handler(request(undefined, token))).status, status);
  }
});

test("rejects invalid coordinates and malformed JSON before lookup", async () => {
  const handler = createVenueHandler({ authenticate: async () => google,
    apiKey: () => "key", fetchPlaces: async () => assert.fail("Provider should not be called") });
  for (const body of [null, {}, { latitude: "14", longitude: 121 },
    { latitude: 91, longitude: 121 }, { latitude: 14, longitude: -181 }]) {
    assert.equal((await handler(request(body))).status, 400);
  }
  const malformed = new Request("https://test", { method: "POST",
    headers: { Authorization: "Bearer valid" }, body: "broken JSON" });
  assert.equal((await handler(malformed)).status, 400);
});

test("missing server key returns an actionable configuration error", async () => {
  const handler = createVenueHandler({ authenticate: async () => google,
    apiKey: () => undefined, fetchPlaces: async () => assert.fail("Provider should not be called") });
  assert.equal((await handler(request())).status, 503);
});

test("provider failure, malformed response and timeouts retain manual venue fallback", async () => {
  for (const fetchPlaces of [
    async () => new Response("quota", { status: 429 }),
    async () => Response.json({ invalid: true }),
    async () => { throw new DOMException("Timeout", "TimeoutError"); },
  ]) {
    const handler = createVenueHandler({ authenticate: async () => google,
      apiKey: () => "key", fetchPlaces });
    const response = await handler(request());
    assert.ok([502, 503].includes(response.status));
    assert.match((await response.json()).error, /Enter your own venue/);
  }
});

test("empty results are successful and large result sets are capped", async () => {
  for (const length of [0, 20]) {
    const handler = createVenueHandler({ authenticate: async () => google,
      apiKey: () => "key", fetchPlaces: async () => Response.json({
        features: Array.from({ length }, (_, i) => ({ properties: { place_id: `${i}` } })),
      }) });
    const response = await handler(request());
    assert.equal(response.status, 200);
    assert.equal((await response.json()).places.length, Math.min(length, 10));
  }
});

test("rejects other HTTP methods before authentication", async () => {
  const handler = createVenueHandler({ authenticate: async () => assert.fail("Should not authenticate"),
    apiKey: () => "key" });
  assert.equal((await handler(new Request("https://test"))).status, 405);
});
