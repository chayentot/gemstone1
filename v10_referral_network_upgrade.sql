-- GEMSTONE V10 REFERRAL NETWORK UPGRADE
-- Adds a secure referral summary and private list of directly referred users.
-- Run once after V6/V7. Existing data is not deleted.

create or replace function public.get_my_referral_summary()
returns table (
  referral_count bigint,
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
  select
    (
      select count(*)::bigint
      from public.profiles p
      where p.referred_by = v_user
    ) as referral_count,
    (
      select coalesce(sum(r.reward_amount), 0)::numeric
      from public.referral_rewards r
      where r.referrer_id = v_user
    ) as total_rewards,
    (
      select coalesce(sum(r.purchase_amount), 0)::numeric
      from public.referral_rewards r
      where r.referrer_id = v_user
    ) as total_referred_purchase_amount;
end;
$$;

create or replace function public.list_my_referrals()
returns table (
  user_id uuid,
  full_name text,
  joined_at timestamptz,
  purchases_count bigint,
  total_purchase_amount numeric,
  total_reward_generated numeric
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
  select
    p.id,
    p.full_name,
    p.created_at,
    count(r.id)::bigint,
    coalesce(sum(r.purchase_amount), 0)::numeric,
    coalesce(sum(r.reward_amount), 0)::numeric
  from public.profiles p
  left join public.referral_rewards r
    on r.referred_user_id = p.id
   and r.referrer_id = v_user
  where p.referred_by = v_user
  group by p.id, p.full_name, p.created_at
  order by p.created_at desc;
end;
$$;

revoke all on function public.get_my_referral_summary() from public;
revoke all on function public.list_my_referrals() from public;

grant execute on function public.get_my_referral_summary() to authenticated;
grant execute on function public.list_my_referrals() to authenticated;
