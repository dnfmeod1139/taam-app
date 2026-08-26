-- ═══════════════════════════════════════════════════════════════
-- TAAM — 초대 좌석행이 '가짜 티켓 id' 를 가리키던 것 복구 · 2026-08-27
-- Supabase SQL Editor 에 붙여넣고 RUN (idempotent — 이미 고친 건 건너뛴다)
--
-- 무엇이 잘못돼 있었나
--   초대를 '판매 티켓 연결' 없이 보내면, 회원이 결제할 때 tickets 행은 생기는데
--   ticket_product_id 에 진짜 티켓 대신 'inv-<초대uuid>' 라는 가짜 값이 들어간다.
--
--       id: (inv.ticket_product_id ? String(inv.ticket_product_id) : 'inv-' + inv.id)
--
--   행은 있으니 「좌석행 있음」 검사는 통과하지만, 그 행이 가리키는 상품이 실재하지
--   않으므로 어떤 티켓의 좌석도 깎지 않는다. 캘린더에는 보이는데 티켓은 멀쩡히 팔린다.
--   1/25 스시 아라이가 앱5+수동2+초대1=8 인데 7 로 나온 이유이고,
--   2/21 이 만석인데 티켓이 되살아난 이유다.
--
-- 왜 새 행을 만들지 않고 고치나
--   좌석 행은 이미 있다. 새로 INSERT 하면 같은 예약이 두 번 좌석을 먹는다.
--   가리키는 대상(ticket_product_id)만 진짜 티켓으로 바꾸는 게 정확하고 안전하다.
--   바꾸는 순간 좌석 트리거가 다시 세므로 잔여석·매진도 그 자리에서 맞춰진다.
--
-- ⚠ 취소된 행(status='cancelled')은 건드리지 않는다 — 좌석을 먹지 않으므로 고칠 게 없다.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- 1) 미리보기 — 무엇이 어느 티켓에 붙을지, 자리가 되는지
--    「후보 수」가 1 이어야 자동으로 붙일 수 있다.
--      0 = 그 날짜에 판매 티켓이 없음 (진짜 별도 판매였을 수 있다)
--      2+ = 같은 매장·날짜에 티켓이 여러 개 (시간대가 다름) → 사람이 골라야 한다
-- ═══════════════════════════════════════════════════════════════
with fake as (
  select inv.id           as invite_id,
         inv.restaurant_id,
         inv.restaurant_name,
         inv.visit_date,
         inv.visit_time,
         inv.pax,
         t.purchase_id
    from public.reservation_invites inv
    join public.tickets t
      on (t.purchase_id like ('INV-'  || left(inv.id::text,8) || '%')
       or t.purchase_id like ('INVH-' || left(inv.id::text,8) || '%'))
   where inv.ticket_product_id is null
     and t.ticket_product_id like 'inv-%'
     and coalesce(t.status,'') <> 'cancelled'
     -- ⚠ 지나간 예약은 손대지 않는다.
     --   이미 다녀온 자리는 좌석을 다시 셀 이유가 없고, 과거 티켓에 좌석을 붙이면
     --   정산이 끝난 매진 티켓의 숫자가 뒤늦게 움직인다. 오늘 이후만 고친다.
     --   연도가 없는 옛 기록('09.11')도 대상에서 뺀다 — 어느 해인지 알 수 없다.
     and length(inv.visit_date) = 10
     and to_date(replace(inv.visit_date,'.','-'), 'YYYY-MM-DD') >= current_date
), matched as (
  select f.*,
         (select count(*) from public.ticket_products tp
           where tp.rest_id::text = f.restaurant_id
             and right(replace(tp.date,'-','.'),5) = right(replace(f.visit_date,'-','.'),5)
             and (length(tp.date) < 10 or length(f.visit_date) < 10
                  or left(replace(tp.date,'-','.'),4) = left(replace(f.visit_date,'-','.'),4))
         ) as cand_cnt,
         (select tp.id from public.ticket_products tp
           where tp.rest_id::text = f.restaurant_id
             and right(replace(tp.date,'-','.'),5) = right(replace(f.visit_date,'-','.'),5)
             and (length(tp.date) < 10 or length(f.visit_date) < 10
                  or left(replace(tp.date,'-','.'),4) = left(replace(f.visit_date,'-','.'),4))
           limit 1
         ) as tp_id
    from fake f
)
select m.invite_id            as "초대 id",
       m.restaurant_name      as "매장",
       m.visit_date           as "방문일",
       m.visit_time           as "시간",
       m.pax                  as "인원",
       m.cand_cnt             as "후보 수",
       m.tp_id                as "붙일 티켓 id",
       tp.total_pax           as "정원",
       (select coalesce(sum(x.party_size),0) from public.tickets x
         where x.ticket_product_id = m.tp_id
           and coalesce(x.status,'') <> 'cancelled')                     as "현재 점유",
       tp.total_pax - (select coalesce(sum(x.party_size),0) from public.tickets x
                        where x.ticket_product_id = m.tp_id
                          and coalesce(x.status,'') <> 'cancelled')      as "붙이기 전 잔여"
  from matched m
  left join public.ticket_products tp on tp.id = m.tp_id
 order by m.visit_date;


