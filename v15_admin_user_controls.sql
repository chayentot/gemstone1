-- GEMSTONE V15 — SECURE ADMIN USER CONTROLS
-- Run once after V14.

create extension if not exists pgcrypto;

drop function if exists public.admin_adjust_user_wallet(uuid, numeric, text);
drop function if exists public.admin_delete_user_account(uuid, text, text);

create function public.admin_adjust_user_wallet(
  p_target_user_id uuid,
  p_adjustment numeric,
  p_reason text
)
returns numeric
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_old_balance numeric;
  v_new_balance numeric;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  if v_actor is null or not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;
  if p_target_user_id is null then
    raise exception 'A target user is required';
  end if;
  if p_target_user_id = v_actor then
    raise exception 'Administrators cannot adjust their own wallet';
  end if;
  if exists (select 1 from public.admins where user_id = p_target_user_id) then
    raise exception 'Administrator wallets are protected';
  end if;
  if p_adjustment is null or p_adjustment = 0 then
    raise exception 'Adjustment must not be zero';
  end if;
  if abs(p_adjustment) > 100000 then
    raise exception 'Maximum adjustment is ₱100,000 per operation';
  end if;
  if length(v_reason) < 5 then
    raise exception 'A clear reason of at least 5 characters is required';
  end if;

  select wallet_balance into v_old_balance
  from public.profiles
  where id = p_target_user_id
  for update;

  if not found then
    raise exception 'User profile not found';
  end if;

  v_new_balance := round(v_old_balance + p_adjustment, 2);
  if v_new_balance < 0 then
    raise exception 'Deduction exceeds the user wallet balance';
  end if;

  update public.profiles
  set wallet_balance = v_new_balance
  where id = p_target_user_id;

  perform public.write_audit_log(
    v_actor, p_target_user_id,
    case when p_adjustment > 0 then 'admin_wallet_credit' else 'admin_wallet_debit' end,
    'profile_wallet', p_target_user_id,
    jsonb_build_object('wallet_balance', v_old_balance),
    jsonb_build_object(
      'wallet_balance', v_new_balance,
      'adjustment', p_adjustment,
      'reason', left(v_reason, 300)
    )
  );

  return v_new_balance;
end;
$$;

create function public.admin_delete_user_account(
  p_target_user_id uuid,
  p_reason text,
  p_confirmation text
)
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := trim(coalesce(p_reason, ''));
  v_email text;
  v_name text;
  v_wallet numeric;
begin
  if v_actor is null or not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;
  if p_confirmation is distinct from 'DELETE' then
    raise exception 'Type DELETE to confirm permanent deletion';
  end if;
  if p_target_user_id is null then
    raise exception 'A target user is required';
  end if;
  if p_target_user_id = v_actor then
    raise exception 'You cannot delete your own administrator account';
  end if;
  if exists (select 1 from public.admins where user_id = p_target_user_id) then
    raise exception 'Administrator accounts cannot be deleted here';
  end if;
  if length(v_reason) < 10 then
    raise exception 'A detailed deletion reason of at least 10 characters is required';
  end if;
  if exists (
    select 1 from public.cash_in_requests
    where user_id = p_target_user_id
      and status in ('awaiting_reference', 'pending_review')
  ) then
    raise exception 'Review pending cash-in requests before deleting this account';
  end if;
  if exists (
    select 1 from public.withdrawal_requests
    where user_id = p_target_user_id and status = 'pending_review'
  ) then
    raise exception 'Review pending withdrawal requests before deleting this account';
  end if;

  select u.email::text, coalesce(p.full_name, 'Unnamed member'), p.wallet_balance
  into v_email, v_name, v_wallet
  from auth.users u
  left join public.profiles p on p.id = u.id
  where u.id = p_target_user_id
  for update of u;

  if not found then
    raise exception 'User account not found';
  end if;

  perform public.write_audit_log(
    v_actor, null, 'admin_user_deleted', 'auth_user', null,
    jsonb_build_object(
      'deleted_user_id', p_target_user_id,
      'email', v_email,
      'full_name', v_name,
      'wallet_balance', v_wallet
    ),
    jsonb_build_object(
      'reason', left(v_reason, 300),
      'deleted_at', now()
    )
  );

  delete from auth.users where id = p_target_user_id;
  if not found then
    raise exception 'User account could not be deleted';
  end if;

  return true;
end;
$$;

revoke all on function public.admin_adjust_user_wallet(uuid, numeric, text) from public;
revoke all on function public.admin_delete_user_account(uuid, text, text) from public;
revoke all on function public.admin_adjust_user_wallet(uuid, numeric, text) from anon;
revoke all on function public.admin_delete_user_account(uuid, text, text) from anon;

grant execute on function public.admin_adjust_user_wallet(uuid, numeric, text) to authenticated;
grant execute on function public.admin_delete_user_account(uuid, text, text) to authenticated;
