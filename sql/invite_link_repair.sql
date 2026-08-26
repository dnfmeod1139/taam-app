-- ═══════════════════════════════════════════════════════════════
-- TAAM — 「초대·수동 예약이 티켓 좌석에서 안 깎인다」 진단 + 복구 · 2026-08-27
-- Supabase SQL Editor 에 붙여넣고 RUN
--
-- 무슨 일이 있었나 (1/25 스시 아라이 · 2/21)
--   초대 발송 화면의 「판매 티켓 연결」 기본값이 「연결 안 함」이었다.
--   캘린더에서 초대를 보내도 reservation_invites 에만 기록이 남고,
--   tickets 에 좌석 행(INVH-/INV-)이 생기지 않았다.
--   → 캘린더에는 보이는데 티켓 좌석은 하나도 안 깎인다
--   → 정원이 다 찼는데도 앱에서 계속 팔린다 (매진이던 티켓이 되살아난다)
--   수동 추가도 같은 구조였다 (「연결 안 함 (기록만)」이 기본).
--
--   앱은 고쳤다 — 캘린더에서 열면 그 날짜 티켓을 자동 연결하고,
--   연결할 티켓이 있는데 연결하지 않으면 발송·저장을 막는다.
--   이 파일은 이미 연결 없이 나가버린 것들을 찾아 고친다.
--
-- ⚠ 좌석 행을 만드는 일이라 사람이 확인하고 하나씩 해야 한다.
--   자동 일괄 처리는 넣지 않았다 — 잘못 붙이면 없는 예약이 정원을 먹는다.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- 1) 연결 없이 나간 초대 — 같은 매장·날짜에 판매 티켓이 있는 것만
--    (티켓이 아예 없는 날짜의 초대는 '별도 판매' 라 정상이다)
-- ═══════════════════════════════════════════════════════════════
select inv.id                      as "초대 id",
       inv.restaurant_name         as "매장",
       inv.visit_date              as "방문일",
       inv.visit_time              as "시간",
       inv.pax                     as "인원",
       inv.status                  as "초대상태",
       inv.invitee_user_id         as "회원 id",
       tp.id                       as "붙일 티켓 id",
       tp.total_pax                as "정원",
       (select coalesce(sum(x.party_size),0) from public.tickets x
         where x.ticket_product_id = tp.id
           and coalesce(x.status,'') <> 'cancelled')  as "현재 점유"
  from public.reservation_invites inv
  join public.ticket_products tp
    -- ⚠ ticket_products.rest_id 는 uuid, reservation_invites.restaurant_id 는 text 다.
    --   캐스트 없이 비교하면 42883 (operator does not exist: uuid = text) 로 실패한다.
    on  tp.rest_id::text = inv.restaurant_id
    -- 날짜는 양쪽 다 텍스트다 ('YYYY.MM.DD' 또는 연도 없는 'MM.DD').
    -- MM.DD 는 반드시 같아야 하고, 둘 다 연도를 가지고 있으면 연도까지 같아야 한다.
    and right(replace(tp.date,'-','.'), 5) = right(replace(inv.visit_date,'-','.'), 5)
    and (length(tp.date) < 10 or length(inv.visit_date) < 10
         or left(replace(tp.date,'-','.'),4) = left(replace(inv.visit_date,'-','.'),4))
 where inv.ticket_product_id is null
   and coalesce(inv.status,'') not in ('cancelled', 'expired')
 order by inv.visit_date;


-- ═══════════════════════════════════════════════════════════════
-- 2) 그 초대가 tickets 에 좌석 행을 가지고 있는가 (없으면 안 깎인 것)
-- ═══════════════════════════════════════════════════════════════
select inv.id                as "초대 id",
       inv.restaurant_name   as "매장",
       inv.visit_date        as "방문일",
       inv.pax               as "인원",
       inv.status            as "초대상태",
       exists (select 1 from public.tickets t
                where t.purchase_id like ('INVH-' || left(inv.id::text, 8) || '%')
                   or t.purchase_id like ('INV-'  || left(inv.id::text, 8) || '%'))  as "좌석행 있음"
  from public.reservation_invites inv
 where coalesce(inv.status,'') not in ('cancelled', 'expired')
 order by inv.visit_date desc
 limit 60;


