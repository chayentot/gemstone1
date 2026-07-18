-- GEMSTONE V13 — SECURE WITHDRAWALS + 6% PROCESSING FEE
-- Run once after V12/V12.1.
--
-- Withdrawal calculation:
--   Gross request:  ₱1,000.00
--   Fee (6%):       ₱60.00
--   Net GCash pay:  ₱940.00
--   Wallet deduct:  ₱1,000.00
--
-- Security controls:
--   - All balance changes happen in security-definer database functions
--   - Fixed search_path
--   - Explicit EXECUTE grants
--   - RLS on sensitive tables
--   - Row locking and status checks
--   - Request idempotency
--   - Daily request limit
--   - Immutable audit log from browser clients

create extension if not exists pgcrypto;

-- =========================================================
-- 1. AUDIT LOG
-- =========================================================

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references auth.users(id),
  target_user_id uuid references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  old_data jsonb,
  new_data jsonb,
  ip_note text,
  created_at timestamptz not null default now()
);

create index if not exists audit_logs_created_idx
  on public.audit_logs(created_at desc);

create index if not exists audit_logs_target_idx
  on public.audit_logs(target_user_id, created_at desc);

alter table public.audit_logs enable row level security;

drop policy if exists "audit_logs_no_browser_access" on public.audit_logs;
create policy "audit_logs_no_browser_access"
on public.audit_logs
for all
using (false)
with check (false);

