create schema if not exists private;

create table public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender uuid not null references auth.users(id) on delete cascade,
  recipient uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  constraint friend_requests_no_self check (sender <> recipient)
);
create unique index friend_requests_pair_idx on public.friend_requests
  (least(sender, recipient), greatest(sender, recipient));
create index friend_requests_sender_idx on public.friend_requests(sender);
create index friend_requests_recipient_idx on public.friend_requests(recipient);
alter table public.friend_requests enable row level security;
create policy friend_requests_read on public.friend_requests for select to authenticated
  using (sender = (select auth.uid()) or recipient = (select auth.uid()));
revoke all on public.friend_requests from anon, authenticated;
grant select on public.friend_requests to authenticated;

create function private.friend_account() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not exists (
    select 1 from auth.users u where u.id = uid and not coalesce(u.is_anonymous, false)
      and (u.raw_app_meta_data->>'provider' = 'google' or u.raw_app_meta_data->'providers' ? 'google')
  ) then raise exception 'Sign in with Google required'; end if;
  return uid;
end;
$$;
revoke all on function private.friend_account() from public, anon, authenticated;

create function private.request_friend(recipient_email text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.friend_account(); target uuid; saved uuid;
begin
  if length(trim(recipient_email)) > 254 or position('@' in trim(recipient_email)) < 2 then
    raise exception 'Enter a valid account email';
  end if;
  select u.id into target from auth.users u
    where lower(u.email) = lower(trim(recipient_email)) and not coalesce(u.is_anonymous, false)
      and (u.raw_app_meta_data->>'provider' = 'google' or u.raw_app_meta_data->'providers' ? 'google');
  if target is null then raise exception 'No existing morsl account has that email'; end if;
  if target = uid then raise exception 'This is your own account'; end if;
  insert into public.friend_requests(sender, recipient) values(uid, target)
    on conflict (least(sender, recipient), greatest(sender, recipient)) do update
      set sender = excluded.sender, recipient = excluded.recipient, status = 'pending', created_at = now()
      where friend_requests.status = 'declined'
    returning id into saved;
  if saved is null then raise exception 'Already friends or a friend request is pending'; end if;
end;
$$;

create function private.my_friends() returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := private.friend_account();
begin
  return query select jsonb_build_object(
    'id', f.id, 'account_id', u.id, 'email', u.email,
    'name', coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), nullif(u.raw_user_meta_data->>'name', ''), u.email),
    'status', f.status, 'direction', case when f.recipient = uid then 'incoming' else 'outgoing' end
  ) from public.friend_requests f
    join auth.users u on u.id = case when f.sender = uid then f.recipient else f.sender end
    where (f.sender = uid or f.recipient = uid) and f.status in ('pending', 'accepted')
    order by f.created_at desc;
end;
$$;

create function private.respond_to_friend_request(friendship uuid, accept boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.friend_account(); request public.friend_requests%rowtype;
begin
  select * into request from public.friend_requests where id = friendship and recipient = uid for update;
  if not found then raise exception 'Friend request unavailable'; end if;
  if request.status <> 'pending' then return; end if;
  update public.friend_requests set status = case when accept then 'accepted' else 'declined' end where id = friendship;
end;
$$;

create function private.remove_friend(friendship uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.friend_account();
begin
  delete from public.friend_requests where id = friendship and (sender = uid or recipient = uid);
  if not found then raise exception 'Friend connection unavailable'; end if;
end;
$$;

create function public.request_friend(recipient_email text) returns void
language sql security invoker set search_path = '' as $$ select private.request_friend(recipient_email) $$;
create function public.my_friends() returns setof jsonb
language sql stable security invoker set search_path = '' as $$ select private.my_friends() $$;
create function public.respond_to_friend_request(friendship uuid, accept boolean) returns void
language sql security invoker set search_path = '' as $$ select private.respond_to_friend_request(friendship, accept) $$;
create function public.remove_friend(friendship uuid) returns void
language sql security invoker set search_path = '' as $$ select private.remove_friend(friendship) $$;

revoke all on function private.request_friend(text), private.my_friends(),
  private.respond_to_friend_request(uuid, boolean), private.remove_friend(uuid),
  public.request_friend(text), public.my_friends(), public.respond_to_friend_request(uuid, boolean), public.remove_friend(uuid)
  from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.request_friend(text), private.my_friends(),
  private.respond_to_friend_request(uuid, boolean), private.remove_friend(uuid),
  public.request_friend(text), public.my_friends(), public.respond_to_friend_request(uuid, boolean), public.remove_friend(uuid)
  to authenticated;