-- ═══════════════════════════════════════════════════════════════
-- 3) 복구 — 1번 목록에서 고른 초대 하나를 티켓에 붙인다
--
--    ⚠ 아래 두 값만 바꿔서 실행하세요. 한 번에 하나씩.
--      :초대id   1번 결과의 「초대 id」
--      :티켓id   1번 결과의 「붙일 티켓 id」
--
--    ① reservation_invites 에 연결을 기록하고
--    ② tickets 에 좌석 행을 만든다
--       · 초대가 아직 결제 전(sent)   → status='hold',   purchase_id='INVH-…'
--       · 이미 결제됨(paid)           → status='active', purchase_id='INV-…'
--    좌석 트리거가 정원을 검증하므로, 자리가 없으면 여기서 거부된다 (안전).
-- ═══════════════════════════════════════════════════════════════
/*
do $$
declare
  v_inv_id  uuid := '여기에 초대 id'::uuid;
  v_tp_id   text := '여기에 티켓 id';
  inv       public.reservation_invites%rowtype;
  tp        public.ticket_products%rowtype;
  v_paid    boolean;
begin
  select * into inv from public.reservation_invites where id = v_inv_id;
  if not found then raise exception '초대를 찾을 수 없습니다: %', v_inv_id; end if;

  select * into tp from public.ticket_products where id = v_tp_id;
  if not found then raise exception '티켓을 찾을 수 없습니다: %', v_tp_id; end if;

  if exists (select 1 from public.tickets t
              where (t.purchase_id like ('INVH-' || left(inv.id::text,8) || '%')
                  or t.purchase_id like ('INV-'  || left(inv.id::text,8) || '%'))
                and coalesce(t.status,'') <> 'cancelled') then
    raise notice 'ℹ️  이미 좌석 행이 있습니다 — 건너뜁니다';
    return;
  end if;

  v_paid := (coalesce(inv.status,'') = 'paid');

  update public.reservation_invites
     set ticket_product_id = v_tp_id
   where id = v_inv_id;

  insert into public.tickets (
    user_id, restaurant_id, restaurant_name, ticket_product_id, ticket_type,
    reservation_date, visit_time, party_size, price, status, purchase_id,
    buyer_name, buyer_phone, extra_data, created_at
  ) values (
    -- 매장 id 는 티켓 쪽(uuid)을 기준으로 넣는다 — 초대의 text 값과 형식이 다를 수 있다
    inv.invitee_user_id, tp.rest_id::text, inv.restaurant_name, v_tp_id, tp.type_class,
    inv.visit_date, inv.visit_time, inv.pax, coalesce(inv.total_amount,0),
    case when v_paid then 'active' else 'hold' end,
    (case when v_paid then 'INV-' else 'INVH-' end) || left(inv.id::text,8) || '-' || extract(epoch from now())::bigint,
    coalesce((select p.display_name from public.profiles p where p.id = inv.invitee_user_id), '초대'), '',
    jsonb_build_object('inviteHold', not v_paid, 'inviteId', inv.id::text, 'repaired', true),
    now()
  );

  raise notice '✅ 초대 % → 티켓 % 연결 완료 (% 명, %)',
    v_inv_id, v_tp_id, inv.pax, case when v_paid then 'active' else 'hold' end;
end $$;
*/


-- ═══════════════════════════════════════════════════════════════
-- 4) 확인 — 각 티켓의 좌석이 출처별로 어떻게 잡혀 있는지
--    앱구매 + 초대 + 수동 = 점유 가 되어야 하고, 점유 <= 정원 이어야 한다
-- ═══════════════════════════════════════════════════════════════
select tp.id, tp.rest_name as "매장", tp.date as "날짜", tp.total_pax as "정원", tp.status,
       coalesce(sum(t.party_size) filter (
         where t.purchase_id not like 'INV%' and t.purchase_id not like 'MAN-%'), 0) as "앱구매",
       coalesce(sum(t.party_size) filter (where t.purchase_id like 'INV%'),  0) as "초대",
       coalesce(sum(t.party_size) filter (where t.purchase_id like 'MAN-%'), 0) as "수동",
       coalesce(sum(t.party_size), 0)                                            as "점유",
       tp.total_pax - coalesce(sum(t.party_size), 0)                              as "잔여"
  from public.ticket_products tp
  left join public.tickets t
    on t.ticket_product_id = tp.id
   and coalesce(t.status,'') <> 'cancelled'
 where coalesce(tp.total_pax,0) > 0
 group by tp.id, tp.rest_name, tp.date, tp.total_pax, tp.status
 order by tp.date
 limit 40;

do $$ begin
  raise notice 'ℹ️  1번 목록이 비어 있으면 연결 누락은 없습니다';
  raise notice 'ℹ️  복구는 3번 블록의 주석을 풀고 id 두 개만 바꿔 하나씩 실행하세요';
end $$;
