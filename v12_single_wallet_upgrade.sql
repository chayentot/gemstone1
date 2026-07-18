-- GEMSTONE V12 — SINGLE WALLET
-- Converts the rewards system to one wallet balance.
--
-- Rules:
--   1 reward point = PHP 1.00
--   Cash-ins credit wallet_balance.
--   Gemstone redemptions credit wallet_balance.
--   Referral commissions already credit wallet_balance.
--   Withdrawals use wallet_balance instead of points_balance.
--
-- Run once after V11. Existing data is preserved.

create extension if not exists pgcrypto;

-- =========================================================
-- 1. MIGRATE EXISTING POINT BALANCES INTO THE WALLET
-- =========================================================

-- Credit existing points into wallet exactly once.
alter table public.profiles
  add column if not exists points_migrated_to_wallet boolean not null default false;

update public.profiles
set wallet_balance = wallet_balance + coalesce(points_balance, 0),
    points_balance = 0,
    points_migrated_to_wallet = true
where points_migrated_to_wallet = false;

-- Add a migration ledger entry for users who had points.
insert into public.wallet_transactions(user_id, type, amount, description)
select
  p.id,
  'points_migration',
  coalesce((
    select abs(sum(pt.points))
    from public.point_transactions pt
    where pt.user_id = p.id
  ), 0),
  'Existing reward points converted to wallet balance at PHP 1 per point'
from public.profiles p
where p.points_migrated_to_wallet = true
  and not exists (
    select 1
    from public.wallet_transactions wt
    where wt.user_id = p.id
      and wt.type = 'points_migration'
  )
  and exists (
    select 1
    from public.point_transactions pt
    where pt.user_id = p.id
  );

-- =========================================================
-- 2. REDEEM GEMSTONE REWARDS DIRECTLY TO WALLET
-- =========================================================

-- Drop known possible old signatures before recreation.
drop function if exists public.redeem_membership(uuid);
drop function if exists public.redeem_reward(uuid);
drop function if exists public.claim_membership_reward(uuid);

