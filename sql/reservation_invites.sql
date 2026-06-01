-- ═══════════════════════════════════════════════════════════════
-- TAAM — reservation_invites (예약 초대) 테이블 + RLS (2026-06-01)
-- ═══════════════════════════════════════════════════════════════
-- 슈퍼어드민이 특정 회원에게 1:1 예약 초대를 발송 → 회원이 알림/팝업으로
-- 받아서 예치금으로 결제 → status='paid' 로 전환.
--
-- 흐름:
--   1. 슈퍼어드민 → "예약 초대 발송" 화면에서 회원/레스토랑/일정/금액 입력
--      → INSERT (status='sent')
--   2. send-push Edge Function 으로 invitee 에게 푸시 발송
--   3. invitee 가 알림 클릭 or 마이페이지 진입 → 결제 팝업 오픈
--   4. 결제 완료 → status='paid', paid_at 채워짐, 예치금 차감
--   5. invitee 가 거절 또는 무시 → status='sent' 유지 (만료 정책 없음 — 단순)
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.reservation_invites (
  id              uuid primary key default gen_random_uuid(),
  host_user_id    uuid not null references auth.users(id) on delete set null,  -- 슈퍼어드민
  invitee_user_id uuid not null references auth.users(id) on delete cascade,   -- 초대받는 회원
  -- 예약 내용 (티켓 업로드와 동일 구조이지만 1회성 1인 초대)
  restaurant_id   text,                       -- restaurantDB.id (string 사용)
  restaurant_name text,
  ticket_genre    text,                       -- 스시/텐푸라/...
  type_class      text default 'std',         -- 'std' | 'eve'
  visit_date      text,                       -- 'YYYY.MM.DD' (UI 포맷 유지)
  visit_time      text,                       -- 'HH:MM' 24h
  pax             integer not null default 1, -- 초대 인원
  meal_fee        integer not null default 0, -- 식사예약금 (1인)
  agency_fee      integer not null default 0, -- 대행비 (1인)
  wine_min        integer not null default 0, -- 주류 미니멈 (1인)
  total_amount    integer not null default 0, -- (meal+agency+wine) * pax — 결제할 총액
  ticket_desc     text,                       -- 티켓 상세 설명
  cancel_policy   jsonb default '{}'::jsonb,  -- {p1, p2, p3, extra, extraText}
  -- 상태
  status          text not null default 'sent' check (status in ('sent','paid','cancelled','expired')),
  created_at      timestamptz not null default now(),
  paid_at         timestamptz,
  cancelled_at    timestamptz,
  -- 결제 시 생성된 ticket 연결 (있으면)
  paid_ticket_id  text
);

comment on table public.reservation_invites is
  '슈퍼어드민이 특정 회원에게 발송하는 1:1 예약 초대. 회원이 예치금으로 결제하면 status=paid.';

create index if not exists idx_resinv_invitee on public.reservation_invites(invitee_user_id, status);
create index if not exists idx_resinv_host on public.reservation_invites(host_user_id, created_at desc);

-- ── RLS ──
alter table public.reservation_invites enable row level security;

-- SELECT: invitee 본인 OR 슈퍼어드민 (모두 가능)
drop policy if exists "resinv_select" on public.reservation_invites;
create policy "resinv_select" on public.reservation_invites
  for select using (
    auth.uid() = invitee_user_id
    or auth.uid() = host_user_id
    or is_super_admin(auth.uid())
  );

-- INSERT: 슈퍼어드민만
drop policy if exists "resinv_insert" on public.reservation_invites;
create policy "resinv_insert" on public.reservation_invites
  for insert with check (
    is_super_admin(auth.uid())
    and host_user_id = auth.uid()
  );

-- UPDATE: invitee 본인 (결제/취소) OR 슈퍼어드민 (관리)
drop policy if exists "resinv_update" on public.reservation_invites;
create policy "resinv_update" on public.reservation_invites
  for update using (
    auth.uid() = invitee_user_id
    or is_super_admin(auth.uid())
  );

-- DELETE: 슈퍼어드민만
drop policy if exists "resinv_delete" on public.reservation_invites;
create policy "resinv_delete" on public.reservation_invites
  for delete using (is_super_admin(auth.uid()));

do $$ begin raise notice '✅ reservation_invites 테이블 + RLS 생성 완료'; end $$;
