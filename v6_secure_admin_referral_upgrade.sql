-- GEMSTONE V6 UPGRADE
-- Secure admins table, recursion-free RLS, manual GCash approval, and 8% referral commission.
-- Run once in Supabase SQL Editor. This migration does not delete existing data.

create extension if not exists pgcrypto;

alter table public.profiles
  add column if not exists referral_code text,
  add column if not exists referred_by uuid references public.profiles(id);

create unique index if not exists profiles_referral_code_unique_idx
  on public.profiles (upper(referral_code)) where referral_code is not null;

update public.profiles
set referral_code = upper(substr(replace(id::text, '-', ''), 1, 10))
where referral_code is null;

alter table public.profiles alter column referral_code set not null;

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;

drop policy if exists "admins_no_direct_access" on public.admins;
create policy "admins_no_direct_access" on public.admins
for all using (false) with check (false);

create or replace function public.is_current_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.admins where user_id=auth.uid()); $$;
revoke all on function public.is_current_admin() from public;
grant execute on function public.is_current_admin() to authenticated;

-- Remove the recursive policy that caused the error.
drop policy if exists "profiles_admin_read_all" on public.profiles;
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
for select using (auth.uid()=id);

create table if not exists public.referral_rewards (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references public.profiles(id) on delete cascade,
  referred_user_id uuid not null references public.profiles(id) on delete cascade,
  membership_id uuid not null references public.user_memberships(id) on delete cascade,
  purchase_amount numeric(12,2) not null check(purchase_amount>0),
  reward_rate numeric(5,4) not null default 0.08 check(reward_rate=0.08),
  reward_amount numeric(12,2) not null check(reward_amount>=0),
  created_at timestamptz not null default now(),
  unique(membership_id)
);
create index if not exists referral_rewards_referrer_idx
  on public.referral_rewards(referrer_id,created_at desc);
alter table public.referral_rewards enable row level security;
drop policy if exists "referral_rewards_read_own" on public.referral_rewards;
create policy "referral_rewards_read_own" on public.referral_rewards
for select using(auth.uid()=referrer_id or auth.uid()=referred_user_id);

create table if not exists public.cash_in_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(12,2) not null check(amount>=50 and amount<=100000),
  reference_number text,
  status text not null default 'awaiting_reference'
    check(status in('awaiting_reference','pending_review','approved','rejected','cancelled')),
  admin_note text,
  created_at timestamptz not null default now(),
  reference_submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);
create unique index if not exists cash_in_reference_unique_idx
  on public.cash_in_requests(lower(reference_number)) where reference_number is not null;
create index if not exists cash_in_user_created_idx on public.cash_in_requests(user_id,created_at desc);
create index if not exists cash_in_status_created_idx on public.cash_in_requests(status,created_at desc);
alter table public.cash_in_requests enable row level security;
drop policy if exists "cash_in_users_read_own" on public.cash_in_requests;
create policy "cash_in_users_read_own" on public.cash_in_requests
for select using(auth.uid()=user_id or public.is_current_admin());

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public
as $$
declare v_code text;
begin
  v_code:=upper(substr(replace(new.id::text,'-',''),1,10));
  insert into public.profiles(id,full_name,referral_code)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),v_code)
  on conflict(id) do update set
    full_name=excluded.full_name,
    referral_code=coalesce(public.profiles.referral_code,excluded.referral_code);
  return new;
end; $$;

create or replace function public.apply_referral_code(p_referral_code text)
returns void language plpgsql security definer set search_path=public
as $$
declare
  v_user uuid:=auth.uid();
  v_referrer uuid;
  v_code text:=upper(trim(p_referral_code));
begin
  if v_user is null then raise exception 'You must be logged in'; end if;
  if exists(select 1 from public.profiles where id=v_user and referred_by is not null)
    then raise exception 'A referral code has already been applied'; end if;
  select id into v_referrer from public.profiles where upper(referral_code)=v_code;
  if v_referrer is null then raise exception 'Referral code not found'; end if;
  if v_referrer=v_user then raise exception 'You cannot use your own referral code'; end if;
  update public.profiles set referred_by=v_referrer where id=v_user and referred_by is null;
  if not found then raise exception 'Referral code could not be applied'; end if;
end; $$;

