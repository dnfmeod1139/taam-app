-- ============================================================================
-- 20260929_kashikiri_seat_sync4.sql — 좌석 연동 4차: 리뷰 지적 반영 + 리마인드 제외 (2026-09-29 밤)
-- ============================================================================
-- 2차·3차를 라이브에 넣은 뒤, 5갈래 적대 리뷰가 잡은 것들:
--   A. 회차 행을 읽고 나서 잠갔다 → 동시에 돈 연결/해제 RPC 의 새 ticket_product_id 를 못 보고 새 좌석을 접을 수 있었다.
--      잠근 뒤 읽는다. 조 인원을 **늘릴** 때 정원 검사가 없었다(정원 트리거는 INSERT 만) → 총 정원을 세서 넘치면 short.
--   B. 트리거 경로에서 자리를 못 잡은 청구(short)가 아무 흔적 없이 버려졌다 → raise warning.
--   C. 티어 가드의 KSK-·LINK- 면제가 접두어만 봤다 → 회원이 자기 홀드에 'KSK-…' 라고 적으면 등급 검사를 피한다.
--      **증명**(동기화 트랜잭션 플래그 또는 실제 정산 청구)이 있을 때만 면제한다.
--   D. 같은 구멍의 뿌리: INSERT 가드가 회원 홀드의 purchase_id 를 안 봤다 → 회원 홀드는 PAYH- 로만.
--      (옛 MAN-·INV-·INVH- 접두어 면제도 같은 방식으로 흉내 낼 수 있었다 — 이제 막힌다.)
--   E. 매장 어드민은 RLS 로 슈퍼어드민 소유 KSK- 행을 못 봐 정산 카드에 「좌석 0석」이 거짓으로 떴다 → definer RPC.
--   F. 방문 리마인드가 KSK-·LINK-·MAN- 행의 user_id(=어드민)에게 「내일 방문 예정입니다」를 남의 자리로 보낼 참이었다 → 제외.
--      notif_prefs 값이 boolean 이 아니면 ::boolean 캐스트가 그날 리마인드 전체를 죽였다 → jsonb_typeof 로 안전하게.
-- C·D·F 는 저장소 원본(sql/general_open_to_guest.sql · sql/audit_hardening_2026-09-13.sql · sql/visit_reminder.sql)에도
-- 같은 줄을 넣었다 — 원본을 다시 돌려도 이 규칙이 사라지지 않게.
-- ============================================================================

