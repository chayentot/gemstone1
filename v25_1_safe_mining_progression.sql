-- GEMSTONE V25.1 — SAFE MINING PROGRESSION
-- Run once after V24. Existing purchase, redeem, wallet, referral,
-- withdrawal, and admin RPCs are not replaced.

alter table public.gemstones
  add column if not exists progression_level integer,
  add column if not exists required_material_gemstone_id uuid references public.gemstones(id),
  add column if not exists required_material_amount bigint not null default 0,
  add column if not exists material_yield bigint not null default 10,
  add column if not exists mining_cooldown_minutes integer not null default 60;

-- Order active gemstones from lowest price to highest price.
with ranked as (
  select g.id,
         row_number() over (order by g.price asc, g.created_at asc, g.id asc)::integer as level_no
  from public.gemstones g
  where g.is_active = true
)
update public.gemstones g
set progression_level = r.level_no
from ranked r
where r.id = g.id;

-- Link each mine to the previous mine's materials.
update public.gemstones g
set required_material_gemstone_id = previous.id,
    required_material_amount = 100 + ((g.progression_level - 2) * 200),
    material_yield = 10 + ((g.progression_level - 1) * 5),
    mining_cooldown_minutes = 60
from public.gemstones previous
where g.progression_level > 1
  and previous.progression_level = g.progression_level - 1;

update public.gemstones g
set required_material_gemstone_id = null,
    required_material_amount = 0,
    material_yield = greatest(coalesce(g.material_yield, 10), 10),
    mining_cooldown_minutes = greatest(coalesce(g.mining_cooldown_minutes, 60), 1)
where g.progression_level = 1;

create table if not exists public.user_gemstone_progress (
  user_id uuid not null references public.profiles(id) on delete cascade,
  gemstone_id uuid not null references public.gemstones(id) on delete cascade,
  materials_owned bigint not null default 0 check (materials_owned >= 0),
  unlocked_at timestamptz,
  unlock_source text check (unlock_source in ('starter','materials','membership')),
  last_mined_at timestamptz,
  next_mine_at timestamptz,
  primary key (user_id, gemstone_id)
);

alter table public.user_gemstone_progress enable row level security;

drop policy if exists mining_progress_select_own on public.user_gemstone_progress;
create policy mining_progress_select_own
on public.user_gemstone_progress
for select
using (auth.uid() = user_id);

drop function if exists public.get_home_mining_progress();
drop function if exists public.unlock_gemstone_with_materials(uuid);
drop function if exists public.mine_gemstone(uuid);

