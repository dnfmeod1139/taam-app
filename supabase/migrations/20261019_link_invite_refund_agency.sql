-- ═══════════════════════════════════════════════════════════════
-- 링크 초대 환불 견적 — 외화 링크는 손님이 낸 대행비(결제 통화)로 센다 (2026-10-19 적대 리뷰 · 확정 해외 정가 2차)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 20261019_link_invite_ovs_prices.sql 뒤 외화 링크의 amount_krw 는 round(외화×환율)인데 좌석 행 extra_data.agencyFee 는 원화 정가 대행비 그대로였다.
--     환불 견적 D-31(taam_link_invite_refund_quote · 20261018 판)은 「amount_krw − agencyFee×인원」을 원화로 빼고 다시 ÷환율 해 토스 부분취소 금액을 만드니,
--     확정 $120 대행비 링크($1,860 · 2인)에서 ₩300,000(원화 정가)을 빼 $1,642.61 을 돌려줬다 — 규정($1,860 − $240 = $1,620.00)보다 $22.61 과환불.
--     옛 overseas_agency_usd 만 있고 원화 대행비가 0 인 회차는 환불 불가인 대행비 $100 이 통째로 돌아갔다. 반대 방향(확정 대행비×환율 < 원화 대행비)이면 소환불.
-- 무엇:
--   ① taam_link_invite_create(확정 정가 판 → 대행비 스냅샷 판): 좌석 행 extra_data 에 agencyPay(1인 · 결제 통화 — 확정 외화 대행비 또는 원화÷환율) ·
--      agencyFee(1인 · 원화 — 확정이면 round(확정값×환율) · 아니면 원화 정가 · amount_krw 와 같은 기준). 응답에 agency_pay · agency_krw. 원화 링크는 종전과 같다.
--   ② taam_link_invite_refund_quote(20261018 판 → 결제 통화 판): 외화 링크의 D-31 은 refund_amount = pay_amount − agencyPay×인원(결제 통화 · USD 센트/JPY 정수) · refund_krw = round(×환율).
--      30분 안·admin_full 은 refund_amount = pay_amount 그대로(종전 round(amount_krw÷환율)이 센트 어긋나 전액인데 부분취소가 되던 것도 닫힘). 원화 링크는 종전 식 그대로.
--      agencyPay 스냅샷이 없는 행(확정 정가 판이 라이브였던 2026-10-18 10:13~ 이 파일 전)은 지금 회차 요금(taam_ticket_price_fx · 확정이면 확정값)으로 어림한다.
--   ⚠ 둘 다 라이브 함수 교체 — 본문 md5 가 저장소 직전 판(create 46f7b200874294c8758a4f1b405208d5 · quote ace3bccb056481ee7125193bc4c9ee73)과 같을 때만. 이미 새 판(agencyPay)이면 ✅ · 모르는 판 ❌ 건너뜀.
-- 회귀: bash sql/_test/t_link_invite.sh · bash sql/_test/t_pay_link.sh
-- ═══════════════════════════════════════════════════════════════

