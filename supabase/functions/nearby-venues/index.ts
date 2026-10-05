// Provider results are returned live, never persisted. Only place IDs are kept.
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST required", { status: 405 });
  const authorization = req.headers.get("Authorization") ?? "";
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return Response.json({ error: "Sign in required" }, { status: 401 });
  try {
    const { latitude, longitude } = await req.json();
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || Math.abs(latitude) > 90 || Math.abs(longitude) > 180) {
      return Response.json({ error: "Valid coordinates required" }, { status: 400 });
    }
    const key = Deno.env.get("GOOGLE_PLACES_API_KEY");
    if (!key) return Response.json({ error: "Venue lookup is not configured" }, { status: 503 });
    const response = await fetch("https://places.googleapis.com/v1/places:searchNearby", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key,
        "X-Goog-FieldMask": "places.id,places.displayName,places.formattedAddress,places.attributions" },
      body: JSON.stringify({ includedTypes: ["restaurant", "cafe"], maxResultCount: 10,
        locationRestriction: { circle: { center: { latitude, longitude }, radius: 250 } } }),
      signal: AbortSignal.timeout(6000),
    });
    if (!response.ok) return Response.json({ error: "Nearby places unavailable. Enter your own venue." }, { status: 502 });
    return Response.json(await response.json(), { headers: { "Cache-Control": "no-store" } });
  } catch {
    return Response.json({ error: "Venue lookup unavailable. Enter your own venue." }, { status: 503 });
  }
});
