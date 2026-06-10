-- ═══════════════════════════════════════════════════════════════
-- 누락된 티켓 구매 거래를 deposit_transactions 에 복원
-- 작성일: 2026-05-21
--
-- 시나리오:
--   회원이 티켓을 구매했지만 코드 배포 전이라 deposit_transactions 에 기록 누락.
--   tickets 테이블에는 구매 기록이 있지만 슈퍼어드민의 거래 내역 조회에는 안 보임.
--   이 SQL 은 tickets 테이블의 cancelled/active 티켓 중 deposit_transactions 에 없는 것을
--   자동으로 추가.
-- ═══════════════════════════════════════════════════════════════

-- 1) 진단 — 누락된 티켓 구매 찾기
--    (tickets 에는 있는데 deposit_transactions 에는 없는 purchase_id)
select
  t.id,
  t.user_id,
  p.email,
  t.restaurant_name,
  t.party_size,
  t.price,
  t.purchase_id,
  t.created_at,
  t.status
from public.tickets t
left join public.profiles p on p.id = t.user_id
where t.purchase_id is not null
  and not exists (
    select 1 from public.deposit_transactions dt
    where dt.user_id = t.user_id
      and dt.change_type = 'ticket_purchase'
      and dt.metadata->>'purchase_id' = t.purchase_id
  )
order by t.created_at desc;

-- ═══════════════════════════════════════════════════════════════
-- 2) 자동 복원 — 위 조회 결과를 deposit_transactions 에 INSERT
--    잔액(balance_after)은 현재 프로필 잔액 기준 (역추적 불가능)
--    description 에 "(복원 기록)" 표시
-- ═══════════════════════════════════════════════════════════════

insert into public.deposit_transactions (
  user_id, deposit_type, change_type, amount, balance_after, description, metadata, created_at
)
select
  t.user_id,
  -- 추론: granted_membership_balance > 0 이면 멤버십 차감으로 간주, 아니면 일반
  case
    when coalesce(p.granted_membership_balance, 0) > 0
      or coalesce(p.charged_membership_balance, 0) > 0
    then 'membership'
    else 'general'
  end::text as deposit_type,
  'ticket_purchase'::text as change_type,
  -coalesce(t.price, 0)::bigint as amount,
  -- 잔액 추정: 차감 직후라 가정하고 현재잔액 사용 (정확한 시점 잔액은 알 수 없음)
  coalesce(p.deposit_balance, 0)::bigint as balance_after,
  coalesce(t.restaurant_name, '레스토랑') || ' 티켓 ' || coalesce(t.party_size, 1) || '인 구매 (복원 기록)' as description,
  jsonb_build_object(
    'purchase_id', t.purchase_id,
    'ticket_id', t.ticket_product_id,
    'restaurant_id', t.restaurant_id,
    'restaurant_name', t.restaurant_name,
    'ticket_type', t.ticket_type,
    'visit_date', t.reservation_date,
    'party_size', t.party_size,
    'payment_method', case when t.extra_data->>'paymentId' is not null then 'portone_card' else 'deposit_only' end,
    'restored', true,
    'note', '코드 배포 전 구매 — 거래내역 자동 복원'
  ) as metadata,
  t.created_at  -- 원래 구매 시점 사용
from public.tickets t
left join public.profiles p on p.id = t.user_id
where t.purchase_id is not null
  and not exists (
    select 1 from public.deposit_transactions dt
    where dt.user_id = t.user_id
      and dt.change_type = 'ticket_purchase'
      and dt.metadata->>'purchase_id' = t.purchase_id
  );

-- ═══════════════════════════════════════════════════════════════
-- 3) 검증
-- ═══════════════════════════════════════════════════════════════

select
  dt.created_at,
  p.email,
  dt.deposit_type,
  dt.change_type,
  dt.amount,
  dt.description,
  dt.metadata->>'purchase_id' as purchase_id,
  dt.metadata->>'payment_method' as payment_method,
  dt.metadata->>'restored' as is_restored
from public.deposit_transactions dt
join public.profiles p on p.id = dt.user_id
where dt.change_type in ('ticket_purchase', 'ticket_refund')
order by dt.created_at desc
limit 30;

-- 완료
do $$ begin raise notice '✅ 누락된 티켓 구매 거래 복원 완료'; end $$;
