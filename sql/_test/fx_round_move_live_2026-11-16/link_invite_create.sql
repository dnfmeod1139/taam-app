-- 라이브 taam_link_invite_create 원문(2026-11-16 · md5(prosrc) 21776bd519dd85e09895d910c21174e5 · pg_get_functiondef 그대로) + 의존 함수
--   회차 날짜 이동 9차(R8-SRV-LINKDL) 회귀용 — 20261116_round_move_sync.sql 8 절이 이 본문의 「만료된 링크 초대의 홀드」 정리 앞에 정산 회차 줄 잠금을 넣는다.
--   taam_ticket_price_krw = 라이브 원문 · taam_ticket_price_fx = 원화 링크만 쓰는 회귀라 비워 둔다(외화 경로는 이 파일 밖)
set check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.taam_ticket_price_krw(p_ticket_id text, p_pax integer)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
           when tp.id is null then null
           -- 요금이 하나도 없으면 근거가 없는 것이다. 0원으로 확정하면 안 된다
           when coalesce(tp.meal_fee,0) + coalesce(tp.agency_fee,0)
                + coalesce(tp.wine_min,0) = 0 then null
           else (coalesce(tp.meal_fee,0) + coalesce(tp.agency_fee,0)
                 + coalesce(tp.wine_min,0)) * greatest(coalesce(p_pax,1), 1)
         end
    from public.ticket_products tp
   where tp.id::text = p_ticket_id
$function$;
create or replace function public.taam_ticket_price_fx(p_ticket_id text, p_pax integer, p_currency text, p_fx numeric)
 returns jsonb language sql stable as $function$ select null::jsonb $function$;