drop table if exists _lir; create temp table _lir(name text primary key, status text);
do $do$
declare v_live text; v_src text;
begin
  -- ① taam_link_invite_create
  select md5(p.prosrc), p.prosrc into v_live, v_src from pg_proc p where p.oid = to_regprocedure('public.taam_link_invite_create(text,text,text,integer,text,numeric,text,text)');
  if v_live is null then
    insert into _lir values ('taam_link_invite_create', '❌ 라이브에 함수가 없다 — 20260929_link_invite.sql 먼저');
  elsif v_src like '%agencyPay%' then
    insert into _lir values ('taam_link_invite_create', '✅ 이미 새 판(대행비 스냅샷)');
  elsif v_live <> '46f7b200874294c8758a4f1b405208d5' then
    insert into _lir values ('taam_link_invite_create', '❌ 라이브 본문이 저장소 확정 정가 판과 다르다 — 건너뜀 (md5 ' || v_live || ') · 20261019_link_invite_ovs_prices.sql 먼저');
  else
    execute $fn$
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
as $b$
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
$b$;
    $fn$;
    insert into _lir values ('taam_link_invite_create', '✅ 교체 (대행비 스냅샷 agencyPay·agencyFee)');
  end if;

  -- ② taam_link_invite_refund_quote
  select md5(p.prosrc), p.prosrc into v_live, v_src from pg_proc p where p.oid = to_regprocedure('public.taam_link_invite_refund_quote(text)');
  if v_live is null then
    insert into _lir values ('taam_link_invite_refund_quote', '❌ 라이브에 함수가 없다 — 20261018_pay_link.sql 먼저');
  elsif v_src like '%agencyPay%' then
    insert into _lir values ('taam_link_invite_refund_quote', '✅ 이미 새 판(결제 통화 견적)');
  elsif v_live <> 'ace3bccb056481ee7125193bc4c9ee73' then
    insert into _lir values ('taam_link_invite_refund_quote', '❌ 라이브 본문이 저장소 20261018 판과 다르다 — 건너뜀 (md5 ' || v_live || ')');
  else
    execute $fn$
create or replace function public.taam_link_invite_refund_quote(p_charge_id text)
returns json language plpgsql stable security definer set search_path = public as $b$
declare
  v_ch  public.kashikiri_charges%rowtype;
  v_tk  public.tickets%rowtype;
  v_days int; v_agency bigint := 0; v_refund bigint := 0; v_policy text; v_visit date;
  v_cur text; v_pax int; v_agency_pay numeric := 0; v_refund_amt numeric := 0; v_fxq jsonb;
