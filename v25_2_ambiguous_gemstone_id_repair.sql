-- GEMSTONE V25.2 — AMBIGUOUS GEMSTONE_ID REPAIR
-- Run this once after V25 or V25.1.
-- It recreates only get_home_mining_progress().
-- Existing purchase, redemption, wallet, referral, withdrawal,
-- admin, and mining data are preserved.

drop function if exists public.get_home_mining_progress();

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
#variable_conflict use_column
declare
  v_user uuid := auth.uid();
  v_starter uuid;
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  select g.id
  into v_starter
  from public.gemstones as g
  where g.is_active = true
  order by g.progression_level asc, g.price asc, g.id asc
  limit 1;

  if v_starter is not null then
    insert into public.user_gemstone_progress as ugp
      (user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at)
    values
      (v_user, v_starter, now(), 'starter', now())
    on conflict on constraint user_gemstone_progress_pkey do nothing;
  end if;

  insert into public.user_gemstone_progress as ugp
    (user_id, gemstone_id, unlocked_at, unlock_source, next_mine_at)
  select
    v_user,
    um.gemstone_id,
    now(),
    'membership',
    now()
  from public.user_memberships as um
  where um.user_id = v_user
  on conflict on constraint user_gemstone_progress_pkey do update
  set
    unlocked_at = coalesce(ugp.unlocked_at, excluded.unlocked_at),
    unlock_source = case
      when ugp.unlock_source is null then 'membership'
      else ugp.unlock_source
    end,
    next_mine_at = coalesce(ugp.next_mine_at, now());

  return query
  select
    g.id as gemstone_id,
    g.name as gemstone_name,
    g.image_url as image_url,
    g.progression_level as progression_level,
    g.material_yield as material_yield,
    g.mining_cooldown_minutes as mining_cooldown_minutes,
    coalesce(progress.materials_owned, 0)::bigint as materials_owned,
    (
      progress.unlocked_at is not null
      or member_gems.member_gemstone_id is not null
    ) as is_unlocked,
    coalesce(
      progress.unlock_source,
      case
        when member_gems.member_gemstone_id is not null then 'membership'
        else null
      end
    ) as unlock_source,
    progress.next_mine_at as next_mine_at,
    (member_gems.member_gemstone_id is not null) as has_membership,
    required_gem.name as required_material_name,
    g.required_material_amount as required_material_amount,
    coalesce(required_progress.materials_owned, 0)::bigint as required_material_owned
  from public.gemstones as g
  left join public.user_gemstone_progress as progress
    on progress.user_id = v_user
   and progress.gemstone_id = g.id
  left join (
    select distinct um2.gemstone_id as member_gemstone_id
    from public.user_memberships as um2
    where um2.user_id = v_user
  ) as member_gems
    on member_gems.member_gemstone_id = g.id
  left join public.gemstones as required_gem
    on required_gem.id = g.required_material_gemstone_id
  left join public.user_gemstone_progress as required_progress
    on required_progress.user_id = v_user
   and required_progress.gemstone_id = g.required_material_gemstone_id
  where g.is_active = true
  order by
    g.progression_level asc,
    g.price asc,
    g.id asc;
end;
$$;

revoke all on function public.get_home_mining_progress() from public;
revoke all on function public.get_home_mining_progress() from anon;
grant execute on function public.get_home_mining_progress() to authenticated;
