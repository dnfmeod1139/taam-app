-- ═══════════════════════════════════════════════════════════════
-- TAAM — auto_soldout 플래그 정리 · 2026-08-27
-- Supabase SQL Editor 에 붙여넣고 RUN (idempotent)
--
-- 무엇이 잘못돼 있었나
--   auto_soldout = false 는 「어드민이 손으로 잠갔다」는 뜻이다. 이 표시가 있으면
--     · 좌석 동기화 트리거가 매진을 되돌리지 못한다
--     · toss-order 가 본인 홀드가 있어도 결제를 무조건 거절한다
--       (수동 매진은 외부 예약이 이미 잡혔다는 뜻이라 뚫으면 이중예약이 된다)
--
--   그런데 앱의 매진 토글이 「판매중으로 되돌릴 때」도 false 를 썼다.
--   그래서 어드민이 한 번이라도 토글한 티켓은 영영 '수동 잠금' 으로 남았다.
--   판매중일 때는 아무 일도 없다가, 나중에 좌석이 차서 자동 매진이 걸리는 순간
--   그 티켓은 아무도 — 좌석을 잡은 본인조차 — 살 수 없게 된다.
--   화면에는 "남은 좌석이 없습니다" 만 뜬다. 2026-08-27 타카미츠가 그 경우다.
--
--   진단 표에서 27건 중 25건이 auto_soldout=false 였다. 어드민이 25건을 손으로
--   잠근 게 아니다 — 토글을 한 번씩 눌렀을 뿐이다.
--
-- 앱 쪽은 고쳤다 (매진으로 잠글 때만 false, 판매 재개하면 true 로 되돌림).
-- 이 파일은 이미 잘못 박혀 있는 값을 정리한다.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- 1) 판매중인 티켓 → auto_soldout = true
--    수동 잠금은 '매진 상태' 에서만 의미가 있다. 판매중인 티켓에 남아 있는
--    false 는 아무 것도 지키지 않으면서, 나중에 자동 매진이 걸릴 때
--    그 티켓을 못 팔게 만드는 지뢰로만 작동한다.
-- ═══════════════════════════════════════════════════════════════
with fixed as (
  update public.ticket_products
     set auto_soldout = true
   where coalesce(status,'') <> 'soldout'
     and coalesce(auto_soldout, true) = false
  returning id
)
select count(*) as "판매중 티켓 플래그 정리" from fixed;


-- ═══════════════════════════════════════════════════════════════
-- 2) 매진인데 실제로 꽉 찬 티켓 → auto_soldout = true
--    점유가 정원을 채웠으면 어떤 기준으로도 '자동 매진' 이다.
--    true 로 돌려놔야 나중에 취소가 나서 자리가 비었을 때 다시 열린다.
-- ═══════════════════════════════════════════════════════════════
with fixed as (
  update public.ticket_products tp
     set auto_soldout = true
   where coalesce(tp.status,'') = 'soldout'
     and coalesce(tp.auto_soldout, true) = false
     and coalesce(tp.total_pax,0) > 0
     and (select coalesce(sum(x.party_size),0) from public.tickets x
           where x.ticket_product_id = tp.id
             and coalesce(x.status,'') <> 'cancelled') >= tp.total_pax
  returning tp.id, tp.rest_name
)
select count(*) as "꽉 찬 매진 플래그 정리" from fixed;


-- ═══════════════════════════════════════════════════════════════
-- 3) ⚠ 사람이 판단해야 하는 것 — 매진인데 자리가 남아 있는 티켓
--
--    두 가지 경우가 섞여 있어 자동으로 풀면 안 된다:
--      · 진짜 수동 매진   — 웹·전화·메신저로 외부 예약이 이미 찼다.
--                          여기서 풀면 이중예약이 난다. 그대로 둬야 한다.
--      · 잘못 박힌 플래그 — 위 버그로 잠긴 것. 풀어야 한다.
--
--    아래 목록을 보고 하나씩 판단하세요.
-- ═══════════════════════════════════════════════════════════════
select tp.id,
       tp.rest_name                                   as "매장",
       tp.date                                        as "날짜",
       tp.total_pax                                   as "정원",
       (select coalesce(sum(x.party_size),0) from public.tickets x
         where x.ticket_product_id = tp.id and coalesce(x.status,'') <> 'cancelled') as "점유",
       (to_jsonb(tp.slots)->>'mode')                  as "구성",
       tp.updated_at                                  as "마지막 변경"
  from public.ticket_products tp
 where coalesce(tp.status,'') = 'soldout'
   and coalesce(tp.total_pax,0) > 0
   and (select coalesce(sum(x.party_size),0) from public.tickets x
         where x.ticket_product_id = tp.id
           and coalesce(x.status,'') <> 'cancelled') < tp.total_pax
 order by tp.updated_at desc;

-- ── 위 목록에서 '풀어야 할' 티켓이 있으면 id 를 넣어 이것만 실행 ──
--    (판매중으로 되돌리고 수동 잠금도 해제한다)
--
--    update public.ticket_products
--       set status = 'active', auto_soldout = true
--     where id in ('여기에 id', '여러 개면 콤마로');


-- ═══════════════════════════════════════════════════════════════
-- 4) 확인 — 이 표에 「점유 < 정원」인데 status='soldout' 인 줄은
--    전부 '의도한 수동 매진' 이어야 한다
-- ═══════════════════════════════════════════════════════════════
select tp.id, tp.rest_name as "매장", tp.total_pax as "정원", tp.status,
       (to_jsonb(tp.slots)->>'mode') as "구성",
       coalesce(tp.auto_soldout, true) as "자동매진",
       (select coalesce(sum(x.party_size),0) from public.tickets x
         where x.ticket_product_id = tp.id and coalesce(x.status,'') <> 'cancelled') as "점유"
  from public.ticket_products tp
 where coalesce(tp.total_pax,0) > 0
 order by (coalesce(tp.status,'') = 'soldout') desc, tp.updated_at desc
 limit 40;

do $$ begin
  raise notice '✅ auto_soldout 플래그 정리 완료 — 3번 목록은 사람이 판단하세요';
end $$;
