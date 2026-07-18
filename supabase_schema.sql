-- GEMSTONE MEMBERSHIP DATABASE
-- Run this entire file once in Supabase Dashboard → SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  wallet_balance numeric(12,2) not null default 0 check (wallet_balance >= 0),
  points_balance bigint not null default 0 check (points_balance >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.gemstones (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  emoji text not null default '💎',
  description text not null default '',
  price numeric(12,2) not null check (price > 0),
  points_per_claim bigint not null check (points_per_claim > 0),
  max_claims integer not null check (max_claims > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.user_memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  gemstone_id uuid not null references public.gemstones(id),
  purchase_price numeric(12,2) not null,
  points_per_claim bigint not null,
  claims_completed integer not null default 0,
  max_claims integer not null,
  purchased_at timestamptz not null default now(),
  last_redeemed_at timestamptz,
  next_redeem_at timestamptz not null default (now() + interval '24 hours'),
  status text not null default 'active' check (status in ('active','completed'))
);

create table if not exists public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  amount numeric(12,2) not null,
  description text,
  created_at timestamptz not null default now()
);

create table if not exists public.point_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  membership_id uuid references public.user_memberships(id) on delete set null,
  type text not null,
  points bigint not null,
  description text,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Seed the 10 plans. Edit these values before launch.
insert into public.gemstones (name, emoji, description, price, points_per_claim, max_claims)
values
 ('Quartz','🔮','A simple starter membership.',500,10,30),
 ('Amethyst','🟣','A balanced early membership.',1000,25,30),
 ('Topaz','🟡','More points over a longer period.',2000,55,45),
 ('Garnet','🔴','A strong mid-level membership.',3000,90,45),
 ('Aquamarine','🔵','A bright long-term membership.',5000,160,60),
 ('Opal','🌈','A colorful premium membership.',7500,260,60),
 ('Sapphire','💙','A high-value gemstone membership.',10000,375,75),
 ('Emerald','💚','A long-running premium membership.',15000,600,90),
 ('Ruby','❤️','A powerful premium membership.',25000,1100,90),
 ('Diamond','💎','The highest gemstone membership.',50000,2500,120)
on conflict (name) do update set
 emoji = excluded.emoji,
 description = excluded.description,
 price = excluded.price,
 points_per_claim = excluded.points_per_claim,
 max_claims = excluded.max_claims;

alter table public.profiles enable row level security;
alter table public.gemstones enable row level security;
alter table public.user_memberships enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.point_transactions enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles for select using (auth.uid() = id);

drop policy if exists "gemstones_public_read" on public.gemstones;
create policy "gemstones_public_read" on public.gemstones for select using (is_active = true);

drop policy if exists "memberships_select_own" on public.user_memberships;
create policy "memberships_select_own" on public.user_memberships for select using (auth.uid() = user_id);

drop policy if exists "wallet_select_own" on public.wallet_transactions;
create policy "wallet_select_own" on public.wallet_transactions for select using (auth.uid() = user_id);

drop policy if exists "points_select_own" on public.point_transactions;
create policy "points_select_own" on public.point_transactions for select using (auth.uid() = user_id);

-- No direct insert/update/delete policies are provided.
-- Changes happen through these security-definer functions with server-side validation.

create or replace function public.buy_gemstone(p_gemstone_id uuid)
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
begin
  if v_user is null then raise exception 'You must be logged in'; end if;

  select * into v_gem from public.gemstones where id = p_gemstone_id and is_active = true;
  if not found then raise exception 'Gemstone is unavailable'; end if;

  select wallet_balance into v_wallet from public.profiles where id = v_user for update;
  if v_wallet < v_gem.price then raise exception 'Insufficient wallet balance'; end if;

  update public.profiles set wallet_balance = wallet_balance - v_gem.price where id = v_user;

  insert into public.user_memberships
    (user_id, gemstone_id, purchase_price, points_per_claim, max_claims, next_redeem_at)
  values
    (v_user, v_gem.id, v_gem.price, v_gem.points_per_claim, v_gem.max_claims, now() + interval '24 hours')
  returning id into v_membership;

  insert into public.wallet_transactions(user_id, type, amount, description)
  values(v_user, 'membership_purchase', -v_gem.price, 'Purchased ' || v_gem.name);

  return v_membership;
end;
$$;

create or replace function public.redeem_membership(p_membership_id uuid)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_membership public.user_memberships%rowtype;
  v_name text;
  v_new_count integer;
begin
  if v_user is null then raise exception 'You must be logged in'; end if;

  select * into v_membership
  from public.user_memberships
  where id = p_membership_id and user_id = v_user
  for update;

  if not found then raise exception 'Membership not found'; end if;
  if v_membership.status <> 'active' then raise exception 'Membership is complete'; end if;
  if now() < v_membership.next_redeem_at then raise exception 'Redemption is not available yet'; end if;

  v_new_count := v_membership.claims_completed + 1;
  select name into v_name from public.gemstones where id = v_membership.gemstone_id;

  update public.profiles
  set points_balance = points_balance + v_membership.points_per_claim
  where id = v_user;

  update public.user_memberships
  set claims_completed = v_new_count,
      last_redeemed_at = now(),
      next_redeem_at = now() + interval '24 hours',
      status = case when v_new_count >= max_claims then 'completed' else 'active' end
  where id = p_membership_id;

  insert into public.point_transactions(user_id, membership_id, type, points, description)
  values(v_user, p_membership_id, 'gemstone_redemption', v_membership.points_per_claim, 'Redeemed ' || v_name);

  return v_membership.points_per_claim;
end;
$$;

-- TESTING ONLY. Remove this function before connecting a real payment provider.
create or replace function public.demo_cash_in(p_amount numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_new_balance numeric(12,2);
begin
  if v_user is null then raise exception 'You must be logged in'; end if;
  if p_amount <= 0 or p_amount > 100000 then raise exception 'Invalid amount'; end if;

  update public.profiles
  set wallet_balance = wallet_balance + round(p_amount, 2)
  where id = v_user
  returning wallet_balance into v_new_balance;

  insert into public.wallet_transactions(user_id, type, amount, description)
  values(v_user, 'demo_cash_in', round(p_amount, 2), 'Testing funds only');

  return v_new_balance;
end;
$$;

revoke all on function public.buy_gemstone(uuid) from public;
revoke all on function public.redeem_membership(uuid) from public;
revoke all on function public.demo_cash_in(numeric) from public;

grant execute on function public.buy_gemstone(uuid) to authenticated;
grant execute on function public.redeem_membership(uuid) to authenticated;
grant execute on function public.demo_cash_in(numeric) to authenticated;
