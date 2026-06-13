-- ═══════════════════════════════════════════════════════════════
-- TAAM 예약 — 요청자 정보 / 알러지 / 어드민 메모 / 방문이력
-- 작성: 2026-06-13 · reservation_simple_settings.sql 이후 실행 (idempotent)
-- ═══════════════════════════════════════════════════════════════
-- 추가 기능:
--   · reservation_requests.allergy     : 회원이 요청 시 기재 (식이/알러지)
--   · reservation_requests.admin_memo  : 어드민(셰프/대표)이 방문 후 남기는 메모 — 어드민 전용
--   · profiles.nationality             : 국적 (회원이 프로필에서 1회 입력)
--   · get_requester_info()             : 어드민용 요청자 집계(구매·캔슬·방문·국적·등급…)
--   · set_reservation_admin_memo()     : 어드민 메모 저장
--   · create_reservation_request()     : p_allergy 파라미터 추가
-- ⚠ 실행 후 Supabase 에 반영됨 (저장소에 두는 것만으로는 미적용).

-- ── 1) 컬럼 추가 ──
alter table public.reservation_requests add column if not exists allergy    text;  -- 회원 기재 (알러지/식이)
alter table public.reservation_requests add column if not exists admin_memo text;  -- 어드민 전용 메모
alter table public.profiles            add column if not exists nationality text;  -- 국적

-- ── 2) 요청 생성 RPC — p_allergy 추가 (예약금=(식사+주류)×인원 폴백 유지) ──
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

  -- 예약금 = (식사비 + 주류) × 인원 / 미설정 시 fixed_deposit 폴백
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

-- ── 3) 어드민용 요청자 정보 집계 (보안 정의자 — 매장 어드민만) ──
--   구매/캔슬 = 티켓 + 예약요청 합산. 방문이력 = 해당 매장 attended 기준.
create or replace function public.get_requester_info(p_user_id uuid, p_venue_id text)
returns table (
  display_name   text,
  phone          text,
  nationality    text,
  membership_tier text,
  purchase_count integer,   -- 구매 합산(티켓 구매 + 확정 예약)
  cancel_count   integer,   -- 캔슬 합산(취소 티켓 + 노쇼)
  venue_visits   integer,   -- 이 매장 방문 횟수(attended)
  last_visit     date       -- 이 매장 마지막 방문일
)
language plpgsql stable security definer set search_path = public
as $$
declare
  v_ticket_buy integer := 0; v_ticket_cancel integer := 0;
  v_resv_conf  integer := 0; v_resv_noshow   integer := 0;
begin
  if not (public.is_super_admin(auth.uid()) or public.is_venue_admin_of(p_venue_id)) then
    raise exception 'FORBIDDEN' using errcode='P0001';
  end if;

  -- 티켓 구매/취소 (테이블 없을 환경 대비 예외 무시)
  begin
    select count(*) filter (where coalesce(status,'') <> 'cancelled'),
           count(*) filter (where status = 'cancelled')
      into v_ticket_buy, v_ticket_cancel
      from public.tickets where user_id = p_user_id;
  exception when undefined_table then v_ticket_buy := 0; v_ticket_cancel := 0;
  end;

  select count(*) filter (where status = 'confirmed'),
         count(*) filter (where visit_status = 'no_show')
    into v_resv_conf, v_resv_noshow
    from public.reservation_requests where user_id = p_user_id;

  return query
  select
    p.display_name,
    p.phone,
    p.nationality,
    p.membership_tier,
    (v_ticket_buy + v_resv_conf)::int,
    (v_ticket_cancel + v_resv_noshow)::int,
    (select count(*)::int from public.reservation_requests rr
       where rr.user_id = p_user_id and rr.venue_id = p_venue_id and rr.visit_status = 'attended'),
    (select max(rr.reserve_date) from public.reservation_requests rr
       where rr.user_id = p_user_id and rr.venue_id = p_venue_id and rr.visit_status = 'attended')
  from public.profiles p where p.id = p_user_id;
end;
$$;
comment on function public.get_requester_info is '어드민용 요청자 집계(구매·캔슬 합산, 매장 방문이력). 매장 어드민/슈퍼어드민만.';

-- ── 4) 어드민 메모 저장 (해당 매장 어드민만) ──
create or replace function public.set_reservation_admin_memo(p_request_id uuid, p_memo text)
returns public.reservation_requests
language plpgsql security definer set search_path = public
as $$
declare r public.reservation_requests%rowtype;
begin
  select * into r from public.reservation_requests where id = p_request_id;
  if not found then raise exception 'NOT_FOUND' using errcode='P0001'; end if;
  if not (public.is_super_admin(auth.uid()) or public.is_venue_admin_of(r.venue_id)) then
    raise exception 'FORBIDDEN' using errcode='P0001';
  end if;
  update public.reservation_requests
    set admin_memo = nullif(btrim(coalesce(p_memo,'')),'')
    where id = p_request_id returning * into r;
  return r;
end;
$$;
comment on function public.set_reservation_admin_memo is '어드민 전용 메모 저장. 해당 매장 어드민/슈퍼어드민만.';