create function public.get_home_mining_progress()
returns table (
  gemstone_id uuid,
  gemstone_name text,
  image_url text,
  progression_level integer,
  material_yield bigint,
  mining_cooldown_minutes integer,
  materials_owned bigint,
  is_unlocked boolean,
  unlock_source text,
  next_mine_at timestamptz,
  has_membership boolean,
  required_material_name text,
  required_material_amount bigint,
  required_material_owned bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_starter uuid;
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  select g.id
  into v_starter
  from public.gemstones g
  where g.is_active = true
  order by g.progression_level asc, g.price asc, g.id asc
  limit 1;

  if v_starter is not null then
    insert into public.user_gemstone_progress
      (user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at)
    values
      (v_user, v_starter, now(), 'starter', now())
    on conflict (user_id, gemstone_id) do nothing;
  end if;

  -- Purchased memberships bypass material requirements automatically.
  insert into public.user_gemstone_progress
    (user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at)
  select v_user, um.gemstone_id, now(), 'membership', now()
  from public.user_memberships um
  where um.user_id = v_user
  on conflict (user_id, gemstone_id) do update
  set unlocked_at = coalesce(public.user_gemstone_progress.unlocked_at, excluded.unlocked_at),
      unlock_source = case
        when public.user_gemstone_progress.unlock_source is null then 'membership'
        else public.user_gemstone_progress.unlock_source
      end,
      next_mine_at = coalesce(public.user_gemstone_progress.next_mine_at, now());

  return query
  select
    g.id,
    g.name,
    g.image_url,
    g.progression_level,
    g.material_yield,
    g.mining_cooldown_minutes,
    coalesce(p.materials_owned, 0)::bigint,
    (p.unlocked_at is not null or mg.gemstone_id is not null),
    coalesce(p.unlock_source, case when mg.gemstone_id is not null then 'membership' end),
    p.next_mine_at,
    (mg.gemstone_id is not null),
    required_g.name,
    g.required_material_amount,
    coalesce(required_p.materials_owned, 0)::bigint
  from public.gemstones g
  left join public.user_gemstone_progress p
    on p.user_id = v_user and p.gemstone_id = g.id
  left join (
    select distinct um2.gemstone_id
    from public.user_memberships um2
    where um2.user_id = v_user
  ) mg on mg.gemstone_id = g.id
  left join public.gemstones required_g
    on required_g.id = g.required_material_gemstone_id
  left join public.user_gemstone_progress required_p
    on required_p.user_id = v_user
   and required_p.gemstone_id = g.required_material_gemstone_id
  where g.is_active = true
  order by g.progression_level asc, g.price asc, g.id asc;
end;
$$;

create function public.unlock_gemstone_with_materials(p_gemstone_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_gem public.gemstones%rowtype;
  v_required_balance bigint;
begin
  if v_user is null then raise exception 'You must be logged in'; end if;

  select g.* into v_gem
  from public.gemstones g
  where g.id = p_gemstone_id and g.is_active = true;

  if not found then raise exception 'Gemstone is unavailable'; end if;

  if exists (
    select 1 from public.user_gemstone_progress p
    where p.user_id = v_user
      and p.gemstone_id = p_gemstone_id
      and p.unlocked_at is not null
  ) then
    raise exception 'This gemstone mine is already unlocked';
  end if;

  if exists (
    select 1 from public.user_memberships um
    where um.user_id = v_user and um.gemstone_id = p_gemstone_id
  ) then
    insert into public.user_gemstone_progress
      (user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at)
    values
      (v_user, p_gemstone_id, now(), 'membership', now())
    on conflict (user_id, gemstone_id) do update
    set unlocked_at = now(), unlock_source = 'membership', next_mine_at = now();
    return true;
  end if;

  if v_gem.progression_level = 1 then
    insert into public.user_gemstone_progress
      (user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at)
    values
      (v_user, p_gemstone_id, now(), 'starter', now())
    on conflict (user_id, gemstone_id) do update
    set unlocked_at = coalesce(public.user_gemstone_progress.unlocked_at, now()),
        unlock_source = coalesce(public.user_gemstone_progress.unlock_source, 'starter'),
        next_mine_at = coalesce(public.user_gemstone_progress.next_mine_at, now());
    return true;
  end if;

  select p.materials_owned into v_required_balance
  from public.user_gemstone_progress p
  where p.user_id = v_user
    and p.gemstone_id = v_gem.required_material_gemstone_id
  for update;

  if coalesce(v_required_balance, 0) < v_gem.required_material_amount then
    raise exception 'Not enough required materials';
  end if;

  update public.user_gemstone_progress p
  set materials_owned = p.materials_owned - v_gem.required_material_amount
  where p.user_id = v_user
    and p.gemstone_id = v_gem.required_material_gemstone_id;

  insert into public.user_gemstone_progress
    (user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at)
  values
    (v_user, p_gemstone_id, now(), 'materials', now())
  on conflict (user_id, gemstone_id) do update
  set unlocked_at = now(), unlock_source = 'materials', next_mine_at = now();

  return true;
end;
$$;

create function public.mine_gemstone(p_gemstone_id uuid)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_gem public.gemstones%rowtype;
  v_progress public.user_gemstone_progress%rowtype;
  v_has_membership boolean;
begin
  if v_user is null then raise exception 'You must be logged in'; end if;

  select g.* into v_gem
  from public.gemstones g
  where g.id = p_gemstone_id and g.is_active = true;

  if not found then raise exception 'Gemstone is unavailable'; end if;

  select exists (
    select 1 from public.user_memberships um
    where um.user_id = v_user and um.gemstone_id = p_gemstone_id
  ) into v_has_membership;

  if v_has_membership then
    insert into public.user_gemstone_progress
      (user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at)
    values
      (v_user, p_gemstone_id, now(), 'membership', now())
    on conflict (user_id, gemstone_id) do nothing;
  end if;

  select p.* into v_progress
  from public.user_gemstone_progress p
  where p.user_id = v_user and p.gemstone_id = p_gemstone_id
  for update;

  if not found or v_progress.unlocked_at is null then
    raise exception 'Unlock this gemstone mine first';
  end if;

  if v_progress.next_mine_at is not null and now() < v_progress.next_mine_at then
    raise exception 'This mine is still cooling down';
  end if;

  update public.user_gemstone_progress p
  set materials_owned = p.materials_owned + v_gem.material_yield,
      last_mined_at = now(),
      next_mine_at = now() + make_interval(mins => v_gem.mining_cooldown_minutes)
  where p.user_id = v_user and p.gemstone_id = p_gemstone_id;

  return v_gem.material_yield;
end;
$$;

revoke all on function public.get_home_mining_progress() from public, anon;
revoke all on function public.unlock_gemstone_with_materials(uuid) from public, anon;
revoke all on function public.mine_gemstone(uuid) from public, anon;

grant execute on function public.get_home_mining_progress() to authenticated;
grant execute on function public.unlock_gemstone_with_materials(uuid) to authenticated;
grant execute on function public.mine_gemstone(uuid) to authenticated;
