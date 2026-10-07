import { sign } from "./r2.ts";

Deno.test("R2 query signatures bind upload type, length and five-minute expiry", async () => {
  for (
    const [key, value] of Object.entries({
      R2_ACCOUNT_ID: "0123456789abcdef0123456789abcdef",
      R2_BUCKET: "morsl-test",
      R2_ACCESS_KEY_ID: "test-key",
      R2_SECRET_ACCESS_KEY: "test-secret",
    })
  ) Deno.env.set(key, value);
  const key = "meal/account/r2/plate.png";
  const url = new URL(
    await sign("PUT", key, {
      "Content-Type": "image/png",
      "Content-Length": "100",
    }),
  );
  if (
    url.hostname !== "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"
  ) throw new Error("Wrong host");
  if (url.pathname !== `/morsl-test/${key}`) {
    throw new Error("Wrong object key");
  }
  if (url.searchParams.get("X-Amz-Expires") !== "300") {
    throw new Error("Wrong expiry");
  }
  const headers = url.searchParams.get("X-Amz-SignedHeaders");
  if (
    !headers?.includes("content-type") || !headers?.includes("content-length")
  ) throw new Error("Upload constraints are not signed");
  if (!url.searchParams.get("X-Amz-Signature")) {
    throw new Error("Missing signature");
  }
  const changed = new URL(
    await sign("PUT", key, {
      "Content-Type": "image/png",
      "Content-Length": "101",
    }),
  );
  if (
    changed.searchParams.get("X-Amz-Signature") ===
      url.searchParams.get("X-Amz-Signature")
  ) throw new Error("Length must affect signature");
});
