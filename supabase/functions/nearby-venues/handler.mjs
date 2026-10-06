// Provider results are returned live. The app keeps only the selected place ID.
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
      const { latitude, longitude } = body ?? {};
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude) ||
          Math.abs(latitude) > 90 || Math.abs(longitude) > 180) {
        return json({ error: "Valid coordinates required" }, 400);
      }
      const key = apiKey();
      if (!key) return json({ error: "Venue lookup is not configured" }, 503);
      const url = new URL("https://api.geoapify.com/v2/places");
      url.search = new URLSearchParams({
        categories: "catering.restaurant,catering.cafe",
        filter: `circle:${longitude},${latitude},250`,
        bias: `proximity:${longitude},${latitude}`,
        limit: "10", apiKey: key,
      }).toString();
      const response = await fetchPlaces(url, { signal: AbortSignal.timeout(6000) });
      if (!response.ok) return json({ error: "Nearby places unavailable. Enter your own venue." }, 502);
      const result = await response.json();
      if (!Array.isArray(result.features)) return json({ error: "Nearby places unavailable. Enter your own venue." }, 502);
      const places = result.features.slice(0, 10).flatMap((feature) => {
        const properties = feature.properties ?? {};
        if (typeof properties.place_id !== "string" || !properties.place_id) return [];
        return [{
          id: `geoapify:${properties.place_id}`,
          name: typeof properties.name === "string" ? properties.name : "Restaurant or cafe",
          address: typeof properties.formatted === "string" ? properties.formatted : "",
        }];
      });
      return json({ places });
    } catch {
      return json({ error: "Venue lookup unavailable. Enter your own venue." }, 503);
    }
  };
}
