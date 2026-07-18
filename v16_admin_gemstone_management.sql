-- GEMSTONE V16 — ADMIN GEMSTONE MANAGEMENT
-- Run once after V15.

alter table public.gemstones
  add column if not exists image_url text;

drop function if exists public.admin_list_gemstones();
drop function if exists public.admin_create_gemstone(text,text,text,numeric,bigint,integer,boolean,text);
drop function if exists public.admin_update_gemstone(uuid,text,text,text,numeric,bigint,integer,boolean,text);

create function public.admin_list_gemstones()
returns table (
  id uuid,
  name text,
  emoji text,
  description text,
  price numeric,
  points_per_claim bigint,
  max_claims integer,
  is_active boolean,
  image_url text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;

  return query
  select
    g.id, g.name, g.emoji, g.description, g.price,
    g.points_per_claim, g.max_claims, g.is_active,
    g.image_url, g.created_at
  from public.gemstones g
  order by g.price, g.created_at;
end;
$$;

create function public.admin_create_gemstone(
  p_name text,
  p_emoji text,
  p_description text,
  p_price numeric,
  p_points_per_claim bigint,
  p_max_claims integer,
  p_is_active boolean,
  p_image_url text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
  v_name text := trim(coalesce(p_name, ''));
  v_image text := nullif(trim(coalesce(p_image_url, '')), '');
begin
  if v_actor is null or not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;
  if length(v_name) < 2 or length(v_name) > 60 then
    raise exception 'Gemstone name must contain 2 to 60 characters';
  end if;
  if p_price is null or p_price <= 0 or p_price > 10000000 then
    raise exception 'Price must be greater than zero and not exceed ₱10,000,000';
  end if;
  if p_points_per_claim is null or p_points_per_claim <= 0 or p_points_per_claim > 10000000 then
    raise exception 'Reward per claim must be from 1 to 10,000,000';
  end if;
  if p_max_claims is null or p_max_claims < 1 or p_max_claims > 3650 then
    raise exception 'Maximum claims must be from 1 to 3,650';
  end if;
  if v_image is not null
     and v_image !~* '^(https://|[a-z0-9][a-z0-9._/-]*\.(webp|png|jpg|jpeg|gif|svg))' then
    raise exception 'Image must be an HTTPS URL or a safe local image filename';
  end if;

  insert into public.gemstones (
    name, emoji, description, price, points_per_claim,
    max_claims, is_active, image_url
  ) values (
    v_name,
    left(coalesce(nullif(trim(p_emoji), ''), '💎'), 12),
    left(coalesce(p_description, ''), 500),
    round(p_price, 2),
    p_points_per_claim,
    p_max_claims,
    coalesce(p_is_active, true),
    v_image
  )
  returning id into v_id;

  perform public.write_audit_log(
    v_actor, null, 'admin_gemstone_created', 'gemstone', v_id,
    null,
    jsonb_build_object(
      'name', v_name,
      'price', round(p_price, 2),
      'points_per_claim', p_points_per_claim,
      'max_claims', p_max_claims,
      'is_active', coalesce(p_is_active, true),
      'image_url', v_image
    )
  );

  return v_id;
exception
  when unique_violation then
    raise exception 'A gemstone with this name already exists';
end;
$$;

create function public.admin_update_gemstone(
  p_gemstone_id uuid,
  p_name text,
  p_emoji text,
  p_description text,
  p_price numeric,
  p_points_per_claim bigint,
  p_max_claims integer,
  p_is_active boolean,
  p_image_url text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_old public.gemstones%rowtype;
  v_name text := trim(coalesce(p_name, ''));
  v_image text := nullif(trim(coalesce(p_image_url, '')), '');
begin
  if v_actor is null or not public.is_current_admin() then
    raise exception 'Administrator access required';
  end if;
  if p_gemstone_id is null then
    raise exception 'Gemstone ID is required';
  end if;
  if length(v_name) < 2 or length(v_name) > 60 then
    raise exception 'Gemstone name must contain 2 to 60 characters';
  end if;
  if p_price is null or p_price <= 0 or p_price > 10000000 then
    raise exception 'Price must be greater than zero and not exceed ₱10,000,000';
  end if;
  if p_points_per_claim is null or p_points_per_claim <= 0 or p_points_per_claim > 10000000 then
    raise exception 'Reward per claim must be from 1 to 10,000,000';
  end if;
  if p_max_claims is null or p_max_claims < 1 or p_max_claims > 3650 then
    raise exception 'Maximum claims must be from 1 to 3,650';
  end if;
  if v_image is not null
     and v_image !~* '^(https://|[a-z0-9][a-z0-9._/-]*\.(webp|png|jpg|jpeg|gif|svg))' then
    raise exception 'Image must be an HTTPS URL or a safe local image filename';
  end if;

  select * into v_old
  from public.gemstones
  where id = p_gemstone_id
  for update;

  if not found then
    raise exception 'Gemstone not found';
  end if;

  update public.gemstones
  set
    name = v_name,
    emoji = left(coalesce(nullif(trim(p_emoji), ''), '💎'), 12),
    description = left(coalesce(p_description, ''), 500),
    price = round(p_price, 2),
    points_per_claim = p_points_per_claim,
    max_claims = p_max_claims,
    is_active = coalesce(p_is_active, false),
    image_url = v_image
  where id = p_gemstone_id;

  perform public.write_audit_log(
    v_actor, null, 'admin_gemstone_updated', 'gemstone', p_gemstone_id,
    jsonb_build_object(
      'name', v_old.name,
      'price', v_old.price,
      'points_per_claim', v_old.points_per_claim,
      'max_claims', v_old.max_claims,
      'is_active', v_old.is_active,
      'image_url', v_old.image_url
    ),
    jsonb_build_object(
      'name', v_name,
      'price', round(p_price, 2),
      'points_per_claim', p_points_per_claim,
      'max_claims', p_max_claims,
      'is_active', coalesce(p_is_active, false),
      'image_url', v_image
    )
  );

  return true;
exception
  when unique_violation then
    raise exception 'A gemstone with this name already exists';
end;
$$;

revoke all on function public.admin_list_gemstones() from public, anon;
revoke all on function public.admin_create_gemstone(text,text,text,numeric,bigint,integer,boolean,text) from public, anon;
revoke all on function public.admin_update_gemstone(uuid,text,text,text,numeric,bigint,integer,boolean,text) from public, anon;

grant execute on function public.admin_list_gemstones() to authenticated;
grant execute on function public.admin_create_gemstone(text,text,text,numeric,bigint,integer,boolean,text) to authenticated;
grant execute on function public.admin_update_gemstone(uuid,text,text,text,numeric,bigint,integer,boolean,text) to authenticated;
