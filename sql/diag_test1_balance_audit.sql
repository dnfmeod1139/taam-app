-- ═══════════════════════════════════════════════════════════════
-- 테스트1 (ripe0315@naver.com) 잔액 정합성 감사
-- 작성일: 2026-05-22
-- 목적:
--   "511만원이 됐는데 실제론 331만원이어야" 한다는 보고.
--   180만원이 어디서 중복 들어왔는지 추적.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. 현재 잔액 (모든 컬럼) ──
select
  id,
  email,
  display_name,
  membership_deposit_balance      as 멤버십,
  general_deposit_balance         as 일반,
  (membership_deposit_balance + general_deposit_balance) as 멤버십_일반_합계,
  deposit_balance                 as 종합잔액컬럼,
  granted_membership_balance      as 멤_부여누적,
  granted_general_balance         as 일_부여누적,
  charged_membership_balance      as 멤_충전누적,
  charged_general_balance         as 일_충전누적
from public.profiles
where email = 'ripe0315@naver.com';

-- ── 2. 모든 거래 내역 (시간 순) ──
select
  created_at,
  change_type,
  deposit_type,
  amount,
  balance_after,
  description,
  metadata->>'purchase_id'   as purchase_id,
  metadata->>'refund_type'   as refund_type
from public.deposit_transactions
where user_id = (select id from public.profiles where email='ripe0315@naver.com')
order by created_at asc;

-- ── 3. ticket_refund row 만 ── (중복 검출)
select
  created_at,
  amount,
  description,
  metadata->>'purchase_id'   as purchase_id,
  metadata->>'refund_type'   as refund_type,
  metadata->>'processed_by'  as processed_by
from public.deposit_transactions
where user_id = (select id from public.profiles where email='ripe0315@naver.com')
  and change_type = 'ticket_refund'
order by created_at asc;

-- ── 4. 정합성 계산 ──
--    잔액 = 부여+충전 합계 - (구매-환불) 순합
with txn_summary as (
  select
    sum(case when change_type = 'admin_grant'      then amount else 0 end) as 관리자부여,
    sum(case when change_type = 'admin_deduct'     then amount else 0 end) as 관리자차감,
    sum(case when change_type = 'user_charge'      then amount else 0 end) as 회원충전,
    sum(case when change_type = 'ticket_purchase'  then amount else 0 end) as 티켓구매,
    sum(case when change_type = 'ticket_refund'    then amount else 0 end) as 티켓환불,
    sum(amount) as 거래_순합계
  from public.deposit_transactions
  where user_id = (select id from public.profiles where email='ripe0315@naver.com')
)
select
  *,
  ('거래순합계 ' || 거래_순합계 || ' = 부여 ' || 관리자부여 || ' + 환불 ' || 티켓환불 || ' + 구매(음수) ' || 티켓구매) as 계산식
from txn_summary;

-- ── 5. 타카미츠 ticket 상태 ──
select
  id,
  purchase_id,
  user_id,
  restaurant_name,
  price,
  party_size,
  status,
  created_at,
  reservation_date,
  extra_data->'deposit_return' as deposit_return,
  extra_data->>'cancelled_at'  as cancelled_at,
  extra_data->>'refunded_amount' as refunded_amount,
  extra_data->>'cancel_reason'  as cancel_reason
from public.tickets
where user_id = (select id from public.profiles where email='ripe0315@naver.com');
