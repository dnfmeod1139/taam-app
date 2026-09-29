-- ═════════════════════════════════════════════════
-- 링크 초대 (비회원 · 해외) · 2026-09-29
-- ═════════════════════════════════════════════════
-- 무엇
--   앱 회원이 아닌 손님(주로 해외)을 판매 티켓 회차에 태운다. 초대 화면에서 이름·번호·통화를 적으면
--   ① 좌석 홀드(tickets · LINK- 행)가 잡히고 ② 정산 링크와 같은 카드 결제 링크(kashikiri_charges)가 만들어진다.
--   ③ 링크에서 결제가 승인되면(kashikiri-confirm → taam_kashikiri_mark_paid → status='paid') 트리거가 홀드를 확정 행으로 바꾼다.
--   금액은 서버가 (식사비+대행비+주류미니멈)×인원 으로 센다 — 회원 결제와 같은 식 · 대행비 포함.
--   예치금·원장은 건드리지 않는다 — 카드 돈은 토스로 간다.
--
-- 취소 규정 = 회원과 같다 (taam_refund_cap 과 같은 축)
--   결제 30분 안 → 전액 · 방문 D-31 이상 → 총액 − 대행비×인원 · 그 뒤 → 0
--   환불 견적(taam_link_invite_refund_quote)은 서버가 내고, 실제 카드 취소는 Edge kashikiri-refund 가
--   토스에 부분취소를 부른 뒤 taam_link_invite_mark_refunded 로 기록한다.
--
-- 대관 정산 테이블을 그대로 쓰는 이유: /pay/ 링크 페이지·통화별 MID 승인·QR·「링크 전부 복사」가 전부 거기 있다.
--   링크 초대는 「티켓 회차에 붙은 정산 회차(kashikiri_events.ticket_product_id)」 하나를 만들어 쓴다.
-- ═════════════════════════════════════════════════

-- ── 0. 컬럼 ──
alter table public.kashikiri_charges add column if not exists refund_krw    integer;
alter table public.kashikiri_charges add column if not exists refund_amount numeric(14,2);
alter table public.kashikiri_charges add column if not exists refunded_at   timestamptz;
alter table public.kashikiri_charges add column if not exists cancel_reason text;
alter table public.kashikiri_charges add column if not exists link_invite   boolean not null default false;
do $$
begin
  -- status 제약에 'refunded' 를 넣는다 (제약 이름이 판마다 달라 조건으로 찾는다)
  perform 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
   where t.relname = 'kashikiri_charges' and c.contype = 'c' and pg_get_constraintdef(c.oid) like '%''pending''%' and pg_get_constraintdef(c.oid) not like '%refunded%';
  if found then
    execute (select 'alter table public.kashikiri_charges drop constraint ' || quote_ident(c.conname)
               from pg_constraint c join pg_class t on t.oid = c.conrelid
              where t.relname = 'kashikiri_charges' and c.contype = 'c' and pg_get_constraintdef(c.oid) like '%''pending''%' limit 1);
    alter table public.kashikiri_charges add constraint kashikiri_charges_status_chk
      check (status in ('pending','paid','cancelled','expired','failed','refunded'));
  end if;
end $$;

