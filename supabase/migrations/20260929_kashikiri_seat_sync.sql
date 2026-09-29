-- ============================================================================
-- 20260929_kashikiri_seat_sync.sql — 정산 결제 → 티켓 좌석 연동 (2026-09-29)
-- ============================================================================
-- 배경: 정산 회차에서 「티켓 연결」을 눌러도 회차 행에 ticket_product_id 가 적힐 뿐
--   tickets 에는 아무것도 생기지 않았다. Takiya 3/20 · Trina Chin 이 $1,679.85 를 결제했는데
--   티켓 캘린더에도 안 보이고 잔여석도 4 그대로였다. 링크 초대(LINK-)는 결제되는 순간
--   홀드→active 로 좌석을 잡지만, 정산 링크(link_invite=false)는 그 길이 없었다.
--
-- 규칙 (한 함수 _taam_ksk_seat_sync 가 전부 맞춘다 — 멱등):
--   · 회차에 티켓이 연결돼 있고 청구가 paid 면 → tickets 에 KSK- 행 하나 (active)
--       인원 = 그 청구의 조(kashikiri_teams.pax). 조가 없는 청구(임의 수신자)는 1.
--   · 청구가 cancelled·expired·failed·refunded 로 바뀌면 → 그 행 cancelled (좌석 복구)
--   · 티켓 연결을 끊거나 다른 티켓으로 바꾸면 → 옛 행 cancelled, 새 티켓에 다시 만든다
--   · 조 인원을 고치면 → 행의 party_size 를 따라 고친다
--   · 정원이 모자라면 그 청구만 건너뛰고 short 에 적어 돌려준다. 돈은 이미 받았으므로
--     예외로 전체를 깨지 않는다 — 어드민이 정원을 늘리고 다시 「티켓 연결」을 누르면 된다.
--   · KSK- 행의 user_id 는 회차 작성자다(회원 소유가 아니다). 회원 앱에서 취소되지 않고,
--     정산 화면의 청구 상태만이 이 행의 주인이다. 캘린더 × 는 정산 화면으로 안내만 한다.
--
-- 부르는 곳:
--   ① RPC taam_kashikiri_link_ticket(p_event_id, p_ticket_id)  — 앱 「티켓 연결」 버튼
--   ② trg_ksk_seat_on_charge  — 청구 status 변경 (kashikiri-confirm → mark_paid, 취소·환불)
--   ③ trg_ksk_seat_on_team    — 조 pax 변경
--   ④ trg_ksk_seat_on_event   — 회차 ticket_product_id 직접 변경 (옛 빌드의 update 경로)
--   링크 초대(link_invite=true) 청구는 여기서 건드리지 않는다 — trg_link_invite_on_charge 가 주인.
-- ============================================================================

