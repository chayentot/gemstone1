-- GCash manual cash-in + protected admin approval upgrade
-- Run this ONCE in Supabase SQL Editor. It does not delete existing data.

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

create table if not exists public.cash_in_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(12,2) not null check (amount >= 50 and amount <= 100000),
  reference_number text,
  status text not null default 'awaiting_reference'
    check (status in ('awaiting_reference','pending_review','approved','rejected','cancelled')),
  admin_note text,
  created_at timestamptz not null default now(),
  reference_submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id)
);

create unique index if not exists cash_in_reference_unique_idx
  on public.cash_in_requests (lower(reference_number))
  where reference_number is not null;

create index if not exists cash_in_user_created_idx
  on public.cash_in_requests(user_id, created_at desc);

create index if not exists cash_in_status_created_idx
  on public.cash_in_requests(status, created_at desc);

alter table public.cash_in_requests enable row level security;

drop policy if exists "cash_in_users_read_own" on public.cash_in_requests;
create policy "cash_in_users_read_own"
on public.cash_in_requests for select
using (
  auth.uid() = user_id
  or exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_admin = true
  )
);

-- Admins need to read profile names on the admin page.
drop policy if exists "profiles_admin_read_all" on public.profiles;
create policy "profiles_admin_read_all"
on public.profiles for select
using (
  auth.uid() = id
  or exists (
    select 1 from public.profiles admin_profile
    where admin_profile.id = auth.uid()
      and admin_profile.is_admin = true
  )
);

create or replace function public.create_cash_in_request(p_amount numeric)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_request uuid;
begin
  if v_user is null then raise exception 'You must be logged in'; end if;
  if p_amount < 50 or p_amount > 100000 then
    raise exception 'Amount must be from 50 to 100000';
  end if;

  if exists (
    select 1 from public.cash_in_requests
    where user_id = v_user
      and status = 'awaiting_reference'
      and created_at > now() - interval '1 hour'
  ) then
    raise exception 'Submit the reference for your existing request first';
  end if;

  insert into public.cash_in_requests(user_id, amount)
  values(v_user, round(p_amount, 2))
  returning id into v_request;

  return v_request;
end;
$$;

create or replace function public.submit_cash_in_reference(
  p_request_id uuid,
  p_reference_number text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_reference text;
begin
  if v_user is null then raise exception 'You must be logged in'; end if;

  v_reference := regexp_replace(trim(p_reference_number), '\s+', '', 'g');
  if length(v_reference) < 6 or length(v_reference) > 80 then
    raise exception 'Invalid reference number';
  end if;

  update public.cash_in_requests
  set reference_number = v_reference,
      status = 'pending_review',
      reference_submitted_at = now()
  where id = p_request_id
    and user_id = v_user
    and status = 'awaiting_reference';

  if not found then
    raise exception 'Cash-in request is unavailable or already submitted';
  end if;

exception
  when unique_violation then
    raise exception 'This reference number has already been submitted';
end;
$$;

create or replace function public.review_cash_in_request(
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
  v_request public.cash_in_requests%rowtype;
begin
  if v_admin is null or not exists (
    select 1 from public.profiles
    where id = v_admin and is_admin = true
  ) then
    raise exception 'Administrator access required';
  end if;

  select * into v_request
  from public.cash_in_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Cash-in request not found'; end if;
  if v_request.status <> 'pending_review' then
    raise exception 'This request has already been reviewed';
  end if;

  if p_approve then
    update public.profiles
    set wallet_balance = wallet_balance + v_request.amount
    where id = v_request.user_id;

    insert into public.wallet_transactions(user_id, type, amount, description)
    values(
      v_request.user_id,
      'gcash_cash_in',
      v_request.amount,
      'Approved GCash reference ' || v_request.reference_number
    );

    update public.cash_in_requests
    set status = 'approved',
        admin_note = nullif(trim(coalesce(p_admin_note,'')), ''),
        reviewed_at = now(),
        reviewed_by = v_admin
    where id = p_request_id;
  else
    if nullif(trim(coalesce(p_admin_note,'')), '') is null then
      raise exception 'A rejection reason is required';
    end if;

    update public.cash_in_requests
    set status = 'rejected',
        admin_note = trim(p_admin_note),
        reviewed_at = now(),
        reviewed_by = v_admin
    where id = p_request_id;
  end if;
end;
$$;

revoke all on function public.create_cash_in_request(numeric) from public;
revoke all on function public.submit_cash_in_reference(uuid,text) from public;
revoke all on function public.review_cash_in_request(uuid,boolean,text) from public;

grant execute on function public.create_cash_in_request(numeric) to authenticated;
grant execute on function public.submit_cash_in_reference(uuid,text) to authenticated;
grant execute on function public.review_cash_in_request(uuid,boolean,text) to authenticated;

-- IMPORTANT: After your admin account is registered, replace the email below
-- and run this separate statement to grant administrator access:
--
-- update public.profiles
-- set is_admin = true
-- where id = (select id from auth.users where email = 'YOUR_ADMIN_EMAIL@example.com');
