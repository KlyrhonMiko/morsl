-- One budget for the entire private, initially empty R2 bucket. Pending bytes
-- count immediately; no device or user can modify this service-only ledger.
create table public.image_storage_budget (
  id boolean primary key default true check (id),
  used_bytes bigint not null default 0 check (used_bytes between 0 and 9000000000)
);
insert into public.image_storage_budget(id) values (true);
create table public.image_storage_objects (
  key text primary key,
  meal_id uuid not null references public.meals(id),
  bytes bigint not null check (bytes between 1 and 20971520),
  confirmed boolean not null default false,
  grant_until timestamptz not null,
  deleting boolean not null default false
);
create index image_storage_objects_meal on public.image_storage_objects(meal_id, key);
alter table public.image_storage_budget enable row level security;
alter table public.image_storage_objects enable row level security;
revoke all on public.image_storage_budget, public.image_storage_objects from public, anon, authenticated;
grant select, insert, update, delete on public.image_storage_budget, public.image_storage_objects to service_role;

create function public.reserve_image(p_key text, p_bytes bigint) returns text
language plpgsql security invoker set search_path = '' as $$
declare v_used bigint; v_object public.image_storage_objects;
begin
  if p_bytes is null or p_bytes < 1 or p_bytes > 20971520 then
    raise exception 'Invalid image size';
  end if;
  -- Every allocation and release locks the same singleton first. This makes
  -- simultaneous uploads across all accounts share one atomic ceiling.
  select used_bytes into strict v_used from public.image_storage_budget where id for update;
  select * into v_object from public.image_storage_objects where key = p_key for update;
  if found then
    if v_object.bytes <> p_bytes or v_object.deleting then return 'unavailable'; end if;
    update public.image_storage_objects set grant_until = now() + interval '5 minutes'
      where key = p_key;
    return 'reserved';
  end if;
  if v_used + p_bytes > 9000000000 then return 'full'; end if;
  insert into public.image_storage_objects(key, meal_id, bytes, grant_until)
    values (p_key, split_part(p_key, '/', 1)::uuid, p_bytes, now() + interval '5 minutes');
  update public.image_storage_budget set used_bytes = v_used + p_bytes where id;
  return 'reserved';
end $$;

-- p_bytes must come from R2 HEAD, never from an unverified client claim.
create function public.confirm_image(p_key text, p_bytes bigint) returns boolean
language plpgsql security invoker set search_path = '' as $$
begin
  update public.image_storage_objects set confirmed = true
    where key = p_key and bytes = p_bytes and not deleting;
  return found;
end $$;

create function public.begin_image_delete(p_key text) returns boolean
language plpgsql security invoker set search_path = '' as $$
begin
  perform 1 from public.image_storage_budget where id for update;
  -- Wait a full day after the last PUT grant expires, including for deleted
  -- meals. Never release a reservation while its URL can still write bytes.
  update public.image_storage_objects set deleting = true
    where key = p_key and not deleting and grant_until < now() - interval '24 hours';
  return found;
end $$;

-- Call ONLY after R2 successfully acknowledges DELETE. Failed deletes leave
-- the entry charged and block new upload grants until cleanup retries.
create function public.finish_image_delete(p_key text) returns boolean
language plpgsql security invoker set search_path = '' as $$
declare v_bytes bigint;
begin
  perform 1 from public.image_storage_budget where id for update;
  delete from public.image_storage_objects where key = p_key and deleting returning bytes into v_bytes;
  if not found then return false; end if;
  update public.image_storage_budget set used_bytes = used_bytes - v_bytes where id;
  return true;
end $$;
create function public.cancel_image_delete(p_key text) returns void
language sql security invoker set search_path = '' as $$
  update public.image_storage_objects set deleting = false where key = p_key and deleting;
$$;
revoke all on function public.reserve_image(text,bigint), public.confirm_image(text,bigint),
  public.begin_image_delete(text), public.finish_image_delete(text), public.cancel_image_delete(text) from public, anon, authenticated;
grant execute on function public.reserve_image(text,bigint), public.confirm_image(text,bigint),
  public.begin_image_delete(text), public.finish_image_delete(text), public.cancel_image_delete(text) to service_role;