-- ── 1. 동기화 본체 (내부용 · 권한 검사 없음 · 트리거와 RPC 가 부른다) ──
create or replace function public._taam_ksk_seat_sync(p_event_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_ev    public.kashikiri_events%rowtype;
  v_tp    public.ticket_products%rowtype;
  v_tp_id text;
  r       record;
  v_made int := 0; v_cancelled int := 0; v_resized int := 0; v_seats int := 0;
  v_short jsonb := '[]'::jsonb;
  v_pid text; v_uid uuid; v_date text; v_time text;
begin
  select * into v_ev from public.kashikiri_events where id = p_event_id;
  if not found then return json_build_object('ok', false, 'error', 'EVENT_NOT_FOUND'); end if;
  v_tp_id := nullif(v_ev.ticket_product_id, '');
  if v_tp_id is not null then
    select * into v_tp from public.ticket_products where id::text = v_tp_id;
    if not found then v_tp_id := null; end if;
  end if;

  -- ① 살아 있는 KSK- 행 중 근거가 사라진 것 → cancelled
  --    (연결 해제 · 다른 티켓으로 변경 · 청구가 더 이상 paid 가 아님)
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

  v_uid  := coalesce(v_ev.created_by, auth.uid());
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
      if r.seat_pax is distinct from r.pax then
        update public.tickets set party_size = r.pax where id = r.seat_id;
        v_resized := v_resized + 1;
      end if;
      v_seats := v_seats + r.pax;
      continue;
    end if;
    v_pid := 'KSK-' || left(r.id::text, 8) || '-' || (extract(epoch from clock_timestamp()) * 1000)::bigint;
    begin
      insert into public.tickets (user_id, restaurant_id, restaurant_name, ticket_product_id, ticket_type,
                                  reservation_date, visit_time, party_size, price, status, purchase_id,
                                  buyer_name, buyer_phone, extra_data, created_at)
      values (v_uid, v_tp.rest_id::text, coalesce(v_tp.rest_name, v_ev.venue_name), v_tp_id, coalesce(v_tp.type_class, ''),
              v_date, v_time, r.pax, r.amount_krw, 'active', v_pid,
              coalesce(nullif(r.payer_name, ''), r.label, '정산 결제'), coalesce(r.payer_phone, ''),
              jsonb_build_object('kashikiri', true, 'eventId', v_ev.id::text, 'chargeId', r.id::text,
                                 'teamId', r.team_id, 'currency', r.pay_currency, 'payAmount', r.pay_amount,
                                 'createdBy', 'ksk_sync'),
              now());
      v_made := v_made + 1; v_seats := v_seats + r.pax;
    exception when others then
      if sqlerrm like 'TICKET_SOLD_OUT%' or sqlerrm like 'SLOT_SOLD_OUT%' or sqlerrm like 'INVALID_PARTY_SIZE%' then
        v_short := v_short || jsonb_build_object('charge_id', r.id, 'label', coalesce(nullif(r.payer_name, ''), r.label),
                                                 'pax', r.pax, 'reason', left(sqlerrm, 120));
      else
        raise;
      end if;
    end;
  end loop;

  return json_build_object('ok', true, 'linked', v_tp_id, 'made', v_made, 'cancelled', v_cancelled,
                           'resized', v_resized, 'short', v_short, 'seats', v_seats);
end $$;
revoke all on function public._taam_ksk_seat_sync(uuid) from public;
grant execute on function public._taam_ksk_seat_sync(uuid) to service_role;

-- ── 2. 앱 「티켓 연결」 RPC — 연결(또는 해제)하고 바로 동기화 결과를 돌려준다 ──
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
    v_ok := public._taam_uid_is_super() or exists (
      select 1 from public.admin_grants g where g.user_id = v_uid
         and (g.rest_id::text = v_tp.rest_id::text or g.venue_id::text = v_tp.rest_id::text));
    if not v_ok then raise exception '이 매장의 어드민만 연결할 수 있습니다' using errcode = '42501'; end if;
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

-- ── 3. 트리거 — 청구 상태 · 조 인원 · 회차 연결이 바뀌면 따라간다 ──
create or replace function public.taam_ksk_seat_on_charge()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.link_invite, false) then return new; end if;          -- 링크 초대는 자기 트리거가 있다
  if new.status is distinct from old.status then
    perform public._taam_ksk_seat_sync(new.event_id);
  end if;
  return new;
end $$;
drop trigger if exists trg_ksk_seat_on_charge on public.kashikiri_charges;
create trigger trg_ksk_seat_on_charge after update of status on public.kashikiri_charges
  for each row execute function public.taam_ksk_seat_on_charge();

create or replace function public.taam_ksk_seat_on_team()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.pax is distinct from old.pax then perform public._taam_ksk_seat_sync(new.event_id); end if;
  return new;
end $$;
drop trigger if exists trg_ksk_seat_on_team on public.kashikiri_teams;
create trigger trg_ksk_seat_on_team after update of pax on public.kashikiri_teams
  for each row execute function public.taam_ksk_seat_on_team();

create or replace function public.taam_ksk_seat_on_event()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('taam.ksk_sync_skip', true), '') = '1' then return new; end if;
  if new.ticket_product_id is distinct from old.ticket_product_id then perform public._taam_ksk_seat_sync(new.id); end if;
  return new;
end $$;
drop trigger if exists trg_ksk_seat_on_event on public.kashikiri_events;
create trigger trg_ksk_seat_on_event after update of ticket_product_id on public.kashikiri_events
  for each row execute function public.taam_ksk_seat_on_event();

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 ──
select '① 동기화 함수' as what,
       case when to_regprocedure('public._taam_ksk_seat_sync(uuid)') is not null then '✅' else '❌ 없음' end as result
union all
select '② 연결 RPC',
       case when to_regprocedure('public.taam_kashikiri_link_ticket(uuid,text)') is not null then '✅' else '❌ 없음' end
union all
select '③ 청구 트리거',
       case when exists (select 1 from pg_trigger where tgname = 'trg_ksk_seat_on_charge') then '✅' else '❌ 없음' end
union all
select '④ 조 트리거',
       case when exists (select 1 from pg_trigger where tgname = 'trg_ksk_seat_on_team') then '✅' else '❌ 없음' end
union all
select '⑤ 회차 트리거',
       case when exists (select 1 from pg_trigger where tgname = 'trg_ksk_seat_on_event') then '✅' else '❌ 없음' end;
