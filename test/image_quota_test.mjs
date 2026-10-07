import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
const runtime = process.argv[2] ?? path.join(os.tmpdir(), 'morsl-postgres-verification');
const { PGlite } = createRequire(path.join(runtime, 'package.json'))('@electric-sql/pglite');
const db = new PGlite();
const meal = '00000000-0000-4000-8000-000000000010';
let checks = 0;
const equal = (actual, expected) => { assert.equal(actual, expected); checks++; };
const result = async (sql, params = []) => (await db.query(sql, params)).rows[0].result;
const reserve = (key, size) => result('select public.reserve_image($1,$2) result',[`${meal}/${key}`,size]);
const used = () => result('select used_bytes result from public.image_storage_budget');
try {
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    grant usage on schema public to service_role, anon, authenticated;
    create table public.meals(id uuid primary key); insert into public.meals values ('${meal}');`);
  await db.exec(await readFile(new URL('../supabase/migrations/20261007012718_image_storage_quota.sql',import.meta.url),'utf8'));
  equal(await reserve('first',100), 'reserved');
  equal(await reserve('first',100), 'reserved');
  equal(await used(),100); // Retry does not double-count.
  equal(await reserve('first',101),'unavailable');
  equal(await result('select public.confirm_image($1,101) result',[`${meal}/first`]),false);
  equal(await result('select public.confirm_image($1,100) result',[`${meal}/first`]),true);
  equal(await used(),100); // Confirmation does not count bytes twice.
  // Near-full fixture represents other accounts' already reserved objects.
  await db.exec('update public.image_storage_budget set used_bytes=8999999900');
  equal(await reserve('boundary',100),'reserved');
  equal(await used(),9000000000);
  equal(await reserve('overflow',1),'full');
  equal(await reserve('boundary',100),'reserved'); // Retry works even at capacity.
  equal(await result('select public.begin_image_delete($1) result',[`${meal}/boundary`]),false);
  await db.query("update public.image_storage_objects set grant_until=now()-interval '25 hours' where key=$1",[`${meal}/boundary`]);
  equal(await result('select public.begin_image_delete($1) result',[`${meal}/boundary`]),true);
  equal(await result('select public.begin_image_delete($1) result',[`${meal}/boundary`]),false); // Exclusive cleaner.
  equal(await reserve('boundary',100),'unavailable');
  equal(await used(),9000000000); // Claimed deletion still counts until R2 acknowledges.
  await db.query('select public.cancel_image_delete($1)',[`${meal}/boundary`]);
  equal(await used(),9000000000);
  equal(await result('select public.begin_image_delete($1) result',[`${meal}/boundary`]),true);
  equal(await result('select public.finish_image_delete($1) result',[`${meal}/boundary`]),true);
  equal(await result('select public.finish_image_delete($1) result',[`${meal}/boundary`]),false);
  equal(await used(),8999999900);
  equal(await reserve('new-user',100),'reserved');
  for (const role of ['anon','authenticated']) {
    await db.exec(`set role ${role}`);
    for (const sql of ['select * from public.image_storage_budget',`select public.reserve_image('${meal}/bypass',1)`]) {
      await assert.rejects(db.query(sql),/permission denied/); checks++;
    }
    await db.exec('reset role');
  }
  await db.exec('set role service_role');
  equal(await reserve('boundary',1),'full');
  console.log(`${checks} PostgreSQL quota checks passed`);
} finally { await db.close(); }
