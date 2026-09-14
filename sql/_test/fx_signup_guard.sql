-- 가입 문지기 재보기용 최소 표 (2026-09-14)
drop schema if exists public cascade; create schema public;
drop schema if exists auth cascade; create schema auth;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, phone text,
  raw_user_meta_data jsonb default '{}'::jsonb, raw_app_meta_data jsonb default '{}'::jsonb);
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('taam.uid', true), '')::uuid $$;
create table public.profiles(id uuid primary key, role text, email text, display_name text);
-- 라이브처럼 expires_at 을 text 로 둔다 (타입 짐작 사고 예방)
create table public.invite_codes(id bigserial primary key, code text, used boolean default false, expires_at text,
  invitee_name text, invitee_phone text, invitee_email text, invited_at timestamptz default now());
create table public.app_config(key text primary key, value jsonb, updated_at timestamptz);
do $$ begin
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
end $$;
grant usage on schema public, auth to authenticated, anon;
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer set search_path=public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'super_admin') $$;
-- 라이브에 있는 profiles 동기화 트리거 (같이 돌아야 순서 문제가 없다)
create or replace function public.sync_profile_email_from_auth() returns trigger language plpgsql security definer as $$
begin insert into public.profiles(id,email,display_name) values (new.id,new.email,coalesce(new.raw_user_meta_data->>'display_name',''))
  on conflict (id) do update set email = excluded.email; return new; end $$;
create trigger trg_sync_profile_email after insert or update of email on auth.users for each row execute function public.sync_profile_email_from_auth();
insert into public.invite_codes(code,used,expires_at,invitee_name,invitee_phone,invitee_email) values
 ('LIVE01', false, null, '홍길동', '010-1111-2222', null),
 ('MAIL01', false, null, 'Kim', null, 'kim@x.com'),
 ('OPEN01', false, null, '', null, null),
 ('USED01', true,  null, '', null, null),
 ('EXP001', false, '2020-01-01T00:00:00Z', '', null, null),
 ('BAD001', false, 'not-a-date', '', null, null);
