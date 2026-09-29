-- ============================================================================
-- 20260929_kashikiri_seat_sync5.sql — 좌석 연동 5차: 적대 리뷰 최종 지적 반영 (2026-09-29 밤)
-- ============================================================================
-- 5갈래 리뷰 33개 에이전트의 검증이 끝났다. 4차에 이미 들어간 것(잠금 순서·인원 늘림 정원·short warning·접두어 위조)을
-- 빼고 남은 확인된 지적:
--   A. 연결 RPC 가 **티켓 매장** 권한만 봤다 → 다른 매장의 정산 회차를 내 티켓에 붙여 남의 결제로 좌석을 만들 수 있었다.
--      슈퍼어드민이 아니면 회차 매장·티켓 매장 둘 다 권한이 있어야 한다.
--   B. KSK- 행의 price 에 **정산 청구액**(인솔비 등 포함)이 들어갔다. tickets 는 매장 어드민이 자기 매장 행을 읽을 수 있어
--      정산 금액이 새는 길이다 → 티켓 정가×인원으로. extra_data.payAmount 도 뺀다. 이미 만든 행도 고친다.
--   C. (낮음) 회차 날짜·시간을 고쳐도 좌석 행은 만든 시점 값 그대로였다 → 트리거를 event_date·event_time 에도 걸고 갱신.
--      청구·회차를 **지우면** 좌석이 남았다 → delete 트리거. when others 가 QUERY_CANCELED 를 안 잡는다 → 같이 잡는다.
-- ============================================================================

