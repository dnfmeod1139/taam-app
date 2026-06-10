-- ═══════════════════════════════════════════════════════════════
-- 티켓 환불/반환 처리 내역 진단
-- 작성일: 2026-05-22
-- 목적:
--   슈퍼어드민이 반환완료/환불불가 처리한 내역이 실제 DB 에 잘 남아있는지 확인.
--   "반환 처리하면 이전 내역이 지워진다" 가 실제 DB 차원의 손실인지, 단순 표시 문제인지 판정.
-- ═══════════════════════════════════════════════════════════════

-- 1) 모든 ticket_refund 거래 (시간 역순, 최근 50건)
--    purchase_id 마다 1건씩 있어야 정상.
--    같은 purchase_id 에 여러 row 가 있으면 → 중복 처리 발생.
select
  dt.created_at,
  p.email,
  dt.amount,
  dt.description,
  dt.metadata->>'purchase_id'   as purchase_id,
  dt.metadata->>'refund_type'   as refund_type,
  dt.metadata->>'penalty_pct'   as penalty_pct,
  dt.metadata->>'agency_held'   as agency_held,
  dt.metadata->>'return_amt'    as return_amt,
  dt.metadata->>'processed_by'  as processed_by
from public.deposit_transactions dt
left join public.profiles p on p.id = dt.user_id
where dt.change_type = 'ticket_refund'
order by dt.created_at desc
limit 50;

-- ─────────────────────────────────────────────────────
-- 2) purchase_id 당 환불 row 개수 (중복 검출)
--    cnt 가 2 이상이면 같은 티켓에 환불이 여러 번 기록됨.
-- ─────────────────────────────────────────────────────
select
  metadata->>'purchase_id' as purchase_id,
  count(*) as cnt,
  max(created_at) as last_processed_at,
  sum(amount) as total_refunded
from public.deposit_transactions
where change_type = 'ticket_refund'
  and metadata->>'purchase_id' is not null
group by metadata->>'purchase_id'
having count(*) >= 1
order by cnt desc, last_processed_at desc
limit 30;

-- ─────────────────────────────────────────────────────
-- 3) tickets 테이블 status 분포 + extra_data.deposit_return 보유 여부
-- ─────────────────────────────────────────────────────
select
  status,
  count(*) as cnt,
  count(extra_data->'deposit_return') filter (where extra_data->'deposit_return' is not null) as has_deposit_return
from public.tickets
group by status
order by cnt desc;

-- ─────────────────────────────────────────────────────
-- 4) 슈퍼어드민 처리된 티켓 — extra_data 와 deposit_transactions 매칭 검증
--    extra_data 에는 처리 기록이 있는데 deposit_transactions 에 환불 row 가 없으면 불일치 (잠재 데이터 누락).
-- ─────────────────────────────────────────────────────
select
  t.purchase_id,
  t.status,
  t.restaurant_name,
  t.price,
  t.extra_data->'deposit_return'->>'type' as extra_dr_type,
  t.extra_data->'deposit_return'->>'returnAmt' as extra_return_amt,
  case when dt.id is not null then '✓ 있음' else '✗ 없음' end as has_dt_row,
  dt.metadata->>'refund_type' as dt_refund_type,
  dt.amount as dt_amount
from public.tickets t
left join lateral (
  select id, amount, metadata
  from public.deposit_transactions
  where change_type = 'ticket_refund'
    and metadata->>'purchase_id' = t.purchase_id
  order by created_at desc
  limit 1
) dt on true
where t.extra_data->'deposit_return' is not null
   or t.status in ('cancelled','completed')
order by t.created_at desc
limit 30;
