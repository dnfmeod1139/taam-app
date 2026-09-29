-- ============================================================================
-- 20260929_kashikiri_seat_sync3.sql — 정원 트리거에 KSK- 우회 (2차 ④ 의 후속)
-- ============================================================================
-- 2차(…sync2.sql) ④ 는 라이브 본문 md5 가 저장소 원본과 달라 건너뛰었다. 사용자가 보내 준
-- pg_get_functiondef 를 보니 **주석만 다르고 논리는 같다** (「동시 INSERT 직렬화」 주석 등이 빠진 판).
-- 그래서 라이브 본문을 그대로 바탕으로, 총 정원(①) 검사 뒤에 KSK- 우회 블록만 더해 교체한다.
-- 이번엔 md5 로 잠그지 않는다 — 라이브 판을 눈으로 확인했다.
-- ============================================================================

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
    return new;   -- 초대 결제(INV-) 등은 통과 (= 관리자 오버라이드 경로)
  end if;

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

  -- ②-A 자유 구성(flex): 좌석 엔진 v3
  if (v_slots->>'mode') = 'flex' then
    v_cap := coalesce(v_cap, 0);
    v_allowed  := array(select jsonb_array_elements_text(coalesce(v_slots->'allowed','[]'::jsonb))::int);
    v_strict   := coalesce((v_slots->>'strict')::boolean, false);
    v_solo_cap := coalesce((v_slots->>'solo')::int, 0);
    v_rem      := v_cap - v_sold;
    select count(*) into v_solo_used
      from public.tickets
     where ticket_product_id = new.ticket_product_id
       and party_size = 1
       and coalesce(status, '') <> 'cancelled';
    v_solo_rem := greatest(0, v_solo_cap - v_solo_used);

    if not (coalesce(new.party_size, 0) = any(v_allowed)) then
      if not ( coalesce(new.party_size, 0) = 1 and (not v_strict) and v_rem = 1 ) then
        raise exception 'INVALID_PARTY_SIZE: %인 구매는 허용되지 않습니다', new.party_size
          using errcode = 'P0001';
      end if;
    end if;

    if coalesce(new.party_size, 0) = 1 and v_solo_rem < 1 then
      if not ( (not v_strict) and v_rem = 1 ) then
        raise exception 'SOLO_LIMIT: 1인 구매 한도 소진' using errcode = 'P0001';
      end if;
    end if;

    if v_strict then
      v_next_solo := case when coalesce(new.party_size,0) = 1 then v_solo_rem - 1 else v_solo_rem end;
      if not public.taam_seat_fillable(v_rem - coalesce(new.party_size,0), v_allowed, v_next_solo) then
        raise exception 'FRAGMENT_BLOCKED: 이 인원으로 예약하면 남는 좌석을 채울 수 없습니다 (잔여 %석)', v_rem
          using errcode = 'P0001';
      end if;
    end if;

    return new;
  end if;

  -- ②-B 고정 슬롯(1·2·4인석)
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

-- ── 확인 — ❌ 가 없어야 정상 ──
select '④ 정원 트리거 KSK- 총 정원만' as what,
       case when exists (select 1 from pg_proc where oid = to_regproc('public.enforce_ticket_capacity') and prosrc like '%taam.seat_engine_bypass%') then '✅' else '❌' end as result
union all
select '④-b 트리거가 여전히 걸려 있다',
       case when exists (select 1 from pg_trigger where tgname = 'trg_enforce_ticket_capacity' and not tgisinternal) then '✅' else '❌ 트리거 없음' end;