-- Internal audit writer. Do not grant this function to authenticated users.
create or replace function public.write_audit_log(
  p_actor uuid,
  p_target uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_old_data jsonb,
  p_new_data jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.audit_logs(
    actor_user_id,
    target_user_id,
    action,
    entity_type,
    entity_id,
    old_data,
    new_data
  )
  values(
    p_actor,
    p_target,
    left(p_action, 100),
    left(p_entity_type, 100),
    p_entity_id,
    p_old_data,
    p_new_data
  );
end;
$$;

revoke all on function public.write_audit_log(uuid,uuid,text,text,uuid,jsonb,jsonb) from public;
revoke all on function public.write_audit_log(uuid,uuid,text,text,uuid,jsonb,jsonb) from anon;
revoke all on function public.write_audit_log(uuid,uuid,text,text,uuid,jsonb,jsonb) from authenticated;

-- =========================================================
-- 2. WITHDRAWAL COLUMNS
-- =========================================================

alter table public.withdrawal_requests
  add column if not exists processing_fee numeric(12,2),
  add column if not exists net_amount numeric(12,2),
  add column if not exists request_key uuid,
  add column if not exists paid_reference text,
  add column if not exists paid_at timestamptz;

-- Backfill old rows using the 6% rule.
update public.withdrawal_requests
set processing_fee = round(amount * 0.06, 2)
where processing_fee is null;

update public.withdrawal_requests
set net_amount = round(amount - processing_fee, 2)
where net_amount is null;

update public.withdrawal_requests
set request_key = gen_random_uuid()
where request_key is null;

alter table public.withdrawal_requests
  alter column processing_fee set not null,
  alter column net_amount set not null,
  alter column request_key set not null;

create unique index if not exists withdrawal_request_key_unique_idx
  on public.withdrawal_requests(user_id, request_key);

alter table public.withdrawal_requests
  drop constraint if exists withdrawal_processing_fee_check,
  drop constraint if exists withdrawal_net_amount_check;

alter table public.withdrawal_requests
  add constraint withdrawal_processing_fee_check
    check (processing_fee = round(amount * 0.06, 2)),
  add constraint withdrawal_net_amount_check
    check (net_amount = round(amount - processing_fee, 2) and net_amount > 0);

-- Keep all direct writes blocked. Users read their own rows through RLS.
revoke insert, update, delete on public.withdrawal_requests from anon, authenticated;
grant select on public.withdrawal_requests to authenticated;

-- =========================================================
-- 3. WITHDRAWAL BALANCE
-- =========================================================

drop function if exists public.get_my_withdrawal_balance();

create function public.get_my_withdrawal_balance()
returns table (
  wallet_balance numeric,
  pending_amount numeric,
  available_amount numeric,
  minimum_amount numeric,
  processing_rate numeric
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
    120::numeric,
    0.06::numeric
  from public.profiles p
  left join public.withdrawal_requests w on w.user_id = p.id
  where p.id = v_user
  group by p.wallet_balance;
end;
$$;

-- =========================================================
-- 4. CREATE WITHDRAWAL
-- =========================================================

drop function if exists public.create_withdrawal_request(numeric,text,text);
drop function if exists public.create_withdrawal_request(numeric,text,text,uuid);

create function public.create_withdrawal_request(
  p_amount numeric,
  p_gcash_name text,
  p_gcash_number text,
  p_request_key uuid
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
  v_amount numeric(12,2) := round(p_amount, 2);
  v_fee numeric(12,2);
  v_net numeric(12,2);
  v_name text := trim(coalesce(p_gcash_name, ''));
  v_number text := regexp_replace(trim(coalesce(p_gcash_number, '')), '[^0-9]', '', 'g');
  v_request uuid;
  v_existing uuid;
begin
  if v_user is null then raise exception 'You must be logged in'; end if;
  if p_request_key is null then raise exception 'Missing secure request key'; end if;

  -- Idempotency: a repeated browser request returns the same record.
  select id into v_existing
  from public.withdrawal_requests
  where user_id = v_user and request_key = p_request_key;

  if v_existing is not null then return v_existing; end if;

  if v_amount is null or v_amount < 120 then
    raise exception 'Minimum withdrawal is PHP 120';
  end if;

  if v_amount > 100000 then
    raise exception 'Maximum withdrawal per request is PHP 100,000';
  end if;

  if length(v_name) < 2 or length(v_name) > 100 then
    raise exception 'Enter the GCash account holder name';
  end if;

  if length(v_number) < 10 or length(v_number) > 13 then
    raise exception 'Enter a valid GCash mobile number';
  end if;

  -- Basic abuse protection.
  if (
    select count(*)
    from public.withdrawal_requests
    where user_id = v_user
      and created_at > now() - interval '24 hours'
  ) >= 3 then
    raise exception 'Maximum of 3 withdrawal requests per 24 hours';
  end if;

  select wallet_balance into v_balance
  from public.profiles
  where id = v_user
  for update;

  if not found then raise exception 'Profile not found'; end if;

  select coalesce(sum(amount), 0)
  into v_pending
  from public.withdrawal_requests
  where user_id = v_user and status = 'pending_review';

  v_available := v_balance - v_pending;
  if v_amount > v_available then
    raise exception 'Only PHP % is available after pending withdrawals', v_available;
  end if;

  v_fee := round(v_amount * 0.06, 2);
  v_net := round(v_amount - v_fee, 2);

  insert into public.withdrawal_requests(
    user_id,
    points_amount,
    amount,
    processing_fee,
    net_amount,
    gcash_name,
    gcash_number,
    request_key,
    status
  )
  values(
    v_user,
    ceil(v_amount)::bigint,
    v_amount,
    v_fee,
    v_net,
    v_name,
    v_number,
    p_request_key,
    'pending_review'
  )
  returning id into v_request;

  perform public.write_audit_log(
    v_user,
    v_user,
    'withdrawal_requested',
    'withdrawal_request',
    v_request,
    null,
    jsonb_build_object(
      'gross_amount', v_amount,
      'processing_fee', v_fee,
      'net_amount', v_net,
      'gcash_number_masked', right(v_number, 4)
    )
  );

  return v_request;
end;
$$;

-- =========================================================
-- 5. ADMIN REVIEW
-- =========================================================

drop function if exists public.review_withdrawal_request(uuid,boolean,text);

create function public.review_withdrawal_request(
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

  select * into v_request
  from public.withdrawal_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Withdrawal request not found'; end if;
  if v_request.status <> 'pending_review' then
    raise exception 'This request was already reviewed';
  end if;
  if v_request.user_id = v_admin then
    raise exception 'Administrators cannot approve their own withdrawal';
  end if;

  if p_approve then
    select wallet_balance into v_balance
    from public.profiles
    where id = v_request.user_id
    for update;

    if v_balance < v_request.amount then
      raise exception 'User has only PHP % remaining', v_balance;
    end if;

    update public.profiles
    set wallet_balance = wallet_balance - v_request.amount
    where id = v_request.user_id;

    insert into public.wallet_transactions(user_id, type, amount, description)
    values(
      v_request.user_id,
      'withdrawal',
      -v_request.amount,
      'Withdrawal: net GCash payout PHP ' || v_request.net_amount ||
      ', processing fee PHP ' || v_request.processing_fee
    );

    update public.withdrawal_requests
    set status = 'approved',
        admin_note = nullif(trim(coalesce(p_admin_note, '')), ''),
        reviewed_at = now(),
        reviewed_by = v_admin
    where id = p_request_id;

    perform public.write_audit_log(
      v_admin,
      v_request.user_id,
      'withdrawal_approved',
      'withdrawal_request',
      v_request.id,
      jsonb_build_object('status', v_request.status),
      jsonb_build_object(
        'status', 'approved',
        'gross_amount', v_request.amount,
        'processing_fee', v_request.processing_fee,
        'net_amount', v_request.net_amount
      )
    );
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

    perform public.write_audit_log(
      v_admin,
      v_request.user_id,
      'withdrawal_rejected',
      'withdrawal_request',
      v_request.id,
      jsonb_build_object('status', v_request.status),
      jsonb_build_object('status', 'rejected', 'reason', trim(p_admin_note))
    );
  end if;
end;
$$;

-- Optional final payment confirmation.
create or replace function public.mark_withdrawal_paid(
  p_request_id uuid,
  p_paid_reference text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_request public.withdrawal_requests%rowtype;
  v_reference text := regexp_replace(trim(coalesce(p_paid_reference, '')), '\s+', '', 'g');
begin
  if v_admin is null or not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;

  if length(v_reference) < 6 or length(v_reference) > 80 then
    raise exception 'Enter a valid payout reference';
  end if;

  select * into v_request
  from public.withdrawal_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'Withdrawal request not found'; end if;
  if v_request.status <> 'approved' then
    raise exception 'Only approved withdrawals can be marked paid';
  end if;
  if v_request.paid_at is not null then
    raise exception 'This withdrawal was already marked paid';
  end if;

  update public.withdrawal_requests
  set paid_reference = v_reference,
      paid_at = now()
  where id = p_request_id;

  perform public.write_audit_log(
    v_admin,
    v_request.user_id,
    'withdrawal_marked_paid',
    'withdrawal_request',
    v_request.id,
    null,
    jsonb_build_object(
      'net_amount', v_request.net_amount,
      'paid_reference', v_reference
    )
  );
end;
$$;

-- =========================================================
-- 6. ADMIN LISTING
-- =========================================================

drop function if exists public.admin_list_withdrawals(text);

create function public.admin_list_withdrawals(
  p_status text default 'pending_review'
)
returns table (
  id uuid,
  user_id uuid,
  full_name text,
  email text,
  amount numeric,
  processing_fee numeric,
  net_amount numeric,
  gcash_name text,
  gcash_number text,
  status text,
  admin_note text,
  paid_reference text,
  paid_at timestamptz,
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
    w.processing_fee,
    w.net_amount,
    w.gcash_name,
    w.gcash_number,
    w.status,
    w.admin_note,
    w.paid_reference,
    w.paid_at,
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

create or replace function public.admin_list_audit_logs()
returns table (
  id uuid,
  actor_email text,
  target_email text,
  action text,
  entity_type text,
  entity_id uuid,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz
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
    a.id,
    actor.email::text,
    target.email::text,
    a.action,
    a.entity_type,
    a.entity_id,
    a.old_data,
    a.new_data,
    a.created_at
  from public.audit_logs a
  left join auth.users actor on actor.id = a.actor_user_id
  left join auth.users target on target.id = a.target_user_id
  order by a.created_at desc
  limit 500;
end;
$$;

-- =========================================================
-- 7. PERMISSIONS
-- =========================================================

revoke all on function public.get_my_withdrawal_balance() from public;
revoke all on function public.create_withdrawal_request(numeric,text,text,uuid) from public;
revoke all on function public.review_withdrawal_request(uuid,boolean,text) from public;
revoke all on function public.mark_withdrawal_paid(uuid,text) from public;
revoke all on function public.admin_list_withdrawals(text) from public;
revoke all on function public.admin_list_audit_logs() from public;

grant execute on function public.get_my_withdrawal_balance() to authenticated;
grant execute on function public.create_withdrawal_request(numeric,text,text,uuid) to authenticated;
grant execute on function public.review_withdrawal_request(uuid,boolean,text) to authenticated;
grant execute on function public.mark_withdrawal_paid(uuid,text) to authenticated;
grant execute on function public.admin_list_withdrawals(text) to authenticated;
grant execute on function public.admin_list_audit_logs() to authenticated;