-- ═══════════════════════════════════════════════════════════════
-- 2) 복구 — 후보가 정확히 1개인 것만 붙인다
--
--    건별로 예외를 잡는다. 한 건이 정원을 넘겨 거부돼도 나머지는 그대로 진행된다.
--    (한 문장으로 UPDATE 하면 하나만 걸려도 전부 롤백된다)
--
--    좌석 트리거가 정원을 검증하므로, 자리가 없으면 그 건만 거부되고 이유가 남는다.
--    거부된 건은 실제로 오버북이라는 뜻이다 — 사람이 판단해야 한다.
-- ═══════════════════════════════════════════════════════════════
do $$
declare
  rec       record;
  v_ok      int := 0;
  v_skip    int := 0;
  v_fail    int := 0;
begin
  for rec in
    with fake as (
      select inv.id as invite_id, inv.restaurant_id, inv.restaurant_name,
             inv.visit_date, inv.pax, t.purchase_id
        from public.reservation_invites inv
        join public.tickets t
          on (t.purchase_id like ('INV-'  || left(inv.id::text,8) || '%')
           or t.purchase_id like ('INVH-' || left(inv.id::text,8) || '%'))
       where inv.ticket_product_id is null
         and t.ticket_product_id like 'inv-%'
         and coalesce(t.status,'') <> 'cancelled'
         -- 지나간 예약·연도 없는 옛 기록은 제외 (위 미리보기와 같은 기준)
         and length(inv.visit_date) = 10
         and to_date(replace(inv.visit_date,'.','-'), 'YYYY-MM-DD') >= current_date
    )
    select f.*,
           (select count(*) from public.ticket_products tp
             where tp.rest_id::text = f.restaurant_id
               and right(replace(tp.date,'-','.'),5) = right(replace(f.visit_date,'-','.'),5)
               and (length(tp.date) < 10 or length(f.visit_date) < 10
                    or left(replace(tp.date,'-','.'),4) = left(replace(f.visit_date,'-','.'),4))
           ) as cand_cnt,
           (select tp.id from public.ticket_products tp
             where tp.rest_id::text = f.restaurant_id
               and right(replace(tp.date,'-','.'),5) = right(replace(f.visit_date,'-','.'),5)
               and (length(tp.date) < 10 or length(f.visit_date) < 10
                    or left(replace(tp.date,'-','.'),4) = left(replace(f.visit_date,'-','.'),4))
             limit 1
           ) as tp_id
      from fake f
  loop
    if rec.cand_cnt <> 1 or rec.tp_id is null then
      v_skip := v_skip + 1;
      raise notice '⏭  건너뜀 (후보 %개): % · % · %명',
        rec.cand_cnt, rec.restaurant_name, rec.visit_date, rec.pax;
      continue;
    end if;

    begin
      -- 좌석 행이 진짜 티켓을 가리키게 한다 (여기서 좌석 트리거가 정원을 검증한다)
      -- purchase_id 로 지목한다 — tickets 의 기본키 이름에 의존하지 않는다
      update public.tickets
         set ticket_product_id = rec.tp_id
       where purchase_id = rec.purchase_id
         and ticket_product_id like 'inv-%'
         and coalesce(status,'') <> 'cancelled';

      -- 초대에도 연결을 남긴다 (다음부터 이 초대는 '연결됨' 으로 보인다)
      update public.reservation_invites
         set ticket_product_id = rec.tp_id
       where id = rec.invite_id;

      v_ok := v_ok + 1;
      raise notice '✅ 연결: % · % · %명 → 티켓 %',
        rec.restaurant_name, rec.visit_date, rec.pax, rec.tp_id;
    exception when others then
      v_fail := v_fail + 1;
      raise notice '❌ 거부: % · % · %명 → %  (사유: %)',
        rec.restaurant_name, rec.visit_date, rec.pax, rec.tp_id, sqlerrm;
    end;
  end loop;

  raise notice '───────────────────────────────';
  raise notice '연결 % 건 / 건너뜀 % 건 / 거부 % 건', v_ok, v_skip, v_fail;
  raise notice '거부는 정원 초과라는 뜻입니다 — 실제 오버북이니 사람이 판단하세요';
end $$;


-- ═══════════════════════════════════════════════════════════════
-- 3) 확인 — 출처별 좌석이 제대로 잡혔는지
--    앱구매 + 초대 + 수동 = 점유, 그리고 점유 <= 정원 이어야 한다
-- ═══════════════════════════════════════════════════════════════
select tp.rest_name as "매장", tp.date as "날짜", tp.total_pax as "정원", tp.status,
       coalesce(sum(t.party_size) filter (
         where t.purchase_id not like 'INV%' and t.purchase_id not like 'MAN-%'), 0) as "앱구매",
       coalesce(sum(t.party_size) filter (where t.purchase_id like 'INV%'),  0) as "초대",
       coalesce(sum(t.party_size) filter (where t.purchase_id like 'MAN-%'), 0) as "수동",
       coalesce(sum(t.party_size), 0)                as "점유",
       tp.total_pax - coalesce(sum(t.party_size), 0) as "잔여"
  from public.ticket_products tp
  left join public.tickets t
    on t.ticket_product_id = tp.id
   and coalesce(t.status,'') <> 'cancelled'
 where coalesce(tp.total_pax,0) > 0
 group by tp.id, tp.rest_name, tp.date, tp.total_pax, tp.status
 having coalesce(sum(t.party_size), 0) > 0
 order by tp.date;


-- ═══════════════════════════════════════════════════════════════
-- 4) 아직 남은 가짜 연결이 있는지 (0 이어야 정상)
-- ═══════════════════════════════════════════════════════════════
select count(*) as "남은 가짜 연결(활성)"
  from public.tickets
 where ticket_product_id like 'inv-%'
   and coalesce(status,'') <> 'cancelled';
