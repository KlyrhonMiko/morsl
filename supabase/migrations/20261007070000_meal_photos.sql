-- Keep all source photos on the shared meal asset.
alter table public.meal_assets add column photos jsonb not null default '[]'::jsonb;
alter table public.meal_assets add constraint meal_photos_array check (jsonb_typeof(photos) = 'array');

create or replace function public.save_memory(payload jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  meal uuid := (payload->>'id')::uuid;
  uid uuid := auth.uid();
  shared meals%rowtype;
  personal personal_memories%rowtype;
  fingerprint text := md5(payload::text);
  detail jsonb;
  presentation jsonb;
  label text;
  photo jsonb;
begin
  if uid is null then raise exception 'Sign in required'; end if;
  select * into shared from meals where id=meal for update;
  if not found then raise exception 'Reserve the meal before uploading'; end if;
  if not can_access_meal(meal) then raise exception 'Membership required'; end if;
  select * into personal from personal_memories where meal_id=meal and user_id=uid for update;
  if personal.last_payload=fingerprint then
    return jsonb_build_object('mealRevision',shared.revision,'memoryRevision',personal.revision);
  end if;
  if coalesce(personal.revision,0)<>coalesce((payload->>'memoryRevision')::int,0) then
    raise exception 'Personal memory conflict. Keep this local edit and review the version on your other device.';
  end if;
  if shared.creator=uid then
    if shared.revision<>coalesce((payload->>'mealRevision')::int,0) then
      raise exception 'Shared meal conflict. Keep this local edit and review the version on your other device.';
    end if;
    detail := jsonb_build_object('createdAt',payload->'createdAt','venue',payload->'venue',
      'placeId',payload->'placeId','companions',payload->'companions','latitude',payload->'latitude',
      'longitude',payload->'longitude','accuracy',payload->'accuracy','measuredAt',payload->'measuredAt',
      'locationConfirmed',payload->'locationConfirmed');
    update meals set details=detail,revision=revision+1,updated_at=now() where id=meal returning * into shared;
    delete from companion_labels where meal_id=meal;
    for label in select jsonb_array_elements_text(coalesce(payload->'companions','[]')) loop
      insert into companion_labels values(meal,label) on conflict do nothing;
    end loop;
    if coalesce(payload->>'original','')<>'' then
    -- Never accept storage references to another meal.
    if split_part(payload->>'original','/',1)<>meal::text or
       (payload->>'cutout' is not null and split_part(payload->>'cutout','/',1)<>meal::text) or
       (payload->>'thumbnail' is not null and split_part(payload->>'thumbnail','/',1)<>meal::text) then
      raise exception 'Invalid asset path';
    end if;
    for photo in select jsonb_array_elements(coalesce(payload->'photos','[]'::jsonb)) loop
      if coalesce(photo->>'id','') = '' or coalesce(photo->>'original','') = '' or
         split_part(photo->>'original','/',1) <> meal::text then
        raise exception 'Invalid photo path';
      end if;
    end loop;
    insert into meal_assets(id,meal_id,uploader,original,cutout,thumbnail,photos)
      values(coalesce((payload->>'assetId')::uuid,meal),meal,uid,payload->>'original',payload->>'cutout',payload->>'thumbnail',coalesce(payload->'photos','[]'::jsonb))
      on conflict(meal_id) do update set original=excluded.original,cutout=excluded.cutout,thumbnail=excluded.thumbnail,
        photos=case when payload ? 'photos' then excluded.photos else meal_assets.photos end
      where meal_assets.uploader=uid;
    end if;
  end if;
  presentation := payload - array['photos','original','cutout','thumbnail','scope','creator','assetId','createdAt','venue',
    'placeId','companions','latitude','longitude','accuracy','measuredAt','locationConfirmed','mealRevision','memoryRevision','error','runtime'];
  insert into personal_memories(meal_id,user_id,data,revision,last_payload)
    values(meal,uid,presentation,coalesce(personal.revision,0)+1,fingerprint)
    on conflict(meal_id,user_id) do update set data=excluded.data,revision=excluded.revision,last_payload=excluded.last_payload
    returning * into personal;
  return jsonb_build_object('mealRevision',shared.revision,'memoryRevision',personal.revision);
end;
$$;

create or replace function public.restore_memories() returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select m.details || p.data || jsonb_build_object('id',m.id,'creator',m.creator,'scope',auth.uid(),
    'assetId',a.id,'original',coalesce(a.original,''),'cutout',a.cutout,'thumbnail',a.thumbnail,'photos',coalesce(a.photos,'[]'::jsonb),
    'mealRevision',m.revision,'memoryRevision',p.revision)
  from personal_memories p join meals m on m.id=p.meal_id left join meal_assets a on a.meal_id=m.id
  where p.user_id=auth.uid() and can_access_meal(m.id);
$$;

