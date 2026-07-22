-- GEMSTONE V25 — MINING PROGRESSION SYSTEM
-- Run once after V24.
--
-- Regular players:
--   Quartz is unlocked automatically.
--   Every next gemstone requires materials from the previous gemstone.
--
-- Membership owners:
--   Their purchased gemstone is unlocked immediately.
--   The first mine and first membership reward are available immediately.

alter table public.gemstones
  add column if not exists progression_level integer,
  add column if not exists required_material_gemstone_id uuid references public.gemstones(id),
  add column if not exists required_material_amount bigint not null default 0,
  add column if not exists material_yield bigint not null default 10,
  add column if not exists mining_cooldown_minutes integer not null default 60;

with levels(name, level_no, required_name, required_amount, yield_amount) as (
  values
    ('Quartz',      1, null::text,   0::bigint,   10::bigint),
    ('Amethyst',    2, 'Quartz',   120::bigint,   14::bigint),
    ('Topaz',       3, 'Amethyst', 300::bigint,   19::bigint),
    ('Garnet',      4, 'Topaz',    500::bigint,   25::bigint),
    ('Aquamarine',  5, 'Garnet',   750::bigint,   32::bigint),
    ('Opal',        6, 'Aquamarine',1000::bigint, 41::bigint),
    ('Sapphire',    7, 'Opal',    1300::bigint,   52::bigint),
    ('Emerald',     8, 'Sapphire',1600::bigint,   66::bigint),
    ('Ruby',        9, 'Emerald', 2000::bigint,   84::bigint),
    ('Diamond',    10, 'Ruby',    2500::bigint,  110::bigint)
)
update public.gemstones g
set
  progression_level = l.level_no,
  required_material_gemstone_id = req.id,
  required_material_amount = l.required_amount,
  material_yield = l.yield_amount,
  mining_cooldown_minutes = 60
from levels l
left join public.gemstones req on req.name = l.required_name
where g.name = l.name;

update public.gemstones
set progression_level = coalesce(progression_level, 999)
where progression_level is null;

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

drop policy if exists "mining_progress_select_own" on public.user_gemstone_progress;
create policy "mining_progress_select_own"
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
  v_quartz uuid;
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  select id into v_quartz
  from public.gemstones
  where progression_level = 1 and is_active = true
  order by created_at
  limit 1;

  if v_quartz is not null then
    insert into public.user_gemstone_progress(
      user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at
    )
    values(v_user, v_quartz, now(), 'starter', now())
    on conflict(user_id, gemstone_id) do nothing;
  end if;

  -- Existing membership holders automatically receive instant mine access.
  insert into public.user_gemstone_progress(
    user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at
  )
  select v_user, um.gemstone_id, now(), 'membership', now()
  from public.user_memberships um
  where um.user_id = v_user
  on conflict(user_id, gemstone_id) do update
  set
    unlocked_at = coalesce(public.user_gemstone_progress.unlocked_at, excluded.unlocked_at),
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
    coalesce(progress.materials_owned, 0),
    (progress.unlocked_at is not null or membership.gemstone_id is not null),
    coalesce(progress.unlock_source,
      case when membership.gemstone_id is not null then 'membership' else null end),
    progress.next_mine_at,
    (membership.gemstone_id is not null),
    required_gem.name,
    g.required_material_amount,
    coalesce(required_progress.materials_owned, 0)
  from public.gemstones g
  left join public.user_gemstone_progress progress
    on progress.user_id = v_user and progress.gemstone_id = g.id
  left join (
    select distinct gemstone_id
    from public.user_memberships
    where user_id = v_user
  ) membership on membership.gemstone_id = g.id
  left join public.gemstones required_gem
    on required_gem.id = g.required_material_gemstone_id
  left join public.user_gemstone_progress required_progress
    on required_progress.user_id = v_user
   and required_progress.gemstone_id = g.required_material_gemstone_id
  where g.is_active = true
  order by g.progression_level, g.price;
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
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  select * into v_gem
  from public.gemstones
  where id = p_gemstone_id and is_active = true
  for update;

  if not found then
    raise exception 'Gemstone is unavailable';
  end if;

  if exists (
    select 1 from public.user_gemstone_progress
    where user_id = v_user
      and gemstone_id = p_gemstone_id
      and unlocked_at is not null
  ) then
    raise exception 'This gemstone mine is already unlocked';
  end if;

  if exists (
    select 1 from public.user_memberships
    where user_id = v_user and gemstone_id = p_gemstone_id
  ) then
    insert into public.user_gemstone_progress(
      user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at
    )
    values(v_user, p_gemstone_id, now(), 'membership', now())
    on conflict(user_id, gemstone_id) do update
    set unlocked_at = now(), unlock_source = 'membership', next_mine_at = now();
    return true;
  end if;

  if v_gem.progression_level = 1 then
    insert into public.user_gemstone_progress(
      user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at
    )
    values(v_user, p_gemstone_id, now(), 'starter', now())
    on conflict(user_id, gemstone_id) do update
    set unlocked_at = coalesce(public.user_gemstone_progress.unlocked_at, now()),
        unlock_source = coalesce(public.user_gemstone_progress.unlock_source, 'starter'),
        next_mine_at = coalesce(public.user_gemstone_progress.next_mine_at, now());
    return true;
  end if;

  select materials_owned into v_required_balance
  from public.user_gemstone_progress
  where user_id = v_user
    and gemstone_id = v_gem.required_material_gemstone_id
  for update;

  if coalesce(v_required_balance, 0) < v_gem.required_material_amount then
    raise exception 'Not enough required materials';
  end if;

  update public.user_gemstone_progress
  set materials_owned = materials_owned - v_gem.required_material_amount
  where user_id = v_user
    and gemstone_id = v_gem.required_material_gemstone_id;

  insert into public.user_gemstone_progress(
    user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at
  )
  values(v_user, p_gemstone_id, now(), 'materials', now())
  on conflict(user_id, gemstone_id) do update
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
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  select * into v_gem
  from public.gemstones
  where id = p_gemstone_id and is_active = true;

  if not found then
    raise exception 'Gemstone is unavailable';
  end if;

  select exists(
    select 1 from public.user_memberships
    where user_id = v_user and gemstone_id = p_gemstone_id
  ) into v_has_membership;

  if v_has_membership then
    insert into public.user_gemstone_progress(
      user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at
    )
    values(v_user, p_gemstone_id, now(), 'membership', now())
    on conflict(user_id, gemstone_id) do nothing;
  end if;

  select * into v_progress
  from public.user_gemstone_progress
  where user_id = v_user and gemstone_id = p_gemstone_id
  for update;

  if not found or v_progress.unlocked_at is null then
    raise exception 'Unlock this gemstone mine first';
  end if;

  if v_progress.next_mine_at is not null and now() < v_progress.next_mine_at then
    raise exception 'This mine is still cooling down';
  end if;

  update public.user_gemstone_progress
  set
    materials_owned = materials_owned + v_gem.material_yield,
    last_mined_at = now(),
    next_mine_at = now() + make_interval(mins => v_gem.mining_cooldown_minutes)
  where user_id = v_user and gemstone_id = p_gemstone_id;

  return v_gem.material_yield;
