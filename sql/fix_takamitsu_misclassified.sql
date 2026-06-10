-- ═══════════════════════════════════════════════════════════════
-- 타카미츠 환불 분류 보정 — penalty → returned + 대행비로 재분류
-- 작성일: 2026-05-22
-- 배경:
--   옛 dmConfirmReturn 버그로 "반환 + 대행비 제외" 처리 시 type='penalty' 로 저장됨.
--   타카미츠(1,800,000원 → 200,000원 공제, 1,600,000원 반환)는 사실 반환완료였음.
--   이를 반환완료 탭에 정상 표시되도록 재분류.
-- ═══════════════════════════════════════════════════════════════

-- 1) 보정 전 상태 확인
select
  dt.created_at,
  dt.amount,
  dt.description,
  dt.metadata->>'refund_type'   as refund_type,
  dt.metadata->>'penalty_amt'   as penalty_amt,
  dt.metadata->>'penalty_pct'   as penalty_pct,
  dt.metadata->>'agency_held'   as agency_held,
  dt.metadata->>'return_amt'    as return_amt
from public.deposit_transactions dt
where dt.change_type = 'ticket_refund'
  and dt.metadata->>'purchase_id' = '1778473943361_1779361743492';

-- ─────────────────────────────────────────────────────
-- 2) deposit_transactions 보정
--    refund_type: penalty → returned
--    penalty_amt/penalty_pct: 0
--    agency_held: 200000 (1인 100,000원 × 2인 = 200,000원 대행비)
--    return_amt: 1,600,000
--    description: 반환완료로 갱신
-- ─────────────────────────────────────────────────────
update public.deposit_transactions
set
  description = '타카미츠 반환 완료',
  metadata = (metadata
    || jsonb_build_object(
      'refund_type', 'returned',
      'penalty_amt', 0,
      'penalty_pct', 0,
      'agency_held', 200000,
      'return_amt',  1600000,
      'note',        '정상 반환 (대행비 ₩200,000 차감)',
      'corrected_at', now()::text,
      'corrected_reason', '옛 dmConfirmReturn 버그로 잘못 분류된 건 재분류 (대행비 차감은 정상 절차)'
    ))
where change_type = 'ticket_refund'
  and metadata->>'purchase_id' = '1778473943361_1779361743492';

-- ─────────────────────────────────────────────────────
-- 3) tickets.extra_data.deposit_return 도 동일하게 보정
-- ─────────────────────────────────────────────────────
update public.tickets
set extra_data = (
  coalesce(extra_data, '{}'::jsonb)
  || jsonb_build_object(
    'deposit_return', jsonb_build_object(
      'type',       'returned',
      'date',       to_char(now(), 'YYYY.MM.DD'),
      'returnAmt',  1600000,
      'penaltyAmt', 0,
      'penaltyPct', 0,
      'agencyHeld', 200000,
      'note',       '정상 반환 (대행비 ₩200,000 차감)'
    )
  )
)
where purchase_id = '1778473943361_1779361743492';

-- ─────────────────────────────────────────────────────
-- 4) 보정 후 검증
-- ─────────────────────────────────────────────────────
select
  '✅ deposit_transactions' as table_name,
  dt.metadata->>'refund_type'  as refund_type,
  dt.metadata->>'agency_held'  as agency_held,
  dt.metadata->>'penalty_amt'  as penalty_amt,
  dt.metadata->>'return_amt'   as return_amt,
  dt.description
from public.deposit_transactions dt
where dt.change_type = 'ticket_refund'
  and dt.metadata->>'purchase_id' = '1778473943361_1779361743492'

union all

select
  '✅ tickets.extra_data',
  t.extra_data->'deposit_return'->>'type',
  t.extra_data->'deposit_return'->>'agencyHeld',
  t.extra_data->'deposit_return'->>'penaltyAmt',
  t.extra_data->'deposit_return'->>'returnAmt',
  t.extra_data->'deposit_return'->>'note'
from public.tickets t
where t.purchase_id = '1778473943361_1779361743492';

-- 완료
do $$ begin
  raise notice '✅ 타카미츠 분류 보정 완료 — 반환완료 탭으로 이동, 대행비 ₩200,000 공제 표시';
end $$;
