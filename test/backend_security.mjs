import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
const runtime = process.argv[2] ?? path.join(os.tmpdir(), 'morsl-postgres-verification');
const { PGlite } = createRequire(path.join(runtime, 'package.json'))('@electric-sql/pglite');
const db = new PGlite();
const A='00000000-0000-4000-8000-000000000001';
const B='00000000-0000-4000-8000-000000000002';
const C='00000000-0000-4000-8000-000000000003';
const M='00000000-0000-4000-8000-000000000010';
const asset='00000000-0000-4000-8000-000000000011';
let checks=0;
function check(condition, message) { assert.ok(condition,message); checks++; console.log(`PASS ${message}`); }
async function as(uid) { await db.exec(`RESET ROLE; SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','${uid}',false);`); }
async function rows(sql, params=[]) { return (await db.query(sql,params)).rows; }
async function rejected(sql, params, pattern, message) {
  try { await db.query(sql,params); assert.fail(message); }
  catch(e) { check(pattern.test(e.message),message); }
}
try {
  await db.exec(`
    CREATE ROLE anon; CREATE ROLE authenticated;
    CREATE SCHEMA auth; CREATE SCHEMA storage;
    CREATE TABLE auth.users(id uuid PRIMARY KEY,email text);
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
      $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean);
    CREATE TABLE storage.objects(id uuid DEFAULT gen_random_uuid(),bucket_id text,name text,owner_id text);
    ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
    CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS
      $$ SELECT string_to_array(regexp_replace(name,'/[^/]*$',''),'/') $$;
    GRANT USAGE ON SCHEMA public,auth,storage TO authenticated,anon;
    GRANT SELECT,INSERT,UPDATE,DELETE ON storage.objects TO authenticated;
    INSERT INTO auth.users VALUES ('${A}','a@example.test'),('${B}','b@example.test'),('${C}','c@example.test');
  `);
  const migration=await readFile(new URL('../supabase/migrations/202610050001_beta.sql',import.meta.url),'utf8');
  await db.exec(migration);
  check(true,'migration compiles in PostgreSQL');
  await as(A);
  await db.query('SELECT public.reserve_meal($1)',[M]);
  const original=`${M}/${asset}/original-digest.jpg`;
  await db.query('INSERT INTO storage.objects(bucket_id,name,owner_id) VALUES ($1,$2,$3)',['meal-images',original,A]);
  const plates=[{id:'plate-a',mask:'alpha-mask',left:.1,top:.2,width:.3,height:.4,x:.2,y:.15,scale:.6,rotation:.3}];
  const payload={plates,platesEdited:true,id:M,scope:A,creator:A,assetId:asset,createdAt:'2026-10-05T12:00:00',original,cutout:null,thumbnail:null,
    venue:'Our own venue label',placeId:null,companions:['Jamie'],caption:'Creator caption',feeling:'cozy',bookmarked:true,draft:false,
    archived:false,useOriginal:true,background:'sage',layout:'classic',x:.1,y:0,scale:.9,rotation:0,latitude:14.55,longitude:121.02,
    accuracy:10,measuredAt:'2026-10-05T12:00:00',locationConfirmed:true,mealRevision:0,memoryRevision:0,demo:false};
  const save=async p => (await rows('SELECT public.save_memory($1::jsonb) result',[JSON.stringify(p)]))[0].result;
  const first=await save(payload);
  check(first.mealRevision===1 && first.memoryRevision===1,'first backup creates a single revision');
  await db.query('INSERT INTO storage.objects(bucket_id,name,owner_id) VALUES ($1,$2,$3)',['meal-images',`${M}/${asset}/old-cutout.png`,A]);
  const own=(await rows('SELECT public.restore_memories() memory'))[0].memory;
  check(own.plates[0].mask==='alpha-mask' && own.plates[0].rotation===.3,'plate masks and independent placement survive private backup');
  const replay=await save(payload);
  check(replay.mealRevision===1 && replay.memoryRevision===1,'interrupted acknowledgement retries idempotently');
  await rejected('SELECT public.save_memory($1::jsonb)',[JSON.stringify({...payload,caption:'Stale edit'})],/conflict/i,'stale revisions preserve the remote memory');
  await db.query('SELECT public.invite_to_meal($1,$2)',[M,'b@example.test']);
  await as(B);
  check((await rows('SELECT * FROM public.meal_assets')).length===0,'pending invitation does not expose asset rows');
  check((await rows('SELECT * FROM storage.objects')).length===0,'pending invitation does not expose private images');
  const invite=(await rows('SELECT public.my_invitations() invitation'))[0].invitation;
  await db.query('SELECT public.respond_to_invitation($1,true)',[invite.id]);
  check((await rows('SELECT * FROM public.meal_assets')).length===1,'acceptance grants shared asset access');
  check((await rows('SELECT * FROM storage.objects')).length===1,'acceptance grants current private image access');
  check((await rows('SELECT * FROM storage.objects WHERE name LIKE $1',['%old-cutout%'])).length===0,'members cannot read unreferenced image versions');
  let shared=(await rows('SELECT public.restore_memories() memory'))[0].memory;
  check(!shared.plates || shared.plates.length===0,'recipient does not receive creator personal plate edits');
  check(shared.caption==='' && shared.background==='cream','recipient begins with separate personal annotations');
  const bPayload={...shared,plates:[{...plates[0],id:'recipient-plate',rotation:-.5}],caption:'Recipient caption',background:'rose',venue:'Attempted shared change',archived:true};
  await save(bPayload);
  shared=(await rows('SELECT public.restore_memories() memory'))[0].memory;
  check(shared.caption==='Recipient caption' && shared.background==='rose','recipient can edit their own presentation');
  check(shared.plates[0].id==='recipient-plate','recipient can back up their own plate mask without uploading creator assets');
  check(shared.venue==='Our own venue label','recipient cannot overwrite creator-managed meal details');
  await as(A);
  let creator=(await rows('SELECT public.restore_memories() memory'))[0].memory;
  check(creator.plates[0].rotation===.3,'recipient plate edits do not alter creator plates');
  check(creator.caption==='Creator caption' && creator.archived===false,'recipient archive and annotation edits do not affect creator');
  await db.query('SELECT public.invite_to_meal($1,$2)',[M,'c@example.test']);
  await as(C);
  const decline=(await rows('SELECT public.my_invitations() invitation'))[0].invitation;
  await db.query('SELECT public.respond_to_invitation($1,false)',[decline.id]);
  check((await rows('SELECT * FROM public.meals')).length===0,'declining grants no membership');
  await rejected('SELECT public.save_memory($1::jsonb)',[JSON.stringify({...payload,scope:C})],/membership/i,'unauthorized account cannot write a meal');
  await as(B); await db.query('SELECT public.leave_meal($1)',[M]);
  check((await rows('SELECT * FROM storage.objects')).length===0,'leaving revokes future private image reads');
  await as(A);
  await db.query('SELECT public.invite_to_meal($1,$2)',[M,'b@example.test']);
  await as(B);
  const reinvite=(await rows('SELECT public.my_invitations() invitation'))[0].invitation;
  await db.query('SELECT public.respond_to_invitation($1,true)',[reinvite.id]);
  await as(A); await db.query('SELECT public.revoke_member($1,$2)',[M,B]); await as(B);
  check((await rows('SELECT * FROM storage.objects')).length===0,'creator revocation removes member image access');
  const M2='00000000-0000-4000-8000-000000000020',A2='00000000-0000-4000-8000-000000000021';
  await as(A); await db.query('SELECT public.reserve_meal($1)',[M2]);
  const original2=`${M2}/${A2}/original.jpg`;
  await db.query('INSERT INTO storage.objects(bucket_id,name,owner_id) VALUES ($1,$2,$3)',['meal-images',original2,A]);
  await save({...payload,id:M2,assetId:A2,original:original2});
  await db.query('SELECT public.invite_to_meal($1,$2)',[M2,'b@example.test']); await as(B);
  const photoInvite=(await rows('SELECT public.my_invitations() invitation')).find(r=>r.invitation.meal_id===M2).invitation;
  await db.query('SELECT public.respond_to_invitation($1,true)',[photoInvite.id]);
  const beforeRemoval=(await rows('SELECT public.restore_memories() memory')).find(r=>r.memory.id===M2).memory;
  await save({...beforeRemoval,caption:'Keep my own words'});
  await rejected('SELECT public.remove_my_asset($1)',[M2],/uploader/i,'participants cannot remove someone else’s photo');
  await as(A); await db.query('DELETE FROM storage.objects WHERE name=$1',[original2]);
  await db.query('SELECT public.remove_my_asset($1)',[M2]); await as(B);
  const afterRemoval=(await rows('SELECT public.restore_memories() memory')).find(r=>r.memory.id===M2).memory;
  check(afterRemoval.original==='' && afterRemoval.caption==='Keep my own words','uploader removal preserves participants’ personal memories');
  await as(A);
  await db.query('SELECT public.delete_meal($1)',[M]);
  check((await rows('SELECT * FROM public.meals WHERE id=$1',[M])).length===0,'creator deletion removes active meal access');
  await rejected('SELECT public.reserve_meal($1)',[M],/deleted|creator/i,'a stale device cannot resurrect a deleted meal');
  await db.exec('RESET ROLE; SET ROLE anon;');
  await rejected('SELECT public.restore_memories()',[],/permission denied/i,'anonymous callers cannot invoke private restoration');
  console.log(`${checks} backend checks passed. Auth and Storage service schemas are mocked; live two-account verification is still required.`);
} catch(e) { console.error(e.message); process.exitCode=1; }
finally { await db.close(); }