CREATE OR REPLACE FUNCTION public.taam_link_invite_create(p_ticket_id text, p_name text, p_phone text, p_pax integer, p_currency text, p_fx numeric, p_visit_date text, p_visit_time text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_super boolean := false;
  v_tp    public.ticket_products%rowtype;
  v_cur   text := upper(coalesce(nullif(p_currency,''),'KRW'));
  v_amt   bigint;
  v_krw   bigint;
  v_pay   numeric(14,2);
  v_fxq   jsonb;
  v_agency_pay numeric;   -- 1인 대행비 · 결제 통화 (환불 견적 D-31 이 뺀다)
  v_agency_krw bigint;    -- 1인 대행비 · 원화 환산 (확정 외화면 round(확정값×환율) · 아니면 원화 정가)
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
       select 1 where public.taam_rest_admin_ok_for(v_uid, v_tp.rest_id::text)) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  if v_name is null then raise exception '이름이 필요합니다' using errcode = '22023'; end if;
  if coalesce(p_pax,0) < 1 then raise exception '인원이 필요합니다' using errcode = '22023'; end if;
  if v_cur not in ('KRW','USD','JPY') then raise exception '통화(%)를 알 수 없습니다', v_cur using errcode = '22023'; end if;
  if v_cur <> 'KRW' and coalesce(p_fx,0) <= 0 then raise exception '외화로 보내려면 환율(1%=₩)이 필요합니다', v_cur using errcode = '22023'; end if;

  -- 금액은 서버가 센다 (회원 결제와 같은 식 · 대행비 포함)
  v_amt := public.taam_ticket_price_krw(p_ticket_id, p_pax);
  if v_amt is null or v_amt <= 0 then raise exception '티켓 요금이 없어 금액을 셀 수 없습니다' using errcode = '22023'; end if;
  -- 🆕 2026-10-19 외화 링크는 티켓 업로드의 확정 해외 정가(ovs_prices)를 항목별로 먼저 쓴다 — 없는 항목만 환율 환산 (taam_ticket_price_fx)
  --   확정 항목이 하나도 없으면 종전 식(round(원화 ÷ 환율))과 같은 값이 나온다. amount_krw 는 확정 항목이 있을 때 round(외화 × 환율).
  v_fxq := case when v_cur = 'KRW' then null else public.taam_ticket_price_fx(p_ticket_id, p_pax, v_cur, p_fx) end;
  v_pay := case v_cur when 'KRW' then v_amt
                      else coalesce((v_fxq->>'pay')::numeric, case v_cur when 'USD' then round(v_amt / p_fx, 2) else round(v_amt / p_fx) end) end;
  v_krw := case when v_cur = 'KRW' then v_amt else coalesce((v_fxq->>'krw')::bigint, v_amt) end;
  if v_pay <= 0 or v_krw <= 0 then raise exception '티켓 요금이 없어 금액을 셀 수 없습니다' using errcode = '22023'; end if;
  -- 🆕 2026-10-19 대행비 스냅샷 — 환불 견적(D-31 = 결제액 − 대행비)이 **손님이 실제로 낸 대행비**를 빼야 한다.
  --   확정 외화 대행비(ovs_prices · overseas_agency_usd)면 그 값, 아니면 원화 정가 ÷ 환율 · agencyFee(원화)는 확정이면 round(확정값 × 환율)(amount_krw 와 같은 기준) — 둘이 어긋나면 환율 차액만큼 과·소환불(적대 리뷰).
  if v_cur = 'KRW' then
    v_agency_pay := coalesce(v_tp.agency_fee, 0); v_agency_krw := coalesce(v_tp.agency_fee, 0);
  elsif coalesce((v_fxq->'parts'->'agency'->>'fixed')::boolean, false) then
    v_agency_pay := (v_fxq->'parts'->'agency'->>'per')::numeric; v_agency_krw := round(v_agency_pay * p_fx)::bigint;
  else
    v_agency_pay := case v_cur when 'USD' then round(coalesce(v_tp.agency_fee, 0) / p_fx, 2) else round(coalesce(v_tp.agency_fee, 0) / p_fx) end;
    v_agency_krw := coalesce(v_tp.agency_fee, 0);
  end if;

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
  values (v_ev, v_team, v_name, v_phone, v_krw::int,
          case when v_cur = 'JPY' then v_pay::int end,
          v_cur, case when v_cur = 'KRW' then 1 else p_fx end, v_pay,
          least(now() + interval '72 hours', (v_date - 1)::timestamptz + interval '23 hours'), true)
  returning * into v_ch;

  v_pid := 'LINK-' || left(v_ch.id::text, 8) || '-' || (extract(epoch from now())*1000)::bigint;
  -- 좌석 홀드 — 용량 트리거가 잔여석을 검증한다 (모자라면 TICKET_SOLD_OUT 으로 전체 롤백)
  --   price 는 원화 정가 × 인원 그대로(매장 어드민이 읽는 칸 — 결제액이 아니다). payAmount 는 외화 정가(확정 또는 환산) — 공개 가격이라 실어도 된다.
  insert into public.tickets (user_id, restaurant_id, restaurant_name, ticket_product_id, ticket_type,
                              reservation_date, visit_time, party_size, price, status, purchase_id,
                              buyer_name, buyer_phone, extra_data, created_at)
  values (v_uid, v_tp.rest_id::text, v_tp.rest_name, p_ticket_id, coalesce(v_tp.type_class,''),
          p_visit_date, coalesce(p_visit_time, v_tp.time, ''), p_pax, v_amt, 'hold', v_pid,
          v_name, coalesce(v_phone,''),
          jsonb_build_object('linkInvite', true, 'chargeId', v_ch.id::text, 'token', v_ch.token,
                             'currency', v_cur, 'payAmount', v_pay, 'fx', p_fx,
                             'agencyFee', v_agency_krw, 'agencyPay', v_agency_pay, 'createdBy', v_uid,
                             'ovsFixed', coalesce((v_fxq->>'fixed_count')::int, 0)),
          now());

  return json_build_object('ok', true, 'charge_id', v_ch.id, 'token', v_ch.token,
                           'url', 'https://taam-app.vercel.app/pay/?t=' || v_ch.token,
                           'amount_krw', v_krw, 'list_krw', v_amt, 'pay_amount', v_pay, 'currency', v_cur,
                           'ovs_fixed', coalesce((v_fxq->>'fixed_count')::int, 0), 'fx_parts', coalesce(v_fxq->'parts', '{}'::jsonb),
                           'agency_pay', v_agency_pay, 'agency_krw', v_agency_krw,
                           'purchase_id', v_pid, 'expires_at', v_ch.expires_at, 'event_id', v_ev);
end;
$function$;
