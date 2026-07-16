-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 좌석 엔진 v3 서버 강제 (2026-07-16)
-- ═══════════════════════════════════════════════════════════════
-- v1: 오버셀 차단(전 회원 합산) + 고정 슬롯(1·2·4인석) 유형 검증
-- v2: 자유 구성(flex) 허용 인원/1인 한도
-- v3: 🆕 좌석 엔진 — 엄격(strict)=조각 사전 차단(DP), 완화(loose)=잔여1석 1인 자동 개방
--     판매 도중 모드 전환(slots.strict) 즉시 반영.
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent, v1/v2 위에 덮어씀).
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 전 회원 합산 판매 인원 (총합) — 호환용 ──
create or replace function public.taam_ticket_sold_pax(p_ticket_id text)
returns integer
language sql stable security definer set search_path = public
as $$
  select coalesce(sum(party_size), 0)::int
    from public.tickets
   where ticket_product_id = p_ticket_id
     and coalesce(status, '') <> 'cancelled';
$$;
grant execute on function public.taam_ticket_sold_pax(text) to authenticated;

-- ── 2) 전 회원 합산 판매현황 (총인원 + 유형별 판매 건수) ──
create or replace function public.taam_ticket_sold_slots(p_ticket_id text)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'total', coalesce(sum(party_size), 0)::int,
    's1', count(*) filter (where party_size = 1)::int,
    's2', count(*) filter (where party_size = 2)::int,
    's4', count(*) filter (where party_size = 4)::int
  )
    from public.tickets
   where ticket_product_id = p_ticket_id
     and coalesce(status, '') <> 'cancelled';
$$;
grant execute on function public.taam_ticket_sold_slots(text) to authenticated;

-- ── 3) 🆕 좌석 채움 가능성 판정 (DP) — rem 석을 허용 인원 조합으로 채울 수 있는가 ──
--   1인은 p_solo 팀까지, 2인 이상은 무제한. (클라이언트 _tseFillable 과 동일 로직)
create or replace function public.taam_seat_fillable(p_rem int, p_allowed int[], p_solo int)
returns boolean
language plpgsql immutable
as $$
declare
  dp boolean[];
  g int; r int; s int;
  v_max_solo int;
begin
  if p_rem = 0 then return true; end if;
  if p_rem < 0 then return false; end if;
  v_max_solo := case when 1 = any(coalesce(p_allowed,'{}')) then greatest(0, coalesce(p_solo,0)) else 0 end;
  dp := array_fill(false, array[p_rem + 1]);   -- dp[i] = (i-1)석을 2인+ 그룹만으로 채움 가능
  dp[1] := true;
  for r in 1 .. p_rem loop
    foreach g in array coalesce(p_allowed,'{}') loop
      if g >= 2 and g <= r and dp[r - g + 1] then
        dp[r + 1] := true;
        exit;
      end if;
    end loop;
  end loop;
  for s in 0 .. least(v_max_solo, p_rem) loop
    if dp[p_rem - s + 1] then return true; end if;
  end loop;
  return false;
end;
$$;

-- ── 4) INSERT 차단 트리거 — 총 정원 + 좌석 엔진 서버 강제 ──
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

drop trigger if exists trg_enforce_ticket_capacity on public.tickets;
create trigger trg_enforce_ticket_capacity
  before insert on public.tickets
  for each row execute function public.enforce_ticket_capacity();

do $$ begin raise notice '✅ 좌석 엔진 v3 적용 — RPC 2종 + fillable(DP) + INSERT 트리거 (엄격/완화)'; end $$;

-- ── 검증 (참고): fillable 스팟 테스트 — 컬럼명이 예상값 ──
select public.taam_seat_fillable(0,  array[2,3], 0) as t_true_0,
       public.taam_seat_fillable(1,  array[1,2,3], 1) as t_true_solo,   -- 1인 허용 시 토큰으로 채움
       public.taam_seat_fillable(1,  array[2,3], 0) as t_false_frag,
       public.taam_seat_fillable(7,  array[3,5], 0) as t_false_35_7,
       public.taam_seat_fillable(10, array[3,5], 0) as t_true_35_10,
       public.taam_seat_fillable(9,  array[2,4,6,8], 0) as t_false_odd_even;

-- ── 진단 (참고): 정원 초과 판매된 티켓 목록 ──
select t.ticket_product_id,
       max(tp.rest_name)  as rest,
       max(tp.date)       as visit_date,
       max(tp.total_pax)  as cap,
       sum(t.party_size)  as sold_pax
  from public.tickets t
  join public.ticket_products tp on tp.id = t.ticket_product_id
 where coalesce(t.status,'') <> 'cancelled'
 group by t.ticket_product_id
having sum(t.party_size) > max(tp.total_pax)
 order by sold_pax desc;
