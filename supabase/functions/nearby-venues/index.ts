import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { createVenueHandler } from "./handler.mjs";

Deno.serve(createVenueHandler({
  apiKey: () => Deno.env.get("GEOAPIFY_PLACES_API_KEY"),
  authenticate: async (token: string) => {
    const client = createClient(
      Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );
    const { data: { user }, error } = await client.auth.getUser(token);
    return error ? null : user;
  },
}));
