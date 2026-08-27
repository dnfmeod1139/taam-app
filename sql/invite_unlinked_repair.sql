-- ═══════════════════════════════════════════════════════════════
-- 초대 ↔ 판매 티켓 연결 누락 복구 (2026-08-27)
-- ═══════════════════════════════════════════════════════════════
-- 왜 생겼나
--   초대 발송 화면에서 날짜를 '직접' 고르면 _riDate 가 'MM.DD' 였는데,
--   「티켓 연결 필요」 가드는 'YYYY.MM.DD' 와 문자열로 비교했다. 항상 불일치라
--   후보 0건 → 가드가 통째로 통과 → 연결 없이 발송됐다.
--   연결 없는 초대는 tickets 에 좌석 행이 안 생겨서 정원에서 안 깎인다.
--   (코드는 _riSameDay 로 고쳤다. 이 파일은 이미 나간 초대를 되돌리는 용도)
--
-- 실행: Supabase SQL Editor. ① 미리보기 → 눈으로 확인 → ② 복구 순서로.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 미리보기 — 연결이 빠진 초대와, 붙일 수 있는 티켓 후보
-- ═══════════════════════════════════════════════════════════════
-- 「후보수」가 1 인 것만 자동 복구 대상이다. 0 이면 붙일 티켓이 없고,
-- 2 이상이면 어느 티켓인지 사람이 골라야 한다.
select
  inv.created_at                      as "보낸시각",
  left(inv.id::text, 8)               as "초대ID앞8",
  inv.status                          as "상태",
  inv.restaurant_name                 as "매장",
  inv.visit_date                      as "방문일",
  inv.visit_time                      as "시간",
  inv.pax                             as "인원",
  (select count(*) from public.ticket_products tp
    where tp.rest_id::text = inv.restaurant_id::text
      and tp.date = inv.visit_date
      and coalesce(tp.status,'') <> 'soldout')                    as "후보수",
  (select tp.id from public.ticket_products tp
    where tp.rest_id::text = inv.restaurant_id::text
      and tp.date = inv.visit_date
      and coalesce(tp.status,'') <> 'soldout'
    order by tp.created_at limit 1)                               as "후보티켓ID",
  (select tp.total_pax from public.ticket_products tp
    where tp.rest_id::text = inv.restaurant_id::text
      and tp.date = inv.visit_date
      and coalesce(tp.status,'') <> 'soldout'
    order by tp.created_at limit 1)                               as "후보정원",
  (select coalesce(sum(x.party_size),0) from public.tickets x
    where x.ticket_product_id = (select tp.id from public.ticket_products tp
        where tp.rest_id::text = inv.restaurant_id::text
          and tp.date = inv.visit_date
          and coalesce(tp.status,'') <> 'soldout'
        order by tp.created_at limit 1)
      and coalesce(x.status,'') <> 'cancelled')                   as "후보점유"
from public.reservation_invites inv
where inv.ticket_product_id is null
  and inv.status in ('sent','paid')
  and length(inv.visit_date) = 10
  and to_date(inv.visit_date, 'YYYY.MM.DD') >= current_date
order by inv.created_at;


-- ═══════════════════════════════════════════════════════════════
-- ② 복구 — 후보가 정확히 1건인 초대만 붙인다
-- ═══════════════════════════════════════════════════════════════
-- 하는 일
--   · reservation_invites.ticket_product_id 를 채운다
--   · tickets 에 좌석 행을 넣는다
--       status='sent' → 'hold'  + purchase_id 'INVH-…'  (아직 미결제)
--       status='paid' → 'active'+ purchase_id 'INV-…'   (이미 결제됨)
--   · 정원을 넘기면 그 초대는 건너뛰고 사유를 남긴다 (강제로 밀어넣지 않는다)
--   · 이미 좌석 행이 있으면 건너뛴다 (중복 차감 방지)
--
-- ⚠ ① 미리보기 결과를 확인한 뒤에 실행할 것.
do $$
declare
  -- 🎯 특정 초대만 복구하려면 초대ID 앞 8자리를 넣는다. 비우면(= '{}') 조건에 맞는 전부.
  --   테스트로 보낸 초대까지 같이 붙는 게 싫을 때 이걸 쓴다.
  v_only     text[] := array['111699c6'];   -- 예: array['111699c6'] / 전부면 '{}'::text[]
  r          record;
  v_tp       record;
  v_occupied int;
  v_pid      text;
  v_status   text;
  v_done     int := 0;
  v_skip     int := 0;
