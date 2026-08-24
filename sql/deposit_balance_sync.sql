-- ═══════════════════════════════════════════════════════════════
-- TAAM — 예치금 잔액 단일화 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 무엇이 문제였나
--   잔액 컬럼이 셋이다: membership_deposit_balance + general_deposit_balance(진짜)
--   그리고 deposit_balance(통합 캐시). 셋을 맞춰주는 장치가 없어서,
--   취소 환불·반환·부여는 분리 컬럼만 갱신하고 통합 컬럼은 뒤처졌다.
--   화면은 읽는 곳마다 소스가 달라(마이페이지=통합, 원장=합계) 잔액이
--   11,000 ↔ 8,000 처럼 번갈아 보였다 — 잔상이 아니라 DB 안의 실제 불일치다.
--
-- 고치는 방법
--   진실은 membership + general 합 하나로 정한다.
--   deposit_balance 는 트리거가 항상 그 합으로 강제한다 — 어떤 코드가
--   어느 컬럼을 갱신하든, 심지어 클라이언트가 틀린 값을 밀어넣어도
--   저장되는 순간 합으로 교정된다. 앞으로는 구조적으로 어긋날 수 없다.
-- ═══════════════════════════════════════════════════════════════

-- ── 0) 진단: 현재 어긋나 있는 회원 확인 (실행 결과로 보임) ──
select id, display_name,
       membership_deposit_balance as mem,
       general_deposit_balance    as gen,
       deposit_balance            as total_cached,
       (coalesce(membership_deposit_balance,0) + coalesce(general_deposit_balance,0)) as total_real,
       deposit_balance - (coalesce(membership_deposit_balance,0) + coalesce(general_deposit_balance,0)) as diff
  from public.profiles
 where coalesce(deposit_balance,0)
       <> (coalesce(membership_deposit_balance,0) + coalesce(general_deposit_balance,0));

-- ── 1) 동기화 트리거: deposit_balance = membership + general (항상) ──
create or replace function public.taam_sync_deposit_balance()
returns trigger language plpgsql as $$
begin
  new.deposit_balance := coalesce(new.membership_deposit_balance, 0)
                       + coalesce(new.general_deposit_balance, 0);
  return new;
end $$;

drop trigger if exists trg_taam_sync_deposit_balance on public.profiles;
create trigger trg_taam_sync_deposit_balance
  before insert or update on public.profiles
  for each row execute function public.taam_sync_deposit_balance();

-- ── 2) 일회성 보정: 지금 어긋나 있는 값을 전부 합으로 교정 ──
update public.profiles
   set deposit_balance = coalesce(membership_deposit_balance,0) + coalesce(general_deposit_balance,0)
 where coalesce(deposit_balance,0)
       <> (coalesce(membership_deposit_balance,0) + coalesce(general_deposit_balance,0));

-- ── 3) 확인: 이제 어긋난 행이 0 이어야 한다 ──
select count(*) as "불일치 남은 회원 수 (0 이어야 정상)"
  from public.profiles
 where coalesce(deposit_balance,0)
       <> (coalesce(membership_deposit_balance,0) + coalesce(general_deposit_balance,0));

do $$ begin raise notice '✅ 예치금 잔액 단일화 완료 — deposit_balance 는 이제 항상 membership+general 합'; end $$;
