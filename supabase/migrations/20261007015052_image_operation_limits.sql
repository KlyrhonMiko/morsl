-- Count every server attempt before contacting R2, including failed attempts.
-- A 32-day window is conservative across any monthly billing-cycle boundary.
create table public.image_operation_usage (
  day date not null,
  class text not null check (class in ('A','B')),
  requests bigint not null check (requests >= 0),
  primary key(day,class)
);
alter table public.image_operation_usage enable row level security;
revoke all on public.image_operation_usage from public, anon, authenticated;
grant select, insert, update on public.image_operation_usage to service_role;
-- Allow for setup checks and activity before request metering was enabled.
insert into public.image_operation_usage(day,class,requests)
values ((now() at time zone 'UTC')::date,'A',1000),
       ((now() at time zone 'UTC')::date,'B',1000);

create function public.consume_image_operation(p_class text) returns boolean
language plpgsql security invoker set search_path = '' as $$
declare v_day date := (now() at time zone 'UTC')::date;
  v_total bigint; v_limit bigint;
begin
  if p_class is null or p_class not in ('A','B') then raise exception 'Invalid operation class'; end if;
  v_limit := case p_class when 'A' then 900000 else 9000000 end;
  -- Allocation, deletion and operation accounting always lock this row first.
  perform 1 from public.image_storage_budget where id for update;
  if not found then raise exception 'Storage budget missing'; end if;
  select coalesce(sum(requests),0) into v_total from public.image_operation_usage
    where class = p_class and day >= v_day - 31;
  if v_total >= v_limit then return false; end if;
  insert into public.image_operation_usage(day,class,requests) values(v_day,p_class,1)
    on conflict(day,class) do update set requests = public.image_operation_usage.requests + 1;
  return true;
end $$;
revoke all on function public.consume_image_operation(text) from public, anon, authenticated;
grant execute on function public.consume_image_operation(text) to service_role;
