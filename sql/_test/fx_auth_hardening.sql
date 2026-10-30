-- 가입·초대·프로필 연락처 강화(20261030_auth_hardening.sql) 재보기용 — 라이브 모양(진단 20261030_diag_signup_*)을 옮겼다
drop schema if exists public cascade; create schema public;
drop schema if exists auth cascade; create schema auth;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;
alter role service_role bypassrls;
grant usage on schema public, auth to authenticated, anon, service_role;
-- Supabase 기본 권한: public 의 새 표·함수는 anon·authenticated·service_role 에게 열린다(권한 회수 검사가 헛돌지 않게)
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

create table auth.users(id uuid primary key default gen_random_uuid(), email text, phone text,
  raw_user_meta_data jsonb default '{}'::jsonb, raw_app_meta_data jsonb default '{}'::jsonb,
  email_confirmed_at timestamptz, phone_confirmed_at timestamptz, last_sign_in_at timestamptz, encrypted_password text default '',
  created_at timestamptz default now());
-- Supabase 와 같은 모양: JWT claims 의 sub
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'sub', '')::uuid $$;
grant execute on function auth.uid() to authenticated, anon, service_role;

create table public.profiles(id uuid primary key, role text default 'user', email text, phone text, display_name text, display_name_en text,
  deleted_at timestamptz, membership_tier text, created_at timestamptz default now());
create table public.notif_prefs(user_id uuid primary key);
create table public.invite_codes(code text, type text, invitee_name text, invitee_phone text, invite_message text, invited_by text,
  invited_at timestamptz default now(), expires_at timestamptz, used boolean default false, member_id text, used_at timestamptz,
  used_by_phone text, used_by_name text, used_by_email text, created_at timestamptz default now(), country text, invitee_email text, invitee_tier text);
create table public.app_config(key text primary key, value jsonb, updated_at timestamptz);
create table public.admin_grants(user_id uuid, rest_id text, status text);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), link_invite boolean, status text, user_id uuid, payer_phone text, payer_name text, label text, payload jsonb default '{}'::jsonb);
create table public.tickets(id bigserial primary key, purchase_id text, user_id uuid, status text, extra_data jsonb default '{}'::jsonb);
grant select, insert, update, delete on public.profiles, public.invite_codes, public.kashikiri_charges, public.tickets to authenticated, service_role;
grant select on public.app_config to authenticated, anon;

create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer set search_path=public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('super_admin','superadmin')) $$;
create or replace function public.is_superadmin() returns boolean language sql stable security definer set search_path=public as $$ select public._taam_uid_is_super() $$;
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists (select 1 from public.profiles p where p.id = uid and p.role in ('super_admin','superadmin')) $$;

-- 라이브 정책 (진단 ⑤ · ⑫)
alter table public.invite_codes enable row level security;
create policy invite_codes_read on public.invite_codes for select to authenticated using (true);
create policy "super_admin can read all invite codes" on public.invite_codes for select to authenticated using (public.is_super_admin(auth.uid()));
create policy invite_codes_superadmin_modify on public.invite_codes for update to authenticated using (public.is_superadmin()) with check (public.is_superadmin());
create policy invite_codes_superadmin_write on public.invite_codes for insert to authenticated with check (public.is_superadmin());
create policy invite_codes_superadmin_delete on public.invite_codes for delete to authenticated using (public.is_superadmin());
alter table public.profiles enable row level security;
create policy profiles_select_own on public.profiles for select to authenticated using ((auth.uid() = id) or public.is_superadmin());
create policy profiles_update_own on public.profiles for update to authenticated using ((auth.uid() = id) or public.is_superadmin()) with check ((auth.uid() = id) or public.is_superadmin());
create policy profiles_insert_own on public.profiles for insert to authenticated with check (auth.uid() = id);
alter table public.tickets enable row level security;
create policy t_own on public.tickets for select to authenticated using (user_id = auth.uid());

