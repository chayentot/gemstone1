-- GEMSTONE V8 WITHDRAWAL UPGRADE
-- Adds point withdrawal requests with protected administrator approval.
-- Minimum withdrawal: 120 points.
-- Run once after the V6/V7 upgrades. Existing data is not deleted.

create table if not exists public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  points_amount bigint not null check (points_amount >= 120),
  gcash_name text not null,
  gcash_number text not null,
  status text not null default 'pending_review'
    check (status in ('pending_review', 'approved', 'rejected', 'cancelled')),
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
create policy "withdrawals_read_own_or_admin"
on public.withdrawal_requests
for select
using (
  auth.uid() = user_id
  or public.is_current_admin()
);

-- Create a withdrawal request.
-- Pending requests reserve availability logically but do not deduct points yet.
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
  v_request uuid;
  v_name text := trim(p_gcash_name);
  v_number text := regexp_replace(trim(p_gcash_number), '\D', '', 'g');
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  if p_points_amount < 120 then
    raise exception 'Minimum withdrawal is 120 points';
  end if;

  if length(v_name) < 2 or length(v_name) > 100 then
    raise exception 'Enter a valid GCash account name';
  end if;

  if length(v_number) < 10 or length(v_number) > 13 then
    raise exception 'Enter a valid GCash mobile number';
  end if;

  select points_balance into v_balance
  from public.profiles
  where id = v_user;

  select coalesce(sum(points_amount), 0)::bigint into v_pending
  from public.withdrawal_requests
  where user_id = v_user
    and status = 'pending_review';

  if p_points_amount > v_balance - v_pending then
    raise exception 'Insufficient available points after pending withdrawals';
  end if;

  insert into public.withdrawal_requests(
    user_id, points_amount, gcash_name, gcash_number
  )
  values(
    v_user, p_points_amount, v_name, v_number
  )
  returning id into v_request;

  return v_request;
end;
$$;

-- Administrator approval/rejection.
-- Approval deducts points exactly once inside a locked transaction.
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

  select * into v_request
  from public.withdrawal_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Withdrawal request not found';
  end if;

  if v_request.status <> 'pending_review' then
    raise exception 'This withdrawal has already been reviewed';
  end if;

  if p_approve then
    select points_balance into v_balance
    from public.profiles
    where id = v_request.user_id
    for update;

    if v_balance < v_request.points_amount then
      raise exception 'User no longer has enough points';
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
      'Approved withdrawal to GCash ' || v_request.gcash_number
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

-- Secure admin listing function.
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
    p.full_name,
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
  order by w.created_at desc
  limit 200;
end;
$$;

revoke all on function public.create_withdrawal_request(bigint, text, text) from public;
revoke all on function public.review_withdrawal_request(uuid, boolean, text) from public;
revoke all on function public.admin_list_withdrawals(text) from public;

grant execute on function public.create_withdrawal_request(bigint, text, text) to authenticated;
grant execute on function public.review_withdrawal_request(uuid, boolean, text) to authenticated;
grant execute on function public.admin_list_withdrawals(text) to authenticated;
