-- GEMSTONE V24 — REDEEM POINTS REPAIR
-- Run this once in Supabase SQL Editor.
--
-- Repairs the redeem_membership RPC so it uses the actual
-- user_memberships.claims_completed column.

drop function if exists public.redeem_membership(uuid);

create function public.redeem_membership(p_membership_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_membership public.user_memberships%rowtype;
  v_reward numeric(12,2);
  v_new_claims integer;
begin
  if v_user is null then
    raise exception 'You must be logged in';
  end if;

  if p_membership_id is null then
    raise exception 'Membership ID is required';
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

  if v_membership.claims_completed >= v_membership.max_claims then
    raise exception 'All rewards for this gemstone have already been claimed';
  end if;

  if v_membership.next_redeem_at is null
     or now() < v_membership.next_redeem_at then
    raise exception 'Reward is not available yet';
  end if;

  v_reward := round(v_membership.points_per_claim::numeric, 2);
  v_new_claims := v_membership.claims_completed + 1;

  update public.profiles
  set wallet_balance = wallet_balance + v_reward
  where id = v_user;

  if not found then
    raise exception 'User wallet was not found';
  end if;

  update public.user_memberships
  set
    claims_completed = v_new_claims,
    last_redeemed_at = now(),
    next_redeem_at = case
      when v_new_claims >= max_claims then null
      else now() + interval '24 hours'
    end,
    status = case
      when v_new_claims >= max_claims then 'completed'
      else 'active'
    end
  where id = p_membership_id;

  insert into public.wallet_transactions(
    user_id,
    type,
    amount,
    description
  )
  values(
    v_user,
    'gemstone_reward',
    v_reward,
    'Gemstone reward redeemed to wallet'
  );

  insert into public.point_transactions(
    user_id,
    membership_id,
    type,
    points,
    description
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
revoke all on function public.redeem_membership(uuid) from anon;
grant execute on function public.redeem_membership(uuid) to authenticated;
