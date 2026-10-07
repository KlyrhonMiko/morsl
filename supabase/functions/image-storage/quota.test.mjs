import test from "node:test";
import assert from "node:assert/strict";
import { createQuotaStorage } from "./quota.mjs";

test("confirmation uses verified HEAD size and rejects missing/wrong-sized objects", async () => {
  for (
    const [status, length, valid] of [[200, "100", true], [200, "99", false], [
      404,
      null,
      false,
    ], [200, null, false]]
  ) {
    const calls = [];
    const storage = createQuotaStorage({
      rpc: async (name, params) => {
        calls.push([name, params]);
        return true;
      },
      fetchObject: async (key, method) => {
        assert.equal(method, "HEAD");
        return new Response(null, {
          status,
          headers: length == null ? {} : { "Content-Length": length },
        });
      },
    });
    if (valid) {
      await storage.confirm("image", 100);
      assert.deepEqual(calls, [["confirm_image", {
        p_key: "image",
        p_bytes: 100,
      }]]);
    } else {
      await assert.rejects(storage.confirm("image", 100));
      assert.equal(calls.length, 0);
    }
  }
});

test("failed R2 deletion retains quota; success releases only after DELETE", async () => {
  for (const success of [true, false]) {
    const calls = [];
    const storage = createQuotaStorage({
      rpc: async (name) => {
        calls.push(name);
        return true;
      },
      fetchObject: async (key, method) => {
        calls.push(method);
        return new Response(null, { status: success ? 204 : 503 });
      },
    });
    if (success) await storage.remove("image");
    else await assert.rejects(storage.remove("image"));
    assert.deepEqual(calls, [
      "begin_image_delete",
      "DELETE",
      success ? "finish_image_delete" : "cancel_image_delete",
    ]);
  }
});

test("active grants and another cleanup claim prevent DELETE", async () => {
  const storage = createQuotaStorage({
    rpc: async () => false,
    fetchObject: async () => {
      assert.fail("must not delete");
    },
  });
  await storage.remove("image");
});