begin
  for r in
    select inv.*,
           (select tp.id from public.ticket_products tp
             where tp.rest_id::text = inv.restaurant_id::text
               and tp.date = inv.visit_date
               and coalesce(tp.status,'') <> 'soldout'
             order by tp.created_at limit 1) as cand_id,
           (select count(*) from public.ticket_products tp
             where tp.rest_id::text = inv.restaurant_id::text
               and tp.date = inv.visit_date
               and coalesce(tp.status,'') <> 'soldout') as cand_n
      from public.reservation_invites inv
     where inv.ticket_product_id is null
       and inv.status in ('sent','paid')
       and length(inv.visit_date) = 10
       and to_date(inv.visit_date, 'YYYY.MM.DD') >= current_date
       and (cardinality(v_only) = 0 or left(inv.id::text, 8) = any(v_only))
     order by inv.created_at
  loop
    if r.cand_n <> 1 then
      raise notice '건너뜀 % (%· %) — 후보 %건',
        left(r.id::text,8), r.restaurant_name, r.visit_date, r.cand_n;
      v_skip := v_skip + 1;
      continue;
    end if;

    -- 이미 좌석 행이 있으면 손대지 않는다
    if exists (select 1 from public.tickets t
                where coalesce(t.status,'') <> 'cancelled'
                  and ( coalesce(t.extra_data->>'inviteId','') = r.id::text
                     or t.purchase_id like 'INV%-' || left(r.id::text,8) || '-%' )) then
      raise notice '건너뜀 % — 이미 좌석 행 있음', left(r.id::text,8);
      v_skip := v_skip + 1;
      continue;
    end if;

    select * into v_tp from public.ticket_products where id = r.cand_id;

    select coalesce(sum(party_size),0) into v_occupied
      from public.tickets
     where ticket_product_id = v_tp.id and coalesce(status,'') <> 'cancelled';

    if coalesce(v_tp.total_pax,0) > 0 and v_occupied + r.pax > v_tp.total_pax then
      raise notice '건너뜀 % (%· %) — 정원 초과: 정원 % · 점유 % · 요청 %',
        left(r.id::text,8), r.restaurant_name, r.visit_date,
        v_tp.total_pax, v_occupied, r.pax;
      v_skip := v_skip + 1;
      continue;
    end if;

    if r.status = 'paid' then
      v_status := 'active';
      v_pid    := 'INV-'  || left(r.id::text,8) || '-' || extract(epoch from now())::bigint;
    else
      v_status := 'hold';
      v_pid    := 'INVH-' || left(r.id::text,8) || '-' || extract(epoch from now())::bigint;
    end if;

    insert into public.tickets(
      user_id, restaurant_id, restaurant_name, ticket_product_id, ticket_type,
      reservation_date, visit_time, party_size, price, status, purchase_id,
      buyer_name, buyer_phone, extra_data, created_at
    ) values (
      coalesce(r.invitee_user_id, r.host_user_id),
      r.restaurant_id, r.restaurant_name, v_tp.id::text, coalesce(v_tp.ticket_type,''),
      r.visit_date, coalesce(r.visit_time,''), r.pax, coalesce(r.total_amount,0),
      v_status, v_pid,
      '초대 연동(복구)', '',
      jsonb_build_object('inviteHold', r.status <> 'paid', 'inviteId', r.id::text, 'repaired', true),
      now()
    );

    update public.reservation_invites
       set ticket_product_id = v_tp.id::text
     where id = r.id;

    raise notice '복구 % (%· %) → 티켓 % · %석 · %',
      left(r.id::text,8), r.restaurant_name, r.visit_date, v_tp.id, r.pax, v_status;
    v_done := v_done + 1;
  end loop;

  raise notice '───────── 복구 %건 · 건너뜀 %건 ─────────', v_done, v_skip;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ③ 확인 — 복구 후 각 티켓의 정원 대비 점유
-- ═══════════════════════════════════════════════════════════════
select
  tp.rest_name                        as "매장",
  tp.date                             as "날짜",
  tp.total_pax                        as "정원",
  (select coalesce(sum(x.party_size),0) from public.tickets x
    where x.ticket_product_id = tp.id and coalesce(x.status,'') <> 'cancelled') as "점유",
  tp.status                           as "상태"
from public.ticket_products tp
where coalesce(tp.total_pax,0) > 0
  and length(tp.date) = 10
  and to_date(tp.date,'YYYY.MM.DD') >= current_date
order by tp.date;
