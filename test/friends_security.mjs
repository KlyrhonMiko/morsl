import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';

const runtime = process.argv[2] ?? path.join(os.tmpdir(), 'morsl-postgres-verification');
const { PGlite } = createRequire(path.join(runtime, 'package.json'))('@electric-sql/pglite');
const db = new PGlite();
const A = '00000000-0000-4000-8000-000000000001';
const B = '00000000-0000-4000-8000-000000000002';
const C = '00000000-0000-4000-8000-000000000003';
const D = '00000000-0000-4000-8000-000000000004';
let checks = 0;
function check(condition, message) { assert.ok(condition, message); checks++; console.log(`PASS ${message}`); }
async function as(uid, role = 'authenticated') {
  await db.exec(`RESET ROLE; SET ROLE ${role}; SELECT set_config('request.jwt.claim.sub','${uid}',false)`);
}
async function reject(sql, params, pattern, message) {
  try { await db.query(sql, params); assert.fail(message); }
  catch (error) { check(pattern.test(error.message), message); }
}
async function friends() { return (await db.query('SELECT public.my_friends() AS friend')).rows.map(row => row.friend); }
try {
  await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth;
    CREATE TABLE auth.users(id uuid PRIMARY KEY, email text, is_anonymous boolean DEFAULT false,
      raw_app_meta_data jsonb DEFAULT '{"provider":"google"}', raw_user_meta_data jsonb DEFAULT '{}');
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
      $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    GRANT USAGE ON SCHEMA public,auth TO authenticated,anon;
    INSERT INTO auth.users(id,email) VALUES ('${A}','a@example.test'),('${B}','b@example.test'),('${C}','c@example.test');
    INSERT INTO auth.users(id,email,raw_app_meta_data) VALUES ('${D}','d@example.test','{"provider":"email"}');`);
  await db.exec(await readFile(new URL('../supabase/migrations/20261007052824_friends.sql', import.meta.url), 'utf8'));
  check(true, 'friend migration compiles in PostgreSQL');
  await as(A);
  await db.query('SELECT public.request_friend($1)', [' B@example.test ']);
  let list = await friends();
  check(list.length === 1 && list[0].status === 'pending' && list[0].direction === 'outgoing', 'sending a request does not create a friendship');
  const id = list[0].id;
  await reject('SELECT public.respond_to_friend_request($1,true)', [id], /unavailable/, 'sender cannot accept their own request');
  await reject('SELECT public.request_friend($1)', ['b@example.test'], /pending/, 'duplicate requests do not create multiple rows');
  await as(C);
  check((await friends()).length === 0, 'unrelated accounts cannot enumerate friends');
  check((await db.query('SELECT * FROM public.friend_requests')).rows.length === 0, 'RLS hides unrelated friendship records');
  await reject('SELECT public.respond_to_friend_request($1,true)', [id], /unavailable/, 'unrelated users cannot accept a request');
  await reject('DELETE FROM public.friend_requests', [], /permission denied/, 'direct writes cannot bypass friendship RPCs');
  await as(B);
  list = await friends();
  check(list[0].email === 'a@example.test' && list[0].direction === 'incoming', 'recipient sees the incoming request');
  await reject('SELECT public.request_friend($1)', ['a@example.test'], /pending/, 'a reciprocal request cannot auto-accept a pending request');
  await db.query('SELECT public.respond_to_friend_request($1,true)', [id]);
  check((await friends())[0].status === 'accepted', 'recipient can explicitly accept');
  await as(A);
  check((await friends())[0].status === 'accepted', 'accepted friends appear for both accounts');
  await reject('SELECT public.request_friend($1)', ['a@example.test'], /own account/, 'self friendship is rejected');
  await reject('SELECT public.request_friend($1)', ['missing@example.test'], /No existing/, 'requests require an existing account');
  await reject('SELECT public.request_friend($1)', ['d@example.test'], /No existing/, 'non-Google accounts cannot receive friend requests');
  await as(C);
  await reject('SELECT public.remove_friend($1)', [id], /unavailable/, 'unrelated accounts cannot remove friends');
  await as(A);
  await db.query('SELECT public.remove_friend($1)', [id]);
  await db.query('SELECT public.request_friend($1)', ['b@example.test']);
  const declined = (await friends())[0].id;
  await as(B);
  await db.query('SELECT public.respond_to_friend_request($1,false)', [declined]);
  check((await friends()).length === 0, 'declining does not add a friend');
  await as(A);
  check((await friends()).length === 0, 'declined requests disappear from the sender list');
  await db.query('SELECT public.request_friend($1)', ['b@example.test']);
  check((await friends())[0].status === 'pending', 'a declined connection can receive a fresh request');
  await as(D);
  await reject('SELECT public.my_friends()', [], /Google/, 'non-Google users cannot access the friends API');
  await as('', 'anon');
  await reject('SELECT public.my_friends()', [], /permission denied/, 'anonymous callers cannot execute friends RPCs');
  console.log(`${checks} friend security checks passed`);
} finally { await db.close(); }
