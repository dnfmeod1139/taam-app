-- ============================================================================
-- 20260929_kashikiri_seat_sync2.sql — 정산 좌석 연동 2차 (2026-09-29 밤)
-- ============================================================================
-- 1차(20260929_kashikiri_seat_sync.sql)를 라이브에 넣고 Takiya 를 맞추다 막혔다:
--   ERROR P0001: SOLO_LIMIT: 1인 구매 한도 소진   (enforce_ticket_capacity)
-- 1차는 매진·슬롯·인원 셋만 short 로 흡수하고 나머지는 예외로 올렸다. 그래서
--   ① 1인 한도·조각 차단은 예외가 됐고
--   ② 그 예외가 **청구 status 갱신(trg_ksk_seat_on_charge) 안에서** 나면 mark_paid 가 통째로 실패한다
--      — 토스는 승인됐는데 우리 기록은 pending 인 채 결제 페이지가 실패로 뜨는 최악의 모양.
--   ③ 티어 가드(trg_taam_guard_ticket_tier)는 auth.uid() 만 보므로, Edge(service_role) 경로에서
--      들어오는 KSK- 행은 M·T 전용 티켓에서 TIER_BLOCKED 로 막힌다.
--
-- 고친 것
--   A. _taam_ksk_seat_sync — insert 실패는 **무엇이든** short 로 적는다(kind: capacity | error).
--      user_id 는 회차 작성자 → 호출자 → 슈퍼어드민 순으로 채운다(Edge 경로엔 auth.uid() 가 없다).
--      insert 동안 taam.seat_engine_bypass=1 을 세워 총 정원만 보게 한다.
--   B. 트리거 3종 — 동기화가 무슨 예외를 내든 **삼킨다(raise warning)**. 결제 확정을 좌석이 막지 않는다.
--   C. 티어 가드 — KSK-·LINK- 면제 (MAN-·INV- 와 같은 자리).  ⚠ 라이브 함수 교체
--   D. 정원 트리거 — KSK- + bypass 플래그면 총 정원(①)만 검사.   ⚠ 라이브 함수 교체
--
--   C·D 는 저장소의 원본(sql/general_open_to_guest.sql · sql/ticket_capacity_guard.sql)에 줄을 더한 것이다.
--   라이브 본문의 md5 가 저장소 원본과 **같을 때만** 바꾸고, 다르면 건너뛰고 확인 표에 ❌ 로 알린다
--   (대시보드에서 손본 판을 모르고 덮어쓰지 않기 위해). 그때는 pg_get_functiondef 결과를 보내 달라.
-- ============================================================================

-- ── A. 동기화 본체 ──
create or replace function public._taam_ksk_seat_sync(p_event_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_ev    public.kashikiri_events%rowtype;
  v_tp    public.ticket_products%rowtype;
  v_tp_id text;
  r       record;
  v_made int := 0; v_cancelled int := 0; v_resized int := 0; v_seats int := 0;
  v_short jsonb := '[]'::jsonb;
  v_pid text; v_uid uuid; v_date text; v_time text; v_kind text;
begin
  select * into v_ev from public.kashikiri_events where id = p_event_id;
  if not found then return json_build_object('ok', false, 'error', 'EVENT_NOT_FOUND'); end if;
  -- 같은 회차의 동기화는 한 번에 하나만 — 「티켓 연결」 두 번 클릭과 결제 확정이 겹치면 같은 청구에 좌석이 둘 생긴다.
  --   잠금 순서는 언제나 회차 → 티켓(정원 트리거의 tkcap_ 락). 반대 순서로 잡는 곳이 없어 교착이 없다.
  perform pg_advisory_xact_lock(hashtext('ksk_sync_' || v_ev.id::text));
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

-- ── B. 트리거 3종 — 좌석 동기화는 결제·조·회차 갱신을 절대 실패시키지 않는다 ──
create or replace function public.taam_ksk_seat_on_charge()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.link_invite, false) then return new; end if;
  if new.status is distinct from old.status then
    begin
      perform public._taam_ksk_seat_sync(new.event_id);
    exception when others then
      raise warning '[ksk_seat] charge % 동기화 실패 (결제 기록은 유지): % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;

create or replace function public.taam_ksk_seat_on_team()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.pax is distinct from old.pax then
    begin
      perform public._taam_ksk_seat_sync(new.event_id);
    exception when others then
      raise warning '[ksk_seat] team % 동기화 실패: % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;

create or replace function public.taam_ksk_seat_on_event()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('taam.ksk_sync_skip', true), '') = '1' then return new; end if;
  if new.ticket_product_id is distinct from old.ticket_product_id then
    begin
      perform public._taam_ksk_seat_sync(new.id);
    exception when others then
      raise warning '[ksk_seat] event % 동기화 실패: % %', new.id, sqlstate, sqlerrm;
    end;
  end if;
  return new;
