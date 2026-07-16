-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 오버셀 + 좌석유형 위반 차단 (전 회원 합산) (2026-07-16)
-- ═══════════════════════════════════════════════════════════════
-- 버그 1: 매진 판정이 '구매자 본인' 내역만 합산 → 4석 티켓 6석 판매.
-- 버그 2: 좌석 유형(1인석/2인석/4인석) 미검증 → 2인석×2 티켓에 1인 판매.
-- 수정: ① 전 회원 합산 판매현황 RPC (총인원 + 유형별 판매 슬롯 수)
--       ② tickets INSERT 트리거 — 총 정원 초과/유형 위반/슬롯 소진 서버 거부
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent).
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

-- ── 2) 전 회원 합산 판매현황 (총인원 + 유형별 슬롯 판매 수) ──
--   s1/s2/s4 = 그 인원수로 구매된 "건수" (= 소진된 해당 인원석 슬롯 수)
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
comment on function public.taam_ticket_sold_slots is
  '티켓 상품별 전 회원 판매현황(취소 제외): 총인원 + 1·2·4인석 판매 건수. 구매 전 검증용.';

-- ── 3) INSERT 차단 트리거 — 총 정원 + 좌석 유형 서버 강제 ──
create or replace function public.enforce_ticket_capacity()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_cap      integer;
  v_slots    jsonb;
  v_slot_cap integer;
  v_has_slot boolean := false;
  v_sold     integer;
  v_sold_cnt integer;
begin
  if new.ticket_product_id is null or coalesce(new.status,'') = 'cancelled' then
    return new;
  end if;
  select total_pax, to_jsonb(slots) into v_cap, v_slots
    from public.ticket_products where id = new.ticket_product_id;
  if v_cap is null and v_slots is null then
    return new;   -- ticket_products 에 없는 구매(초대 결제 INV- 등)는 통과
  end if;

  -- 같은 티켓 동시 INSERT 직렬화
  perform pg_advisory_xact_lock(hashtext('tkcap_' || new.ticket_product_id));

  -- ① 총 정원
  if coalesce(v_cap, 0) > 0 then
    select coalesce(sum(party_size), 0) into v_sold
      from public.tickets
     where ticket_product_id = new.ticket_product_id
       and coalesce(status, '') <> 'cancelled';
    if v_sold + coalesce(new.party_size, 0) > v_cap then
      raise exception 'TICKET_SOLD_OUT: 잔여 % 석, 요청 % 명', (v_cap - v_sold), new.party_size
        using errcode = 'P0001';
    end if;
  end if;

  -- ② 좌석 유형 (slots 설정된 티켓만): 유형 위반 + 해당 인원석 슬롯 소진 차단
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

do $$ begin raise notice '✅ 티켓 오버셀+좌석유형 차단 적용 (RPC 2종 + INSERT 트리거)'; end $$;

-- ── 진단 (참고): 정원 초과/유형 위반 판매된 티켓 목록 ──
select t.ticket_product_id,
       max(tp.rest_name)  as rest,
       max(tp.date)       as visit_date,
       max(tp.total_pax)  as cap,
       sum(t.party_size)  as sold_pax,
       count(*) filter (where t.party_size = 1) as sold_1seat,
       count(*) filter (where t.party_size = 2) as sold_2seat,
       count(*) filter (where t.party_size = 4) as sold_4seat
  from public.tickets t
  join public.ticket_products tp on tp.id = t.ticket_product_id
 where coalesce(t.status,'') <> 'cancelled'
 group by t.ticket_product_id
having sum(t.party_size) > max(tp.total_pax)
 order by sold_pax desc;
