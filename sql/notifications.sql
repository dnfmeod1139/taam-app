-- ═══════════════════════════════════════════════════════════════
-- TAAM — notifications 테이블 + RLS (2026-06-01) — v2 보강
-- ═══════════════════════════════════════════════════════════════
-- 회원에게 발송되는 인앱 알림 (예치금 부여, 예약 초대 등).
-- 미접속 중 발생한 이벤트도 다음 접속 시 토스트로 표시 + 알림 메뉴에 레드닷.
--
-- ※ v1 SQL 에서 'column seen does not exist' 에러:
--    이미 다른 정의의 notifications 테이블이 존재하면 create table if not exists
--    는 skip 되고 인덱스 만들 때 컬럼 없다고 실패.
--    → 이 v2 는 alter table add column if not exists 로 누락 컬럼 안전 보강.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 테이블 (없으면 생성, 있으면 다음 alter 들이 컬럼 보강) ──
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  type        text not null default 'system',
  title       text not null default '',
  body        text,
  url         text,
  payload     jsonb default '{}'::jsonb,
  seen        boolean not null default false,
  created_at  timestamptz not null default now(),
  seen_at     timestamptz
);

-- ── 2. 누락 컬럼 보강 (기존 테이블이 있을 경우) ──
alter table public.notifications add column if not exists user_id    uuid;
alter table public.notifications add column if not exists type       text default 'system';
alter table public.notifications add column if not exists title      text default '';
alter table public.notifications add column if not exists body       text;
alter table public.notifications add column if not exists url        text;
alter table public.notifications add column if not exists payload    jsonb default '{}'::jsonb;
alter table public.notifications add column if not exists seen       boolean not null default false;
alter table public.notifications add column if not exists created_at timestamptz not null default now();
alter table public.notifications add column if not exists seen_at    timestamptz;

comment on table public.notifications is
  '회원 인앱 알림. 미접속 중 발생 이벤트도 다음 접속 시 토스트로 표시.';

-- ── 3. 인덱스 (이제 seen 컬럼이 반드시 존재) ──
create index if not exists idx_notif_user_unseen on public.notifications(user_id, seen, created_at desc);

-- ── 4. RLS ──
alter table public.notifications enable row level security;

-- SELECT: 본인 알림만
drop policy if exists "notif_select_own" on public.notifications;
create policy "notif_select_own" on public.notifications
  for select using (auth.uid() = user_id);

-- INSERT: 슈퍼어드민이 다른 회원에게 알림 발송 가능 / 본인 self-알림도 가능
drop policy if exists "notif_insert" on public.notifications;
create policy "notif_insert" on public.notifications
  for insert with check (
    is_super_admin(auth.uid())
    or auth.uid() = user_id
  );

-- UPDATE: 본인이 seen=true 로 표시 가능
drop policy if exists "notif_update_own" on public.notifications;
create policy "notif_update_own" on public.notifications
  for update using (auth.uid() = user_id);

-- DELETE: 본인 or 슈퍼어드민
drop policy if exists "notif_delete" on public.notifications;
create policy "notif_delete" on public.notifications
  for delete using (auth.uid() = user_id or is_super_admin(auth.uid()));

-- ── 5. 검증 — 현재 컬럼 구조 ──
select column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='notifications'
order by ordinal_position;

do $$ begin raise notice '✅ notifications 테이블 + RLS 보강 완료'; end $$;
