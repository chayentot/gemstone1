-- GEMSTONE V11 REPAIR
-- Repairs referral user listing and recreates the withdrawal workflow.
-- Run once after the prior upgrades. Existing requests and rewards are preserved.

create extension if not exists pgcrypto;

-- =========================================================
-- REFERRAL REPAIR
-- =========================================================

-- PostgreSQL cannot change the OUT-column structure of an existing function
-- with CREATE OR REPLACE. Drop the old signatures first, then recreate them.
drop function if exists public.get_my_referral_summary();
drop function if exists public.list_my_referrals();


-- Recover referred_by from historical reward records when possible.
-- A referred user can have only one referrer in this direct-referral system.
update public.profiles p
set referred_by = recovered.referrer_id
from (
  select referred_user_id, min(referrer_id::text)::uuid as referrer_id
  from public.referral_rewards
  group by referred_user_id
  having count(distinct referrer_id) = 1
) recovered
where p.id = recovered.referred_user_id
  and p.referred_by is null;

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

-- =========================================================
-- WITHDRAWAL RECREATION
-- =========================================================

create table if not exists public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  points_amount bigint not null check (points_amount >= 120),
  gcash_name text not null,
  gcash_number text not null,
  status text not null default 'pending_review'
    check (status in ('pending_review','approved','rejected','cancelled')),
  admin_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);

create index if not exists withdrawal_user_created_idx
  on public.withdrawal_requests(user_id, created_at desc);

create index if not exists withdrawal_status_created_idx
  on public.withdrawal_requests(status, created_at desc);

alter table public.withdrawal_requests enable row level security;

drop policy if exists "withdrawals_read_own_or_admin" on public.withdrawal_requests;
drop policy if exists "withdrawal_users_read_own" on public.withdrawal_requests;

create policy "withdrawals_read_own_or_admin"
on public.withdrawal_requests
for select
using (auth.uid() = user_id or public.is_current_admin());

-- Return available points after reserving pending requests.
create or replace function public.get_my_withdrawal_balance()
returns table (
  points_balance bigint,
  pending_points bigint,
  available_points bigint,
  minimum_points bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'You must be logged in'; end if;

  return query
  select
    p.points_balance::bigint,
    coalesce(sum(w.points_amount) filter (where w.status = 'pending_review'), 0)::bigint,
    (
      p.points_balance -
      coalesce(sum(w.points_amount) filter (where w.status = 'pending_review'), 0)
    )::bigint,
    120::bigint
  from public.profiles p
  left join public.withdrawal_requests w on w.user_id = p.id
  where p.id = v_user
  group by p.points_balance;
end;
$$;

create or replace function public.create_withdrawal_request(
  p_points_amount bigint,
  p_gcash_name text,
  p_gcash_number text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_balance bigint;
  v_pending bigint;
  v_available bigint;
  v_request uuid;
  v_name text := trim(coalesce(p_gcash_name, ''));
  v_number text := regexp_replace(trim(coalesce(p_gcash_number, '')), '[^0-9]', '', 'g');
begin
  if v_user is null then raise exception 'You must be logged in'; end if;
  if p_points_amount is null or p_points_amount < 120 then
    raise exception 'Minimum withdrawal is 120 points';
  end if;
  if length(v_name) < 2 or length(v_name) > 100 then
    raise exception 'Enter the GCash account holder name';
  end if;
  if length(v_number) < 10 or length(v_number) > 13 then
    raise exception 'Enter a valid GCash mobile number';
  end if;

  select points_balance::bigint
  into v_balance
  from public.profiles
  where id = v_user
  for update;

  if not found then raise exception 'Profile not found'; end if;

  select coalesce(sum(points_amount), 0)::bigint
  into v_pending
  from public.withdrawal_requests
  where user_id = v_user and status = 'pending_review';

  v_available := v_balance - v_pending;

  if p_points_amount > v_available then
    raise exception 'Only % points are available after pending withdrawals', v_available;
  end if;

  insert into public.withdrawal_requests(
    user_id, points_amount, gcash_name, gcash_number, status
  )
  values(v_user, p_points_amount, v_name, v_number, 'pending_review')
  returning id into v_request;

  return v_request;
end;
$$;

create or replace function public.review_withdrawal_request(
  p_request_id uuid,
  p_approve boolean,
  p_admin_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_request public.withdrawal_requests%rowtype;
  v_balance bigint;
begin
  if v_admin is null or not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;

  select *
  into v_request
  from public.withdrawal_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Withdrawal request not found'; end if;
  if v_request.status <> 'pending_review' then
    raise exception 'This request was already reviewed';
  end if;

  if p_approve then
    select points_balance::bigint
    into v_balance
    from public.profiles
    where id = v_request.user_id
    for update;

    if v_balance < v_request.points_amount then
      raise exception 'User has only % points remaining', v_balance;
    end if;

    update public.profiles
    set points_balance = points_balance - v_request.points_amount
    where id = v_request.user_id;

    insert into public.point_transactions(
      user_id, membership_id, type, points, description
    )
    values(
      v_request.user_id,
      null,
      'withdrawal',
      -v_request.points_amount,
      'Withdrawal approved for GCash ' || v_request.gcash_number
    );

    update public.withdrawal_requests
    set status = 'approved',
        admin_note = nullif(trim(coalesce(p_admin_note, '')), ''),
        reviewed_at = now(),
        reviewed_by = v_admin
    where id = p_request_id;
  else
    if nullif(trim(coalesce(p_admin_note, '')), '') is null then
      raise exception 'A rejection reason is required';
    end if;

    update public.withdrawal_requests
    set status = 'rejected',
        admin_note = trim(p_admin_note),
        reviewed_at = now(),
        reviewed_by = v_admin
    where id = p_request_id;
  end if;
end;
$$;

create or replace function public.admin_list_withdrawals(
  p_status text default 'pending_review'
)
returns table (
  id uuid,
  user_id uuid,
  full_name text,
  email text,
  points_amount bigint,
  gcash_name text,
  gcash_number text,
  status text,
  admin_note text,
  created_at timestamptz,
  reviewed_at timestamptz
)
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;

  return query
  select
    w.id,
    w.user_id,
    coalesce(nullif(trim(p.full_name), ''), 'Unnamed member')::text,
    u.email::text,
    w.points_amount,
    w.gcash_name,
    w.gcash_number,
    w.status,
    w.admin_note,
    w.created_at,
    w.reviewed_at
  from public.withdrawal_requests w
  join public.profiles p on p.id = w.user_id
  join auth.users u on u.id = w.user_id
  where p_status = 'all' or w.status = p_status
  order by
    case when w.status = 'pending_review' then 0 else 1 end,
    w.created_at desc
  limit 300;
end;
$$;

revoke all on function public.get_my_withdrawal_balance() from public;
revoke all on function public.create_withdrawal_request(bigint,text,text) from public;
revoke all on function public.review_withdrawal_request(uuid,boolean,text) from public;
revoke all on function public.admin_list_withdrawals(text) from public;

grant execute on function public.get_my_withdrawal_balance() to authenticated;
grant execute on function public.create_withdrawal_request(bigint,text,text) to authenticated;
grant execute on function public.review_withdrawal_request(uuid,boolean,text) to authenticated;
grant execute on function public.admin_list_withdrawals(text) to authenticated;
