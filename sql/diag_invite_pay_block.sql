-- ═══════════════════════════════════════════════════════════════
-- 진단 — "결제 불가: 연결된 티켓의 좌석이 부족" 이 왜 뜨는지 확인
-- 2026-08-27 · 아카 11/12 이창훈 건
-- ═══════════════════════════════════════════════════════════════
-- 읽기 전용. 아무것도 바꾸지 않는다. SQL Editor 에서 RUN.
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 문제의 초대와, 그 초대가 연결한 티켓의 좌석 현황 ──
--    「내홀드」 = 이 초대가 발송 때 잡아둔 좌석. 이게 「서버판매」에 포함돼 있어서
--    잔여석이 0 으로 보이고 본인 결제가 막힌 것이다.
select
  inv.id                                    as "초대ID",
  inv.status                                as "초대상태",
  inv.visit_date                            as "방문일",
  inv.restaurant_name                       as "매장",
  inv.pax                                   as "인원",
  tp.total_pax                              as "정원",
  coalesce(occ.sold, 0)                     as "서버판매",
  coalesce(mine.pax, 0)                     as "내홀드",
  tp.total_pax - coalesce(occ.sold, 0)      as "앱이_본_잔여",
  tp.total_pax - (coalesce(occ.sold,0) - coalesce(mine.pax,0)) as "실제_잔여",
  case
    when tp.id is null then '연결 티켓 없음'
    when inv.pax > tp.total_pax - coalesce(occ.sold,0)
     and inv.pax <= tp.total_pax - (coalesce(occ.sold,0) - coalesce(mine.pax,0))
      then '⚠ 자기차단 — 자기 홀드 때문에 막힘'
    when inv.pax > tp.total_pax - (coalesce(occ.sold,0) - coalesce(mine.pax,0))
      then '❌ 진짜 좌석 부족 (다른 예약이 채움)'
    else '✅ 좌석 문제 아님 (다른 원인)'
  end                                       as "판정"
from public.reservation_invites inv
left join public.ticket_products tp
       on tp.id::text = inv.ticket_product_id::text
left join lateral (
  select coalesce(sum(t.party_size),0)::int as sold
    from public.tickets t
   where t.ticket_product_id = inv.ticket_product_id::text
     and coalesce(t.status,'') <> 'cancelled'
) occ on true
left join lateral (
  select coalesce(sum(t.party_size),0)::int as pax
    from public.tickets t
   where coalesce(t.status,'') = 'hold'
     and ( coalesce(t.extra_data->>'inviteId','') = inv.id::text
        or t.purchase_id like 'INVH-' || left(inv.id::text, 8) || '-%' )
) mine on true
where inv.restaurant_name like '%아카%'
   or inv.visit_date like '%11.12%'
order by inv.created_at desc;


-- ── 2) 아카 11/12 티켓의 좌석을 누가 잡고 있는지 전부 ──
--    옛 초대 홀드가 안 풀린 채 남아 있으면 새 초대까지 같이 막힌다.
select
  tp.id                    as "티켓ID",
  tp.rest_name             as "매장",
  tp.date                  as "날짜",
  tp.total_pax             as "정원",
  t.purchase_id            as "구매ID",
  case
    when t.purchase_id like 'INVH-%' then '초대 홀드(미결제)'
    when t.purchase_id like 'INV-%'  then '초대 결제완료'
    when t.purchase_id like 'PAYH-%' then '결제 홀드(5분)'
    when t.purchase_id like 'MAN-%'  then '수동 연동'
    else '앱/웹 구매'
  end                      as "종류",
  t.status                 as "상태",
  t.party_size             as "좌석",
  t.buyer_name             as "이름",
  t.created_at             as "생성"
from public.tickets t
join public.ticket_products tp on tp.id::text = t.ticket_product_id
where coalesce(t.status,'') <> 'cancelled'
  and (tp.rest_name like '%아카%' or tp.rest_name like '%AKA%')
order by tp.date, t.created_at;