-- ── A. 연결 RPC ──
create or replace function public.taam_kashikiri_link_ticket(p_event_id uuid, p_ticket_id text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_ev  public.kashikiri_events%rowtype;
  v_tp  public.ticket_products%rowtype;
  v_ok  boolean := false;
begin
  if v_uid is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  select * into v_ev from public.kashikiri_events where id = p_event_id;
  if not found then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;

  if nullif(p_ticket_id, '') is not null then
    select * into v_tp from public.ticket_products where id::text = p_ticket_id;
    if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
    -- 🔧 2026-09-29 (5차) 티켓 매장 권한만 보면 다른 매장의 정산 회차를 내 티켓에 붙여 남의 결제로 좌석을 만들 수 있었다 (리뷰 지적).
    --   슈퍼어드민이 아니면 **회차 매장과 티켓 매장 둘 다** 권한이 있어야 한다.
    v_ok := public._taam_uid_is_super() or (
      exists (select 1 from public.admin_grants g where g.user_id = v_uid
                 and (g.rest_id::text = v_tp.rest_id::text or g.venue_id::text = v_tp.rest_id::text))
      and exists (select 1 from public.admin_grants g where g.user_id = v_uid
                 and (g.rest_id::text = v_ev.venue_id or g.venue_id::text = v_ev.venue_id)));
    if not v_ok then raise exception '이 매장의 어드민만 연결할 수 있습니다 (회차·티켓 둘 다)' using errcode = '42501'; end if;
    -- 회차 트리거(④)가 또 돌면 RPC 의 결과가 「이미 다 됐음(made 0)」으로 가려진다 → 이 트랜잭션에서는 건너뛴다
    perform set_config('taam.ksk_sync_skip', '1', true);
    update public.kashikiri_events
       set ticket_product_id = p_ticket_id, venue_id = v_tp.rest_id::text
     where id = p_event_id;
  else
    v_ok := public._taam_uid_is_super() or exists (
      select 1 from public.admin_grants g where g.user_id = v_uid
         and (g.rest_id::text = v_ev.venue_id or g.venue_id::text = v_ev.venue_id));
    if not v_ok then raise exception '이 매장의 어드민만 해제할 수 있습니다' using errcode = '42501'; end if;
    perform set_config('taam.ksk_sync_skip', '1', true);
    update public.kashikiri_events set ticket_product_id = null where id = p_event_id;
  end if;
  perform set_config('taam.ksk_sync_skip', '', true);
  return public._taam_ksk_seat_sync(p_event_id);
end $$;
revoke all on function public.taam_kashikiri_link_ticket(uuid, text) from public;
grant execute on function public.taam_kashikiri_link_ticket(uuid, text) to authenticated, service_role;

-- ── B. 동기화 4판 ──
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
      -- 🔧 (5차) price 는 정산 청구액이 아니라 티켓 정가×인원. 정산 금액(인솔비 등 포함)은 매장 어드민이 볼 수 없어야 하는데
      --   tickets 는 매장 어드민이 자기 매장 행을 읽는다 (리뷰 지적). payAmount 도 싣지 않는다.
      values (v_uid, v_tp.rest_id::text, coalesce(v_tp.rest_name, v_ev.venue_name), v_tp_id, coalesce(v_tp.type_class, ''),
              v_date, v_time, r.pax, coalesce(public.taam_ticket_price_krw(v_tp_id, r.pax), 0), 'active', v_pid,
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

-- ── C. 트리거 ──
-- 트리거 — (5차) query_canceled 도 삼킨다(when others 는 QUERY_CANCELED 를 안 잡는다) · 회차 날짜·시간 변경도 따라간다 · 삭제도 따라간다
create or replace function public.taam_ksk_seat_on_charge()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_res json;
begin
  if tg_op = 'DELETE' then
    if not coalesce(old.link_invite, false) then
      begin perform public._taam_ksk_seat_sync(old.event_id);
      exception when query_canceled or others then raise warning '[ksk_seat] charge % 삭제 동기화 실패: % %', old.id, sqlstate, sqlerrm; end;
    end if;
    return old;
  end if;
  if coalesce(new.link_invite, false) then return new; end if;
  if new.status is distinct from old.status then
    begin
      v_res := public._taam_ksk_seat_sync(new.event_id);
      if jsonb_array_length(coalesce((v_res->'short')::jsonb, '[]'::jsonb)) > 0 then
        raise warning '[ksk_seat] charge % 좌석 못 잡음(결제 기록은 유지): %', new.id, v_res->'short';
      end if;
    exception when query_canceled or others then
      raise warning '[ksk_seat] charge % 동기화 실패 (결제 기록은 유지): % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;
drop trigger if exists trg_ksk_seat_on_charge on public.kashikiri_charges;
create trigger trg_ksk_seat_on_charge after update of status on public.kashikiri_charges
  for each row execute function public.taam_ksk_seat_on_charge();
drop trigger if exists trg_ksk_seat_on_charge_del on public.kashikiri_charges;
create trigger trg_ksk_seat_on_charge_del after delete on public.kashikiri_charges
  for each row execute function public.taam_ksk_seat_on_charge();

create or replace function public.taam_ksk_seat_on_team()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_res json;
begin
  if new.pax is distinct from old.pax then
    begin
      v_res := public._taam_ksk_seat_sync(new.event_id);
      if jsonb_array_length(coalesce((v_res->'short')::jsonb, '[]'::jsonb)) > 0 then
        raise warning '[ksk_seat] team % 좌석 못 맞춤: %', new.id, v_res->'short';
      end if;
    exception when query_canceled or others then
      raise warning '[ksk_seat] team % 동기화 실패: % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;

create or replace function public.taam_ksk_seat_on_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_res json;
begin
  if tg_op = 'DELETE' then
    -- 회차가 지워지면 그 좌석은 근거가 없다 (청구는 cascade 로 같이 지워진다)
    begin
      update public.tickets set status = 'cancelled',
             extra_data = coalesce(extra_data,'{}'::jsonb) || jsonb_build_object('cancelledBy','ksk_event_deleted','cancelledAt',now())
       where purchase_id like 'KSK-%' and extra_data->>'eventId' = old.id::text and coalesce(status,'') <> 'cancelled';
    exception when query_canceled or others then raise warning '[ksk_seat] event % 삭제 정리 실패: % %', old.id, sqlstate, sqlerrm; end;
    return old;
  end if;
  if coalesce(current_setting('taam.ksk_sync_skip', true), '') = '1' then return new; end if;
  if new.ticket_product_id is distinct from old.ticket_product_id
     or new.event_date is distinct from old.event_date or new.event_time is distinct from old.event_time then
    begin
      v_res := public._taam_ksk_seat_sync(new.id);
      if jsonb_array_length(coalesce((v_res->'short')::jsonb, '[]'::jsonb)) > 0 then
        raise warning '[ksk_seat] event % 좌석 못 잡음: %', new.id, v_res->'short';
      end if;
    exception when query_canceled or others then
      raise warning '[ksk_seat] event % 동기화 실패: % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;
drop trigger if exists trg_ksk_seat_on_event on public.kashikiri_events;
create trigger trg_ksk_seat_on_event after update of ticket_product_id, event_date, event_time on public.kashikiri_events
  for each row execute function public.taam_ksk_seat_on_event();
drop trigger if exists trg_ksk_seat_on_event_del on public.kashikiri_events;
create trigger trg_ksk_seat_on_event_del before delete on public.kashikiri_events
  for each row execute function public.taam_ksk_seat_on_event();

-- ── D. 이미 만들어진 KSK- 행 정리 — 정산 청구액이 price 에 들어가 있던 것을 정가로, payAmount 제거 ──
update public.tickets t
   set price = coalesce(public.taam_ticket_price_krw(t.ticket_product_id, t.party_size), 0),
       extra_data = coalesce(t.extra_data, '{}'::jsonb) - 'payAmount'
 where t.purchase_id like 'KSK-%'
   and (t.extra_data ? 'payAmount' or t.price is distinct from coalesce(public.taam_ticket_price_krw(t.ticket_product_id, t.party_size), 0));

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 ──
select '① 연결 RPC: 회차·티켓 둘 다 권한' as what,
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_kashikiri_link_ticket') and prosrc like '%회차·티켓 둘 다%') then '✅' else '❌ 옛 판' end as result
union all
select '② 동기화 4판: 정가·날짜 갱신',
       case when exists (select 1 from pg_proc where oid = to_regproc('public._taam_ksk_seat_sync') and prosrc like '%taam_ticket_price_krw%' and prosrc like '%reservation_date = v_date%') then '✅' else '❌ 옛 판' end
union all
select '③ 삭제 트리거 2종',
       case when (select count(*) from pg_trigger where tgname in ('trg_ksk_seat_on_charge_del','trg_ksk_seat_on_event_del')) = 2 then '✅' else '❌' end
union all
select '④ KSK- 행에 정산 금액 흔적 없음',
       case when not exists (select 1 from public.tickets where purchase_id like 'KSK-%' and extra_data ? 'payAmount') then '✅' else '❌ 남음' end;
