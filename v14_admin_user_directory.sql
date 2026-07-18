-- GEMSTONE V14 — ADMIN USER DIRECTORY
-- Run once after V13.
-- Adds administrator-only summary and user listing functions.

drop function if exists public.admin_user_summary();
drop function if exists public.admin_list_users(text);

create function public.admin_user_summary()
returns table (
  total_users bigint,
  total_wallet_balance numeric,
  active_memberships bigint,
  pending_cash_ins bigint,
  pending_withdrawals bigint,
  total_referral_rewards numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;

  return query
  select
    (select count(*)::bigint from public.profiles),
    (select coalesce(sum(wallet_balance), 0)::numeric from public.profiles),
    (
      select count(*)::bigint
      from public.user_memberships
      where status = 'active'
    ),
    (
      select count(*)::bigint
      from public.cash_in_requests
      where status = 'pending_review'
    ),
    (
      select count(*)::bigint
      from public.withdrawal_requests
      where status = 'pending_review'
    ),
    (
      select coalesce(sum(reward_amount), 0)::numeric
      from public.referral_rewards
    );
end;
$$;

create function public.admin_list_users(
  p_search text default ''
)
returns table (
  user_id uuid,
  full_name text,
  email text,
  joined_at timestamptz,
  wallet_balance numeric,
  referral_code text,
  referred_by_name text,
  memberships_count bigint,
  active_memberships bigint,
  referral_count bigint,
  pending_cash_in_amount numeric,
  pending_withdrawal_amount numeric,
  is_admin boolean
)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_search text := lower(trim(coalesce(p_search, '')));
begin
  if not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;

  return query
  select
    p.id,
    coalesce(nullif(trim(p.full_name), ''), 'Unnamed member')::text,
    u.email::text,
    p.created_at,
    p.wallet_balance::numeric,
    p.referral_code,
    coalesce(nullif(trim(referrer.full_name), ''), referrer_user.email::text),
    (
      select count(*)::bigint
      from public.user_memberships m
      where m.user_id = p.id
    ),
    (
      select count(*)::bigint
      from public.user_memberships m
      where m.user_id = p.id and m.status = 'active'
    ),
    (
      select count(*)::bigint
      from public.profiles child
      where child.referred_by = p.id
    ),
    (
      select coalesce(sum(c.amount), 0)::numeric
      from public.cash_in_requests c
      where c.user_id = p.id and c.status = 'pending_review'
    ),
    (
      select coalesce(sum(w.amount), 0)::numeric
      from public.withdrawal_requests w
      where w.user_id = p.id and w.status = 'pending_review'
    ),
    exists (
      select 1 from public.admins a where a.user_id = p.id
    )
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.profiles referrer on referrer.id = p.referred_by
  left join auth.users referrer_user on referrer_user.id = p.referred_by
  where
    v_search = ''
    or lower(coalesce(p.full_name, '')) like '%' || v_search || '%'
    or lower(coalesce(u.email, '')) like '%' || v_search || '%'
    or lower(coalesce(p.referral_code, '')) like '%' || v_search || '%'
  order by p.created_at desc
  limit 500;
end;
$$;

revoke all on function public.admin_user_summary() from public;
revoke all on function public.admin_list_users(text) from public;

grant execute on function public.admin_user_summary() to authenticated;
grant execute on function public.admin_list_users(text) to authenticated;
