-- ═══════════════════════════════════════════════════════════════
-- TAAM — 알림 설정을 서버로 (2026-08-27)
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   알림 설정(_notifPrefs)이 IDB(기기 로컬)에만 있었다. 그래서
--     ① 아이폰 앱에서 끈 것이 PC 웹에는 반영되지 않았다 — 기기마다 따로 놀았다
--     ② 앱을 새로 깔면 초기화됐다
--     ③ 무엇보다 send-push 가 이 값을 보지 않으므로,
--        회원이 껐는데도 푸시는 그대로 갔다(화면 토스트만 막혔다).
--        설정이 설정 노릇을 못 했다.
--
--   서버에 두면 셋이 한 번에 해결된다.
--   기본값은 '전부 켜짐' 이다 — 빈 객체 {} 는 아무것도 끄지 않은 상태를 뜻하고,
--   send-push 는 false 로 명시된 항목만 막는다.
--
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent)
-- ═══════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists notif_prefs jsonb not null default '{}'::jsonb;

comment on column public.profiles.notif_prefs is
  '회원 알림 설정. 키: all·fav·ticket·charge·use·refund·remind7·remind3·remind1. '
  '기본은 켜짐 — false 로 명시된 항목만 발송에서 제외된다. send-push 가 uid/user 스코프에서만 참조.';


-- ── 회원이 자기 설정을 저장할 수 있어야 한다 ──
-- 이미 "본인 profiles UPDATE" 정책이 있으면 아래는 무해하게 덮어쓴다.
-- (없으면 알림 설정 저장이 조용히 0행으로 실패한다 — 그러면 또 기기별로 논다)
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own" on public.profiles
  for update to authenticated
  using      ( auth.uid() = id )
  with check ( auth.uid() = id );


-- ═══════════════════════════════════════════════════════════════
-- 확인
-- ═══════════════════════════════════════════════════════════════
select column_name, data_type, column_default
  from information_schema.columns
 where table_schema = 'public' and table_name = 'profiles'
   and column_name = 'notif_prefs';

-- 지금 무언가를 끈 회원이 있는지 (처음엔 전부 {} 라 0건이 정상)
select
  coalesce(display_name, left(id::text, 8)) as "회원",
  notif_prefs                               as "설정"
from public.profiles
where notif_prefs <> '{}'::jsonb
order by display_name;
