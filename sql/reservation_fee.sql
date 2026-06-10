-- ═══════════════════════════════════════════════════════════════
-- TAAM 예약 — 고정 예약금 + 중계 수수료(매장별·슈퍼어드민·회원부담)
-- 작성: 2026-06-10
-- ⚠ reservation_requests_phase1.sql + reservation_admin_rpcs.sql 이후 실행.
-- 실행: Supabase SQL Editor (idempotent).
-- ═══════════════════════════════════════════════════════════════
-- 결정:
--   · 예약금 = 매장(어드민)이 고정액 직접 설정 (venue_partners.fixed_deposit)
--   · 중계 수수료 = 슈퍼어드민이 매장별 설정 (reservation_fee_policy) — 어드민 수정 불가
--   · 모든 금액(예약금+수수료)은 회원이 부담, 매장은 0원 지불
--   · 요청 시점 스냅샷(deposit_amount, broker_fee)으로 잠금
-- ═══════════════════════════════════════════════════════════════


-- ── 1) 고정 예약금 + 수수료 스냅샷 컬럼 ──
alter table public.venue_partners      add column if not exists fixed_deposit integer default 0;  -- 매장 고정 예약금
alter table public.reservation_requests add column if not exists broker_fee   integer default 0;  -- 중계 수수료 스냅샷


-- ── 2) reservation_fee_policy — 슈퍼어드민이 매장별 수수료 책정 ──
create table if not exists public.reservation_fee_policy (
  venue_id   text primary key,
  fee_type   text not null default 'fixed' check (fee_type in ('fixed','percent','per_person')),
  fee_value  integer not null default 0,     -- fixed: 원/건, percent: %, per_person: 원/인
  label      text,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
comment on table public.reservation_fee_policy is '예약 중계 수수료 정책(매장별). 슈퍼어드민만 설정.';

alter table public.reservation_fee_policy enable row level security;

-- 읽기: 모두(회원이 결제 전 금액 확인) / 쓰기: 슈퍼어드민만 → 어드민 수정 불가
drop policy if exists "rfp read" on public.reservation_fee_policy;
create policy "rfp read" on public.reservation_fee_policy
  for select to authenticated using ( true );

drop policy if exists "rfp write" on public.reservation_fee_policy;
create policy "rfp write" on public.reservation_fee_policy
  for all to authenticated
  using      ( public.is_super_admin(auth.uid()) )
  with check ( public.is_super_admin(auth.uid()) );


-- ── 3) 수수료 계산 헬퍼 ──
create or replace function public.calc_broker_fee(p_venue_id text, p_deposit integer, p_party integer)
returns integer language sql stable security definer set search_path = public
as $$
  select coalesce((
    select case fee_type
      when 'fixed'      then fee_value
      when 'percent'    then round(coalesce(p_deposit,0) * fee_value / 100.0)::int
      when 'per_person' then fee_value * coalesce(p_party,1)
      else 0 end
    from public.reservation_fee_policy where venue_id = p_venue_id
  ), 0);
$$;


-- ── 4) create_reservation_request 갱신 — 고정 예약금 + 수수료 스냅샷 ──
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
  v_deposit integer; v_fee integer;
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

  -- 예약금 = 매장 고정액 / 수수료 = 매장별 정책 (요청 시점 스냅샷)
  v_deposit := coalesce(v_partner.fixed_deposit, 0);
  v_fee     := public.calc_broker_fee(p_venue_id, v_deposit, p_party_size);

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


-- ── 5) confirm_reservation 갱신 — (예약금 + 수수료) 전액 차감 ──
create or replace function public.confirm_reservation(p_request_id uuid)
returns public.reservation_requests
language plpgsql security definer set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  v_mem bigint; v_gen bigint; v_need bigint; v_from_m bigint; v_from_g bigint; v_after bigint;
  v_meta jsonb;
begin
  select * into r from public.reservation_requests where id=p_request_id;
  if not found then raise exception 'NOT_FOUND' using errcode='P0001'; end if;
  if not (public.is_super_admin(auth.uid()) or public.is_venue_admin_of(r.venue_id)) then
    raise exception 'FORBIDDEN' using errcode='P0001'; end if;
  if r.status <> 'pending' then raise exception 'NOT_PENDING' using errcode='P0001'; end if;

  v_need := coalesce(r.deposit_amount,0) + coalesce(r.broker_fee,0);   -- 회원 전액 부담
  v_meta := jsonb_build_object('reservation_id', r.id, 'venue_id', r.venue_id,
                               'deposit', r.deposit_amount, 'broker_fee', r.broker_fee);

  select coalesce(membership_deposit_balance,0), coalesce(general_deposit_balance,0)
    into v_mem, v_gen from public.profiles where id=r.user_id;

  if v_need > 0 and (v_mem + v_gen) >= v_need then
    v_from_m := least(v_mem, v_need);
    v_from_g := v_need - v_from_m;
    v_after  := (v_mem - v_from_m) + (v_gen - v_from_g);

    update public.profiles
      set membership_deposit_balance = v_mem - v_from_m,
          general_deposit_balance    = v_gen - v_from_g,
          deposit_balance            = v_after
      where id = r.user_id;

    if v_from_m > 0 then
      insert into public.deposit_transactions (user_id,deposit_type,change_type,amount,balance_after,description,metadata)
      values (r.user_id,'membership','reservation_payment',-v_from_m,v_after,'예약 확정 결제 (예약금+중계수수료)',v_meta);
    end if;
    if v_from_g > 0 then
      insert into public.deposit_transactions (user_id,deposit_type,change_type,amount,balance_after,description,metadata)
      values (r.user_id,'general','reservation_payment',-v_from_g,v_after,'예약 확정 결제 (예약금+중계수수료)',v_meta);
    end if;

    update public.reservation_requests
      set status='confirmed', handled_by=auth.uid(), handled_at=now(), deposit_status='paid'
      where id=p_request_id returning * into r;
  else
    update public.reservation_requests
      set status='confirmed', handled_by=auth.uid(), handled_at=now(),
          deposit_status = case when v_need=0 then 'none' else 'unpaid' end
      where id=p_request_id returning * into r;
  end if;

  return r;
end;
$$;
