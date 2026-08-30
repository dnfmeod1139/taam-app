-- ═══════════════════════════════════════════════════════════════
-- 구매 흐름 서버화 — 설계에 필요한 숫자 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- docs/DESIGN_purchase_server_rpc.md 의 「미리 정해야 할 것」에 답한다.
-- 읽기만 한다.
-- ═══════════════════════════════════════════════════════════════

select 'ⓐ 외화 회원' as "구분",
       coalesce(currency, 'KRW(원화)') as "통화",
       count(*)::text as "회원 수"
from public.profiles
where deleted_at is null
group by coalesce(currency, 'KRW(원화)')

union all

-- 외화 흔적이 실제 구매에 남아 있나 (extra_data 에 card_currency 가 찍힌다)
select 'ⓑ 외화로 결제된 구매',
       coalesce(extra_data ->> 'card_currency', '(원화)'),
       count(*)::text
from public.tickets
where coalesce(status,'') not in ('cancelled','canceled')
group by coalesce(extra_data ->> 'card_currency', '(원화)')

union all

-- 결제 수단별 — 예치금 전액 구매가 몇 건인가 (2단계가 덮을 범위)
select 'ⓒ 결제 수단',
       case when coalesce(extra_data ->> 'paidBy','') <> '' then extra_data ->> 'paidBy'
            when coalesce(extra_data ->> 'order_id','') <> '' then 'card(추정)'
            else '예치금(추정)' end,
       count(*)::text
from public.tickets
where coalesce(status,'') not in ('cancelled','canceled')
  and purchase_id like 'PAYH-%'
group by 2

union all

-- 앱 금액 = 서버 재계산이 맞는지 대조할 근거가 있나
select 'ⓓ 금액 근거가 없는 티켓',
       '(ticket_products 에 없거나 요금이 0)',
       count(*)::text
from public.tickets k
left join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
where coalesce(k.status,'') not in ('cancelled','canceled')
  and k.purchase_id like 'PAYH-%'
  and (tp.id is null
       or coalesce(tp.meal_fee,0) + coalesce(tp.agency_fee,0) + coalesce(tp.wine_min,0) = 0)

order by 1, 2;


-- ═══════════════════════════════════════════════════════════════
-- ⓔ 앱 금액 vs 서버 재계산 — 어긋나는 구매가 있나
-- ═══════════════════════════════════════════════════════════════
--   2단계의 핵심이다. 여기가 전부 0원 차이여야 서버 계산으로 갈아탈 수 있다.
--   차이가 있으면 그 이유(외화·할인·수동 조정)를 먼저 알아야 한다.
--   ⚠ 원화 기준으로만 본다. 외화 건은 rate 가 그때그때 달라 여기서 못 잰다.
select coalesce(k.restaurant_name,'(매장 없음)')                       as "매장",
       k.reservation_date                                              as "방문일",
       k.party_size                                                    as "인원",
       k.price                                                         as "앱이 적은 금액",
       (coalesce(tp.meal_fee,0) + coalesce(tp.agency_fee,0)
        + coalesce(tp.wine_min,0)) * coalesce(k.party_size,1)          as "서버 재계산",
       k.price - (coalesce(tp.meal_fee,0) + coalesce(tp.agency_fee,0)
        + coalesce(tp.wine_min,0)) * coalesce(k.party_size,1)          as "차이",
       coalesce(k.extra_data ->> 'card_currency', 'KRW')               as "통화"
from public.tickets k
join public.ticket_products tp on tp.id::text = k.ticket_product_id::text
where coalesce(k.status,'') not in ('cancelled','canceled')
  and k.purchase_id like 'PAYH-%'
  and coalesce(k.price,0) > 0
  and k.price <> (coalesce(tp.meal_fee,0) + coalesce(tp.agency_fee,0)
                  + coalesce(tp.wine_min,0)) * coalesce(k.party_size,1)
order by abs(k.price - (coalesce(tp.meal_fee,0) + coalesce(tp.agency_fee,0)
                        + coalesce(tp.wine_min,0)) * coalesce(k.party_size,1)) desc
limit 30;

-- 여기가 0건이면 서버 재계산이 앱과 정확히 같다는 뜻 —
--   2단계를 원화 기준으로 바로 만들 수 있다.
