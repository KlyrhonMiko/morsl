import test from "node:test";
import assert from "node:assert/strict";
import { createImageHandler, referencedKeys } from "./handler.mjs";

const M = "11111111-1111-4111-8111-111111111111";
const A = "22222222-2222-4222-8222-222222222222";
const B = "33333333-3333-4333-8333-333333333333";
const original = `${M}/${M}/r2/original-${"a".repeat(64)}.jpg`;
const plate = `${M}/${A}/r2/plate-${"b".repeat(64)}.png`;
function setup(overrides = {}) {
  const signed = [];
  const handler = createImageHandler({
    authenticate: async () => ({ id: A, app_metadata: { provider: "google" } }),
    mealForUser: async () => ({ creator: A, deleted_at: null }),
    referencesForUser: async () => new Set([original, plate]),
    sign: async (...args) => {
      signed.push(args);
      return "https://private.example/signed";
    },
    cleanup: async () => {},
    ...overrides,
  });
  const request = (body) =>
    handler(
      new Request("https://example.com", {
        method: "POST",
        headers: { Authorization: "Bearer test" },
        body: JSON.stringify(body),
      }),
    );
  return { request, signed, handler };
}
test("signed image reads require authentication, membership and current reference", async () => {
  assert.equal(
    (await setup({ authenticate: async () => null }).request({
      action: "download",
      key: original,
    })).status,
    401,
  );
  assert.equal(
    (await setup({ mealForUser: async () => null }).request({
      action: "download",
      key: original,
    })).status,
    403,
  );
  const { request, signed } = setup({
    referencesForUser: async () => new Set(),
  });
  assert.equal(
    (await request({ action: "download", key: original })).status,
    403,
  );
  assert.equal(signed.length, 0);
  const ok = setup();
  assert.equal(
    (await ok.request({ action: "download", key: plate })).status,
    200,
  );
  assert.equal(ok.signed[0][0], "GET");
});
test("members can upload their own cutouts but cannot upload original photos or another member cutouts", async () => {
  const { request, signed } = setup({
    mealForUser: async () => ({ creator: B }),
  });
  assert.equal(
    (await request({ action: "upload", key: original, size: 100 })).status,
    403,
  );
  assert.equal(
    (await request({ action: "upload", key: plate.replace(A, B), size: 100 }))
      .status,
    403,
  );
  assert.equal(
    (await request({ action: "upload", key: plate, size: 100 })).status,
    200,
  );
  assert.deepEqual(signed[0], ["PUT", plate, {
    "Content-Type": "image/png",
    "Content-Length": "100",
  }]);
});
test("rejects oversized uploads, malformed paths, non-Google sign-in and copied cutout references", async () => {
  const { request } = setup();
  for (const size of [0, -1, 1.5, 20 * 1024 * 1024 + 1]) {
    assert.equal(
      (await request({ action: "upload", key: original, size })).status,
      400,
    );
  }
  assert.equal(
    (await request({ action: "upload", key: "../escape.jpg", size: 100 }))
      .status,
    400,
  );
  assert.equal(
    (await setup({
      authenticate: async () => ({
        id: A,
        app_metadata: { provider: "email" },
      }),
    }).request({ action: "download", key: original })).status,
    403,
  );
  assert.equal(
    (await setup({
      referencesForUser: async () => new Set([plate.replace(A, B)]),
    }).request({ action: "download", key: plate.replace(A, B) })).status,
    403,
  );
});
test("removed source assets revoke all cutout references; cleanup retains all members current references", () => {
  assert.equal(
    referencedKeys(null, [{ data: { plates: [{ cloudPath: plate }] } }]).size,
    0,
  );
  assert.deepEqual(
    referencedKeys({ original }, [
      { data: { plates: [{ cloudPath: plate }] } },
      { data: { plates: [{ cloudPath: "other" }] } },
    ]),
    new Set([original, plate, "other"]),
  );
});
test("never returns a signed URL on backend failure", async () => {
  const { request, signed } = setup({
    referencesForUser: async () => {
      throw new Error("private credential");
    },
  });
  const response = await request({ action: "download", key: original });
  assert.equal(response.status, 503);
  assert.equal(signed.length, 0);
  assert.equal((await response.text()).includes("private credential"), false);
});
