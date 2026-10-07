import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
const {PGlite}=createRequire(path.join(os.tmpdir(),'morsl-postgres-verification','package.json'))('@electric-sql/pglite');
const db=new PGlite();
let checks=0;
const equal=(a,b)=>{assert.equal(a,b);checks++;};
const consume=async kind=>(await db.query('select public.consume_image_operation($1) result',[kind])).rows[0].result;
try {
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    grant usage on schema public to anon,authenticated,service_role;
    create table public.image_storage_budget(id boolean primary key); insert into public.image_storage_budget values(true);
    grant select,update on public.image_storage_budget to service_role;`);
  await db.exec(await readFile(new URL('../supabase/migrations/20261007015052_image_operation_limits.sql',import.meta.url),'utf8'));
  equal(await consume('A'),true); equal(await consume('B'),true);
  const day="(now() at time zone 'UTC')::date";
  await db.exec(`update public.image_operation_usage set requests=case class when 'A' then 899999 else 8999999 end`);
  for(const kind of ['A','B']) { const attempts=await Promise.all([consume(kind),consume(kind)]); equal(attempts.filter(Boolean).length,1); equal(await consume(kind),false); }
  // Month boundaries do not clear the allowance: the previous 31 dates count.
  await db.exec(`delete from public.image_operation_usage; insert into public.image_operation_usage values (${day}-31,'A',900000)`);
  equal(await consume('A'),false);
  await db.exec(`update public.image_operation_usage set day=${day}-32`);
  equal(await consume('A'),true);
  equal(await consume('B'),true);
  for(const role of ['anon','authenticated']) {
    await db.exec(`set role ${role}`);
    await assert.rejects(consume('A'),/permission denied/);checks++;
    await assert.rejects(db.query('select * from public.image_operation_usage'),/permission denied/);checks++;
    await db.exec('reset role');
  }
  await db.exec('set role service_role'); equal(await consume('B'),true);
  await assert.rejects(consume('invalid'),/Invalid operation/);checks++;
  console.log(`${checks} PostgreSQL operation-limit checks passed`);
} finally {await db.close();}
