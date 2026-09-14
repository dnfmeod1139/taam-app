-- 미감사 5개 영역 SQL 재보기용 최소 표 (2026-09-14) — 라이브 모양을 흉내낸다
drop schema if exists public cascade; create schema public;
drop schema if exists auth cascade; create schema auth;
drop schema if exists storage cascade; create schema storage;
create table auth.users(id uuid primary key, email text, phone text, raw_user_meta_data jsonb default '{}'::jsonb, banned_until timestamptz);
create table auth.sessions(id uuid primary key default gen_random_uuid(), user_id uuid);
create table auth.refresh_tokens(id bigserial primary key, user_id text, session_id uuid);
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('taam.uid', true), '')::uuid $$;
create table storage.buckets(id text primary key, name text, public boolean default true, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table storage.objects enable row level security;
create table public.profiles(id uuid primary key, role text, membership_tier text, membership_expires_at timestamptz,
  guest_expires_at timestamptz, is_admin boolean default false, deleted_at timestamptz, display_name text, display_name_en text,
  phone text, email text, single_device_exempt boolean default false);
create table public.tickets(id bigserial primary key, user_id uuid, purchase_id text, status text);
create table public.invite_codes(id bigserial primary key, member_id text, invitee_tier text, invitee_email text, invitee_phone text, used_by_email text, used_by_phone text, used_at timestamptz);
create table public.admin_grants(id uuid primary key default gen_random_uuid(), user_id uuid, rest_id text);
create table public.membership_settings(k text primary key, v jsonb);
create table public.active_sessions(user_id uuid primary key, device_id text);
create table public.billing_keys(id bigserial, user_id uuid, deleted_at timestamptz);
create table public.push_subscriptions(id bigserial, user_id uuid);
do $$ begin
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;
grant usage on schema public, auth, storage to authenticated, anon, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select, insert, update, delete on storage.objects to authenticated, anon;
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer set search_path=public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('super_admin','superadmin')) $$;
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists (select 1 from public.profiles p where p.id = uid and p.role in ('super_admin','superadmin')) $$;
create or replace function public._taam_phone_key(p_text text) returns text language sql immutable as $$
  select right(regexp_replace(coalesce(p_text,''), '[^0-9]', '', 'g'), 10) $$;
-- 옛 정의들 (라이브에 있던 모양)
create or replace function public.taam_visit_reminder_notify() returns jsonb language sql as $$ select '{}'::jsonb $$;
create or replace function public.taam_guest_expiry_notify() returns jsonb language sql as $$ select '{}'::jsonb $$;
create or replace function public.taam_kashikiri_mark_paid(a text,b text,c bigint,d text,e text) returns jsonb language sql as $$ select '{}'::jsonb $$;
grant execute on function public.taam_kashikiri_mark_paid(text,text,bigint,text,text) to authenticated;  -- 「열려 있을 가능성」 재현
create or replace function public.taam_invited_tier(p_user_id uuid, p_email text, p_phone text) returns text language sql stable as $$
  select upper(ic.invitee_tier) from public.invite_codes ic
   where public._taam_phone_key(ic.invitee_phone) = public._taam_phone_key(p_phone) limit 1 $$;
-- 옛 게스트 연장 트리거 (INSERT 마다)
create or replace function public.taam_guest_touch_on_purchase() returns trigger language plpgsql as $$
begin update public.profiles set guest_expires_at = now() + interval '90 day' where id = new.user_id; return new; end $$;
create trigger trg_taam_guest_touch_on_purchase after insert on public.tickets for each row execute function public.taam_guest_touch_on_purchase();
-- 옛 Storage 정책들
insert into storage.buckets(id,name) values ('restaurant-videos','restaurant-videos'),('taam-photos','taam-photos'),('chef-photos','chef-photos'),('splash-media','splash-media');
create policy "Public read videos" on storage.objects for select to public using (bucket_id = 'restaurant-videos');
create policy "restaurant_videos_auth_insert" on storage.objects for insert to authenticated with check (bucket_id = 'restaurant-videos');
create policy "restaurant_videos_auth_update" on storage.objects for update to authenticated using (bucket_id = 'restaurant-videos') with check (bucket_id = 'restaurant-videos');
create policy "restaurant_videos_delete_superadmin" on storage.objects for delete to authenticated using (bucket_id = 'restaurant-videos' and public._taam_uid_is_super());
create policy chef_photos_admin_write on storage.objects for insert to authenticated
  with check (bucket_id = 'chef-photos' and (exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_admin=true) or public._taam_uid_is_super()));
create policy chef_photos_admin_update on storage.objects for update to authenticated
  using (bucket_id = 'chef-photos' and (exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_admin=true) or public._taam_uid_is_super()))
  with check (bucket_id = 'chef-photos' and (exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_admin=true) or public._taam_uid_is_super()));
-- 옛 탈퇴 RPC
create or replace function public.taam_delete_my_account() returns json language plpgsql security definer as $$
begin update public.profiles set deleted_at = now() where id = auth.uid(); return json_build_object('ok', true); end $$;
