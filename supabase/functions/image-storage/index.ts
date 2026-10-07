import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { aws, endpoint, env, objectUrl } from "./r2.ts";
import { createImageHandler, referencedKeys } from "./handler.mjs";
import { createQuotaStorage } from "./quota.mjs";
import { createMeteredFetch, readUpload } from "./operations.mjs";

const userClient = (token: string) =>
  createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
const admin = () =>
  createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
const decodeXml = (value: string) =>
  value.replaceAll("&amp;", "&").replaceAll("&lt;", "<").replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"').replaceAll("&apos;", "'");

const quota = async (name: string, params: Record<string, unknown>) => {
  const { data, error } = await admin().rpc(name, params);
  if (error) throw error; // Missing migration or database failures deny uploads.
  return data;
};

const r2Fetch = createMeteredFetch({
  consume: (kind: string) =>
    quota("consume_image_operation", { p_class: kind }),
  fetch: (url: string | URL, options: RequestInit) => aws().fetch(url, options),
});
const storage = createQuotaStorage({
  rpc: quota,
  fetchObject: (key: string, method: string) =>
    r2Fetch(objectUrl(key), { method }),
});
const deleteTracked = storage.remove;

Deno.serve(createImageHandler({
  authenticate: async (token: string) => {
    const { data, error } = await userClient(token).auth.getUser(token);
    return error ? null : data.user;
  },
  mealForUser: async (token: string, meal: string) => {
    const { data, error } = await userClient(token).from("meals").select(
      "creator,deleted_at",
    ).eq("id", meal).maybeSingle();
    if (error) throw error;
    return data;
  },
  referencesForUser: async (token: string, user: string, meal: string) => {
    const client = userClient(token);
    const { data: asset, error } = await client.from("meal_assets").select(
      "original,thumbnail,cutout",
    ).eq("meal_id", meal).maybeSingle();
    if (error) throw error;
    const { data: memories, error: memoryError } = await client.from(
      "personal_memories",
    ).select("data").eq("meal_id", meal).eq("user_id", user);
    if (memoryError) throw memoryError;
    return referencedKeys(asset, memories ?? []);
  },
  // Return only an authenticated app endpoint. Direct R2 URLs are reusable
  // and would allow transfers that bypass operation accounting.
  sign: (method: string, key: string, headers: Record<string, string>) => {
    const url = new URL(env("SUPABASE_URL") + "/functions/v1/image-storage");
    url.searchParams.set("key", key);
    if (method === "PUT") {
      url.searchParams.set("size", headers["Content-Length"]);
    }
    return url.toString();
  },
  transfer: async (req: Request, key: string, size: number, type: string) => {
    const upload = req.method === "PUT";
    const bytes = upload ? await readUpload(req, size) : undefined;
    const response = await r2Fetch(objectUrl(key), {
      method: upload ? "PUT" : "GET",
      ...(upload
        ? {
          body: bytes,
          headers: { "Content-Type": type, "Content-Length": String(size) },
        }
        : {}),
    });
    if (!response.ok) throw new Error("Image transfer failed");
    return new Response(upload ? null : response.body, {
      status: upload ? 204 : 200,
      headers: upload
        ? {}
        : { "Content-Type": type, "Cache-Control": "no-store" },
    });
  },
  reserve: storage.reserve,
  confirm: storage.confirm,
  cleanup: async (token: string, user: string, meal: string) => {
    const cleanupMeal = async (meal: string) => {
      // Administrative reads also cover soft-deleted meals. Creator check is mandatory.
      const client = admin();
      const { data: record, error } = await client.from("meals").select(
        "creator,deleted_at,revision",
      ).eq("id", meal).maybeSingle();
      if (error || !record || record.creator !== user) {
        throw new Error("Creator required");
      }
      const { data: asset, error: assetError } = await client.from(
        "meal_assets",
      ).select("original,thumbnail,cutout").eq("meal_id", meal).maybeSingle();
      const { data: memories, error: memoryError } = await client.from(
        "personal_memories",
      ).select("data").eq("meal_id", meal);
      if (assetError || memoryError) {
        throw new Error("Reference lookup failed");
      }
      const refs = record.deleted_at
        ? new Set<string>()
        : referencedKeys(asset, memories ?? []);
      const purge = !!record.deleted_at || (!asset && record.revision > 0);
      let continuation: string | undefined;
      do {
        const url = new URL(endpoint());
        url.searchParams.set("list-type", "2");
        url.searchParams.set("prefix", `${meal}/`);
        if (continuation) {
          url.searchParams.set("continuation-token", continuation);
        }
        const response = await r2Fetch(url, { operationClass: "A" });
        if (!response.ok) {
          throw new Error("Listing failed");
        }
        const xml = await response.text();
        for (
          const entry of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)
        ) {
          const key = decodeXml(
            /<Key>(.*?)<\/Key>/.exec(entry[1])?.[1] ?? "",
          );
          const modified = Date.parse(
            /<LastModified>(.*?)<\/LastModified>/.exec(entry[1])?.[1] ?? "",
          );
          // Grace period protects in-flight uploads and another device's pending save.
          if (
            key.startsWith(`${meal}/`) && !refs.has(key) &&
            (purge || modified < Date.now() - 86400000)
          ) {
            await deleteTracked(key);
          }
        }
        const next = /<NextContinuationToken>(.*?)<\/NextContinuationToken>/
          .exec(xml)?.[1];
        continuation = next ? decodeXml(next) : undefined;
      } while (continuation);
      // R2 listing omits reservations whose PUT never completed. DELETE is
      // idempotent for missing objects, but quota is freed only on its success.
      let after = "";
      for (;;) {
        const { data: pending, error: pendingError } = await client.from(
          "image_storage_objects",
        )
          .select("key,confirmed,deleting").eq("meal_id", meal)
          .lt("grant_until", new Date(Date.now() - 86400000).toISOString())
          .gt("key", after).order("key").limit(100);
        if (pendingError) throw pendingError;
        for (const row of pending ?? []) {
          if (!refs.has(row.key) && (purge || !row.confirmed || row.deleting)) {
            await deleteTracked(row.key);
          }
          after = row.key;
        }
        if ((pending?.length ?? 0) < 100) break;
      }
    };
    if (meal) {
      await cleanupMeal(meal);
    } else {
      // Daily owner sweep also retries cleanup of previously deleted meals.
      const client = admin();
      for (let offset = 0;; offset += 100) {
        const { data, error } = await client.from("meals").select("id").eq(
          "creator",
          user,
        ).order("id").range(offset, offset + 99);
        if (error) throw error;
        for (const row of data ?? []) await cleanupMeal(row.id);
        if ((data?.length ?? 0) < 100) break;
      }
    }
  },
}));