end $$;

-- ── C. 티어 가드 — KSK-·LINK- 면제 (라이브 본문이 저장소 원본과 같을 때만) ──
do $do$
declare v_live text;
begin
  select md5(p.prosrc) into v_live from pg_proc p where p.oid = to_regproc('public.taam_guard_ticket_tier');
  if v_live = '3003d144d67fced91e919bb6f2c529bd' then
    execute $fn$
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
  if coalesce(new.purchase_id, '') like 'KSK-%'  then return new; end if;
  if coalesce(new.purchase_id, '') like 'LINK-%' then return new; end if;
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
    $fn$;
    raise notice '✅ 티어 가드 교체 (KSK-·LINK- 면제)';
  elsif exists (select 1 from pg_proc p where p.oid = to_regproc('public.taam_guard_ticket_tier') and p.prosrc like '%KSK-%') then
    raise notice '· 티어 가드는 이미 KSK- 를 안다 — 건너뜀';
  else
    raise warning '❌ 티어 가드 라이브 본문이 저장소 원본(sql/general_open_to_guest.sql)과 다르다 — 건너뜀 (md5 %)', v_live;
  end if;
end $do$;

-- ── D. 정원 트리거 — KSK- 는 총 정원만 (라이브 본문이 저장소 원본과 같을 때만) ──
do $do$
declare v_live text;
begin
  select md5(p.prosrc) into v_live from pg_proc p where p.oid = to_regproc('public.enforce_ticket_capacity');
  if v_live = '29933de04b75bb4d8d1e51d8a751f3c5' then
    execute $fn$
create or replace function public.enforce_ticket_capacity()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_cap       integer;
  v_slots     jsonb;
  v_slot_cap  integer;
  v_has_slot  boolean := false;
  v_sold      integer := 0;
  v_sold_cnt  integer;
  v_strict    boolean;
  v_solo_cap  integer;
  v_solo_used integer;
  v_solo_rem  integer;
  v_allowed   int[];
  v_rem       integer;
  v_next_solo integer;
