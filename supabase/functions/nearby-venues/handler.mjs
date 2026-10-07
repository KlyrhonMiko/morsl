// Provider results are returned live; the user chooses a venue to save.
export function createVenueHandler({ authenticate, apiKey, fetchPlaces = fetch,
  consumeSearch = async () => ({ allowed: false, reason: "disabled" }) }) {
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
      if (name.length < 2) return json({ places: [] });
      const key = apiKey();
      if (!key) return json({ error: "Restaurant search is not configured. Enter your own venue." }, 503);
      const reservation = await consumeSearch(user.id);
      if (reservation?.allowed !== true) {
        const message = reservation?.reason === "user_minute_limit"
          ? "Restaurant search is taking a short break. Try again in a minute, or enter your own venue."
          : reservation?.reason === "user_daily_limit"
          ? "You've reached today's restaurant search limit. Enter your own venue."
          : "Restaurant search is paused to stay within its free allowance. Enter your own venue.";
        return json({ error: message, code: reservation?.reason ?? "disabled" }, 429);
      }
      const url = new URL("https://autosuggest.search.hereapi.com/v1/autosuggest");
      url.search = new URLSearchParams({
        at: `${latitude},${longitude}`,
        q: name, limit: "10", apiKey: key,
      }).toString();
      // Meals may be edited after travelling home. Rank named branches by
      // distance without excluding venues outside the user's current area.
      const response = await fetchPlaces(url, { signal: AbortSignal.timeout(8000) });
      if (!response.ok) return json({ error: "Nearby places unavailable. Enter your own venue." }, 502);
      const result = await response.json();
      if (!Array.isArray(result.items)) return json({ error: "Nearby places unavailable. Enter your own venue." }, 502);
      const places = result.items.flatMap((item) => {
        if (item?.resultType !== "place") return [];
        // Only restaurant, cafe and bar suggestions can become meal locations.
        if (!Array.isArray(item.categories) || !item.categories.some(category =>
          typeof category.id === "string" &&
          (category.id.startsWith("100-") || category.id === "200-2000-0011"))) return [];
        const lat = item.position?.lat;
        const lon = item.position?.lng;
        if (typeof item.id !== "string" || !item.id.startsWith("here:") ||
            typeof item.title !== "string" || !item.title.trim() ||
            !Number.isFinite(lat) || !Number.isFinite(lon) ||
            Math.abs(lat) > 90 || Math.abs(lon) > 180) return [];
        return [{
          id: item.id,
          name: item.title,
          address: typeof item.address?.label === "string" ? item.address.label : "",
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