-- This is the standard V12 redemption function used by the website.
create or replace function public.redeem_membership(p_membership_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_membership public.user_memberships%rowtype;
  v_reward numeric(12,2);
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  select *
  into v_membership
  from public.user_memberships
  where id = p_membership_id
    and user_id = v_user
  for update;

  if not found then
    raise exception 'Membership not found';
  end if;

  if v_membership.status <> 'active' then
    raise exception 'This membership is no longer active';
  end if;

  if v_membership.claims_made >= v_membership.max_claims then
    raise exception 'All rewards for this gemstone have already been claimed';
  end if;

  if v_membership.next_redeem_at is null or now() < v_membership.next_redeem_at then
    raise exception 'Reward is not available yet';
  end if;

  -- 1 point = PHP 1
  v_reward := v_membership.points_per_claim::numeric;

  update public.profiles
  set wallet_balance = wallet_balance + v_reward
  where id = v_user;

  update public.user_memberships
  set claims_made = claims_made + 1,
      last_redeemed_at = now(),
      next_redeem_at = case
        when claims_made + 1 >= max_claims then null
        else now() + interval '24 hours'
      end,
      status = case
        when claims_made + 1 >= max_claims then 'completed'
        else status
      end
  where id = p_membership_id;

  insert into public.wallet_transactions(
    user_id, type, amount, description
  )
  values(
    v_user,
    'gemstone_reward',
    v_reward,
    'Gemstone reward redeemed to wallet'
  );

  -- Keep an audit trail in point_transactions without affecting points_balance.
  insert into public.point_transactions(
    user_id, membership_id, type, points, description
  )
  values(
    v_user,
    p_membership_id,
    'redeemed_to_wallet',
    v_membership.points_per_claim,
    'Reward converted to wallet at PHP 1 per point'
  );

  return v_reward;
end;
$$;

revoke all on function public.redeem_membership(uuid) from public;
grant execute on function public.redeem_membership(uuid) to authenticated;

-- =========================================================
-- 3. RECREATE WITHDRAWALS USING WALLET BALANCE
-- =========================================================

-- Preserve the existing table but add a peso amount.
alter table public.withdrawal_requests
  add column if not exists amount numeric(12,2);

-- Convert old pending point requests to peso at 1:1.
update public.withdrawal_requests
set amount = points_amount::numeric
where amount is null;

alter table public.withdrawal_requests
  alter column amount set not null;

alter table public.withdrawal_requests
  drop constraint if exists withdrawal_requests_amount_check;

alter table public.withdrawal_requests
  add constraint withdrawal_requests_amount_check
  check (amount >= 120);

drop function if exists public.get_my_withdrawal_balance();

create or replace function public.get_my_withdrawal_balance()
returns table (
  wallet_balance numeric,
  pending_amount numeric,
  available_amount numeric,
  minimum_amount numeric
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
    p.wallet_balance::numeric,
    coalesce(sum(w.amount) filter (where w.status = 'pending_review'), 0)::numeric,
    (
      p.wallet_balance -
      coalesce(sum(w.amount) filter (where w.status = 'pending_review'), 0)
    )::numeric,
    120::numeric
  from public.profiles p
  left join public.withdrawal_requests w on w.user_id = p.id
  where p.id = v_user
  group by p.wallet_balance;
end;
$$;

drop function if exists public.create_withdrawal_request(bigint,text,text);
drop function if exists public.create_withdrawal_request(numeric,text,text);

create or replace function public.create_withdrawal_request(
  p_amount numeric,
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
  v_balance numeric(12,2);
  v_pending numeric(12,2);
  v_available numeric(12,2);
  v_request uuid;
  v_name text := trim(coalesce(p_gcash_name, ''));
  v_number text := regexp_replace(trim(coalesce(p_gcash_number, '')), '[^0-9]', '', 'g');
  v_amount numeric(12,2) := round(p_amount, 2);
begin
  if v_user is null then raise exception 'You must be logged in'; end if;

  if v_amount is null or v_amount < 120 then
    raise exception 'Minimum withdrawal is PHP 120';
  end if;

  if length(v_name) < 2 or length(v_name) > 100 then
    raise exception 'Enter the GCash account holder name';
  end if;

  if length(v_number) < 10 or length(v_number) > 13 then
    raise exception 'Enter a valid GCash mobile number';
  end if;

  select wallet_balance
  into v_balance
  from public.profiles
  where id = v_user
  for update;

  if not found then raise exception 'Profile not found'; end if;

  select coalesce(sum(amount), 0)
  into v_pending
  from public.withdrawal_requests
  where user_id = v_user
    and status = 'pending_review';

  v_available := v_balance - v_pending;

  if v_amount > v_available then
    raise exception 'Only PHP % is available after pending withdrawals', v_available;
  end if;

  insert into public.withdrawal_requests(
    user_id,
    points_amount,
    amount,
    gcash_name,
    gcash_number,
    status
  )
  values(
    v_user,
    ceil(v_amount)::bigint,
    v_amount,
    v_name,
    v_number,
    'pending_review'
  )
  returning id into v_request;

  return v_request;
end;
$$;

drop function if exists public.review_withdrawal_request(uuid,boolean,text);

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
  v_balance numeric(12,2);
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
    select wallet_balance
    into v_balance
    from public.profiles
    where id = v_request.user_id
    for update;

    if v_balance < v_request.amount then
      raise exception 'User has only PHP % remaining', v_balance;
    end if;

    update public.profiles
    set wallet_balance = wallet_balance - v_request.amount
    where id = v_request.user_id;

    insert into public.wallet_transactions(
      user_id, type, amount, description
    )
    values(
      v_request.user_id,
      'withdrawal',
      -v_request.amount,
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

drop function if exists public.admin_list_withdrawals(text);

create or replace function public.admin_list_withdrawals(
  p_status text default 'pending_review'
)
returns table (
  id uuid,
  user_id uuid,
  full_name text,
  email text,
  amount numeric,
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
    w.amount,
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
revoke all on function public.create_withdrawal_request(numeric,text,text) from public;
revoke all on function public.review_withdrawal_request(uuid,boolean,text) from public;
revoke all on function public.admin_list_withdrawals(text) from public;

grant execute on function public.get_my_withdrawal_balance() to authenticated;
grant execute on function public.create_withdrawal_request(numeric,text,text) to authenticated;
grant execute on function public.review_withdrawal_request(uuid,boolean,text) to authenticated;
grant execute on function public.admin_list_withdrawals(text) to authenticated;