end;
$$;

-- Replace purchase flow while preserving the 8% referral commission.
drop function if exists public.buy_gemstone(uuid);

create function public.buy_gemstone(p_gemstone_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_gem public.gemstones%rowtype;
  v_wallet numeric(12,2);
  v_membership uuid;
  v_referrer uuid;
  v_reward numeric(12,2);
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  select * into v_gem
  from public.gemstones
  where id = p_gemstone_id and is_active = true;

  if not found then
    raise exception 'Gemstone is unavailable';
  end if;

  select wallet_balance, referred_by
  into v_wallet, v_referrer
  from public.profiles
  where id = v_user
  for update;

  if v_wallet < v_gem.price then
    raise exception 'Insufficient wallet balance';
  end if;

  update public.profiles
  set wallet_balance = wallet_balance - v_gem.price
  where id = v_user;

  insert into public.user_memberships(
    user_id, gemstone_id, purchase_price,
    points_per_claim, max_claims, next_redeem_at
  )
  values(
    v_user, v_gem.id, v_gem.price,
    v_gem.points_per_claim, v_gem.max_claims, now()
  )
  returning id into v_membership;

  insert into public.user_gemstone_progress(
    user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at
  )
  values(v_user, v_gem.id, now(), 'membership', now())
  on conflict(user_id, gemstone_id) do update
  set
    unlocked_at = coalesce(public.user_gemstone_progress.unlocked_at, now()),
    unlock_source = 'membership',
    next_mine_at = now();

  insert into public.wallet_transactions(user_id, type, amount, description)
  values(v_user, 'membership_purchase', -v_gem.price, 'Purchased ' || v_gem.name);

  if v_referrer is not null then
    v_reward := round(v_gem.price * 0.08, 2);

    update public.profiles
    set wallet_balance = wallet_balance + v_reward
    where id = v_referrer;

    insert into public.referral_rewards(
      referrer_id, referred_user_id, membership_id,
      purchase_amount, reward_rate, reward_amount
    )
    values(
      v_referrer, v_user, v_membership,
      v_gem.price, 0.08, v_reward
    );

    insert into public.wallet_transactions(
      user_id, type, amount, description
    )
    values(
      v_referrer, 'referral_commission', v_reward,
      '8% referral commission from a ' || v_gem.name || ' purchase'
    );
  end if;

  return v_membership;
end;
$$;

revoke all on function public.get_home_mining_progress() from public, anon;
revoke all on function public.unlock_gemstone_with_materials(uuid) from public, anon;
revoke all on function public.mine_gemstone(uuid) from public, anon;
revoke all on function public.buy_gemstone(uuid) from public, anon;

grant execute on function public.get_home_mining_progress() to authenticated;
grant execute on function public.unlock_gemstone_with_materials(uuid) to authenticated;
grant execute on function public.mine_gemstone(uuid) to authenticated;
grant execute on function public.buy_gemstone(uuid) to authenticated;
