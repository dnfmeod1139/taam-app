-- ═══════════════════════════════════════════════════════════════
-- TAAM 권한 통합 — admin_grants (어드민↔매장 서버 기록) + 권한함수 일원화
-- 작성: 2026-06-10  ⚠ 먼저 이 파일 → (앱에서 동기화) → 그 다음 ticket_products_enforcement.sql
-- ═══════════════════════════════════════════════════════════════
-- 목적:
--   · 기존 어드민 권한이 기기 로컬(adminCodes/IDB)에만 있어 서버 강제 불가했던 문제 해결.
--   · 티켓(rest_id)·예약(venue_id) 두 도메인의 어드민 매핑을 admin_grants 한 곳으로 통일.
--   · is_restaurant_admin_of / is_venue_admin_of 를 admin_grants 기반으로 재정의(#3 통합).
-- 키:
--   · rest_id   = ticket_products.rest_id (티켓 도메인)
--   · venue_id  = venue_partners.venue_id (예약 도메인, 정적 큐레이션 id)
-- 실행: Supabase SQL Editor (idempotent).
-- ═══════════════════════════════════════════════════════════════


-- ── 1) admin_grants 테이블 ──
create table if not exists public.admin_grants (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  rest_id    text,                       -- 티켓 도메인 권한 (nullable)
  venue_id   text,                       -- 예약 도메인 권한 (nullable)
  label      text,                       -- 매장명 표시용
  granted_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_ag_user  on public.admin_grants(user_id);
create index if not exists idx_ag_rest   on public.admin_grants(rest_id);
create index if not exists idx_ag_venue  on public.admin_grants(venue_id);
-- 중복 방지 (부분 unique — null 도메인은 제외)
create unique index if not exists uq_ag_user_rest  on public.admin_grants(user_id, rest_id)  where rest_id  is not null;
create unique index if not exists uq_ag_user_venue on public.admin_grants(user_id, venue_id) where venue_id is not null;

comment on table public.admin_grants is '어드민↔매장 권한 서버 기록. rest_id=티켓도메인, venue_id=예약도메인.';


-- ── 2) 권한 판정 함수 (admin_grants 기반으로 일원화) ──
create or replace function public.is_ticket_admin_of(p_rest_id text)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.admin_grants
                 where user_id = auth.uid() and rest_id = p_rest_id);
$$;

-- 기존 함수 재정의 — admin_grants 우선 + 레거시 테이블도 함께 인정(이행기 안전)
create or replace function public.is_restaurant_admin_of(p_restaurant_id text)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.admin_grants
                 where user_id = auth.uid() and rest_id = p_restaurant_id)
      or exists (select 1 from public.restaurant_admins
                 where user_id = auth.uid() and restaurant_id = p_restaurant_id);
$$;

create or replace function public.is_venue_admin_of(p_venue_id text)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.admin_grants
                 where user_id = auth.uid() and venue_id = p_venue_id)
      or exists (select 1 from public.venue_admins
                 where admin_user_id = auth.uid() and venue_id = p_venue_id);
$$;


-- ── 3) 기존 매핑 테이블 → admin_grants 이행 ──
insert into public.admin_grants (user_id, rest_id, granted_by)
  select ra.user_id, ra.restaurant_id, ra.added_by
  from public.restaurant_admins ra
  where ra.restaurant_id is not null
    and not exists (select 1 from public.admin_grants ag
                    where ag.user_id = ra.user_id and ag.rest_id = ra.restaurant_id);

insert into public.admin_grants (user_id, venue_id, granted_by)
  select va.admin_user_id, va.venue_id, va.granted_by
  from public.venue_admins va
  where va.venue_id is not null
    and not exists (select 1 from public.admin_grants ag
                    where ag.user_id = va.admin_user_id and ag.venue_id = va.venue_id);


-- ── 4) admin_grants RLS ──
alter table public.admin_grants enable row level security;

drop policy if exists "ag select" on public.admin_grants;
create policy "ag select" on public.admin_grants
  for select to authenticated
  using ( public.is_super_admin(auth.uid()) or user_id = auth.uid() );

drop policy if exists "ag write" on public.admin_grants;
create policy "ag write" on public.admin_grants
  for all to authenticated
  using      ( public.is_super_admin(auth.uid()) )
  with check ( public.is_super_admin(auth.uid()) );


-- ═══════════════════════════════════════════════════════════════
-- 다음 단계:
--   1) 앱 배포 후 슈퍼어드민이 '어드민 권한 서버 동기화' 1회 실행
--      (로컬 adminCodes → admin_grants) — 또는 관리자 코드 재부여
--   2) admin_grants 에 행이 채워진 것 확인:
--        select user_id, rest_id, venue_id, label from public.admin_grants;
--   3) 그 다음 ticket_products_enforcement.sql 실행 (티켓 승인 게이트 서버 강제)
-- ═══════════════════════════════════════════════════════════════
