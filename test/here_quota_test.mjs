import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
const runtime = process.argv[2] ?? path.join(os.tmpdir(), 'morsl-postgres-verification');
const { PGlite } = createRequire(path.join(runtime, 'package.json'))('@electric-sql/pglite');
const db = new PGlite();
const first = '00000000-0000-4000-8000-000000000001';
const second = '00000000-0000-4000-8000-000000000002';
let checks = 0;
const equal = (actual, expected) => { assert.deepEqual(actual, expected); checks++; };
const result = async (sql, params=[]) => (await db.query(sql,params)).rows[0].result;
const reserve = (user=first) => result('select public.consume_here_search($1) result',[user]);
const used = () => result('select coalesce(sum(requests),0)::integer result from public.here_search_usage');
const reset = async (settings='max_requests_32days=4000, per_user_daily=100, per_user_minute=10') => {
  await db.exec(`reset role; truncate public.here_search_usage,public.here_search_requests;
    update public.here_search_budget set enabled=true,max_requests_32days=4000,per_user_daily=100,per_user_minute=10;
    update public.here_search_budget set ${settings}; set role service_role;`);
};
try {
  await db.exec('create role anon; create role authenticated; create role service_role bypassrls; grant usage on schema public to service_role,anon,authenticated;');
  await db.exec(await readFile(new URL('../supabase/migrations/20261007170446_here_search_limits.sql',import.meta.url),'utf8'));
  await db.exec('set role service_role');
  equal(await reserve(),{allowed:false,reason:'disabled'});
  equal(await used(),0);
  await reset('max_requests_32days=0');
  equal(await reserve(),{allowed:false,reason:'disabled'});
  await reset('max_requests_32days=2');
  equal(await reserve(),{allowed:true});
  equal(await reserve(second),{allowed:true});
  equal(await reserve(),{allowed:false,reason:'shared_limit'});
  equal(await used(),2);
  await reset('max_requests_32days=4000,per_user_daily=1');
  equal(await reserve(),{allowed:true});
  equal(await reserve(),{allowed:false,reason:'user_daily_limit'});
  equal(await reserve(second),{allowed:true});
  equal(await used(),2);
  await reset('max_requests_32days=4000,per_user_daily=100,per_user_minute=1');
  equal(await reserve(),{allowed:true});
  equal(await reserve(),{allowed:false,reason:'user_minute_limit'});
  await db.exec("reset role; update public.here_search_requests set requested_at=clock_timestamp()-interval '61 seconds'; set role service_role;");
  equal(await reserve(),{allowed:true});
  await reset('max_requests_32days=1');
  await db.exec("reset role; insert into public.here_search_usage values ((now() at time zone 'UTC')::date-31,1); set role service_role;");
  equal(await reserve(),{allowed:false,reason:'shared_limit'});
  await db.exec("reset role; update public.here_search_usage set day=day-1; set role service_role;");
  equal(await reserve(),{allowed:true});
  // Queued competing reservations cannot exceed the shared budget.
  await reset('max_requests_32days=3');
  const competing = await Promise.all(Array.from({length:8},()=>reserve()));
  equal(competing.filter(r=>r.allowed).length,3);
  equal(await used(),3);
  await assert.rejects(db.query('update public.here_search_budget set enabled=false'),/permission denied/);checks++;
  await assert.rejects(db.query('update public.here_search_budget set max_requests_32days=99999'),/permission denied/);checks++;
  await assert.rejects(reserve(null),/User required/);checks++;
  for(const role of ['anon','authenticated']) {
    await db.exec(`reset role; set role ${role}`);
    for(const sql of ['select * from public.here_search_budget',`select public.consume_here_search('${first}')`,
      'update public.here_search_usage set requests=0']) {
      await assert.rejects(db.query(sql),/permission denied/);checks++;
    }
  }
  await db.exec('reset role; delete from public.here_search_budget; set role service_role');
  await assert.rejects(reserve(),/HERE budget missing/);checks++;
  console.log(`${checks} HERE PostgreSQL safeguards passed`);
} finally { await db.close(); }
