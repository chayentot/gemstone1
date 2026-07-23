-- GEMSTONE V26 — QUARTZ IDLE MINE
-- Run once after V24.
--
-- Mechanics:
-- Level 1 = 1 Quartz/second, 3,600 capacity.
-- Each level adds +1 Quartz/second and +3,600 capacity.
-- Upgrade cost = 1,000 × current_level² Quartz.
-- Quartz production is calculated from Supabase server time and stops at capacity.

create table if not exists public.user_quartz_mines (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  mine_level integer not null default 1 check (mine_level >= 1),
  quartz_balance bigint not null default 0 check (quartz_balance >= 0),
  stored_quartz numeric(20,4) not null default 0 check (stored_quartz >= 0),
  last_calculated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.user_quartz_mines enable row level security;

drop policy if exists "quartz_mines_select_own" on public.user_quartz_mines;
create policy "quartz_mines_select_own"
on public.user_quartz_mines
for select
using (auth.uid() = user_id);

drop function if exists public.get_quartz_mine();
drop function if exists public.collect_quartz();
drop function if exists public.upgrade_quartz_mine();

create function public.get_quartz_mine()
returns table (
  mine_level integer,
  quartz_per_second integer,
  capacity bigint,
  quartz_balance bigint,
  stored_quartz numeric,
  upgrade_cost bigint,
  calculated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_mine public.user_quartz_mines%rowtype;
  v_rate integer;
  v_capacity bigint;
  v_elapsed numeric;
  v_current_stored numeric;
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  insert into public.user_quartz_mines(user_id)
  values(v_user)
  on conflict on constraint user_quartz_mines_pkey do nothing;

  select qm.*
  into v_mine
  from public.user_quartz_mines qm
  where qm.user_id = v_user;

  v_rate := v_mine.mine_level;
  v_capacity := v_mine.mine_level::bigint * 3600;
  v_elapsed := greatest(0, extract(epoch from (now() - v_mine.last_calculated_at)));
  v_current_stored := least(
    v_capacity::numeric,
    v_mine.stored_quartz + (v_elapsed * v_rate)
  );

  return query
  select
    v_mine.mine_level,
    v_rate,
    v_capacity,
    v_mine.quartz_balance,
    floor(v_current_stored),
    (1000::bigint * v_mine.mine_level::bigint * v_mine.mine_level::bigint),
    now();
end;
$$;

create function public.collect_quartz()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_mine public.user_quartz_mines%rowtype;
  v_rate integer;
  v_capacity bigint;
  v_elapsed numeric;
  v_current_stored numeric;
  v_collected bigint;
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  insert into public.user_quartz_mines(user_id)
  values(v_user)
  on conflict on constraint user_quartz_mines_pkey do nothing;

  select qm.*
  into v_mine
  from public.user_quartz_mines qm
  where qm.user_id = v_user
  for update;

  v_rate := v_mine.mine_level;
  v_capacity := v_mine.mine_level::bigint * 3600;
  v_elapsed := greatest(0, extract(epoch from (now() - v_mine.last_calculated_at)));
  v_current_stored := least(
    v_capacity::numeric,
    v_mine.stored_quartz + (v_elapsed * v_rate)
  );
  v_collected := floor(v_current_stored)::bigint;

  if v_collected <= 0 then
    return 0;
  end if;

  update public.user_quartz_mines qm
  set
    quartz_balance = qm.quartz_balance + v_collected,
    stored_quartz = v_current_stored - v_collected,
    last_calculated_at = now(),
    updated_at = now()
  where qm.user_id = v_user;

  return v_collected;
end;
$$;

create function public.upgrade_quartz_mine()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_mine public.user_quartz_mines%rowtype;
  v_rate integer;
  v_capacity bigint;
  v_elapsed numeric;
  v_current_stored numeric;
  v_collectable bigint;
  v_total_balance bigint;
  v_cost bigint;
  v_new_level integer;
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  insert into public.user_quartz_mines(user_id)
  values(v_user)
  on conflict on constraint user_quartz_mines_pkey do nothing;

  select qm.*
  into v_mine
  from public.user_quartz_mines qm
  where qm.user_id = v_user
  for update;

  v_rate := v_mine.mine_level;
  v_capacity := v_mine.mine_level::bigint * 3600;
  v_elapsed := greatest(0, extract(epoch from (now() - v_mine.last_calculated_at)));
  v_current_stored := least(
    v_capacity::numeric,
    v_mine.stored_quartz + (v_elapsed * v_rate)
  );
  v_collectable := floor(v_current_stored)::bigint;
  v_total_balance := v_mine.quartz_balance + v_collectable;
  v_cost := 1000::bigint * v_mine.mine_level::bigint * v_mine.mine_level::bigint;

  if v_total_balance < v_cost then
    raise exception 'You need % more Quartz for this upgrade', (v_cost - v_total_balance);
  end if;

  v_new_level := v_mine.mine_level + 1;

  update public.user_quartz_mines qm
  set
    mine_level = v_new_level,
    quartz_balance = v_total_balance - v_cost,
    stored_quartz = v_current_stored - v_collectable,
    last_calculated_at = now(),
    updated_at = now()
  where qm.user_id = v_user;

  return v_new_level;
end;
$$;

revoke all on function public.get_quartz_mine() from public;
revoke all on function public.get_quartz_mine() from anon;
revoke all on function public.collect_quartz() from public;
revoke all on function public.collect_quartz() from anon;
revoke all on function public.upgrade_quartz_mine() from public;
revoke all on function public.upgrade_quartz_mine() from anon;

grant execute on function public.get_quartz_mine() to authenticated;
grant execute on function public.collect_quartz() to authenticated;
grant execute on function public.upgrade_quartz_mine() to authenticated;
