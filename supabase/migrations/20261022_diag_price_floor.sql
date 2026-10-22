-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 홀드 확정 금액 하한(PRICE_BELOW_TICKET)을 걸기 전에: 지금까지 확정된 앱 구매 중 정가 × 인원보다 싸게 확정된 것이 있나 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 20261022_card_refund_quote2.sql 의 C(trg_taam_guard_ticket_price_floor)가 hold→active 때 price < taam_ticket_price_krw 면 막는다.
--     라이브 toss-confirm(대시보드 판 · 저장소와 대조 전)이 price 에 무엇을 쓰는지 모른다 — 카드 몫만 쓰면 섞은 결제가 모두 막힌다.
--     지난 확정 행이 어떤 모양이었는지 먼저 본다. (지금 회차 요금 기준이라 그 뒤 요금이 바뀐 회차는 따로 센다.)
-- 무엇: SELECT 만 · 집계만(이름·번호·uid 없음).
-- ═══════════════════════════════════════════════════════════════
create or replace function pg_temp.diag_price_floor()
returns table(sec text, info text)
language plpgsql as $$
declare r record;
begin
  for r in
    with x as (
      select t.purchase_id, t.price, t.party_size, t.created_at,
             coalesce(t.extra_data->>'paidBy', '(없음)') paid_by,
             coalesce(t.extra_data->>'card_currency', '') cur,
             (t.extra_data->>'server_confirmed') = 'true' srv,
             nullif(to_jsonb(tp)->>'updated_at', '')::timestamptz > t.created_at tp_after,
             (select public.taam_ticket_price_krw(t.ticket_product_id::text, greatest(coalesce(t.party_size, 1), 1))) fl
        from public.tickets t left join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
       where t.purchase_id ~ '^PAY' and lower(coalesce(t.status, '')) in ('active', 'used', 'completed', 'returned', 'cancelled', 'canceled')
         and coalesce(t.extra_data->>'seatHold', 'false') <> 'true'
    )
    select left(purchase_id, 5) pfx, paid_by, (cur <> '') fx,
           count(*) n,
           count(*) filter (where fl is null) no_floor,
           count(*) filter (where fl is not null and coalesce(price, 0) < fl) below,
           count(*) filter (where fl is not null and coalesce(price, 0) < fl and tp_after) below_tp_after,
           count(*) filter (where fl is not null and coalesce(price, 0) = fl) eq,
           count(*) filter (where fl is not null and coalesce(price, 0) > fl) above,
           to_char(max(created_at) filter (where fl is not null and coalesce(price, 0) < fl) at time zone 'Asia/Seoul', 'YYYY-MM-DD') last_below
      from x group by 1, 2, 3 order by 1, 2, 3
  loop
    sec := '① ' || r.pfx || ' · ' || r.paid_by || case when r.fx then ' · 외화' else '' end;
    info := r.n || '건 · 정가 미만 ' || r.below || '(그 뒤 회차 수정 ' || r.below_tp_after || ' · 마지막 ' || coalesce(r.last_below, '-') || ') · 같음 ' || r.eq || ' · 초과 ' || r.above || ' · 정가 못 셈 ' || r.no_floor;
    return next;
  end loop;
  -- ② 정가 미만 · 회차 수정 없음 — 차이의 모양(정가 대비 비율 구간)
  for r in
    with x as (
      select t.price, coalesce(t.extra_data->>'paidBy', '(없음)') paid_by,
             nullif(t.extra_data->>'cardPaid', '')::numeric card, nullif(t.extra_data->>'depositUsed', '')::numeric dep,
             (select public.taam_ticket_price_krw(t.ticket_product_id::text, greatest(coalesce(t.party_size, 1), 1))) fl,
             nullif(to_jsonb(tp)->>'updated_at', '')::timestamptz > t.created_at tp_after
        from public.tickets t left join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
       where t.purchase_id ~ '^PAY' and coalesce(t.extra_data->>'card_currency', '') = ''
         and lower(coalesce(t.status, '')) in ('active', 'used', 'completed', 'returned', 'cancelled', 'canceled')
         and coalesce(t.extra_data->>'seatHold', 'false') <> 'true'
    )
    select paid_by,
           count(*) n,
           count(*) filter (where card is not null and price = card) price_is_card,
           count(*) filter (where card is not null and dep is not null and price = card + dep) price_is_sum,
           count(*) filter (where price = 0) zero,
           round(avg(price::numeric / nullif(fl, 0)), 3) ratio
      from x where fl is not null and coalesce(price, 0) < fl and not coalesce(tp_after, false)
     group by 1 order by 2 desc
  loop
    sec := '② 정가 미만(회차 수정 없음) · ' || r.paid_by;
    info := r.n || '건 · price=카드몫 ' || r.price_is_card || ' · price=카드+예치금 ' || r.price_is_sum || ' · 0원 ' || r.zero || ' · 평균 정가 대비 ' || coalesce(r.ratio::text, '-');
    return next;
  end loop;
  -- ③ 최근 30일 카드(섞음 포함) 확정 — 하한이 걸렸다면 막혔을 건수
  for r in
    select count(*) n,
           count(*) filter (where coalesce(t.price, 0) < public.taam_ticket_price_krw(t.ticket_product_id::text, greatest(coalesce(t.party_size, 1), 1))) below
      from public.tickets t
     where t.purchase_id ~ '^PAY' and t.created_at > now() - interval '30 days'
       and coalesce(t.extra_data->>'card_currency', '') = '' and coalesce(t.extra_data->>'order_id', '') <> ''
       and lower(coalesce(t.status, '')) <> 'hold'
  loop
    sec := '③ 최근 30일 카드 확정(원화)'; info := r.n || '건 · 지금 정가 미만 ' || r.below; return next;
  end loop;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_price_floor();
