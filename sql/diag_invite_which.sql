-- ═══════════════════════════════════════════════════════════════
-- 진단 — 남아 있는 초대 홀드가 '어느 초대' 것인지 가려낸다
-- 2026-08-27 · 아카 11/12 이창훈 · 초대를 2번 보낸 건
-- ═══════════════════════════════════════════════════════════════
-- 읽기 전용. 아무것도 바꾸지 않는다.
--
-- 홀드 행의 purchase_id 는 'INVH-<초대ID 앞 8자>-<timestamp>' 형식이라
-- 어느 초대가 잡은 좌석인지 역추적할 수 있다.
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 이창훈 · 11/12 로 나간 초대 전부 (보낸 순서대로) ──
--    「연결티켓」 이 비어 있으면 좌석이 안 잡히는 초대다 (결제해도 정원에서 안 깎임).
--    「내홀드」 가 0 이면 그 초대는 지금 좌석을 안 잡고 있다.
select
  inv.created_at                              as "보낸시각",
  left(inv.id::text, 8)                       as "초대ID앞8",
  inv.status                                  as "상태",
  inv.restaurant_name                         as "매장",
  inv.visit_date                              as "방문일",
  inv.pax                                     as "인원",
  inv.total_amount                            as "금액",
  coalesce(inv.ticket_product_id::text, '(연결없음)')  as "연결티켓ID",
  coalesce(tp.rest_name, '—')                 as "연결티켓매장",
  coalesce(tp.date, '—')                      as "연결티켓날짜",
  coalesce(tp.total_pax, 0)                   as "연결티켓정원",
  tp.status                                   as "연결티켓상태",
  coalesce(h.pax, 0)                          as "이초대가_잡은좌석",
  coalesce(h.pid, '—')                        as "홀드_구매ID",
  tp.created_at                               as "티켓_생성시각"
from public.reservation_invites inv
left join public.ticket_products tp
       on tp.id::text = inv.ticket_product_id::text
left join lateral (
  select coalesce(sum(t.party_size),0)::int as pax,
         max(t.purchase_id)                 as pid
    from public.tickets t
   where coalesce(t.status,'') = 'hold'
     and ( coalesce(t.extra_data->>'inviteId','') = inv.id::text
        or t.purchase_id like 'INVH-' || left(inv.id::text, 8) || '-%' )
) h on true
where inv.visit_date like '%11.12%'
   or inv.restaurant_name like '%아카%'
order by inv.created_at;


-- ── 2) 문제의 홀드(INVH-7a2c975a-…) 하나만 콕 집어서 ──
--    「티켓_생성시각」 이 「보낸시각」보다 한참 전이면 → 미공개 보관 티켓에서 보낸 것.
--    거의 같으면(몇 분 이내) → 그때 새로 만들어 보낸 것.
select
  t.purchase_id                as "홀드_구매ID",
  t.created_at                 as "홀드_생성시각",
  t.party_size                 as "좌석",
  t.buyer_name                 as "이름",
  inv.id                       as "초대ID_전체",
  inv.created_at               as "초대_보낸시각",
  inv.status                   as "초대상태",
  tp.id                        as "티켓ID",
  tp.rest_name                 as "티켓매장",
  tp.date                      as "티켓날짜",
  tp.total_pax                 as "정원",
  tp.status                    as "티켓상태",
  tp.created_at                as "티켓_생성시각",
  tp.updated_at                as "티켓_수정시각",
  case
    when tp.created_at < inv.created_at - interval '30 minutes'
      then '📦 미공개 보관 티켓에서 보낸 초대 (티켓이 먼저 있었음)'
    else '🆕 그 자리에서 새로 만든 티켓으로 보낸 초대'
  end                          as "판정"
from public.tickets t
left join public.reservation_invites inv
       on left(inv.id::text, 8) = split_part(t.purchase_id, '-', 2)
left join public.ticket_products tp
       on tp.id::text = t.ticket_product_id
where t.purchase_id = 'INVH-7a2c975a-1787830119946';


-- ── 3) 아카 11/12 티켓이 몇 개나 있는지 (2번 보냈으면 2개일 수 있다) ──
select
  tp.id                        as "티켓ID",
  tp.rest_name                 as "매장",
  tp.date                      as "날짜",
  tp.time                      as "시간",
  tp.total_pax                 as "정원",
  tp.status                    as "상태",
  tp.created_at                as "생성시각",
  (select coalesce(sum(x.party_size),0) from public.tickets x
    where x.ticket_product_id = tp.id and coalesce(x.status,'') <> 'cancelled') as "점유좌석"
from public.ticket_products tp
where tp.date like '%11.12%'
  and (tp.rest_name like '%아카%' or tp.rest_name like '%aca%' or tp.rest_name like '%AKA%')
order by tp.created_at;
