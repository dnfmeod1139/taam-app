drop schema if exists public cascade; create schema public;
create schema if not exists auth;
create table auth.users(id uuid primary key);
-- 실측 타입 그대로
create table public.profiles(id uuid primary key, role text, display_name text);
create table public.restaurants(id uuid primary key default gen_random_uuid(), name text);
create table public.restaurant_admins(user_id uuid, restaurant_id text);
create table public.reservation_requests(
  id uuid primary key default gen_random_uuid(), user_id uuid, venue_id text,
  visit_status text, reserve_date date, status text default 'pending');
create table public.tickets(
  id uuid primary key default gen_random_uuid(),
  user_id uuid, restaurant_id text, purchase_id text,
  status text default 'active', price integer, party_size integer default 2,
  reservation_date text, reservation_time text, visit_time text,
  created_at timestamptz default now(), cancelled_at timestamptz,
  used_at timestamptz, extra_data jsonb);

-- auth.uid() 흉내
create or replace function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('taam.uid', true), '')::uuid $$;

-- 기존 가드(적용 전 상태)
create or replace function public._taam_uid_is_super() returns boolean
language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles p where p.id=auth.uid()
                 and p.role in ('super_admin','superadmin')) $$;
