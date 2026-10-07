// Provider results are returned live; the user chooses a venue to save.
export function createVenueHandler({ authenticate, apiKey, fetchPlaces = fetch }) {
  const json = (body, status = 200) => Response.json(body, {
    status, headers: { "Cache-Control": "no-store" },
  });
  return async (req) => {
    if (req.method !== "POST") return json({ error: "POST required" }, 405);
    const authorization = req.headers.get("Authorization") ?? "";
    const match = /^Bearer (\S+)$/i.exec(authorization);
    if (!match || match[1].length > 8192) return json({ error: "Sign in required" }, 401);
    try {
      const user = await authenticate(match[1]);
      if (!user || !user.id || user.is_anonymous) return json({ error: "Sign in required" }, 401);
      const metadata = user.app_metadata ?? {};
      if (metadata.provider !== "google" &&
          !(Array.isArray(metadata.providers) && metadata.providers.includes("google"))) {
        return json({ error: "Sign in with Google required" }, 403);
      }
      let body;
      try { body = await req.json(); } catch { return json({ error: "Valid coordinates required" }, 400); }
      const { latitude, longitude, query = "" } = body ?? {};
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude) ||
          Math.abs(latitude) > 90 || Math.abs(longitude) > 180) {
        return json({ error: "Valid coordinates required" }, 400);
      }
      if (typeof query !== "string" || query.trim().length > 120) {
        return json({ error: "Enter a restaurant name up to 120 characters" }, 400);
      }
      const name = query.normalize("NFKC").replace(/\s+/g, " ").trim();
      const key = apiKey();
      if (!key) return json({ error: "Venue lookup is not configured" }, 503);
      // Autocomplete is optimized for typed names; Places handles nearby browsing.
      const url = new URL(name
        ? "https://api.geoapify.com/v1/geocode/autocomplete"
        : "https://api.geoapify.com/v2/places");
      url.search = new URLSearchParams({
        bias: `proximity:${longitude},${latitude}`,
        limit: "10", apiKey: key,
      }).toString();
      // Meals may be edited after travelling home. Rank named branches by
      // distance without excluding venues outside the user's current area.
      if (name) {
        url.searchParams.set("text", name);
        url.searchParams.set("type", "amenity");
      } else {
        url.searchParams.set("categories", "catering");
        url.searchParams.set("filter", `circle:${longitude},${latitude},2000`);
      }
      const response = await fetchPlaces(url, { signal: AbortSignal.timeout(8000) });
      if (!response.ok) return json({ error: "Nearby places unavailable. Enter your own venue." }, 502);
      const result = await response.json();
      if (!Array.isArray(result.features)) return json({ error: "Nearby places unavailable. Enter your own venue." }, 502);
      const places = result.features.flatMap((feature) => {
        const properties = feature.properties ?? {};
        // Some amenities lack a category. Keep those, but omit known non-food POIs.
        if (name && typeof properties.category === "string" &&
            properties.category !== "catering" &&
            !properties.category.startsWith("catering.")) return [];
        const lat = properties.lat;
        const lon = properties.lon;
        if (typeof properties.place_id !== "string" || !properties.place_id ||
            !Number.isFinite(lat) || !Number.isFinite(lon) ||
            Math.abs(lat) > 90 || Math.abs(lon) > 180) return [];
        return [{
          id: `geoapify:${properties.place_id}`,
          name: typeof properties.name === "string" ? properties.name : "Restaurant or cafe",
          address: typeof properties.formatted === "string" ? properties.formatted : "",
          latitude: lat,
          longitude: lon,
        }];
      }).slice(0, 10);
      return json({ places });
    } catch {
      return json({ error: "Venue lookup unavailable. Enter your own venue." }, 503);
    }
  };
}