begin
  if new.ticket_product_id is null or coalesce(new.status,'') = 'cancelled' then
    return new;
  end if;
  select total_pax, to_jsonb(slots) into v_cap, v_slots
    from public.ticket_products where id = new.ticket_product_id;
  if v_cap is null and v_slots is null then
    return new;   -- ticket_products 에 없는 구매(초대 결제 INV- 등)는 통과 (= 관리자 오버라이드 경로)
  end if;

  -- 같은 티켓 동시 INSERT 직렬화
  perform pg_advisory_xact_lock(hashtext('tkcap_' || new.ticket_product_id));

  -- ① 총 정원 (전 회원 합산)
  select coalesce(sum(party_size), 0) into v_sold
    from public.tickets
   where ticket_product_id = new.ticket_product_id
     and coalesce(status, '') <> 'cancelled';
  if coalesce(v_cap, 0) > 0 and v_sold + coalesce(new.party_size, 0) > v_cap then
    raise exception 'TICKET_SOLD_OUT: 잔여 % 석, 요청 % 명', (v_cap - v_sold), new.party_size
      using errcode = 'P0001';
  end if;

  -- 🆕 2026-09-29 정산 결제 좌석(KSK-) — 총 정원(①)만 본다. 1인 한도·허용 인원·조각 차단·고정 슬롯은
  --   회원 자가 구매를 다듬는 규칙이라, 어드민이 매장과 직접 잡은 자리에는 적용하지 않는다.
  --   플래그는 _taam_ksk_seat_sync 만 세우고, 트랜잭션 안에서만 산다.
  if coalesce(current_setting('taam.seat_engine_bypass', true), '') = '1'
     and coalesce(new.purchase_id, '') like 'KSK-%' then
    return new;
  end if;

  -- ②-A 🆕 자유 구성(flex): 좌석 엔진 v3
  if (v_slots->>'mode') = 'flex' then
    v_cap := coalesce(v_cap, 0);
    v_allowed  := array(select jsonb_array_elements_text(coalesce(v_slots->'allowed','[]'::jsonb))::int);
    v_strict   := coalesce((v_slots->>'strict')::boolean, false);   -- 미지정(구버전)=완화
    v_solo_cap := coalesce((v_slots->>'solo')::int, 0);
    v_rem      := v_cap - v_sold;   -- 이번 구매 전 잔여
    select count(*) into v_solo_used
      from public.tickets
     where ticket_product_id = new.ticket_product_id
       and party_size = 1
       and coalesce(status, '') <> 'cancelled';
    v_solo_rem := greatest(0, v_solo_cap - v_solo_used);

    -- 허용 인원 검사 (완화: 잔여 1석이면 1인 자동 개방)
    if not (coalesce(new.party_size, 0) = any(v_allowed)) then
      if not ( coalesce(new.party_size, 0) = 1 and (not v_strict) and v_rem = 1 ) then
        raise exception 'INVALID_PARTY_SIZE: %인 구매는 허용되지 않습니다', new.party_size
          using errcode = 'P0001';
      end if;
    end if;

    -- 1인 팀 수 제한 (완화: 잔여 1석 예외)
    if coalesce(new.party_size, 0) = 1 and v_solo_rem < 1 then
      if not ( (not v_strict) and v_rem = 1 ) then
        raise exception 'SOLO_LIMIT: 1인 구매 한도 소진' using errcode = 'P0001';
      end if;
    end if;

    -- 엄격 모드: 조각 사전 차단 — 이번 구매 후 잔여를 채울 수 없으면 거부
    if v_strict then
      v_next_solo := case when coalesce(new.party_size,0) = 1 then v_solo_rem - 1 else v_solo_rem end;
      if not public.taam_seat_fillable(v_rem - coalesce(new.party_size,0), v_allowed, v_next_solo) then
        raise exception 'FRAGMENT_BLOCKED: 이 인원으로 예약하면 남는 좌석을 채울 수 없습니다 (잔여 %석)', v_rem
          using errcode = 'P0001';
      end if;
    end if;

    return new;   -- flex 는 고정 슬롯 검사 미적용
  end if;

  -- ②-B 고정 슬롯(1·2·4인석): 유형 위반 + 해당 인원석 슬롯 소진 차단
  v_has_slot := coalesce((v_slots->>'s1')::int,0) > 0
             or coalesce((v_slots->>'s2')::int,0) > 0
             or coalesce((v_slots->>'s4')::int,0) > 0;
  if v_has_slot and coalesce(new.party_size,0) in (1,2,4) then
    v_slot_cap := coalesce((v_slots->>('s' || new.party_size))::int, 0);
    if v_slot_cap <= 0 then
      raise exception 'INVALID_PARTY_SIZE: 이 티켓에는 %인석이 없습니다', new.party_size
        using errcode = 'P0001';
    end if;
    select count(*) into v_sold_cnt
      from public.tickets
     where ticket_product_id = new.ticket_product_id
       and party_size = new.party_size
       and coalesce(status, '') <> 'cancelled';
    if v_sold_cnt >= v_slot_cap then
      raise exception 'SLOT_SOLD_OUT: %인석 %개 모두 판매됨', new.party_size, v_slot_cap
        using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;
    $fn$;
    raise notice '✅ 정원 트리거 교체 (KSK- 총 정원만)';
  elsif exists (select 1 from pg_proc p where p.oid = to_regproc('public.enforce_ticket_capacity') and p.prosrc like '%taam.seat_engine_bypass%') then
    raise notice '· 정원 트리거는 이미 bypass 를 안다 — 건너뜀';
  else
    raise warning '❌ 정원 트리거 라이브 본문이 저장소 원본(sql/ticket_capacity_guard.sql)과 다르다 — 건너뜀 (md5 %)', v_live;
  end if;
end $do$;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상. ❌ 가 있으면 그 함수의 pg_get_functiondef 를 보내 주세요 ──
select '① 동기화 함수 2차 (short.kind)' as what,
       case when exists (select 1 from pg_proc where oid = to_regproc('public._taam_ksk_seat_sync') and prosrc like '%seat_engine_bypass%') then '✅' else '❌ 옛 판' end as result
union all
select '② 청구 트리거가 예외를 삼킨다',
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_ksk_seat_on_charge') and prosrc like '%raise warning%') then '✅' else '❌ 옛 판' end
union all
select '③ 티어 가드 KSK-·LINK- 면제',
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_guard_ticket_tier') and prosrc like '%KSK-%') then '✅'
            else '❌ 건너뜀 — select pg_get_functiondef(''public.taam_guard_ticket_tier''::regproc) 결과를 보내 주세요' end
union all
select '④ 정원 트리거 KSK- 총 정원만',
       case when exists (select 1 from pg_proc where oid = to_regproc('public.enforce_ticket_capacity') and prosrc like '%taam.seat_engine_bypass%') then '✅'
            else '❌ 건너뜀 — select pg_get_functiondef(''public.enforce_ticket_capacity''::regproc) 결과를 보내 주세요' end
union all
select '⑤ 트리거 3종 존재',
       case when (select count(*) from pg_trigger where tgname in ('trg_ksk_seat_on_charge','trg_ksk_seat_on_team','trg_ksk_seat_on_event')) = 3 then '✅' else '❌' end;
