-- ═══════════════════════════════════════════════════════════════
-- TAAM 예약 — 매장별 '예약 요청 받기' ON/OFF (request_enabled) (2026-06-22)
-- ═══════════════════════════════════════════════════════════════
-- 파트너 리스트엔 보이되, 요청은 받는 곳/안 받는 곳을 구분.
--   · is_partner      = 파트너 리스트 노출 여부
--   · request_enabled = 예약 요청 가능 여부 (요청 탭 노출·요청 RPC 허용)
-- ⚠ 기본값 false(OFF) — 모든 매장이 우선 '요청 OFF'. 관리화면에서 켜기.
-- 라우팅: 요청은 reservation_requests 에 쌓이고, RLS 로
--   슈퍼어드민=전체 / 매장 어드민(is_venue_admin_of)=자기 매장 자동 분기.
--   (현재 어드민 매핑 없음 → 전부 슈퍼어드민이 수신. 어드민 연결 시 자동 라우팅.)
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent).
-- ⚠ reservation_requester_info.sql 이후 실행 (RPC 최신본 기준).
-- ═══════════════════════════════════════════════════════════════

-- 1) 컬럼 추가 — 기본 OFF
alter table public.venue_partners
  add column if not exists request_enabled boolean not null default false;

-- 2) 요청 생성 RPC — request_enabled 체크 추가 (그 외 로직 동일)
create or replace function public.create_reservation_request(
  p_venue_id            text,
  p_reserve_date        date,
  p_reserve_time        time,
  p_party_size          integer,
  p_member_memo         text default null,
  p_conditions_accepted boolean default false,
  p_allergy             text default null
)
returns public.reservation_requests
language plpgsql security definer set search_path = public
as $$
declare
  ANNUAL_LIMIT constant integer := 9999;
  v_uid     uuid := auth.uid();
  v_partner public.venue_partners%rowtype;
  v_pending integer; v_annual integer; v_dow integer;
  v_per     integer; v_deposit integer; v_fee integer;
  v_row     public.reservation_requests%rowtype;
begin
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode='P0001'; end if;
  if coalesce(p_conditions_accepted,false)=false then raise exception 'CONDITIONS_NOT_ACCEPTED' using errcode='P0001'; end if;

  select * into v_partner from public.venue_partners where venue_id=p_venue_id;
  if not found or v_partner.is_partner=false then raise exception 'NOT_A_PARTNER_VENUE' using errcode='P0001'; end if;
  -- 🆕 요청 OFF 매장 차단
  if coalesce(v_partner.request_enabled,false)=false then raise exception 'REQUEST_DISABLED' using errcode='P0001'; end if;

  if p_party_size < coalesce(v_partner.party_min,1) or p_party_size > coalesce(v_partner.party_max,9999) then
    raise exception 'PARTY_SIZE_OUT_OF_RANGE' using errcode='P0001'; end if;
  if p_reserve_date < (current_date + (coalesce(v_partner.min_lead_time_months,0) || ' months')::interval) then
    raise exception 'LEAD_TIME_TOO_SHORT' using errcode='P0001'; end if;
  v_dow := extract(dow from p_reserve_date)::int;
  if v_dow = any (coalesce(v_partner.closed_weekdays,'{}')) then raise exception 'VENUE_CLOSED_THAT_DAY' using errcode='P0001'; end if;

  select count(*) into v_pending from public.reservation_requests where user_id=v_uid and status='pending';
  if v_pending >= 2 then raise exception 'TOO_MANY_PENDING' using errcode='P0001'; end if;
  select count(*) into v_annual from public.reservation_requests where user_id=v_uid and created_at >= date_trunc('year', now());
  if v_annual >= ANNUAL_LIMIT then raise exception 'ANNUAL_LIMIT_REACHED' using errcode='P0001'; end if;

  v_per := coalesce(v_partner.deposit_meal,0) + coalesce(v_partner.deposit_alcohol,0);
  if v_per > 0 then v_deposit := v_per * p_party_size; else v_deposit := coalesce(v_partner.fixed_deposit, 0); end if;
  v_fee := public.calc_broker_fee(p_venue_id, v_deposit, p_party_size);

  insert into public.reservation_requests
    (user_id, venue_id, reserve_date, reserve_time, party_size,
     member_memo, allergy, conditions_accepted, status, deposit_amount, broker_fee)
  values
    (v_uid, p_venue_id, p_reserve_date, p_reserve_time, p_party_size,
     p_member_memo, nullif(btrim(coalesce(p_allergy,'')),''), true, 'pending', v_deposit, v_fee)
  returning * into v_row;
  return v_row;
end;
$$;

do $$ begin raise notice '✅ request_enabled 컬럼 + 요청 RPC 게이트 적용 (기본 OFF)'; end $$;
