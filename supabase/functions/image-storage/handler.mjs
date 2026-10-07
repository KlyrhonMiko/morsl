const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const keyPattern = new RegExp(
  `^(${uuid})/(${uuid})/r2/(original|thumbnail|cutout|plate)-([0-9a-f]{64})\\.(jpg|jpeg|png|webp|heic|heif)$`,
);
const types = {
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
  heic: "image/heic",
  heif: "image/heif",
};

export function createImageHandler(
  {
    authenticate,
    mealForUser,
    referencesForUser,
    sign,
    cleanup,
    reserve,
    confirm,
  },
) {
  const json = (body, status = 200) =>
    Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
  return async (req) => {
    if (req.method !== "POST") return json({ error: "POST required" }, 405);
    const token = /^Bearer (\S+)$/i.exec(req.headers.get("Authorization") ?? "")
      ?.[1];
    if (!token || token.length > 8192) {
      return json({ error: "Sign in required" }, 401);
    }
    try {
      const user = await authenticate(token);
      if (!user || user.is_anonymous) {
        return json({ error: "Sign in required" }, 401);
      }
      if (
        user.app_metadata?.provider !== "google" &&
        !user.app_metadata?.providers?.includes("google")
      ) {
        return json({ error: "Sign in with Google required" }, 403);
      }
      let body;
      try {
        body = await req.json();
      } catch {
        return json({ error: "Invalid request" }, 400);
      }
      if (body?.action === "cleanup") {
        if (body.meal != null && !new RegExp(`^${uuid}$`).test(body.meal)) {
          return json({ error: "Invalid meal" }, 400);
        }
        await cleanup(token, user.id, body.meal);
        return json({ ok: true });
      }
      const match = typeof body?.key === "string" && keyPattern.exec(body.key);
      if (!match || !["upload", "confirm", "download"].includes(body.action)) {
        return json({ error: "Invalid image request" }, 400);
      }
      const [, mealId, folder, kind, , extension] = match;
      const meal = await mealForUser(token, mealId);
      if (!meal || meal.deleted_at) {
        return json({ error: "Image unavailable" }, 403);
      }
      if (body.action !== "download") {
        if (
          !Number.isInteger(body.size) || body.size <= 0 ||
          body.size > 20 * 1024 * 1024
        ) {
          return json({ error: "Images must be at most 20 MB" }, 400);
        }
        if (
          kind === "plate"
            ? folder !== user.id || extension !== "png"
            : meal.creator !== user.id
        ) {
          return json({ error: "Upload not allowed" }, 403);
        }
        if (body.action === "confirm") {
          await confirm(body.key, body.size);
          return json({ ok: true });
        }
        const reservation = await reserve(body.key, body.size);
        if (reservation === "full") {
          return json({
            code: "storage_full",
            error: "Cloud storage is full. Your photo is saved on this device.",
          }, 507);
        }
        if (reservation !== "reserved") {
          throw new Error("Reservation unavailable");
        }
      } else {
        if (kind === "plate" && folder !== user.id) {
          return json({ error: "Image unavailable" }, 403);
        }
        const refs = await referencesForUser(token, user.id, mealId);
        if (!refs.has(body.key)) {
          return json({ error: "Image unavailable" }, 403);
        }
      }
      const url = await sign(
        body.action === "upload" ? "PUT" : "GET",
        body.key,
        body.action === "upload"
          ? {
            "Content-Type": types[extension],
            "Content-Length": String(body.size),
          }
          : {},
      );
      return json({ url, expiresIn: 300 });
    } catch {
      return json(
        { error: "Image storage unavailable. Please try again." },
        503,
      );
    }
  };
}

export function referencedKeys(asset, memories) {
  const refs = new Set();
  // Removing the source photo revokes access to all of its derivatives.
  if (!asset) return refs;
  for (const key of ["original", "thumbnail", "cutout"]) {
    if (asset[key]) refs.add(asset[key]);
  }
  for (const memory of memories) {
    for (const plate of memory.data?.plates ?? []) {
      if (plate.cloudPath) refs.add(plate.cloudPath);
    }
  }
  return refs;
}