begin
  select * into v_ch from public.kashikiri_charges where id::text = p_charge_id;
  if not found then raise exception 'CHARGE_NOT_FOUND' using errcode = 'P0002'; end if;
  if v_ch.status <> 'paid' then
    return json_build_object('charge_id', v_ch.id, 'status', v_ch.status, 'refund_krw', 0, 'refund_amount', 0, 'policy', 'not_paid');
  end if;
  v_cur := upper(coalesce(v_ch.pay_currency, 'KRW'));
  if coalesce(v_ch.purpose,'') in ('membership','custom') and not coalesce(v_ch.link_invite,false) then
    v_refund := v_ch.amount_krw; v_refund_amt := coalesce(v_ch.pay_amount, v_ch.amount_krw); v_policy := 'admin_full';
  else
    select * into v_tk from public.tickets where purchase_id like 'LINK-%' and extra_data->>'chargeId' = v_ch.id::text order by created_at desc limit 1;
    v_pax := greatest(coalesce(v_tk.party_size,1),1);
    v_agency := coalesce((v_tk.extra_data->>'agencyFee')::bigint, 0) * v_pax;
    -- 🆕 2026-10-19 외화 링크는 **결제 통화**로 센다 — 손님이 낸 대행비(agencyPay 스냅샷 · 확정 외화 또는 원화÷환율)를 빼고 원화는 round(외화×환율).
    --   종전 「amount_krw − 원화 정가 대행비」는 확정 외화 대행비(amount_krw = round(외화×환율))와 기준이 달라 환율 차액만큼 과·소환불했다(적대 리뷰).
    --   스냅샷이 없는 옛 행(2026-10-18 확정 정가 판 사이)은 지금 회차 요금으로 어림 — 확정이면 확정값, 아니면 원화 대행비 ÷ 환율.
    if v_cur <> 'KRW' then
      v_agency_pay := nullif(btrim(coalesce(v_tk.extra_data->>'agencyPay','')), '')::numeric;
      if v_agency_pay is null then
        begin v_fxq := public.taam_ticket_price_fx(v_tk.ticket_product_id::text, 1, v_cur, v_ch.pay_fx); exception when others then v_fxq := null; end;
        v_agency_pay := case when coalesce((v_fxq->'parts'->'agency'->>'fixed')::boolean, false) then (v_fxq->'parts'->'agency'->>'per')::numeric
                             when coalesce(v_ch.pay_fx, 0) > 0 then (case v_cur when 'USD' then round(coalesce((v_tk.extra_data->>'agencyFee')::numeric, 0) / v_ch.pay_fx, 2)
                                                                                 else round(coalesce((v_tk.extra_data->>'agencyFee')::numeric, 0) / v_ch.pay_fx) end)
                             else 0 end;
      end if;
      v_agency_pay := coalesce(v_agency_pay, 0) * v_pax;
    end if;
    begin v_visit := to_date(v_tk.reservation_date, 'YYYY.MM.DD'); exception when others then v_visit := null; end;
    v_days := case when v_visit is null then null else (v_visit - (now() at time zone 'Asia/Seoul')::date) end;
    if v_ch.approved_at is not null and now() - v_ch.approved_at <= interval '30 minutes' then
      v_refund := v_ch.amount_krw; v_refund_amt := coalesce(v_ch.pay_amount, v_ch.amount_krw); v_policy := 'within_30min_full';
    elsif v_days is null or v_days >= 31 then
      if v_cur = 'KRW' then
        v_refund := greatest(0, v_ch.amount_krw - v_agency); v_refund_amt := v_refund;
      else
        v_refund_amt := greatest(0, coalesce(v_ch.pay_amount, 0) - v_agency_pay);
        v_refund_amt := case v_cur when 'USD' then round(v_refund_amt, 2) else round(v_refund_amt) end;
        v_refund := round(v_refund_amt * coalesce(v_ch.pay_fx, 0))::bigint;
      end if;
      v_policy := 'd31_minus_agency';
    else
      v_refund := 0; v_refund_amt := 0; v_policy := 'after_d30_none';
    end if;
  end if;
  return json_build_object('charge_id', v_ch.id, 'status', v_ch.status, 'currency', v_ch.pay_currency, 'purpose', coalesce(v_ch.purpose,'custom'),
    'paid_krw', v_ch.amount_krw, 'paid_amount', v_ch.pay_amount, 'agency_krw', v_agency, 'agency_pay', v_agency_pay, 'days_left', v_days,
    'refund_krw', v_refund,
    'refund_amount', case when v_cur = 'KRW' then v_refund
                          when v_cur = 'JPY' then round(v_refund_amt)
                          else round(v_refund_amt, 2) end,
    'policy', v_policy, 'payment_key', v_ch.payment_key);
end $b$;
    $fn$;
    insert into _lir values ('taam_link_invite_refund_quote', '✅ 교체 (외화는 결제 통화로 · agencyPay)');
  end if;
end $do$;

-- ── 확인 — 한 표 ──
select '① ' || name || ' 교체' as 항목, status as 결과 from _lir
union all select '③ 두 판이 agencyPay 를 안다', case when exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_link_invite_create(text,text,text,integer,text,numeric,text,text)') and p.prosrc like '%agencyPay%')
             and exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_link_invite_refund_quote(text)') and p.prosrc like '%agencyPay%') then '✅' else '❌ 옛 판 — 외화 링크 D-31 환불이 원화 대행비 기준으로 남는다' end
union all select '④ 의존 — taam_ticket_price_fx', case when to_regprocedure('public.taam_ticket_price_fx(text,integer,text,numeric)') is not null then '✅' else '❌ 20261019_link_invite_ovs_prices.sql 먼저' end
union all select '⑤ 스냅샷 없는 외화 LINK- 행(결제됨 · 어림 견적 대상)', (select count(*) from public.tickets t where t.purchase_id like 'LINK-%' and coalesce(t.status,'') in ('active','hold') and coalesce(t.extra_data->>'currency','KRW') <> 'KRW' and (t.extra_data ? 'agencyPay') = false)::text || '건'
order by 1;
