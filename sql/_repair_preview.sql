-- ═══════════════════════════════════════════════════════════════
-- TAAM — 복구 전 미리보기 묶음 (2026-08-28)
-- ═══════════════════════════════════════════════════════════════
-- 읽기 전용. 아무것도 바꾸지 않는다.
--
-- 점검 SQL(_health_check.sql) 두 번째 표에서 건수가 나온 항목을
-- 「그래서 정확히 무엇을 손대게 되나」까지 펼쳐 본다.
-- 손대기 전에 이걸 먼저 보는 이유는 단순하다 —
-- 좌석과 예치금은 되돌리기 어렵다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--       결과 표 두 개가 나온다.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 좌석에 안 붙은 초대 — 무엇을, 어느 티켓에 붙이게 되나
-- ═══════════════════════════════════════════════════════════════
--   「후보수」가 판단 기준이다.
--     1  → 붙일 티켓이 하나뿐. 자동 복구 대상
--     0  → 붙일 티켓이 없다. 티켓을 먼저 만들거나, 그냥 둔다
--     2+ → 어느 티켓인지 사람이 골라야 한다
--
--   「테스트로 보낸 초대」가 섞여 있으면 여기서 걸러낸다.
--   복구 스크립트의 v_only 에 초대ID앞8 을 넣어 그 건만 처리할 수 있다.
select
  to_char(inv.created_at, 'MM-DD HH24:MI')            as "보낸시각",
  left(inv.id::text, 8)                               as "초대ID앞8",
  inv.status                                          as "상태",
  coalesce(pr.display_name, left(inv.invitee_user_id::text, 8)) as "받는분",
  inv.restaurant_name                                 as "매장",
  inv.visit_date                                      as "방문일",
  inv.pax                                             as "인원",
  (select count(*) from public.ticket_products tp
    where tp.rest_id::text = inv.restaurant_id::text
      and tp.date = inv.visit_date
      and coalesce(tp.status,'') <> 'soldout')        as "후보수",
  (select tp.total_pax from public.ticket_products tp
    where tp.rest_id::text = inv.restaurant_id::text
      and tp.date = inv.visit_date
      and coalesce(tp.status,'') <> 'soldout'
    order by tp.created_at limit 1)                   as "후보정원",
  (select coalesce(sum(x.party_size),0) from public.tickets x
    where x.ticket_product_id = (select tp.id from public.ticket_products tp
        where tp.rest_id::text = inv.restaurant_id::text
          and tp.date = inv.visit_date
          and coalesce(tp.status,'') <> 'soldout'
        order by tp.created_at limit 1)
      and coalesce(x.status,'') <> 'cancelled')       as "후보점유",
  case
    when (select count(*) from public.ticket_products tp
           where tp.rest_id::text = inv.restaurant_id::text
             and tp.date = inv.visit_date
             and coalesce(tp.status,'') <> 'soldout') = 0
      then '· 티켓 없이 보낸 초대 — 붙일 대상 없음 (정상)'
    when (select count(*) from public.ticket_products tp
           where tp.rest_id::text = inv.restaurant_id::text
             and tp.date = inv.visit_date
             and coalesce(tp.status,'') <> 'soldout') > 1
      then '⛔ 후보가 여럿 — 사람이 골라야 함'
    when exists (select 1 from public.tickets t
                  where coalesce(t.status,'') <> 'cancelled'
                    and ( coalesce(t.extra_data->>'inviteId','') = inv.id::text
                       or t.purchase_id like 'INV%-' || left(inv.id::text,8) || '-%' ))
      then '· 이미 좌석 행 있음 — 건너뜀'
    else '✅ 붙일 수 있음'
  end                                                 as "판정"
from public.reservation_invites inv
left join public.profiles pr on pr.id = inv.invitee_user_id
where inv.ticket_product_id is null
  and inv.status in ('sent','paid')
  and length(inv.visit_date) = 10
  and to_date(inv.visit_date, 'YYYY.MM.DD') >= current_date
order by inv.created_at;


