-- ============================================================================
-- 20260929_kashikiri_seat_sync6.sql — 정산 좌석 행의 금액은 0 (티켓 금액과 분리) (2026-09-29 밤)
-- ============================================================================
-- 5차에서 정산 청구액 대신 티켓 정가를 넣었더니 캘린더에 Trina ₩900,000 이 떠서 실제 결제(₩2,321,555 · $1,679.85)와 달랐다.
-- 링크·정산 결제액은 티켓 금액과 별개다 — 좌석 행에는 0 을 넣고, 캘린더는 슈퍼어드민일 때 kashikiri_charges 에서 실제 결제액을
-- 따로 읽어 「정산 결제」로 보여 준다. 매장 어드민은 정산 표를 못 읽으니 금액 없이 좌석만 본다. 매출 집계가 tickets.price 를
-- 더하더라도 정산 좌석은 0 이라 두 번 세지 않는다 (정산 매출은 정산 화면이 갖는다).
-- ============================================================================

create or replace function public._taam_ksk_seat_sync(p_event_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_ev    public.kashikiri_events%rowtype;
  v_tp    public.ticket_products%rowtype;
  v_tp_id text;
  r       record;
  v_made int := 0; v_cancelled int := 0; v_resized int := 0; v_seats int := 0;
  v_short jsonb := '[]'::jsonb;
  v_pid text; v_uid uuid; v_date text; v_time text; v_kind text; v_others int;
begin
  -- 같은 회차의 동기화는 한 번에 하나만. ⚠ 회차 행을 읽기 **전에** 잠근다 — 잠근 뒤 읽어야
  --   동시에 돈 연결/해제 RPC 가 바꾼 ticket_product_id 를 본다 (리뷰 지적: 낡은 값으로 새 좌석을 접을 수 있었다).
  --   잠금 순서는 언제나 회차 → 티켓(정원 트리거의 tkcap_ 락). 반대 순서로 잡는 곳이 없어 교착이 없다.
  perform pg_advisory_xact_lock(hashtext('ksk_sync_' || p_event_id::text));
  select * into v_ev from public.kashikiri_events where id = p_event_id;
  if not found then return json_build_object('ok', false, 'error', 'EVENT_NOT_FOUND'); end if;
  v_tp_id := nullif(v_ev.ticket_product_id, '');
  if v_tp_id is not null then
    select * into v_tp from public.ticket_products where id::text = v_tp_id;
    if not found then v_tp_id := null; end if;
  end if;

  -- ① 살아 있는 KSK- 행 중 근거가 사라진 것 → cancelled
  for r in
    select t.id, t.ticket_product_id, t.extra_data->>'chargeId' as charge_id
      from public.tickets t
     where t.purchase_id like 'KSK-%'
       and t.extra_data->>'eventId' = v_ev.id::text
       and coalesce(t.status,'') <> 'cancelled'
  loop
    if v_tp_id is null or r.ticket_product_id is distinct from v_tp_id
       or not exists (select 1 from public.kashikiri_charges c
                       where c.id::text = r.charge_id and c.status = 'paid' and not coalesce(c.link_invite, false)) then
      update public.tickets
         set status = 'cancelled',
             extra_data = coalesce(extra_data,'{}'::jsonb) || jsonb_build_object('cancelledBy','ksk_sync','cancelledAt',now())
       where id = r.id;
      v_cancelled := v_cancelled + 1;
    end if;
  end loop;

  if v_tp_id is null then
    return json_build_object('ok', true, 'linked', null, 'made', 0, 'cancelled', v_cancelled,
                             'resized', 0, 'short', v_short, 'seats', 0);
  end if;

  -- 소유자: 회차 작성자 → 호출자 → (Edge 경로엔 둘 다 없을 수 있다) 아무 슈퍼어드민
  v_uid := coalesce(v_ev.created_by, auth.uid(),
                    (select p.id from public.profiles p where p.role in ('super_admin','superadmin') order by p.id limit 1));
  v_date := to_char(v_ev.event_date, 'YYYY.MM.DD');
  v_time := coalesce(to_char(v_ev.event_time, 'HH24:MI'), v_tp.time, '');

  -- ② paid 인 정산 청구(링크 초대 제외)마다 KSK- 행 하나. 있으면 인원만 맞춘다.
  for r in
    select c.id, c.label, c.payer_name, c.payer_phone, c.amount_krw, c.pay_currency, c.pay_amount, c.team_id,
           greatest(coalesce(tm.pax, 1), 1) as pax,
           s.seat_id, s.seat_pax
      from public.kashikiri_charges c
      left join public.kashikiri_teams tm on tm.id = c.team_id
      left join lateral (
        select t.id as seat_id, t.party_size as seat_pax
          from public.tickets t
         where t.purchase_id like 'KSK-%' and t.extra_data->>'chargeId' = c.id::text
           and coalesce(t.status,'') <> 'cancelled'
         order by t.created_at desc limit 1) s on true
     where c.event_id = v_ev.id and c.status = 'paid' and not coalesce(c.link_invite, false)
     order by c.approved_at nulls last, c.id
  loop
    if r.seat_id is not null then
      -- 🆕 (5차) 회차의 날짜·시간이 바뀌면 좌석 행도 따라간다 (리뷰 지적: 만든 시점 값이 굳어 있었다)
      update public.tickets set reservation_date = v_date, visit_time = v_time
       where id = r.seat_id and (reservation_date is distinct from v_date or visit_time is distinct from v_time);
      if r.seat_pax is distinct from r.pax then
        -- 늘리는 쪽은 총 정원을 본다 — 정원 트리거는 INSERT 에만 걸려 UPDATE 로는 검사가 없다 (리뷰 지적: 조용한 오버셀).
        if r.pax > coalesce(r.seat_pax, 0) and coalesce(v_tp.total_pax, 0) > 0 then
          perform pg_advisory_xact_lock(hashtext('tkcap_' || v_tp_id));
          select coalesce(sum(party_size), 0) into v_others
            from public.tickets
           where ticket_product_id = v_tp_id and coalesce(status,'') <> 'cancelled' and id <> r.seat_id;
          if v_others + r.pax > v_tp.total_pax then
            v_short := v_short || jsonb_build_object('charge_id', r.id, 'label', coalesce(nullif(r.payer_name, ''), r.label),
                                                     'pax', r.pax, 'kind', 'capacity', 'sqlstate', 'P0001',
                                                     'reason', 'RESIZE_OVER_CAPACITY: 잔여 ' || (v_tp.total_pax - v_others) || '석, 요청 '
                                                               || r.pax || '명 — 현재 ' || coalesce(r.seat_pax, 0) || '명 유지');
            v_seats := v_seats + coalesce(r.seat_pax, 0);
            continue;
          end if;
        end if;
        update public.tickets set party_size = r.pax where id = r.seat_id;
        v_resized := v_resized + 1;
      end if;
      v_seats := v_seats + r.pax;
      continue;
    end if;
    v_pid := 'KSK-' || left(r.id::text, 8) || '-' || (extract(epoch from clock_timestamp()) * 1000)::bigint;
    begin
      perform set_config('taam.seat_engine_bypass', '1', true);
      insert into public.tickets (user_id, restaurant_id, restaurant_name, ticket_product_id, ticket_type,
                                  reservation_date, visit_time, party_size, price, status, purchase_id,
                                  buyer_name, buyer_phone, extra_data, created_at)
      -- 🔧 (6차) price 는 0. 정산·링크 결제액은 티켓 금액과 **별개로** kashikiri_charges 가 관리한다 — 좌석 행에 정가를 넣으니
      --   캘린더에 결제액(₩2,321,555)과 다른 숫자(정가 ₩900,000)가 떠서 헷갈렸고, 정산 청구액을 넣으면 매장 어드민에게 샌다.
      --   캘린더는 슈퍼어드민일 때만 정산 청구에서 실제 결제액을 따로 읽어 보여 준다.
      values (v_uid, v_tp.rest_id::text, coalesce(v_tp.rest_name, v_ev.venue_name), v_tp_id, coalesce(v_tp.type_class, ''),
              v_date, v_time, r.pax, 0, 'active', v_pid,
              coalesce(nullif(r.payer_name, ''), r.label, '정산 결제'), coalesce(r.payer_phone, ''),
              jsonb_build_object('kashikiri', true, 'eventId', v_ev.id::text, 'chargeId', r.id::text,
                                 'teamId', r.team_id, 'currency', r.pay_currency,
                                 'createdBy', 'ksk_sync'),
              now());
      perform set_config('taam.seat_engine_bypass', '', true);
      v_made := v_made + 1; v_seats := v_seats + r.pax;
    exception when others then
      perform set_config('taam.seat_engine_bypass', '', true);
      -- 무엇이든 삼키고 적는다. 돈은 이미 받았다 — 여기서 예외를 올리면 결제 확정까지 같이 죽는다.
      v_kind := case when sqlerrm ~ '^(TICKET_SOLD_OUT|SLOT_SOLD_OUT|INVALID_PARTY_SIZE|SOLO_LIMIT|FRAGMENT_BLOCKED)'
                     then 'capacity' else 'error' end;
      v_short := v_short || jsonb_build_object('charge_id', r.id, 'label', coalesce(nullif(r.payer_name, ''), r.label),
                                               'pax', r.pax, 'kind', v_kind, 'sqlstate', sqlstate,
                                               'reason', left(sqlerrm, 160));
    end;
  end loop;

  return json_build_object('ok', true, 'linked', v_tp_id, 'made', v_made, 'cancelled', v_cancelled,
                           'resized', v_resized, 'short', v_short, 'seats', v_seats);
end $$;
revoke all on function public._taam_ksk_seat_sync(uuid) from public;
grant execute on function public._taam_ksk_seat_sync(uuid) to service_role;

-- ── 기존 KSK- 행 정리 ──
update public.tickets set price = 0 where purchase_id like 'KSK-%' and coalesce(price, 0) <> 0;

-- ── 확인 ──
select '① 동기화 5판 (price 0)' as what,
       case when exists (select 1 from pg_proc where oid = to_regproc('public._taam_ksk_seat_sync') and prosrc like '%(6차) price 는 0%') then '✅' else '❌ 옛 판' end as result
union all
select '② KSK- 행 금액 전부 0',
       case when not exists (select 1 from public.tickets where purchase_id like 'KSK-%' and coalesce(price,0) <> 0) then '✅' else '❌ 남음' end;
