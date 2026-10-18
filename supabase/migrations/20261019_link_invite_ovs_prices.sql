-- ═══════════════════════════════════════════════════════════════
-- 결제 링크(티켓 좌석) 외화 금액 = 티켓 업로드의 확정 해외 정가(ovs_prices) 우선 (2026-10-19 운영 요청)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: 티켓 업로드 폼에는 「$·¥ 자동 채우기」와 손으로 다듬은 확정 정가(ticket_products.ovs_prices · 1인 · meal/agency/wine)가 있는데,
--     $·¥ 결제 링크(taam_link_invite_create → taam_pay_link_create 'ticket')는 그것을 보지 않고 **원화 정가 ÷ 환율**로 금액을 지었다.
--     어드민이 $300 으로 적어 둔 식사비가 링크에서는 $271.74 처럼 나왔다(「업로드 때 수정한 게 링크에 반영이 안 된다」).
-- 무엇:
--   ① taam_ticket_price_fx(ticket, pax, currency, fx) — 항목(식사·대행·주류)마다 **확정 해외 정가가 있으면 그 값 × 인원**, 없는 항목만 원화 × 인원 ÷ 환율
--      (USD 센트 · JPY 정수 반올림). USD 대행비는 옛 overseas_agency_usd 도 폴백(앱 _fxTicketFixed 와 같은 규칙). 확정 항목이 하나도 없으면 종전 식 그대로
--      (round(원화 합계 ÷ 환율)) — 옛 링크와 금액이 바뀌지 않는다. 원화 링크는 아무것도 바뀌지 않는다.
--   ② taam_link_invite_create 가 ①을 쓴다. 외화 링크의 amount_krw 는 확정 항목이 있을 때 round(외화 × 환율)(정산 링크 외화 규칙 · 환불 견적도 이 값 기준),
--      없으면 종전처럼 원화 정가. 좌석 행 price 는 종전대로 원화 정가 × 인원(매장 어드민이 읽는 칸 — 정산 금액이 아니다) · extra_data.ovsFixed 에 확정 항목 수.
--   ⚠ taam_link_invite_create 는 라이브 함수 교체 — 본문 md5 가 저장소 원본(20260929_link_invite.sql · c53eceb383f113e7f7ef8b665ebe34aa)과 같을 때만.
--      이미 새 판(taam_ticket_price_fx 를 부름)이면 ✅ 그대로 · 모르는 판이면 ❌ 건너뜀(앱은 서버가 센 금액이 화면 예상과 다르면 경고한다).
--   금액 수동 설정(20261019_pay_link_ticket_override.sql · p.total)은 이 값 **위에서** 그대로 이긴다 — 정가 비교 기준이 확정 정가 기준으로 바뀌는 것뿐.
-- 회귀: bash sql/_test/t_link_invite.sh · bash sql/_test/t_pay_link.sh · 스크래치 paylink.js
-- ═══════════════════════════════════════════════════════════════

-- ── ① 외화 금액 계산 ──────────────────────────────────────────
create or replace function public.taam_ticket_price_fx(p_ticket_id text, p_pax int, p_currency text, p_fx numeric)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_tp public.ticket_products%rowtype;
  v_j jsonb; v_op jsonb;
  v_cur text := upper(coalesce(nullif(p_currency,''),'KRW'));
  v_n int := greatest(coalesce(p_pax,1),1);
  v_comp text; v_v numeric; v_krw_c bigint;
  v_fixed numeric := 0; v_unfixed bigint := 0; v_cnt int := 0;
  v_parts jsonb := '{}'::jsonb; v_list bigint; v_pay numeric;
begin
  select * into v_tp from public.ticket_products where id::text = p_ticket_id;
  if not found then return null; end if;
  v_list := (coalesce(v_tp.meal_fee,0) + coalesce(v_tp.agency_fee,0) + coalesce(v_tp.wine_min,0)) * v_n;
  if v_cur = 'KRW' then
    return jsonb_build_object('currency','KRW','pay', v_list, 'krw', v_list, 'list_krw', v_list, 'fixed_count', 0, 'parts', '{}'::jsonb);
  end if;
  if v_cur not in ('USD','JPY') or coalesce(p_fx,0) <= 0 then return null; end if;
  v_j := to_jsonb(v_tp);                                        -- 컬럼이 없는 DB 에서도 깨지지 않게 jsonb 로 읽는다
  v_op := case when jsonb_typeof(v_j->'ovs_prices') = 'object' then (v_j->'ovs_prices')->lower(v_cur) end;
  if jsonb_typeof(v_op) <> 'object' then v_op := null; end if;
  foreach v_comp in array array['meal','agency','wine'] loop
    v_krw_c := case v_comp when 'meal' then coalesce(v_tp.meal_fee,0) when 'agency' then coalesce(v_tp.agency_fee,0) else coalesce(v_tp.wine_min,0) end;
    if v_krw_c <= 0 and v_comp <> 'agency' then continue; end if;   -- 0원 항목은 건너뜀(대행비만 확정값이 있으면 센다) — 앱 _fxUnitSum 과 같은 규칙
    v_v := null;
    begin v_v := nullif(btrim(coalesce(v_op->>v_comp,'')),'')::numeric; exception when others then v_v := null; end;
    if (v_v is null or v_v <= 0) and v_cur = 'USD' and v_comp = 'agency' then
      begin v_v := nullif(btrim(coalesce(v_j->>'overseas_agency_usd','')),'')::numeric; exception when others then v_v := null; end;   -- 레거시 해외 대행비 예외
    end if;
    if v_v is not null and v_v > 0 then
      v_fixed := v_fixed + v_v; v_cnt := v_cnt + 1;
      v_parts := v_parts || jsonb_build_object(v_comp, jsonb_build_object('fixed', true, 'per', v_v, 'krw_per', v_krw_c));
    elsif v_krw_c > 0 then
      v_unfixed := v_unfixed + v_krw_c;
      v_parts := v_parts || jsonb_build_object(v_comp, jsonb_build_object('fixed', false, 'krw_per', v_krw_c));
    end if;
  end loop;
  v_pay := v_fixed * v_n + case when v_cur = 'USD' then round((v_unfixed * v_n)::numeric / p_fx, 2) else round((v_unfixed * v_n)::numeric / p_fx) end;
  v_pay := case when v_cur = 'USD' then round(v_pay, 2) else round(v_pay) end;
  return jsonb_build_object('currency', v_cur, 'pay', v_pay,
                            'krw', case when v_cnt > 0 then round(v_pay * p_fx)::bigint else v_list end,
                            'list_krw', v_list, 'fixed_count', v_cnt, 'fixed_per', v_fixed, 'unfixed_krw_per', v_unfixed, 'parts', v_parts);