-- ═══════════════════════════════════════════════════════════════
-- ② 예치금 주머니 — 누구를 얼마나 되돌리게 되나
-- ═══════════════════════════════════════════════════════════════
--   ⚠ 총액은 한 원도 바뀌지 않는다. 멤버십 ↔ 일반 사이만 옮긴다.
--   구매건별로 '멤버십에서 나간 비율' 을 계산해 그 비율만큼만 되돌린다.
with refund_g as (
  select user_id,
         metadata->>'purchase_id' as pid,
         sum(amount)              as ref_amt
    from public.deposit_transactions
   where change_type = 'ticket_refund'
     and deposit_type = 'general'
     and metadata->>'purchase_id' is not null
   group by 1, 2
),
purch as (
  select user_id,
         coalesce(
           metadata->>'purchase_id',
           case when metadata->>'invite_id' is not null
                then 'INV-' || left(metadata->>'invite_id', 8) end
         ) as pid,
         sum(case when deposit_type = 'membership' then abs(amount) else 0 end) as mem_out,
         sum(abs(amount))                                                       as tot_out
    from public.deposit_transactions
   where change_type = 'ticket_purchase'
     and (metadata->>'purchase_id' is not null or metadata->>'invite_id' is not null)
   group by 1, 2
),
already as (
      -- 🆕 2026.08-28: 이미 적용한 보정을 뺀다.
      --   이 스크립트는 '일반으로 들어온 환불' 을 근거로 옮길 금액을 낸다. 그런데 한 번
      --   돌리고 나도 그 환불 기록은 그대로 남는다 — 근거를 지우지 않으니 당연하다.
      --   그래서 다시 돌리면 **같은 금액을 또 옮긴다.** 실제로 세 회원이 이미 보정된
      --   상태인데 '아직 남았다' 로 나왔다. 그대로 실행했으면 멤버십이 부풀고,
      --   진짜 일반 입금(admin_grant)까지 멤버십으로 넘어갈 뻔했다.
      select user_id, sum(abs(amount)) as moved
        from public.deposit_transactions
       where change_type = 'other'
         and deposit_type = 'general'
         and amount < 0
         and ( metadata->>'reason' = 'refund_pocket_repair'
            or coalesce(description,'') like '%주머니 보정%' )
       group by 1
    ),
calc as (
  select r.user_id,
         greatest(0,
           sum(round(r.ref_amt * p.mem_out::numeric / nullif(p.tot_out, 0)))::bigint
           - coalesce(max(a.moved), 0)
         )::bigint as to_move
    from refund_g r
    join purch p on p.user_id = r.user_id
                and (p.pid = r.pid
                     or (r.pid like 'INV-%' and p.pid = left(r.pid, 12)))
   left join already a on a.user_id = r.user_id
   where p.mem_out > 0
   group by r.user_id
)
select
  coalesce(pr.display_name, left(c.user_id::text, 8)) as "회원",
  pr.membership_deposit_balance                       as "현재_멤버십",
  pr.general_deposit_balance                          as "현재_일반",
  pr.membership_deposit_balance
    + pr.general_deposit_balance                      as "합계(안변함)",
  least(c.to_move, pr.general_deposit_balance)        as "옮길금액",
  pr.membership_deposit_balance
    + least(c.to_move, pr.general_deposit_balance)    as "보정후_멤버십",
  pr.general_deposit_balance
    - least(c.to_move, pr.general_deposit_balance)    as "보정후_일반",
  case when c.to_move > pr.general_deposit_balance
       then '⚠ 일반 잔액이 부족 — 남은 만큼만 옮김'
       else '✅ 전액 복원 가능' end                     as "비고"
from calc c
join public.profiles pr on pr.id = c.user_id
where c.to_move > 0
order by c.to_move desc;


-- ═══════════════════════════════════════════════════════════════
-- ③ 이미 적용된 주머니 보정 이력
-- ═══════════════════════════════════════════════════════════════
--   ② 가 비어 있으면 '할 게 없다' 인지 '쿼리가 안 돌았나' 인지 헷갈린다.
--   여기에 줄이 있으면 ② 가 빈 것이 정상이라는 뜻이다 — 이미 끝났다.
select
  coalesce(pr.display_name, left(d.user_id::text, 8)) as "회원",
  to_char(d.created_at, 'YYYY-MM-DD HH24:MI')         as "보정시각",
  abs(d.amount)                                       as "옮긴금액",
  d.description                                       as "내용"
from public.deposit_transactions d
join public.profiles pr on pr.id = d.user_id
where d.change_type = 'other'
  and d.deposit_type = 'general'
  and d.amount < 0
  and ( d.metadata->>'reason' = 'refund_pocket_repair'
     or coalesce(d.description,'') like '%주머니 보정%' )
order by d.created_at desc;