-- ── 1. 만들기 ──
create or replace function public.taam_link_invite_create(
  p_ticket_id  text,
  p_name       text,
  p_phone      text,
  p_pax        int,
  p_currency   text,
  p_fx         numeric,
  p_visit_date text,           -- 'YYYY.MM.DD' (앱이 티켓에서 읽어 넘긴다 · tickets.reservation_date 와 같은 꼴)
  p_visit_time text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_super boolean := false;
  v_tp    public.ticket_products%rowtype;
  v_cur   text := upper(coalesce(nullif(p_currency,''),'KRW'));
  v_amt   bigint;
  v_pay   numeric(14,2);
  v_ev    uuid;
  v_team  uuid;
  v_ch    public.kashikiri_charges%rowtype;
  v_pid   text;
  v_date  date;
  v_name  text := nullif(trim(coalesce(p_name,'')), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9+]', '', 'g'), '');
begin
  if v_uid is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  begin v_super := public._taam_uid_is_super(); exception when others then v_super := false; end;
  select * into v_tp from public.ticket_products where id::text = p_ticket_id;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  if not v_super and not exists (
       select 1 from public.admin_grants g where g.user_id = v_uid
          and (g.rest_id::text = v_tp.rest_id::text or g.venue_id::text = v_tp.rest_id::text)) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  if v_name is null then raise exception '이름이 필요합니다' using errcode = '22023'; end if;
  if coalesce(p_pax,0) < 1 then raise exception '인원이 필요합니다' using errcode = '22023'; end if;
  if v_cur not in ('KRW','USD','JPY') then raise exception '통화(%)를 알 수 없습니다', v_cur using errcode = '22023'; end if;
  if v_cur <> 'KRW' and coalesce(p_fx,0) <= 0 then raise exception '외화로 보내려면 환율(1%=₩)이 필요합니다', v_cur using errcode = '22023'; end if;

  -- 금액은 서버가 센다 (회원 결제와 같은 식 · 대행비 포함)
  v_amt := public.taam_ticket_price_krw(p_ticket_id, p_pax);
  if v_amt is null or v_amt <= 0 then raise exception '티켓 요금이 없어 금액을 셀 수 없습니다' using errcode = '22023'; end if;
  v_pay := case v_cur when 'USD' then round(v_amt / p_fx, 2) when 'JPY' then round(v_amt / p_fx) else v_amt end;

  -- 방문일
  begin v_date := to_date(p_visit_date, 'YYYY.MM.DD'); exception when others then v_date := null; end;
  if v_date is null then raise exception '방문일(YYYY.MM.DD)이 필요합니다' using errcode = '22023'; end if;

  -- 만료된 링크 초대의 홀드는 이 기회에 푼다 (별도 잡 없이)
  update public.tickets t set status = 'cancelled'
   where t.status = 'hold' and t.purchase_id like 'LINK-%'
     and exists (select 1 from public.kashikiri_charges c
                  where c.id::text = t.extra_data->>'chargeId' and c.status = 'pending'
                    and c.expires_at is not null and c.expires_at < now());

  -- 정산 회차: 이 티켓에 붙은 것 하나 (없으면 만든다)
  select e.id into v_ev from public.kashikiri_events e
   where e.ticket_product_id = p_ticket_id and e.status <> 'cancelled' order by e.created_at limit 1;
  if v_ev is null then
    insert into public.kashikiri_events (venue_id, venue_name, event_date, event_time, total_pax, escort, status,
                                         fx_rate, fx_usd, ticket_product_id, created_by, memo)
    values (v_tp.rest_id::text, v_tp.rest_name, v_date,
            case when coalesce(p_visit_time, v_tp.time) ~ '^\d{1,2}:\d{2}' then coalesce(p_visit_time, v_tp.time)::time else null end,
            coalesce(v_tp.total_pax, 0), false, 'open',
            case when v_cur = 'JPY' then p_fx end, case when v_cur = 'USD' then p_fx end,
            p_ticket_id, v_uid, '링크 초대 (자동 생성)')
    returning id into v_ev;
  else
    -- 이 통화의 환율이 비어 있으면 이번 값으로 채운다 (있으면 회차 값을 존중 — 링크마다 다른 환율을 쓰지 않는다)
    update public.kashikiri_events set
      fx_rate = coalesce(fx_rate, case when v_cur = 'JPY' then p_fx end),
      fx_usd  = coalesce(fx_usd,  case when v_cur = 'USD' then p_fx end)
     where id = v_ev;
  end if;

  insert into public.kashikiri_teams (event_id, seq, host_label, pax)
  values (v_ev, coalesce((select max(seq) from public.kashikiri_teams where event_id = v_ev), 0) + 1, v_name, p_pax)
  returning id into v_team;

  insert into public.kashikiri_charges (event_id, team_id, label, payer_phone, amount_krw, amount_jpy,
                                        pay_currency, pay_fx, pay_amount, expires_at, link_invite)
  values (v_ev, v_team, v_name, v_phone, v_amt::int,
          case when v_cur = 'JPY' then v_pay::int end,
          v_cur, case when v_cur = 'KRW' then 1 else p_fx end, v_pay,
          least(now() + interval '72 hours', (v_date - 1)::timestamptz + interval '23 hours'), true)
  returning * into v_ch;

  v_pid := 'LINK-' || left(v_ch.id::text, 8) || '-' || (extract(epoch from now())*1000)::bigint;
  -- 좌석 홀드 — 용량 트리거가 잔여석을 검증한다 (모자라면 TICKET_SOLD_OUT 으로 전체 롤백)
  insert into public.tickets (user_id, restaurant_id, restaurant_name, ticket_product_id, ticket_type,
                              reservation_date, visit_time, party_size, price, status, purchase_id,
                              buyer_name, buyer_phone, extra_data, created_at)
  values (v_uid, v_tp.rest_id::text, v_tp.rest_name, p_ticket_id, coalesce(v_tp.type_class,''),
          p_visit_date, coalesce(p_visit_time, v_tp.time, ''), p_pax, v_amt, 'hold', v_pid,
          v_name, coalesce(v_phone,''),
          jsonb_build_object('linkInvite', true, 'chargeId', v_ch.id::text, 'token', v_ch.token,
                             'currency', v_cur, 'payAmount', v_pay, 'fx', p_fx,
                             'agencyFee', coalesce(v_tp.agency_fee,0), 'createdBy', v_uid),
          now());

  return json_build_object('ok', true, 'charge_id', v_ch.id, 'token', v_ch.token,
                           'url', 'https://taam-app.vercel.app/pay/?t=' || v_ch.token,
                           'amount_krw', v_amt, 'pay_amount', v_pay, 'currency', v_cur,
                           'purchase_id', v_pid, 'expires_at', v_ch.expires_at, 'event_id', v_ev);
end;
$$;
revoke all on function public.taam_link_invite_create(text,text,text,int,text,numeric,text,text) from public;
grant execute on function public.taam_link_invite_create(text,text,text,int,text,numeric,text,text) to authenticated;

-- ── 2. 결제되면 홀드 → 확정 · 링크가 죽으면 홀드 해제 ──
create or replace function public.taam_link_invite_on_charge()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(new.link_invite, false) then return new; end if;
  if new.status = 'paid' and coalesce(old.status,'') <> 'paid' then
    update public.tickets
       set status = 'active',
           buyer_name = coalesce(nullif(new.payer_name,''), buyer_name),
           extra_data = coalesce(extra_data,'{}'::jsonb) || jsonb_build_object('paidAt', coalesce(new.approved_at, now()), 'paymentKey', new.payment_key)
     where status = 'hold' and purchase_id like 'LINK-%' and extra_data->>'chargeId' = new.id::text;
  elsif new.status in ('cancelled','expired','failed','refunded') and coalesce(old.status,'') not in ('cancelled','expired','refunded') then
    update public.tickets set status = 'cancelled',
           extra_data = coalesce(extra_data,'{}'::jsonb) || jsonb_build_object('cancelledBy', 'charge_' || new.status, 'cancelledAt', now())
     where status in ('hold','active') and purchase_id like 'LINK-%' and extra_data->>'chargeId' = new.id::text;
  end if;
  return new;
end $$;
drop trigger if exists trg_link_invite_on_charge on public.kashikiri_charges;
create trigger trg_link_invite_on_charge after update of status on public.kashikiri_charges
  for each row execute function public.taam_link_invite_on_charge();

-- ── 3. 환불 견적 — 회원과 같은 규정 ──
create or replace function public.taam_link_invite_refund_quote(p_charge_id text)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_ch  public.kashikiri_charges%rowtype;
  v_tk  public.tickets%rowtype;
  v_days int; v_agency bigint := 0; v_refund bigint := 0; v_policy text; v_visit date;
begin
  select * into v_ch from public.kashikiri_charges where id::text = p_charge_id;
  if not found then raise exception 'CHARGE_NOT_FOUND' using errcode = 'P0002'; end if;
  select * into v_tk from public.tickets where purchase_id like 'LINK-%' and extra_data->>'chargeId' = v_ch.id::text
   order by created_at desc limit 1;
  if v_ch.status <> 'paid' then
    return json_build_object('charge_id', v_ch.id, 'status', v_ch.status, 'refund_krw', 0, 'refund_amount', 0, 'policy', 'not_paid');
  end if;
  v_agency := coalesce((v_tk.extra_data->>'agencyFee')::bigint, 0) * greatest(coalesce(v_tk.party_size,1),1);
  begin v_visit := to_date(v_tk.reservation_date, 'YYYY.MM.DD'); exception when others then v_visit := null; end;
  v_days := case when v_visit is null then null else (v_visit - (now() at time zone 'Asia/Seoul')::date) end;
  if v_ch.approved_at is not null and now() - v_ch.approved_at <= interval '30 minutes' then
    v_refund := v_ch.amount_krw; v_policy := 'within_30min_full';
  elsif v_days is null or v_days >= 31 then
    v_refund := greatest(0, v_ch.amount_krw - v_agency); v_policy := 'd31_minus_agency';
  else
    v_refund := 0; v_policy := 'after_d30_none';
  end if;
  return json_build_object('charge_id', v_ch.id, 'status', v_ch.status, 'currency', v_ch.pay_currency,
    'paid_krw', v_ch.amount_krw, 'paid_amount', v_ch.pay_amount, 'agency_krw', v_agency, 'days_left', v_days,
    'refund_krw', v_refund,
    'refund_amount', case when v_ch.pay_currency = 'KRW' then v_refund
                          when v_ch.pay_currency = 'JPY' then round(v_refund / nullif(v_ch.pay_fx,0))
                          else round(v_refund / nullif(v_ch.pay_fx,0), 2) end,
    'policy', v_policy, 'payment_key', v_ch.payment_key);
end $$;
revoke all on function public.taam_link_invite_refund_quote(text) from public;
grant execute on function public.taam_link_invite_refund_quote(text) to authenticated, service_role;

-- ── 4. 환불 확정 기록 (Edge 가 토스 취소 뒤에 부른다 · service_role/슈퍼만) ──
create or replace function public.taam_link_invite_mark_refunded(p_charge_id text, p_refund_krw int, p_refund_amount numeric, p_reason text)
returns json language plpgsql security definer set search_path = public as $$
declare v_super boolean := false; v_role text := coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','');
begin
  begin v_super := public._taam_uid_is_super(); exception when others then v_super := false; end;
  if not (v_super or v_role = 'service_role' or session_user = 'postgres') then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  update public.kashikiri_charges
     set status = 'refunded', refund_krw = p_refund_krw, refund_amount = p_refund_amount,
         refunded_at = now(), cancel_reason = left(coalesce(p_reason,''), 200)
   where id::text = p_charge_id and status = 'paid';
  if not found then raise exception '결제된 링크가 아닙니다' using errcode = 'P0002'; end if;
  return json_build_object('ok', true, 'charge_id', p_charge_id, 'refund_krw', p_refund_krw);
end $$;
revoke all on function public.taam_link_invite_mark_refunded(text,int,numeric,text) from public;
grant execute on function public.taam_link_invite_mark_refunded(text,int,numeric,text) to authenticated, service_role;

-- 확인 (❌ 가 한 줄도 없어야 정상)
select string_agg(case when exists (select 1 from pg_proc where proname = f) then '✅ ' || f else '❌ ' || f end, ' · ')
  from unnest(array['taam_link_invite_create','taam_link_invite_on_charge','taam_link_invite_refund_quote','taam_link_invite_mark_refunded']) f;