end $$;
revoke all on function public.taam_ticket_price_fx(text, int, text, numeric) from public, anon;
grant execute on function public.taam_ticket_price_fx(text, int, text, numeric) to authenticated;
comment on function public.taam_ticket_price_fx(text, int, text, numeric) is
  '티켓의 외화 링크 금액 — 항목별 확정 해외 정가(ovs_prices · USD 대행비는 overseas_agency_usd 폴백) × 인원 + 없는 항목은 원화 ÷ 환율. 확정 항목 0 이면 종전 식(원화 합계 ÷ 환율) · krw 는 확정 항목이 있으면 round(외화×환율) 아니면 원화 정가.';

-- ── ② taam_link_invite_create 교체 (md5 가드) ──────────────────
drop table if exists _lio; create temp table _lio(name text primary key, status text);
do $do$
declare v_live text; v_src text;
begin
  select md5(p.prosrc), p.prosrc into v_live, v_src from pg_proc p where p.oid = to_regprocedure('public.taam_link_invite_create(text,text,text,integer,text,numeric,text,text)');
  if v_live is null then
    insert into _lio values ('taam_link_invite_create', '❌ 라이브에 함수가 없다 — 20260929_link_invite.sql 먼저');
  elsif v_src like '%taam_ticket_price_fx%' then
    insert into _lio values ('taam_link_invite_create', '✅ 이미 새 판(확정 해외 정가)');
  elsif v_live <> 'c53eceb383f113e7f7ef8b665ebe34aa' then
    insert into _lio values ('taam_link_invite_create', '❌ 라이브 본문이 저장소 원본과 다르다 — 건너뜀 (md5 ' || v_live || ')');
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
                             'agencyFee', coalesce(v_tp.agency_fee,0), 'createdBy', v_uid,
                             'ovsFixed', coalesce((v_fxq->>'fixed_count')::int, 0)),
          now());

  return json_build_object('ok', true, 'charge_id', v_ch.id, 'token', v_ch.token,
                           'url', 'https://taam-app.vercel.app/pay/?t=' || v_ch.token,
                           'amount_krw', v_krw, 'list_krw', v_amt, 'pay_amount', v_pay, 'currency', v_cur,
                           'ovs_fixed', coalesce((v_fxq->>'fixed_count')::int, 0), 'fx_parts', coalesce(v_fxq->'parts', '{}'::jsonb),
                           'purchase_id', v_pid, 'expires_at', v_ch.expires_at, 'event_id', v_ev);
end;
$b$
    $fn$;
    insert into _lio values ('taam_link_invite_create', '✅ 교체 (확정 해외 정가 우선)');
  end if;
end $do$;

-- ── 확인 — 한 표 ──
select '① taam_link_invite_create 교체' as 항목, status as 결과 from _lio
union all select '② taam_ticket_price_fx · anon 없음', case when to_regprocedure('public.taam_ticket_price_fx(text,integer,text,numeric)') is not null
             and not has_function_privilege('anon', 'public.taam_ticket_price_fx(text,integer,text,numeric)', 'execute') then '✅' else '❌' end
union all select '③ 새 판이 확정 정가를 본다', case when exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_link_invite_create(text,text,text,integer,text,numeric,text,text)') and p.prosrc like '%taam_ticket_price_fx%') then '✅' else '❌ 옛 판 — 외화 링크가 환율 환산으로 남는다' end
union all select '④ ovs_prices 컬럼', case when exists (select 1 from information_schema.columns where table_schema='public' and table_name='ticket_products' and column_name='ovs_prices') then '✅' else '⚠ 없음 — sql/ticket_overseas_prices.sql (없어도 함수는 환산으로 돈다)' end
order by 1;
