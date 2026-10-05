-- morsl beta: private shared events, private personal presentations.
create table public.meals (
  id uuid primary key,
  creator uuid not null references auth.users(id),
  details jsonb not null default '{}',
  revision integer not null default 0,
  deleted_at timestamptz,
  updated_at timestamptz not null default now()
);
create table public.meal_memberships (
  meal_id uuid references public.meals(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  primary key(meal_id,user_id)
);
create table public.meal_assets (
  id uuid primary key,
  meal_id uuid not null unique references public.meals(id) on delete cascade,
  uploader uuid not null references auth.users(id),
  original text not null,
  cutout text,
  thumbnail text
);
create table public.companion_labels (
  meal_id uuid references public.meals(id) on delete cascade,
  name text not null,
  primary key(meal_id,name)
);
create table public.personal_memories (
  meal_id uuid references public.meals(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  data jsonb not null default '{}',
  revision integer not null default 0,
  last_payload text,
  primary key(meal_id,user_id)
);
create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid not null references public.meals(id) on delete cascade,
  sender uuid not null references auth.users(id),
  recipient uuid not null references auth.users(id),
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  unique(meal_id,recipient)
);
create index invitations_recipient_idx on public.invitations(recipient);
create index membership_user_idx on public.meal_memberships(user_id);

create function public.can_access_meal(meal uuid) returns boolean
language sql stable security definer set search_path=public,pg_temp as $$
  select auth.uid() is not null and exists(select 1 from meals m where m.id=meal and m.deleted_at is null and
    (m.creator=auth.uid() or exists(select 1 from meal_memberships where meal_id=meal and user_id=auth.uid())));
$$;
alter table public.meals enable row level security;
alter table public.meal_memberships enable row level security;
alter table public.meal_assets enable row level security;
alter table public.companion_labels enable row level security;
alter table public.personal_memories enable row level security;
alter table public.invitations enable row level security;
create policy meals_read on public.meals for select to authenticated using (can_access_meal(id));
create policy memberships_read on public.meal_memberships for select to authenticated using (can_access_meal(meal_id));
create policy assets_read on public.meal_assets for select to authenticated using (can_access_meal(meal_id));
create policy labels_read on public.companion_labels for select to authenticated using (can_access_meal(meal_id));
create policy memories_read on public.personal_memories for select to authenticated using (user_id=auth.uid() and can_access_meal(meal_id));
create policy invitations_read on public.invitations for select to authenticated using (sender=auth.uid() or recipient=auth.uid());
-- Writes go through revision-checked RPCs, not unrestricted table upserts.
revoke insert,update,delete on public.meals,public.meal_memberships,public.meal_assets,public.companion_labels,public.personal_memories,public.invitations from anon,authenticated;
grant select on public.meals,public.meal_memberships,public.meal_assets,public.companion_labels,public.personal_memories,public.invitations to authenticated;

create function public.reserve_meal(meal uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  insert into meals(id,creator) values(meal,auth.uid()) on conflict do nothing;
  if not exists(select 1 from meals where id=meal and creator=auth.uid() and deleted_at is null) then raise exception 'Creator access required or meal was deleted'; end if;
end;
$$;

create function public.save_memory(payload jsonb) returns jsonb
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
    insert into meal_assets(id,meal_id,uploader,original,cutout,thumbnail)
      values(coalesce((payload->>'assetId')::uuid,meal),meal,uid,payload->>'original',payload->>'cutout',payload->>'thumbnail')
      on conflict(meal_id) do update set original=excluded.original,cutout=excluded.cutout,thumbnail=excluded.thumbnail
      where meal_assets.uploader=uid;
    end if;
  end if;
  presentation := payload - array['original','cutout','thumbnail','scope','creator','assetId','createdAt','venue',
    'placeId','companions','latitude','longitude','accuracy','measuredAt','locationConfirmed','mealRevision','memoryRevision','error','runtime'];
  insert into personal_memories(meal_id,user_id,data,revision,last_payload)
    values(meal,uid,presentation,coalesce(personal.revision,0)+1,fingerprint)
    on conflict(meal_id,user_id) do update set data=excluded.data,revision=excluded.revision,last_payload=excluded.last_payload
    returning * into personal;
  return jsonb_build_object('mealRevision',shared.revision,'memoryRevision',personal.revision);
end;
$$;

create function public.restore_memories() returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select m.details || p.data || jsonb_build_object('id',m.id,'creator',m.creator,'scope',auth.uid(),
    'assetId',a.id,'original',coalesce(a.original,''),'cutout',a.cutout,'thumbnail',a.thumbnail,
    'mealRevision',m.revision,'memoryRevision',p.revision)
  from personal_memories p join meals m on m.id=p.meal_id left join meal_assets a on a.meal_id=m.id
  where p.user_id=auth.uid() and can_access_meal(m.id);
$$;

create function public.invite_to_meal(meal uuid,recipient_email text) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare recipient_id uuid;
begin
  if not exists(select 1 from meals where id=meal and creator=auth.uid()) then raise exception 'Only the creator can invite'; end if;
  if not exists(select 1 from meal_assets where meal_id=meal) then raise exception 'Back up the photos first'; end if;
  if exists(select 1 from personal_memories where meal_id=meal and user_id=auth.uid() and (data->>'draft')::boolean) then raise exception 'Save this memory before inviting'; end if;
  select id into recipient_id from auth.users where lower(email)=lower(trim(recipient_email));
  if recipient_id is null then raise exception 'No existing morsl account has that email'; end if;
  if recipient_id=auth.uid() then raise exception 'This is your own account'; end if;
  if exists(select 1 from meal_memberships where meal_id=meal and user_id=recipient_id) then raise exception 'Already at the table'; end if;
  insert into invitations(meal_id,sender,recipient) values(meal,auth.uid(),recipient_id)
    on conflict(meal_id,recipient) do update set status='pending',created_at=now();
end;
$$;

create function public.my_invitations() returns setof jsonb
language sql stable security definer set search_path=public,pg_temp as $$
  select jsonb_build_object('id',i.id,'meal_id',i.meal_id,'status',i.status,'venue',m.details->>'venue','sender_email',u.email)
  from invitations i join meals m on m.id=i.meal_id join auth.users u on u.id=i.sender
  where i.recipient=auth.uid() order by i.created_at desc;
$$;

create function public.respond_to_invitation(invitation uuid,accept boolean) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare i invitations%rowtype;
begin
  select * into i from invitations where id=invitation and recipient=auth.uid() for update;
  if not found then raise exception 'Invitation unavailable'; end if;
  if i.status<>'pending' then return; end if;
  update invitations set status=case when accept then 'accepted' else 'declined' end where id=invitation;
  if accept then
    insert into meal_memberships values(i.meal_id,auth.uid()) on conflict do nothing;
    insert into personal_memories(meal_id,user_id,data,revision)
      values(i.meal_id,auth.uid(),'{"caption":"","feeling":"happy","bookmarked":false,"draft":false,"archived":false,"useOriginal":true,"background":"cream","layout":"classic","x":0,"y":0,"scale":1,"rotation":0}',1)
      on conflict do nothing;
  end if;
end;
$$;

create function public.leave_meal(meal uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if exists(select 1 from meals where id=meal and creator=auth.uid()) then raise exception 'Creators must delete a meal to leave it'; end if;
  delete from personal_memories where meal_id=meal and user_id=auth.uid();
  delete from meal_memberships where meal_id=meal and user_id=auth.uid();
  update invitations set status='declined' where meal_id=meal and recipient=auth.uid();
end;
$$;

create function public.revoke_member(meal uuid,participant uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not exists(select 1 from meals where id=meal and creator=auth.uid()) then raise exception 'Creator access required'; end if;
  delete from personal_memories where meal_id=meal and user_id=participant;
  delete from meal_memberships where meal_id=meal and user_id=participant;
  update invitations set status='declined' where meal_id=meal and recipient=participant;
end;
$$;

create function public.delete_meal(meal uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not exists(select 1 from meals where id=meal and creator=auth.uid()) then raise exception 'Creator access required'; end if;
  update meals set deleted_at=now(),revision=revision+1 where id=meal and creator=auth.uid();
  delete from meal_memberships where meal_id=meal;
  delete from personal_memories where meal_id=meal;
  delete from invitations where meal_id=meal;
  delete from companion_labels where meal_id=meal;
  delete from meal_assets where meal_id=meal;
end;
$$;

create function public.remove_my_asset(meal uuid) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not exists(select 1 from meal_assets where meal_id=meal and uploader=auth.uid()) then raise exception 'Only the uploader can remove this photo'; end if;
  delete from meal_assets where meal_id=meal and uploader=auth.uid();
  update meals set revision=revision+1,updated_at=now() where id=meal;
end;
$$;

insert into storage.buckets(id,name,public) values('meal-images','meal-images',false) on conflict(id) do nothing;
create policy meal_images_read on storage.objects for select to authenticated using (
  bucket_id='meal-images' and can_access_meal(case when (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$' then (storage.foldername(name))[1]::uuid else null end)
  and (owner_id=auth.uid()::text or exists(select 1 from meal_assets a where a.original=name or a.cutout=name or a.thumbnail=name))
);
create policy meal_images_insert on storage.objects for insert to authenticated with check (
  bucket_id='meal-images' and exists(select 1 from meals where id::text=(storage.foldername(name))[1] and creator=auth.uid() and deleted_at is null)
);
create policy meal_images_update on storage.objects for update to authenticated using (
  bucket_id='meal-images' and owner_id=auth.uid()::text and exists(select 1 from meals where id::text=(storage.foldername(name))[1] and creator=auth.uid() and deleted_at is null)
) with check (bucket_id='meal-images' and owner_id=auth.uid()::text and exists(select 1 from meals where id::text=(storage.foldername(name))[1] and creator=auth.uid() and deleted_at is null));
create policy meal_images_delete on storage.objects for delete to authenticated using (bucket_id='meal-images' and owner_id=auth.uid()::text);

-- No anonymous invocation of SECURITY DEFINER functions.
revoke all on function public.can_access_meal(uuid),public.reserve_meal(uuid),public.save_memory(jsonb),public.restore_memories(),
  public.invite_to_meal(uuid,text),public.my_invitations(),public.respond_to_invitation(uuid,boolean),
  public.leave_meal(uuid),public.revoke_member(uuid,uuid),public.delete_meal(uuid),public.remove_my_asset(uuid) from public,anon;
grant execute on function public.can_access_meal(uuid),public.reserve_meal(uuid),public.save_memory(jsonb),public.restore_memories(),
  public.invite_to_meal(uuid,text),public.my_invitations(),public.respond_to_invitation(uuid,boolean),
  public.leave_meal(uuid),public.revoke_member(uuid,uuid),public.delete_meal(uuid),public.remove_my_asset(uuid) to authenticated;
