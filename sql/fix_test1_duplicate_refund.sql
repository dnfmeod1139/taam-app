-- ═══════════════════════════════════════════════════════════════
-- 테스트1 중복 환불 회수 (511만 → 331만 정정)
-- 작성일: 2026-05-22
--
-- ⚠ 실행 전: 반드시 sql/diag_test1_balance_audit.sql 먼저 실행해서
--           ticket_refund row 가 정말 2개인지 확인 후 실행할 것.
--
-- 가설: 회원 본인이 마이페이지에서 취소 → +180만 환불받음
--      슈퍼어드민이 또 반환 처리 → +160만 추가 (중복!)
--      → 합계 +340만 (정상은 +160만 only)
--      → 잔액 511만 = 171만(구매후) + 180만(중복) + 160만(슈퍼어드민)
--      → 정상 잔액 331만 = 171만(구매후) + 160만(슈퍼어드민이 의도한 환불)
--
-- 처리 방향:
--   1) 회원 본인 취소가 더 일찍이고 슈퍼어드민이 나중에 함 → 회원 본인 환불을 "유효"로
--      슈퍼어드민의 추가 환불(160만)을 회수 (-160만)
--   2) 또는 슈퍼어드민 처리가 최종 의도라고 보고 회원 본인 환불(180만)을 회수
-- 어느 쪽이 옳은지 사용자 의사 확인 필요.
-- 아래는 케이스 A (슈퍼어드민의 160만 환불을 유효로) 정정.
-- ═══════════════════════════════════════════════════════════════

-- 1) 두 환불 row 확인
select
  id,
  created_at,
  amount,
  description,
  metadata->>'processed_by' as processed_by,
  metadata->>'purchase_id'  as purchase_id
from public.deposit_transactions
where user_id = (select id from public.profiles where email='ripe0315@naver.com')
  and change_type = 'ticket_refund'
order by created_at asc;

-- 2) ⚠ 정정 SQL — 아래 두 옵션 중 하나만 골라서 실행 ⚠

-- ─── 옵션 A: 회원 본인 취소가 우선이라고 본다 (슈퍼어드민 처리분 회수) ───
-- 슈퍼어드민이 추가로 크레딧한 160만원을 잔액에서 차감
-- + slot/created_at 기준 가장 최근 슈퍼어드민 환불 row 삭제
/*
update public.profiles
set general_deposit_balance = greatest(0, general_deposit_balance - 1600000)
where email = 'ripe0315@naver.com';

delete from public.deposit_transactions
where user_id = (select id from public.profiles where email='ripe0315@naver.com')
  and change_type = 'ticket_refund'
  and metadata->>'processed_by' = 'super_admin';
*/

-- ─── 옵션 B: 슈퍼어드민 처리가 최종 의도 (회원 본인 환불분 회수) ───
-- 회원 본인 취소로 인한 180만원을 잔액에서 차감
-- + 회원 본인 환불 row 삭제 (processed_by 가 super_admin 이 아닌 것)
/*
update public.profiles
set general_deposit_balance = greatest(0, general_deposit_balance - 1800000)
where email = 'ripe0315@naver.com';

delete from public.deposit_transactions
where user_id = (select id from public.profiles where email='ripe0315@naver.com')
  and change_type = 'ticket_refund'
  and (metadata->>'processed_by' is null or metadata->>'processed_by' != 'super_admin');
*/

-- 3) 검증
select
  email,
  membership_deposit_balance,
  general_deposit_balance,
  (membership_deposit_balance + general_deposit_balance) as 합계
from public.profiles
where email = 'ripe0315@naver.com';

select
  created_at,
  amount,
  description,
  metadata->>'processed_by' as processed_by
from public.deposit_transactions
where user_id = (select id from public.profiles where email='ripe0315@naver.com')
  and change_type = 'ticket_refund'
order by created_at;
