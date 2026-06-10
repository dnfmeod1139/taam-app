-- ═══════════════════════════════════════════════════════════════
-- 테스트1 잔액 정정 (511만 → 331만)
-- 작성일: 2026-05-22
--
-- 원인 확정:
--   1) 5/21 11:09 타카미츠 구매 시 클라이언트 코드가 deposit_balance 만 차감하고
--      membership_deposit_balance 는 안 건드림.
--   2) 5/21 16:15 슈퍼어드민 반환 시 general += 1,600,000 update.
--      이 때 트리거가 deposit_balance = membership + general 로 덮어쓰면서
--      처음 차감(1,800,000)이 증발.
--
-- 정정 방향:
--   membership_deposit_balance 에서 1,800,000 차감 (= 3,510,000 → 1,710,000)
--   합계: 1,710,000 + 1,600,000 = 3,310,000 ✅
-- ═══════════════════════════════════════════════════════════════

-- 1) 보정 전 상태
select
  email,
  membership_deposit_balance as 멤버십_전,
  general_deposit_balance    as 일반_전,
  deposit_balance            as 종합_전,
  (membership_deposit_balance + general_deposit_balance) as 합계_검증_전
from public.profiles
where email = 'ripe0315@naver.com';

-- 2) 정정 — 멤버십 차감
update public.profiles
set membership_deposit_balance = greatest(0, membership_deposit_balance - 1800000)
where email = 'ripe0315@naver.com';

-- 3) deposit_balance 가 트리거로 자동 갱신되지 않은 경우 대비 — 명시 보정
update public.profiles
set deposit_balance = (coalesce(membership_deposit_balance,0) + coalesce(general_deposit_balance,0))
where email = 'ripe0315@naver.com';

-- 4) 보정 후 검증
select
  email,
  membership_deposit_balance as 멤버십_후,
  general_deposit_balance    as 일반_후,
  deposit_balance            as 종합_후,
  (membership_deposit_balance + general_deposit_balance) as 합계_검증_후,
  case
    when (membership_deposit_balance + general_deposit_balance) = 3310000
      and deposit_balance = 3310000
    then '✅ 정상 (331만)'
    else '⚠ 불일치 — ' || deposit_balance::text
  end as 결과
from public.profiles
where email = 'ripe0315@naver.com';

-- 5) 마지막 ticket_refund 의 balance_after 도 일관성 위해 갱신 (감사 추적)
update public.deposit_transactions
set balance_after = 3310000
where user_id = (select id from public.profiles where email='ripe0315@naver.com')
  and change_type = 'ticket_refund'
  and metadata->>'purchase_id' = '1778473943361_1779361743492';

-- 완료
do $$ begin
  raise notice '✅ 테스트1 잔액 정정 완료 — 511만 → 331만';
end $$;
