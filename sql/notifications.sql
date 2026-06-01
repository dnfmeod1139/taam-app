-- ═══════════════════════════════════════════════════════════════
-- TAAM — notifications 테이블 + RLS (2026-06-01)
-- ═══════════════════════════════════════════════════════════════
-- 회원에게 발송되는 인앱 알림 (예치금 부여, 예약 초대 등).
-- 미접속 중 발생한 이벤트도 다음 접속 시 토스트로 표시 + 알림 메뉴에 레드닷.
--
-- 흐름:
--   1. 슈퍼어드민 부여 / 예약 초대 발송 → notifications INSERT (+ send-push)
--   2. 회원 접속 → seen=false 조회 → 각 항목 토스트 표시 + seen=true 업데이트
--   3. 마이페이지의 "알림 설정" 옆에 미확인 개수 레드닷 (선택)
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  type        text not null,                  -- 'deposit_grant' | 'reservation_invite' | ...
  title       text not null,
  body        text,
  url         text,                           -- 클릭 시 이동 URL (예: '/?ri_pay=<id>')
  payload     jsonb default '{}'::jsonb,      -- 추가 메타데이터
  seen        boolean not null default false, -- 회원이 본 적 있나
  created_at  timestamptz not null default now(),
  seen_at     timestamptz
);

comment on table public.notifications is
  '회원 인앱 알림. 미접속 중 발생 이벤트도 다음 접속 시 토스트로 표시.';

create index if not exists idx_notif_user_unseen on public.notifications(user_id, seen, created_at desc);

-- ── RLS ──
alter table public.notifications enable row level security;

-- SELECT: 본인 알림만
drop policy if exists "notif_select_own" on public.notifications;
create policy "notif_select_own" on public.notifications
  for select using (auth.uid() = user_id);

-- INSERT: 슈퍼어드민이 다른 회원에게 알림 발송 가능 (서버사이드는 service_role 우회)
drop policy if exists "notif_insert" on public.notifications;
create policy "notif_insert" on public.notifications
  for insert with check (
    is_super_admin(auth.uid())
    or auth.uid() = user_id  -- 본인 알림은 본인이 insert 가능 (예: 클라이언트 self-알림)
  );

-- UPDATE: 본인이 seen=true 로 표시 가능
drop policy if exists "notif_update_own" on public.notifications;
create policy "notif_update_own" on public.notifications
  for update using (auth.uid() = user_id);

-- DELETE: 본인 or 슈퍼어드민
drop policy if exists "notif_delete" on public.notifications;
create policy "notif_delete" on public.notifications
  for delete using (auth.uid() = user_id or is_super_admin(auth.uid()));

do $$ begin raise notice '✅ notifications 테이블 + RLS 생성 완료'; end $$;
