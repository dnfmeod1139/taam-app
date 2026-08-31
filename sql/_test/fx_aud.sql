-- ②가 기대는 표들을 실측 타입으로 추가
alter table public.profiles add column if not exists membership_tier text;
create table if not exists public.ticket_products(
  id text primary key, rest_id uuid, uploader_rest_id uuid,
  min_tier text, status text default 'active', audience jsonb);
create table if not exists public.ticket_access_lists(
  id uuid primary key default gen_random_uuid(),
  ticket_id text not null, user_id uuid not null,
  access_type text not null check (access_type in ('allow','block')),
  added_by uuid, added_at timestamptz default now(),
  unique (ticket_id, user_id, access_type));
create or replace function public.is_super_admin(uid uuid) returns boolean
 language sql stable as $$ select exists(select 1 from public.profiles p
   where p.id=uid and p.role in ('super_admin','superadmin')) $$;
-- 고치기 전 원본 (인자를 안 쓰는 버전) — ④ 검증이 진짜인지 보려고
create or replace function public.can_manage_ticket_access(p_ticket_id text)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_super_admin(auth.uid())
      or exists (select 1 from public.profiles p
                  where p.id=auth.uid() and p.role in ('admin','partner')) $$;
