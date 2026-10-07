import test from "node:test";
import assert from "node:assert/strict";
import { createMeteredFetch, readUpload } from "./operations.mjs";

test("meters PUT, GET, HEAD and listing attempts before R2; deletes remain free", async () => {
  const calls = [];
  const fetch = createMeteredFetch({
    consume: async (kind) => {
      calls.push(kind);
      return true;
    },
    fetch: async (url, options) => {
      calls.push(options.method ?? "GET");
      assert.equal(options.operationClass, undefined);
      return new Response();
    },
  });
  for (
    const options of [
      { method: "PUT" },
      { method: "GET" },
      { method: "HEAD" },
      { operationClass: "A" },
      { method: "DELETE" },
    ]
  ) await fetch("https://example.test", options);
  assert.deepEqual(calls, [
    "A",
    "PUT",
    "B",
    "GET",
    "B",
    "HEAD",
    "A",
    "GET",
    "DELETE",
  ]);
});

test("exhausted and unavailable counters never contact R2; failed attempts are not refunded", async () => {
  for (const broken of [false, true]) {
    const fetch = createMeteredFetch({
      consume: async () => {
        if (broken) throw new Error("database offline");
        return false;
      },
      fetch: async () => {
        assert.fail("must not contact R2");
      },
    });
    await assert.rejects(fetch("https://example.test", { method: "PUT" }));
  }
  let count = 0;
  const fetch = createMeteredFetch({
    consume: async () => {
      count++;
      return true;
    },
    fetch: async () => {
      throw new Error("network failure");
    },
  });
  await assert.rejects(fetch("https://example.test"));
  assert.equal(count, 1);
});

test("binary uploads reject oversized and short bodies before any R2 write", async () => {
  const req = (bytes) =>
    new Request("https://example.test", {
      method: "PUT",
      body: new Uint8Array(bytes),
    });
  assert.deepEqual(
    await readUpload(req([1, 2, 3]), 3),
    new Uint8Array([1, 2, 3]),
  );
  await assert.rejects(readUpload(req([1, 2, 3]), 2));
  await assert.rejects(readUpload(req([1]), 2));
});
