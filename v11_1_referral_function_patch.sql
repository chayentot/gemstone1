-- V11.1 REFERRAL FUNCTION PATCH
-- Run this first if V11 failed with:
-- "cannot change return type of existing function"

drop function if exists public.get_my_referral_summary();
drop function if exists public.list_my_referrals();

create or replace function public.get_my_referral_summary()
returns table (
  referral_count bigint,
  active_referral_count bigint,
  total_rewards numeric,
  total_referred_purchase_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  return query
  with referral_users as (
    select p.id
    from public.profiles p
    where p.referred_by = v_user

    union

    select r.referred_user_id
    from public.referral_rewards r
    where r.referrer_id = v_user
  )
  select
    (select count(*)::bigint from referral_users),
    (
      select count(distinct r.referred_user_id)::bigint
      from public.referral_rewards r
      where r.referrer_id = v_user
    ),
    (
      select coalesce(sum(r.reward_amount), 0)::numeric
      from public.referral_rewards r
      where r.referrer_id = v_user
    ),
    (
      select coalesce(sum(r.purchase_amount), 0)::numeric
      from public.referral_rewards r
      where r.referrer_id = v_user
    );
end;
$$;

create or replace function public.list_my_referrals()
returns table (
  user_id uuid,
  full_name text,
  joined_at timestamptz,
  purchases_count bigint,
  total_purchase_amount numeric,
  total_reward_generated numeric,
  referral_status text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  return query
  with referral_users as (
    select p.id
    from public.profiles p
    where p.referred_by = v_user

    union

    select r.referred_user_id
    from public.referral_rewards r
    where r.referrer_id = v_user
  ),
  reward_totals as (
    select
      r.referred_user_id,
      count(*)::bigint as purchases_count,
      coalesce(sum(r.purchase_amount), 0)::numeric as total_purchase_amount,
      coalesce(sum(r.reward_amount), 0)::numeric as total_reward_generated
    from public.referral_rewards r
    where r.referrer_id = v_user
    group by r.referred_user_id
  )
  select
    p.id,
    coalesce(nullif(trim(p.full_name), ''), 'Unnamed member')::text,
    p.created_at,
    coalesce(rt.purchases_count, 0)::bigint,
    coalesce(rt.total_purchase_amount, 0)::numeric,
    coalesce(rt.total_reward_generated, 0)::numeric,
    case when coalesce(rt.purchases_count, 0) > 0 then 'Active' else 'Registered' end::text
  from referral_users ru
  join public.profiles p on p.id = ru.id
  left join reward_totals rt on rt.referred_user_id = p.id
  order by p.created_at desc;
end;
$$;

revoke all on function public.get_my_referral_summary() from public;
revoke all on function public.list_my_referrals() from public;

grant execute on function public.get_my_referral_summary() to authenticated;
grant execute on function public.list_my_referrals() to authenticated;
