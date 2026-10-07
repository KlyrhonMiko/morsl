-- Shared protection for HERE Autosuggest. No allowance is assumed on install.
create table public.here_search_budget (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  max_requests_32days bigint not null default 0 check (max_requests_32days >= 0),
  per_user_daily integer not null default 100 check (per_user_daily between 1 and 1000),
  per_user_minute integer not null default 10 check (per_user_minute between 1 and 100)
);
insert into public.here_search_budget(id) values (true);

create table public.here_search_usage (
  day date primary key,
  requests bigint not null check (requests >= 0)
);
create table public.here_search_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  requested_at timestamptz not null
);
create index here_search_requests_user_time
  on public.here_search_requests(user_id, requested_at desc);

alter table public.here_search_budget enable row level security;
alter table public.here_search_usage enable row level security;
alter table public.here_search_requests enable row level security;
revoke all on public.here_search_budget, public.here_search_usage,
  public.here_search_requests from public, anon, authenticated, service_role;
grant select on public.here_search_budget to service_role;
grant select, insert, update on public.here_search_usage to service_role;
grant select, insert on public.here_search_requests to service_role;
grant usage on sequence public.here_search_requests_id_seq to service_role;

create function public.consume_here_search(p_user_id uuid) returns jsonb
language plpgsql security invoker set search_path = '' set lock_timeout = '2s' as $$
declare
  v_budget public.here_search_budget%rowtype;
  v_now timestamptz;
  v_day date;
  v_count bigint;
begin
  if p_user_id is null then raise exception 'User required'; end if;
  -- Every reservation and budget edit locks the same real configuration row.
  -- SELECT FOR UPDATE needs UPDATE privilege, granted on one harmless column.
  select * into v_budget from public.here_search_budget where id for update;
  if not found then raise exception 'HERE budget missing'; end if;
  if not v_budget.enabled or v_budget.max_requests_32days = 0 then
    return jsonb_build_object('allowed', false, 'reason', 'disabled');
  end if;
  v_now := clock_timestamp();
  v_day := (v_now at time zone 'UTC')::date;
  -- 32 UTC dates conservatively cover every monthly billing-cycle boundary.
  select coalesce(sum(requests), 0) into v_count from public.here_search_usage
    where day >= v_day - 31;
  if v_count >= v_budget.max_requests_32days then
    return jsonb_build_object('allowed', false, 'reason', 'shared_limit');
  end if;
  select count(*) into v_count from public.here_search_requests
    where user_id = p_user_id and requested_at >= (v_day::timestamp at time zone 'UTC');
  if v_count >= v_budget.per_user_daily then
    return jsonb_build_object('allowed', false, 'reason', 'user_daily_limit');
  end if;
  select count(*) into v_count from public.here_search_requests
    where user_id = p_user_id and requested_at >= v_now - interval '60 seconds';
  if v_count >= v_budget.per_user_minute then
    return jsonb_build_object('allowed', false, 'reason', 'user_minute_limit');
  end if;
  -- Reserve before contacting HERE; failures and timeouts are not refunded.
  insert into public.here_search_usage(day, requests) values (v_day, 1)
    on conflict(day) do update set requests = public.here_search_usage.requests + 1;
  insert into public.here_search_requests(user_id, requested_at) values(p_user_id, v_now);
  return jsonb_build_object('allowed', true);
end $$;
grant update(id) on public.here_search_budget to service_role;
revoke all on function public.consume_here_search(uuid) from public, anon, authenticated;
grant execute on function public.consume_here_search(uuid) to service_role;
