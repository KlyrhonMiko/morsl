import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { createVenueHandler } from "./handler.mjs";

Deno.serve(createVenueHandler({
  apiKey: () => Deno.env.get("HERE_API_KEY"),
  consumeSearch: async (userId: string) => {
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );
    const { data, error } = await admin.rpc("consume_here_search", { p_user_id: userId });
    if (error) throw error; // Missing migration, timeouts and errors block HERE calls.
    return data;
  },
  authenticate: async (token: string) => {
    const client = createClient(
      Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );
    const { data: { user }, error } = await client.auth.getUser(token);
    return error ? null : user;
  },
}));
