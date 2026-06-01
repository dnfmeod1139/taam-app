-- ═══════════════════════════════════════════════════════════════
-- TAAM — 단일 기기 강제 로그인 (active_sessions) — 2026-06-01
-- ═══════════════════════════════════════════════════════════════
-- 한 회원이 한 번에 한 기기에서만 로그인 가능. 새 기기에서 로그인하면
-- 이전 기기는 Realtime 으로 즉시 강제 로그아웃.
--
-- 슈퍼어드민(super_admin) 만 면제 — admin / staff / member 는 단일 기기.
--
-- 흐름:
--   1. 로그인 성공 → active_sessions UPSERT (user_id PK 라 자동 덮어쓰기)
--   2. 클라이언트가 Realtime 으로 본인 row 구독
--   3. row.device_id 가 변하면 = 다른 기기에서 로그인 → 자동 signOut()
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.active_sessions (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  device_id    text not null,
  device_label text,            -- 사용자 인지용 (예: "iOS · Safari", "Windows · Chrome")
  last_active  timestamptz not null default now(),
  signed_in_at timestamptz not null default now()
);

comment on table public.active_sessions is
  '단일 기기 강제 로그인 추적. user_id 가 PK 라 UPSERT 시 자동 덮어쓰기.';

create index if not exists idx_active_sessions_device on public.active_sessions(device_id);

-- ── RLS ──
alter table public.active_sessions enable row level security;

-- SELECT: 본인 + 슈퍼어드민 (모니터링용)
drop policy if exists "active_sessions_select" on public.active_sessions;
create policy "active_sessions_select" on public.active_sessions
  for select using (
    auth.uid() = user_id or is_super_admin(auth.uid())
  );

-- INSERT: 본인만 (UPSERT 의 INSERT 부분)
drop policy if exists "active_sessions_insert_own" on public.active_sessions;
create policy "active_sessions_insert_own" on public.active_sessions
  for insert with check (auth.uid() = user_id);

-- UPDATE: 본인만 (UPSERT 의 UPDATE 부분 + last_active 갱신)
drop policy if exists "active_sessions_update_own" on public.active_sessions;
create policy "active_sessions_update_own" on public.active_sessions
  for update using (auth.uid() = user_id);

-- DELETE: 본인 (로그아웃) 또는 슈퍼어드민 (강제 만료)
drop policy if exists "active_sessions_delete" on public.active_sessions;
create policy "active_sessions_delete" on public.active_sessions
  for delete using (
    auth.uid() = user_id or is_super_admin(auth.uid())
  );

-- ── Realtime 활성화 (postgres_changes 이벤트 발생) ──
do $$ begin
  begin
    alter publication supabase_realtime add table public.active_sessions;
  exception when duplicate_object then null;
  end;
end $$;

do $$ begin raise notice '✅ active_sessions 테이블 + RLS + Realtime 설정 완료'; end $$;