create or replace function public.buy_gemstone(p_gemstone_id uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare
  v_user uuid:=auth.uid();
  v_gem public.gemstones%rowtype;
  v_wallet numeric(12,2);
  v_membership uuid;
  v_referrer uuid;
  v_reward numeric(12,2);
begin
  if v_user is null then raise exception 'You must be logged in'; end if;
  select * into v_gem from public.gemstones where id=p_gemstone_id and is_active=true;
  if not found then raise exception 'Gemstone is unavailable'; end if;
  select wallet_balance,referred_by into v_wallet,v_referrer
    from public.profiles where id=v_user for update;
  if v_wallet<v_gem.price then raise exception 'Insufficient wallet balance'; end if;
  update public.profiles set wallet_balance=wallet_balance-v_gem.price where id=v_user;
  insert into public.user_memberships
    (user_id,gemstone_id,purchase_price,points_per_claim,max_claims,next_redeem_at)
  values(v_user,v_gem.id,v_gem.price,v_gem.points_per_claim,v_gem.max_claims,now()+interval '24 hours')
  returning id into v_membership;
  insert into public.wallet_transactions(user_id,type,amount,description)
  values(v_user,'membership_purchase',-v_gem.price,'Purchased '||v_gem.name);
  if v_referrer is not null then
    v_reward:=round(v_gem.price*0.08,2);
    update public.profiles set wallet_balance=wallet_balance+v_reward where id=v_referrer;
    insert into public.referral_rewards(referrer_id,referred_user_id,membership_id,purchase_amount,reward_rate,reward_amount)
    values(v_referrer,v_user,v_membership,v_gem.price,0.08,v_reward);
    insert into public.wallet_transactions(user_id,type,amount,description)
    values(v_referrer,'referral_commission',v_reward,'8% referral commission from a '||v_gem.name||' purchase');
  end if;
  return v_membership;
end; $$;

create or replace function public.create_cash_in_request(p_amount numeric)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_user uuid:=auth.uid(); v_request uuid;
begin
  if v_user is null then raise exception 'You must be logged in'; end if;
  if p_amount<50 or p_amount>100000 then raise exception 'Amount must be from 50 to 100000'; end if;
  if exists(select 1 from public.cash_in_requests where user_id=v_user and status='awaiting_reference' and created_at>now()-interval '1 hour')
    then raise exception 'Submit the reference for your existing request first'; end if;
  insert into public.cash_in_requests(user_id,amount) values(v_user,round(p_amount,2)) returning id into v_request;
  return v_request;
end; $$;

create or replace function public.submit_cash_in_reference(p_request_id uuid,p_reference_number text)
returns void language plpgsql security definer set search_path=public
as $$
declare v_user uuid:=auth.uid(); v_reference text;
begin
  if v_user is null then raise exception 'You must be logged in'; end if;
  v_reference:=regexp_replace(trim(p_reference_number),'\s+','','g');
  if length(v_reference)<6 or length(v_reference)>80 then raise exception 'Invalid reference number'; end if;
  update public.cash_in_requests set reference_number=v_reference,status='pending_review',reference_submitted_at=now()
  where id=p_request_id and user_id=v_user and status='awaiting_reference';
  if not found then raise exception 'Cash-in request is unavailable or already submitted'; end if;
exception when unique_violation then raise exception 'This reference number has already been submitted';
end; $$;

create or replace function public.review_cash_in_request(p_request_id uuid,p_approve boolean,p_admin_note text default null)
returns void language plpgsql security definer set search_path=public
as $$
declare v_admin uuid:=auth.uid(); v_request public.cash_in_requests%rowtype;
begin
  if v_admin is null or not public.is_current_admin() then raise exception 'Administrator access required'; end if;
  select * into v_request from public.cash_in_requests where id=p_request_id for update;
  if not found then raise exception 'Cash-in request not found'; end if;
  if v_request.status<>'pending_review' then raise exception 'This request has already been reviewed'; end if;
  if p_approve then
    update public.profiles set wallet_balance=wallet_balance+v_request.amount where id=v_request.user_id;
    insert into public.wallet_transactions(user_id,type,amount,description)
    values(v_request.user_id,'gcash_cash_in',v_request.amount,'Approved GCash reference '||v_request.reference_number);
    update public.cash_in_requests set status='approved',admin_note=nullif(trim(coalesce(p_admin_note,'')),''),reviewed_at=now(),reviewed_by=v_admin where id=p_request_id;
  else
    if nullif(trim(coalesce(p_admin_note,'')),'') is null then raise exception 'A rejection reason is required'; end if;
    update public.cash_in_requests set status='rejected',admin_note=trim(p_admin_note),reviewed_at=now(),reviewed_by=v_admin where id=p_request_id;
  end if;
end; $$;

create or replace function public.admin_list_cash_ins(p_status text default 'pending_review')
returns table(id uuid,user_id uuid,full_name text,email text,amount numeric,reference_number text,status text,admin_note text,created_at timestamptz,reference_submitted_at timestamptz,reviewed_at timestamptz)
language plpgsql security definer set search_path=public,auth
as $$
begin
  if not public.is_current_admin() then raise exception 'Administrator access required'; end if;
  return query
  select c.id,c.user_id,p.full_name,u.email::text,c.amount,c.reference_number,c.status,c.admin_note,c.created_at,c.reference_submitted_at,c.reviewed_at
  from public.cash_in_requests c
  join public.profiles p on p.id=c.user_id
  join auth.users u on u.id=c.user_id
  where p_status='all' or c.status=p_status
  order by c.created_at desc limit 200;
end; $$;

revoke all on function public.apply_referral_code(text) from public;
revoke all on function public.buy_gemstone(uuid) from public;
revoke all on function public.create_cash_in_request(numeric) from public;
revoke all on function public.submit_cash_in_reference(uuid,text) from public;
revoke all on function public.review_cash_in_request(uuid,boolean,text) from public;
revoke all on function public.admin_list_cash_ins(text) from public;
grant execute on function public.apply_referral_code(text) to authenticated;
grant execute on function public.buy_gemstone(uuid) to authenticated;
grant execute on function public.create_cash_in_request(numeric) to authenticated;
grant execute on function public.submit_cash_in_reference(uuid,text) to authenticated;
grant execute on function public.review_cash_in_request(uuid,boolean,text) to authenticated;
grant execute on function public.admin_list_cash_ins(text) to authenticated;

-- After registering the admin account, run separately:
-- insert into public.admins(user_id)
-- select id from auth.users where email='YOUR_ADMIN_EMAIL@gmail.com'
-- on conflict(user_id) do nothing;
