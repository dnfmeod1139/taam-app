-- ═══════════════════════════════════════════════════════════════
-- TAAM — deposit_transactions CHECK 제약 수정
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-21
-- 목적:
--   슈퍼어드민 예치금 부여/차감 시 change_type 값이 거절되는 문제 해결
--   PostgreSQL 에러: code 23514 (check_violation)
-- ═══════════════════════════════════════════════════════════════

-- 1) 현재 제약 확인 (선택)
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.deposit_transactions'::regclass
  and contype = 'c';

-- 2) 기존 제약 제거
alter table public.deposit_transactions
  drop constraint if exists deposit_transactions_change_type_check;

-- 3) 새 제약 — 코드가 보낼 수 있는 모든 change_type 허용
alter table public.deposit_transactions
  add constraint deposit_transactions_change_type_check
  check (change_type in (
    -- 슈퍼어드민 수동 부여/차감
    'admin_grant',
    'admin_deduct',
    -- 회원 충전/사용
    'user_charge',
    'user_use',
    -- 멤버십 결제
    'membership_payment',
    'membership_refund',
    -- 티켓
    'ticket_purchase',
    'ticket_refund',
    -- 예약
    'reservation_payment',
    'reservation_refund',
    -- 일반 환불
    'refund',
    -- 기타 (확장용)
    'other'
  ));

-- 4) 검증
select conname, pg_get_constraintdef(oid) as new_definition
from pg_constraint
where conname = 'deposit_transactions_change_type_check';

-- 완료
do $$ begin
  raise notice '✅ deposit_transactions.change_type CHECK 제약 12개 값 허용으로 재설치';
end $$;
