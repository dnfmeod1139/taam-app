-- ═══════════════════════════════════════════════════════════════
-- TAAM 예약 — 심플 설정 v2 (요청 전용 사진 · 예약금=식사+주류 · 예약 가능 시간)
-- 작성: 2026-06-10 · reservation_fee.sql 이후 실행 (idempotent)
-- ═══════════════════════════════════════════════════════════════
-- '나의 레스토랑' 새 설정 화면용:
--   · request_photo      : 예약 요청 전용 대표 사진 (base64, 등록 사진과 별개)
--   · reservation_hours  : 예약 가능 시간 (자유 텍스트)
--   · deposit_meal/alcohol : 예약금 구성 (1인 기준 식사비/주류)
--   · 예약금 = (식사비 + 주류) × 인원.  미설정(0) 시 기존 fixed_deposit 폴백.

alter table public.venue_partners add column if not exists request_photo     text;
alter table public.venue_partners add column if not exists reservation_hours text;
alter table public.venue_partners add column if not exists deposit_meal      integer default 0;
alter table public.venue_partners add column if not exists deposit_alcohol   integer default 0;

-- ── create_reservation_request 갱신 — 예약금 = (식사+주류)×인원 ──
create or replace function public.create_reservation_request(
  p_venue_id            text,
  p_reserve_date        date,
  p_reserve_time        time,
  p_party_size          integer,
  p_member_memo         text default null,
  p_conditions_accepted boolean default false
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
  if v_per > 0 then
    v_deposit := v_per * p_party_size;
  else
    v_deposit := coalesce(v_partner.fixed_deposit, 0);
  end if;
  v_fee := public.calc_broker_fee(p_venue_id, v_deposit, p_party_size);

  insert into public.reservation_requests
    (user_id, venue_id, reserve_date, reserve_time, party_size,
     member_memo, conditions_accepted, status, deposit_amount, broker_fee)
  values
    (v_uid, p_venue_id, p_reserve_date, p_reserve_time, p_party_size,
     p_member_memo, true, 'pending', v_deposit, v_fee)
  returning * into v_row;
  return v_row;
end;
$$;