-- 라이브 auth 트리거 함수 셋 (진단 본문 그대로)
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles (id, phone) values (new.id, new.phone);
  insert into public.notif_prefs (user_id) values (new.id);
  return new;
end; $$;
create or replace function public.sync_profile_contact_from_auth() returns trigger language plpgsql security definer set search_path=public as $$
begin
  update public.profiles
  set
    email = coalesce(nullif(public.profiles.email,''), new.email),
    phone = coalesce(nullif(public.profiles.phone,''), new.phone, new.raw_user_meta_data->>'phone')
  where id = new.id;
  return new;
end; $$;
create or replace function public.sync_profile_email_from_auth() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'display_name', ''))
  on conflict (id) do update
    set email = excluded.email
    where public.profiles.email is distinct from excluded.email;
  return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
create trigger trg_sync_profile_contact after insert or update of email, phone, raw_user_meta_data on auth.users for each row execute function public.sync_profile_contact_from_auth();
create trigger trg_sync_profile_email after insert or update of email on auth.users for each row execute function public.sync_profile_email_from_auth();

-- K 글자 검사(회원 세션) — 20261029 와 같은 판정
create or replace function public._taam_text_bad(v jsonb, p_old jsonb)
returns boolean language sql immutable as $$
  select exists (
    select 1 from jsonb_path_query(v, 'strict $.** ? (@.type() == "string")') x
     where ((x #>> '{}') ~* '<\s*[a-z/!?]' or (x #>> '{}') ~* 'javascript\s*:')
       and (p_old is null or not exists (select 1 from jsonb_path_query(p_old, 'strict $.** ? (@.type() == "string")') y where (y #>> '{}') = (x #>> '{}'))))
$$;
grant execute on function public._taam_text_bad(jsonb, jsonb) to authenticated;
create or replace function public.taam_guard_text_input() returns trigger language plpgsql set search_path = public as $$
begin
  if auth.uid() is null or public.is_super_admin(auth.uid()) then return new; end if;
  if public._taam_text_bad(to_jsonb(new), case when tg_op = 'UPDATE' then to_jsonb(old) end) then
    raise exception 'BAD_INPUT: 태그 모양' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger trg_taam_guard_text_input before insert or update on public.profiles for each row execute function public.taam_guard_text_input();

-- 초대코드 행 가드 (audit_hardening_2026-09-13)
create or replace function public.taam_guard_invite_code_row() returns trigger language plpgsql set search_path = public as $$
declare
  v_allowed text[] := array['used','used_at','used_by','used_by_email','used_by_name','used_by_phone','used_by_user_id','used_by_uid','updated_at'];
  v_old jsonb := to_jsonb(old) - v_allowed;
  v_new jsonb := to_jsonb(new) - v_allowed;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if public._taam_uid_is_super() then return new; end if;
  if v_new <> v_old then raise exception '초대코드는 사용 표시만 바꿀 수 있습니다' using errcode = '42501'; end if;
  if coalesce((to_jsonb(old)->>'used')::boolean, false) and not coalesce((to_jsonb(new)->>'used')::boolean, false) then
    raise exception '사용된 초대코드는 되살릴 수 없습니다' using errcode = '42501';
  end if;
  return new;
end; $$;
create trigger trg_taam_guard_invite_code_row before update on public.invite_codes for each row execute function public.taam_guard_invite_code_row();

-- 라이브 RPC 둘 (진단 본문 그대로)
create or replace function public.consume_invite_by_self() returns integer language plpgsql volatile security definer set search_path=public as $$
declare my_id uuid; my_email text; my_phone text; my_phone_digits text; my_name text; updated_count integer := 0;
begin
  my_id := auth.uid();
  if my_id is null then return 0; end if;
  select lower(coalesce(email,'')), coalesce(phone,'') into my_email, my_phone from auth.users where id = my_id;
  if my_phone is null or my_phone = '' then select coalesce(phone,'') into my_phone from public.profiles where id = my_id; end if;
  select coalesce(nullif(btrim(display_name),''), '') into my_name from public.profiles where id = my_id;
  my_phone_digits := regexp_replace(coalesce(my_phone,''), '[^0-9]', '', 'g');
  my_phone_digits := regexp_replace(my_phone_digits, '^82', '');
  my_phone_digits := regexp_replace(my_phone_digits, '^0+', '');
  update public.invite_codes ic set used = true, used_at = coalesce(ic.used_at, now()),
    used_by_email = coalesce(nullif(btrim(ic.used_by_email),''), nullif(my_email,'')),
    used_by_phone = coalesce(nullif(btrim(ic.used_by_phone),''), nullif(my_phone,'')),
    used_by_name  = coalesce(nullif(btrim(ic.used_by_name),''), nullif(my_name,''), ic.invitee_name),
    member_id     = coalesce(nullif(btrim(ic.member_id),''), my_id::text)
  where ic.used = false
    and ((my_email <> '' and (lower(coalesce(ic.invitee_email,'')) = my_email or lower(coalesce(ic.used_by_email,'')) = my_email))
      or (length(my_phone_digits) >= 4 and (
            regexp_replace(coalesce(ic.invitee_phone,''), '[^0-9]', '', 'g') like '%' || my_phone_digits || '%'
         or regexp_replace(coalesce(ic.used_by_phone,''), '[^0-9]', '', 'g') like '%' || my_phone_digits || '%')));
  get diagnostics updated_count = row_count;
  return updated_count;
end; $$;
create or replace function public.user_has_invite_match() returns boolean language plpgsql stable security definer set search_path=public as $$
declare my_email text; my_phone text; my_phone_digits text; my_id uuid; cnt integer;
begin
  my_id := auth.uid();
  if my_id is null then return false; end if;
  select lower(coalesce(email, '')), coalesce(phone, '') into my_email, my_phone from auth.users where id = my_id;
  if my_phone is null or my_phone = '' then select coalesce(phone, '') into my_phone from public.profiles where id = my_id; end if;
  my_phone_digits := regexp_replace(coalesce(my_phone, ''), '[^0-9]', '', 'g');
  my_phone_digits := regexp_replace(my_phone_digits, '^82', '');
  my_phone_digits := regexp_replace(my_phone_digits, '^0+', '');
  select count(*) into cnt from public.invite_codes ic
  where (my_email <> '' and (lower(coalesce(ic.invitee_email,'')) = my_email or lower(coalesce(ic.used_by_email,'')) = my_email))
     or (length(my_phone_digits) >= 4 and (
          regexp_replace(coalesce(ic.invitee_phone,''), '[^0-9]', '', 'g') like '%' || my_phone_digits || '%'
       or regexp_replace(coalesce(ic.used_by_phone,''), '[^0-9]', '', 'g') like '%' || my_phone_digits || '%'));
  return cnt > 0;
end; $$;
grant execute on function public.consume_invite_by_self(), public.user_has_invite_match() to anon, authenticated;

-- 서버 전용 도우미(라이브에 있다) — 회수 검사용
create or replace function public.email_exists_in_auth(email_to_check text) returns boolean language sql stable security definer set search_path=public, auth as $$
  select exists (select 1 from auth.users where lower(email) = lower(email_to_check)) $$;
create or replace function public.email_exists_in_auth_other(email_to_check text, exclude_id uuid) returns boolean language sql stable security definer set search_path=public, auth as $$
  select exists (select 1 from auth.users where lower(email) = lower(email_to_check) and id is distinct from exclude_id) $$;
grant execute on function public.email_exists_in_auth(text), public.email_exists_in_auth_other(text, uuid) to anon, authenticated;
-- 회원·anon 이 부를 수 있는 정의자 함수가 초대장을 소진하는 모양(소진 가드의 회원/anon 분기 검사용)
create or replace function public._t_mark_used(p_code text) returns int language plpgsql security definer set search_path=public as $$
declare n int; begin update public.invite_codes set used = true where code = p_code and not used; get diagnostics n = row_count; return n; end $$;
grant execute on function public._t_mark_used(text) to anon, authenticated;