-- ── A. 동기화 본체 3판 ──
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
      values (v_uid, v_tp.rest_id::text, coalesce(v_tp.rest_name, v_ev.venue_name), v_tp_id, coalesce(v_tp.type_class, ''),
              v_date, v_time, r.pax, r.amount_krw, 'active', v_pid,
              coalesce(nullif(r.payer_name, ''), r.label, '정산 결제'), coalesce(r.payer_phone, ''),
              jsonb_build_object('kashikiri', true, 'eventId', v_ev.id::text, 'chargeId', r.id::text,
                                 'teamId', r.team_id, 'currency', r.pay_currency, 'payAmount', r.pay_amount,
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

-- ── B. 트리거 ──
-- 트리거 3종 — 동기화가 무슨 예외를 내든 삼킨다. 자리를 못 잡은 청구(short)는 로그(warning)로 남긴다 (리뷰 지적: 조용히 버려졌다).
create or replace function public.taam_ksk_seat_on_charge()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_res json;
begin
  if coalesce(new.link_invite, false) then return new; end if;
  if new.status is distinct from old.status then
    begin
      v_res := public._taam_ksk_seat_sync(new.event_id);
      if jsonb_array_length(coalesce((v_res->'short')::jsonb, '[]'::jsonb)) > 0 then
        raise warning '[ksk_seat] charge % 좌석 못 잡음(결제 기록은 유지): %', new.id, v_res->'short';
      end if;
    exception when others then
      raise warning '[ksk_seat] charge % 동기화 실패 (결제 기록은 유지): % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;

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
    exception when others then
      raise warning '[ksk_seat] team % 동기화 실패: % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;

create or replace function public.taam_ksk_seat_on_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_res json;
begin
  if coalesce(current_setting('taam.ksk_sync_skip', true), '') = '1' then return new; end if;
  if new.ticket_product_id is distinct from old.ticket_product_id then
    begin
      v_res := public._taam_ksk_seat_sync(new.id);
      if jsonb_array_length(coalesce((v_res->'short')::jsonb, '[]'::jsonb)) > 0 then
        raise warning '[ksk_seat] event % 좌석 못 잡음: %', new.id, v_res->'short';
      end if;
    exception when others then
      raise warning '[ksk_seat] event % 동기화 실패: % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;

-- ── C. 티어 가드 — 면제는 증명 있을 때만 ──
create or replace function public.taam_guard_ticket_tier()
returns trigger
language plpgsql security definer set search_path = public
as $tier$
declare
  v_need text; v_mine text;
  tp public.ticket_products%rowtype;
  v_allowed boolean; v_sold int;
  v_pax int; v_should int;
begin
  if new.ticket_product_id is null or btrim(new.ticket_product_id::text) = '' then
    return new;
  end if;
  if coalesce(new.purchase_id, '') like 'MAN-%'  then return new; end if;
  if coalesce(new.purchase_id, '') like 'INV-%'  then return new; end if;
  if coalesce(new.purchase_id, '') like 'INVH-%' then return new; end if;
  -- 🆕 2026-09-29 어드민이 만든 좌석 — 정산 결제(KSK-)·링크 초대(LINK-). 회원 등급이 아니라 어드민의 결정이다.
  --   KSK- 는 Edge(service_role) 경로에서 auth.uid() 없이 들어오므로 아래 슈퍼어드민 면제로는 못 걸러진다.
  --   ⚠ 접두어만 보고 면제하면 회원이 자기 홀드에 'KSK-…' 라고 적어 등급 검사를 피한다 (리뷰 지적).
  --     그래서 **증명**이 있을 때만 면제한다: ① _taam_ksk_seat_sync 가 세운 트랜잭션 플래그, 또는
  --     ② extra_data.chargeId 가 가리키는 정산 청구가 실제로 있다 (회원은 kashikiri_charges 를 못 만든다).
  --     증명이 없으면 회원 구매와 똑같이 아래 검사를 받는다.
  if coalesce(new.purchase_id, '') like 'KSK-%' or coalesce(new.purchase_id, '') like 'LINK-%' then
    if coalesce(current_setting('taam.seat_engine_bypass', true), '') = '1'
       or exists (select 1 from public.kashikiri_charges c
                   where c.id::text = coalesce(new.extra_data->>'chargeId', '')
                     and ((new.purchase_id like 'LINK-%' and coalesce(c.link_invite, false))
                       or (new.purchase_id like 'KSK-%' and not coalesce(c.link_invite, false) and c.status = 'paid'))) then
      return new;
    end if;
  end if;
  if coalesce(new.status, '') in ('cancelled','canceled') then return new; end if;

  -- 슈퍼어드민만 면제. 운영·검수에서 모든 티켓을 열어봐야 한다.
  if public._taam_uid_is_super() then return new; end if;

  select * into tp from public.ticket_products where id::text = new.ticket_product_id::text;
  v_need := upper(coalesce(btrim(tp.min_tier), ''));
  v_mine := public.taam_user_tier(new.user_id);

  -- ── 게스트(A) ────────────────────────────────────────────
  if upper(coalesce(v_mine, '')) = 'A' then

    -- ① 🆕 「일반공개」로 지정한 회차 — 회원과 완전히 같다.
    --    금액도 상태도 손대지 않는다. 확정 대기로 돌리지 않는다.
    --    ⚠ 반드시 게스트석 분기보다 **먼저** 본다.
    if public.taam_tier_is_open(v_need) then
      return new;
    end if;

    -- ② 게스트 초대석 (입구는 닫혔지만 규칙은 살아 있다)
    if tp.id is null or not coalesce(tp.guest_open, false) then
      raise exception 'GUEST_BLOCKED: 이 자리는 멤버십 회원만 예약할 수 있습니다'
        using errcode = '42501';
    end if;
    if coalesce(btrim(tp.guest_open_reason), '') = '' then
      raise exception 'GUEST_BLOCKED: 게스트석 안내가 준비되지 않았습니다'
        using errcode = '42501';
    end if;
    select coalesce(r.guest_seat_allowed, false) into v_allowed
      from public.restaurants r where r.id::text = tp.rest_id::text;
    if not coalesce(v_allowed, false) then
      raise exception 'GUEST_BLOCKED: 이 매장은 게스트석을 열지 않습니다'
        using errcode = '42501';
    end if;
    select count(*) into v_sold
      from public.tickets t
      join public.profiles p on p.id = t.user_id
     where t.ticket_product_id::text = new.ticket_product_id::text
       and coalesce(t.status,'') not in ('cancelled','canceled')
       and upper(coalesce(p.membership_tier,'')) = 'A';
    if coalesce(v_sold,0) >= coalesce(tp.guest_seat_qty, 0) then
      raise exception 'GUEST_BLOCKED: 게스트석이 모두 나갔습니다 (%/%)',
        v_sold, coalesce(tp.guest_seat_qty,0) using errcode = '42501';
    end if;

    -- 금액은 서버가 정한다. 앱이 보낸 price 를 믿지 않는다.
    --   ⚠ guest_price 는 1인당. tickets.price 는 총액이다 — 그래서 곱한다.
    v_pax := greatest(1, coalesce(new.party_size, 1));
    v_should := coalesce(tp.guest_price, 0) * v_pax;
    if v_should > 0 then
      if coalesce(new.price, 0) <> v_should then
        new.extra_data := coalesce(new.extra_data, '{}'::jsonb)
          || jsonb_build_object(
               'guest_price_fixed', true,
               'guest_price_app',    coalesce(new.price, 0),
               'guest_price_server', v_should,
               'guest_price_per',    tp.guest_price);
      end if;
      new.price := v_should;
    end if;

    new.status := 'pending_confirm';
    return new;
  end if;

  -- ── 회원 (기존 규칙 그대로) ──────────────────────────────
  if v_need is null or public.taam_tier_rank(v_need) = 0 then
    return new;
  end if;

  -- ⚠ 「일반공개(min_tier=A)」는 하한이 아니라 개방이다. 게스트가 아닌
  --   사람에게는 그대로 열려 있어야 한다. 이 줄을 빼면 등급이 아예 없는
  --   옛 회원이 튕긴다 — 열어 놓고 못 사게 되는 정반대의 결과다.
  if public.taam_tier_is_open(v_need) then
    return new;
  end if;
  if public.taam_tier_rank(v_mine) >= public.taam_tier_rank(v_need) then
    return new;
  end if;

  raise exception
    'TIER_BLOCKED: 이 티켓은 % 등급 이상만 구매할 수 있습니다 (회원 등급 %)',
    v_need, coalesce(v_mine, '없음')
    using errcode = '42501';
end;
$tier$;

-- ── D. INSERT 가드 — 회원 홀드는 PAYH- 만 ──
create or replace function public.taam_guard_ticket_insert()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_role text;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public._taam_uid_is_super() then
    return new;
  end if;

  if new.user_id is distinct from auth.uid() then
    raise exception '남의 이름으로 예약을 넣을 수 없습니다' using errcode = '42501';
  end if;

  v_role := public._taam_uid_role();
  if new.status = 'hold' then
    -- 🆕 2026-09-29 회원의 홀드는 PAYH- 뿐이다. 다른 접두어(MAN-·INV-·INVH-·KSK-·LINK-)는 서버·어드민 몫이라
    --   회원이 흉내 내면 등급 가드 면제를 타거나(접두어 면제) 5분 스윕에 안 잡히는 영구 홀드가 된다.
    if v_role <> 'admin' and coalesce(new.purchase_id, '') not like 'PAYH-%' then
      raise exception 'HOLD_PREFIX: 회원 좌석 홀드는 PAYH- 로만 만들 수 있습니다' using errcode = '42501';
    end if;
    return new;                               -- 좌석 홀드(5분) — 확정은 서버가 한다
  end if;

  if new.status = 'manual' and v_role = 'admin' then
    return new;                               -- 매장 어드민의 수동 연동 행(MAN-)
  end if;

  raise exception '예약은 서버가 확정합니다 — 직접 넣을 수 없는 상태: %', coalesce(new.status, '(없음)')
    using errcode = '42501';
end;
$$;

-- ── E. 정산 카드용 좌석 조회 ──
-- 정산 카드가 「좌석 N석 연동」을 읽는 창구. 매장 어드민은 RLS 로 슈퍼어드민 소유 KSK- 행을 못 봐서
--   「좌석 0석」이 거짓으로 떴다 (리뷰 지적). definer 로 세되, 회차 매장의 어드민·슈퍼어드민만.
create or replace function public.taam_ksk_seat_rows(p_event_id uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_ev public.kashikiri_events%rowtype;
begin
  if v_uid is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  select * into v_ev from public.kashikiri_events where id = p_event_id;
  if not found then return '[]'::json; end if;
  if not (public._taam_uid_is_super() or exists (
        select 1 from public.admin_grants g where g.user_id = v_uid
           and (g.rest_id::text = v_ev.venue_id or g.venue_id::text = v_ev.venue_id))) then
    raise exception '이 매장의 어드민만 볼 수 있습니다' using errcode = '42501';
  end if;
  return coalesce((select json_agg(json_build_object('id', t.id, 'party_size', t.party_size, 'status', t.status,
                                                     'buyer_name', t.buyer_name, 'purchase_id', t.purchase_id,
                                                     'charge_id', t.extra_data->>'chargeId') order by t.created_at)
                     from public.tickets t
                    where t.purchase_id like 'KSK-%' and t.extra_data->>'eventId' = p_event_id::text
                      and coalesce(t.status,'') <> 'cancelled'), '[]'::json);
end $$;
revoke all on function public.taam_ksk_seat_rows(uuid) from public;
grant execute on function public.taam_ksk_seat_rows(uuid) to authenticated, service_role;

-- ── F. 방문 리마인드 — 어드민이 잡은 좌석 제외 · 안전 캐스트 ──
create or replace function public.taam_visit_reminder_notify()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_cnt int := 0; v_rows jsonb;
begin
  with due as (
    select t.id            as ticket_id,
           t.user_id,
           coalesce(nullif(btrim(t.restaurant_name), ''), '예약하신 매장') as rest_nm,
           coalesce(nullif(btrim(t.visit_time), ''), '')                   as vtime,
           public.taam_visit_days_left(t.reservation_date)                 as d
      from public.tickets t
     where t.user_id is not null
       -- 확정된 예약만. 'hold'(좌석 잡아둔 미결제)·'cancelled'·'expired' 는 제외한다.
       and lower(coalesce(t.status,'')) = 'active'
       -- 🆕 2026-09-29 어드민이 잡은 좌석은 회원의 예약이 아니다 — 정산 결제(KSK-)·링크 초대(LINK-)·수동(MAN-) 행의
       --   user_id 는 회차 작성자·어드민이라, 두면 어드민이 「내일 방문 예정입니다」를 남의 자리로 받는다.
       and coalesce(t.purchase_id, '') not like 'KSK-%'
       and coalesce(t.purchase_id, '') not like 'LINK-%'
       and coalesce(t.purchase_id, '') not like 'MAN-%'
       and not coalesce((t.extra_data ? 'kashikiri') or (t.extra_data ? 'linkInvite') or (t.extra_data ? 'manualEntry'), false)
  ), pick as (
    select * from due where d in (1, 3, 7)
  ), want as (
    -- 회원이 켜 둔 것만. 설정을 안 만졌으면 3일·1일만 보낸다(7일은 기본 꺼짐).
    select k.*
      from pick k
      join public.profiles p on p.id = k.user_id
     -- 🆕 2026-09-29 boolean 이 아닌 값이 하나라도 있으면 ::boolean 캐스트가 함수 전체를 죽여 그날 아무도 못 받았다.
     --   boolean 일 때만 읽고, 아니면 기본값(3일·1일 켜짐)으로 본다.
     where coalesce(
             case when jsonb_typeof(p.notif_prefs -> ('remind' || k.d::text)) = 'boolean'
                  then (p.notif_prefs ->> ('remind' || k.d::text))::boolean else null end,
             k.d in (1, 3)
           ) is true
  ), ins as (
    insert into public.notifications (user_id, type, title, body, url, payload)
    select w.user_id,
           'visit_reminder',
           case when w.d = 1 then '내일 방문 예정입니다'
                when w.d = 3 then '3일 뒤 방문 예정입니다'
                else '방문 ' || w.d || '일 전입니다' end,
           w.rest_nm
             || case when w.vtime <> '' then ' · ' || w.vtime else '' end
             || case when w.d = 1 then ' 예약이 내일입니다.'
                     else ' 예약이 ' || w.d || '일 남았습니다.' end,
           '/',
           -- rest·time 도 실어 둔다 — Edge Function 이 이걸로 EN·JA 문구를 만든다.
           --   (send-push 는 payload.i18n 을 받으면 기기 언어로 골라 보낸다)
           jsonb_build_object('ticket_id', w.ticket_id, 'days', w.d,
                              'kind', 'visit_reminder',
                              'rest', w.rest_nm, 'time', w.vtime)
      from want w
     -- 같은 티켓·같은 일수로는 한 번만. 하루가 지나면 일수가 달라져 다시 나간다.
     where not exists (
       select 1 from public.notifications n
        where n.user_id = w.user_id
          and n.type = 'visit_reminder'
          and n.payload ->> 'ticket_id' = w.ticket_id::text
          and (n.payload ->> 'days')::int = w.d)
    -- ⚠ 이번 실행이 **실제로 넣은 행만** 돌려받는다.
    --   예전에는 여기서 1 만 돌려받고, 푸시 대상은 따로
    --   「created_at > now() - 2분」으로 다시 긁었다. 그러면 이번 실행이
    --   만든 것인지 구분하지 못해, 2분 안에 두 번 부르면 앞 실행이 만든
    --   알림을 다시 집어 **같은 회원에게 푸시가 두 번** 나갔다.
    --   (made:0 인데 push_sent:1 로 실제로 관측됨)
    returning id, user_id, title, body, url, payload
  )
  select count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object(
           'id',        i.id,
           'user_id',   i.user_id,
           'title',     i.title,
           'body',      i.body,
           'url',       i.url,
           'days',      (i.payload ->> 'days')::int,
           'ticket_id', i.payload ->> 'ticket_id',
           'rest',      i.payload ->> 'rest',
           'vtime',     i.payload ->> 'time'
         )), '[]'::jsonb)
    into v_cnt, v_rows
    from ins i;

  return jsonb_build_object('made', v_cnt, 'rows', v_rows);
end;
$$;
revoke all on function public.taam_visit_reminder_notify() from public, anon, authenticated;
grant execute on function public.taam_visit_reminder_notify() to service_role;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 ──
select '① 동기화 3판 (잠금→읽기 · 인원 늘림 정원 검사)' as what,
       case when exists (select 1 from pg_proc where oid = to_regproc('public._taam_ksk_seat_sync') and prosrc like '%RESIZE_OVER_CAPACITY%') then '✅' else '❌ 옛 판' end as result
union all
select '② 트리거가 short 를 warning 으로 남긴다',
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_ksk_seat_on_charge') and prosrc like '%좌석 못 잡음%') then '✅' else '❌ 옛 판' end
union all
select '③ 티어 가드 KSK-·LINK- 면제는 증명 있을 때만',
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_guard_ticket_tier') and prosrc like '%kashikiri_charges%') then '✅' else '❌ 옛 판' end
union all
select '④ INSERT 가드 회원 홀드 PAYH- 만',
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_guard_ticket_insert') and prosrc like '%HOLD_PREFIX%') then '✅' else '❌ 옛 판' end
union all
select '⑤ 좌석 조회 RPC',
       case when to_regprocedure('public.taam_ksk_seat_rows(uuid)') is not null then '✅' else '❌ 없음' end
union all
select '⑥ 리마인드가 KSK-·LINK-·MAN- 을 뺀다 · 안전 캐스트',
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_visit_reminder_notify') and prosrc like '%jsonb_typeof%' and prosrc like '%KSK-%') then '✅' else '❌ 옛 판' end;
