-- ═══════════════════════════════════════════════════════════════
-- TAAM — tickets RLS: 레스토랑 어드민이 '자기 매장' 구매(buyer) 조회 (2026-06-07)
-- ═══════════════════════════════════════════════════════════════
-- 배경:
--   · 티켓 캘린더에서 슈퍼어드민은 전체 구매자를 본다 (기존 RLS 로 동작 중).
--   · 레스토랑 어드민(파트너)은 '본인 매장' 의 구매만 보게 하려고 한다.
--   · 그런데 현재 어드민↔레스토랑 매핑(restId)은 앱 기기(IDB: adminCodes)에만 있고
--     서버 테이블이 없어서, Postgres RLS 가 "이 어드민이 어느 매장 담당인지" 알 수 없다.
--   · 따라서 (1) 서버 매핑 테이블을 만들고 (2) 그걸 참조하는 tickets SELECT 정책을 추가한다.
--
-- 전제(이미 존재):
--   · tickets.restaurant_id 는 text (앱이 String(restId) 로 저장).
--   · public.is_super_admin(uuid) 함수 — 다른 테이블 정책에서 이미 사용 중.
--   · profiles.role 에 'admin'/'partner' 값이 들어갈 수 있음.
--
-- 안전성:
--   · 이 스크립트는 '접근을 넓히기만' 한다. PostgreSQL 의 permissive 정책은 OR 로 합쳐지므로
--     기존 정책(본인 구매 조회 / 슈퍼어드민 조회)을 건드리지 않는다.
--   · 여러 번 실행해도 안전(idempotent): create if not exists / drop policy if exists 사용.
--
-- 실행: Supabase 대시보드 → SQL Editor 에 붙여넣고 1회 Run.
-- ═══════════════════════════════════════════════════════════════


-- ── 1) 어드민 ↔ 레스토랑 매핑 테이블 ────────────────────────────
create table if not exists public.restaurant_admins (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  restaurant_id   text not null,                 -- tickets.restaurant_id 와 동일 포맷(text)
  restaurant_name text,
  added_by        uuid references auth.users(id),-- 부여한 슈퍼어드민
  added_at        timestamptz not null default now(),
  unique (user_id, restaurant_id)
);

comment on table public.restaurant_admins is
  '레스토랑 어드민(파트너) ↔ 담당 매장 매핑. tickets RLS 에서 본인 매장 구매 조회 허용에 사용.';

create index if not exists idx_ra_user on public.restaurant_admins(user_id);
create index if not exists idx_ra_rest on public.restaurant_admins(restaurant_id);


-- ── 2) 헬퍼: 로그인 유저가 해당 매장의 어드민인가 ───────────────
--   SECURITY DEFINER 로 restaurant_admins 의 RLS 를 우회(재귀 정책 방지).
create or replace function public.is_restaurant_admin_of(p_restaurant_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.restaurant_admins ra
    where ra.user_id = auth.uid()
      and ra.restaurant_id = p_restaurant_id
  );
$$;

comment on function public.is_restaurant_admin_of(text) is
  '로그인 유저가 p_restaurant_id 매장의 어드민이면 true.';


-- ── 3) restaurant_admins 테이블 RLS ────────────────────────────
alter table public.restaurant_admins enable row level security;

-- SELECT: 슈퍼어드민은 전체 / 일반 어드민은 본인 매핑만
drop policy if exists "ra select" on public.restaurant_admins;
create policy "ra select" on public.restaurant_admins
  for select to authenticated
  using ( public.is_super_admin(auth.uid()) or user_id = auth.uid() );

-- INSERT/UPDATE/DELETE: 슈퍼어드민만 (매핑 부여·회수)
drop policy if exists "ra write" on public.restaurant_admins;
create policy "ra write" on public.restaurant_admins
  for all to authenticated
  using      ( public.is_super_admin(auth.uid()) )
  with check ( public.is_super_admin(auth.uid()) );


-- ── 4) tickets SELECT 정책 추가 (레스토랑 어드민용) ─────────────
-- ⚠ 기존 정책(본인 구매 조회, 슈퍼어드민 조회)은 그대로 둔다. 이 정책은 OR 로 합쳐져 접근만 넓힌다.
drop policy if exists "tickets select restaurant admin" on public.tickets;
create policy "tickets select restaurant admin" on public.tickets
  for select to authenticated
  using ( public.is_restaurant_admin_of(restaurant_id) );

-- (참고) 만약 슈퍼어드민 전체 조회 정책이 없다면(=캘린더에서 슈퍼어드민이 전체를 못 본다면)
--        아래 주석을 해제해 추가:
-- drop policy if exists "tickets select super admin" on public.tickets;
-- create policy "tickets select super admin" on public.tickets
--   for select to authenticated
--   using ( public.is_super_admin(auth.uid()) );


-- ═══════════════════════════════════════════════════════════════
-- 5) 매핑 데이터 채우기 ─ ⚠ 이 단계가 없으면 RLS 가 어드민을 알아보지 못한다
-- ═══════════════════════════════════════════════════════════════
-- 현재 앱은 어드민 코드(restId)를 기기 IDB(adminCodes) 에만 저장한다.
-- 서버 restaurant_admins 에 행이 있어야 RLS 가 "이 사람 = OO매장 어드민" 으로 인식한다.
--
-- 방법 A) 수동 1건 등록 (즉시 테스트용):
--   insert into public.restaurant_admins (user_id, restaurant_id, restaurant_name, added_by)
--   values ('<어드민 회원의 auth user uuid>', '<restId 문자열>', '<매장명>', auth.uid())
--   on conflict (user_id, restaurant_id) do nothing;
--
--   · '<어드민 회원의 auth user uuid>' = profiles.id (= auth.users.id).
--     이메일로 찾기:  select id, email from auth.users where email = 'admin@example.com';
--   · '<restId 문자열>' = tickets.restaurant_id 와 동일한 값.
--     매장별 값 확인:  select distinct restaurant_id, restaurant_name from public.tickets order by 2;
--
-- 방법 B) 앱 연동 (권장, 지속적):
--   슈퍼어드민이 '관리자 코드 부여'(acRegister) 할 때, 로컬 adminCodes 저장과 함께
--   restaurant_admins 에도 insert 하도록 앱을 수정.
--   (acRegister 는 이미 memberId(_acSelectedMember.id = profiles.id) 와 restId 를 알고 있으므로 바로 매핑 가능.)
--   → 이 앱 수정도 원하면 이어서 작업해줄게.
-- ═══════════════════════════════════════════════════════════════


-- ── 6) 검증 ────────────────────────────────────────────────────
-- 어드민 계정으로 로그인한 세션에서:
--   select count(*) from public.tickets;          -- 본인 매장 + 본인 구매만 보여야 함
--   select public.is_restaurant_admin_of('<restId>');  -- true 면 정상
