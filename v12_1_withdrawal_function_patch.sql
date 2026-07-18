-- GEMSTONE V12.1 SQL PATCH
-- Fixes:
-- ERROR 42P13: cannot change return type of existing function
--
-- Run this patch first if V12 stopped at get_my_withdrawal_balance().
-- Then run the corrected v12_single_wallet_upgrade.sql again.

drop function if exists public.get_my_withdrawal_balance();
drop function if exists public.admin_list_withdrawals(text);

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
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  return query
  select
    p.wallet_balance::numeric,
    coalesce(
      sum(w.amount) filter (where w.status = 'pending_review'),
      0
    )::numeric,
    (
      p.wallet_balance -
      coalesce(
        sum(w.amount) filter (where w.status = 'pending_review'),
        0
      )
    )::numeric,
    120::numeric
  from public.profiles p
  left join public.withdrawal_requests w
    on w.user_id = p.id
  where p.id = v_user
  group by p.wallet_balance;
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
  where p_status = 'all'
     or w.status = p_status
  order by
    case when w.status = 'pending_review' then 0 else 1 end,
    w.created_at desc
  limit 300;
end;
$$;

revoke all on function public.get_my_withdrawal_balance() from public;
revoke all on function public.admin_list_withdrawals(text) from public;

grant execute on function public.get_my_withdrawal_balance() to authenticated;
grant execute on function public.admin_list_withdrawals(text) to authenticated;
