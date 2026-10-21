-- ═══════════════════════════════════════════════════════════════
-- 📊 티켓 판매 현황 — 슈퍼어드민 보고 RPC (2026-10-21)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). 함수만 만든다 — 데이터는 바꾸지 않는다. 마지막 표에 ❌ 가 없어야 정상.
-- 왜: 「티켓 전체나 월별 판매금액을 볼 수 있는 기능」. 판매가 여러 갈래로 남는다(진단 20261021_diag_sales_shape.sql · 라이브):
--     회원 구매는 홀드 id(PAYH-)를 그대로 둔 채 active 로 바뀐다(PAYC- 는 카드 폴백 INSERT 뿐) · 초대는 reservation_invites(paid_at) ·
--     결제 링크·대관 정산은 kashikiri_charges · 수동 입력(MAN-)·수동 기록(daegwan_manual)은 어드민이 적은 금액.
-- 규칙: **판매 하나 = 결제 하나**, 돈의 출처는 하나만(INV- 행·원장 차감·LINK-/KSK- 행 price 를 더하지 않는다).
--   환불은 그 판매에 붙인다(원장 ticket_refund 를 metadata.purchase_id 로 · 종류: 취소/위약/방문 후 반환/인원 줄임 · 정정(fix)·카드 승인 되돌림은 환불 아님) ·
--   카드 환불은 extra_data.card_refund_pending · 링크·정산은 refund_krw. 순판매 = 판매 − 취소·위약·인원 줄임 환불(방문 후 반환은 따로).
--   대행비(TAAM 수익) = 방문 후 반환은 기록된 agency_held · 위약은 기록이 0 보다 클 때만 그 값 · 그 밖은 1인 대행비(회차) × 인원(순판매 이하).
--   결제일(KST) = 카드 승인 → 원장 첫 결제 → confirmed_at → created_at · 방문일 = reservation_date → 회차 날짜.
-- 금액은 **회원이 못 쓰는 기록만** 믿는다(적대 리뷰 2026-10-21). 회원은 자기 tickets 의 extra_data·홀드 price 를, 자기 초대 행 전 칸을,
--   원장에 ₩0·음수 줄(metadata 아무거나)을 쓸 수 있다 — 그래서:
--   · 앱 구매 판매액 = **같은 회원**의 원장 결제 줄(음수 · 정정·자동 되돌림 제외) + **그 회원의** 카드 주문(payment_orders paid · 한 주문은 한 판매).
--     tickets.price · extra_data 금액 · pax_changes 는 근거로 쓰지 않는다(정가와 다르면 표시만). 원장 금액이 0 이하인 줄은 아무 뜻도 없다.
--     돈 기록이 없는 살아 있는 행은 합계 밖 「확인 필요」(app_no_money_record) · 취소된 것은 조용히 뺀다(위조 홀드).
--   · 초대 판매액 = 초대받은 회원의 원장 결제 줄 − 자동 되돌림 · 대행비는 회차 대행비 이하 · 원장이 없거나 되돌려졌는데 paid 면 「확인 필요」.
--   · 'returned'(방문 후 반환) 환불이 방문 전날보다 앞이면 취소로 센다(return_before_visit).
--   · 결제 링크 memberUid 는 uuid 모양일 때만 · 통화는 KRW/USD/JPY 만 · 시각은 2020~2100 만(_taam_sr_ts).
--   테스트 계정(profiles.is_test)의 판매는 기본 제외(구매자 기준 — 운영 행의 주인인 어드민 계정으로 거르지 않는다).
-- 반환: jsonb 한 덩어리 {ok, v, basis, from, to, today, generated_at, rows[], excluded{}, exceptions[]} — table 로 돌려주면 PostgREST 행 제한(1000)에 잘린다.
-- 호출: 슈퍼어드민 · SQL Editor · service_role 만(_taam_fee_caller_ok) — 그 밖은 FORBIDDEN. anon 실행 권한 없음.
-- 회귀: bash sql/_test/t_ticket_sales.sh
-- ═══════════════════════════════════════════════════════════════

-- 회원이 쓸 수 있는 extra_data 의 숫자를 안전하게 읽는다 — 'abc' 한 줄이 보고서 전체를 22P02 로 깨면 안 된다
create or replace function public._taam_sr_int(p text)
returns bigint language sql immutable as $$
  select case when p ~ '^\s*-?\d{1,12}(\.\d+)?\s*$' then round(p::numeric)::bigint end   -- 12자리(₩9,999억)까지 — 곱셈에서 bigint 가 넘치지 않게
$$;
create or replace function public._taam_sr_ts(p text)
returns timestamptz language plpgsql stable as $$
begin
  if p is null or btrim(p) = '' then return null; end if;
  if p::timestamptz < timestamptz '2020-01-01' or p::timestamptz >= timestamptz '2100-01-01' then return null; end if;   -- infinity·만 년 뒤 같은 값은 버린다(화면·CSV 가 깨진다)
  return p::timestamptz;
exception when others then return null;
end $$;

create or replace function public.taam_ticket_sales_report(
  p_from date default null, p_to date default null,
  p_basis text default 'paid', p_include_test boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_basis text := case when lower(coalesce(p_basis,'')) = 'visit' then 'visit' else 'paid' end;
  v_test  uuid[];
  v_led   jsonb := '{}'::jsonb;   -- purchase_id → 원장 요약
  v_iled  jsonb := '{}'::jsonb;   -- invite_id → 초대 결제 원장 요약
  v_all   jsonb := '[]'::jsonb;
  v_exc   jsonb := '[]'::jsonb;
  v_xm    jsonb := '{}'::jsonb;   -- 티켓 판매가 아닌 결제 (멤버십·자유 금액·취소된 수동 입력)
  v_rows  jsonb;
  v_skip  jsonb;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then
    raise exception 'FORBIDDEN: 슈퍼어드민만 볼 수 있습니다' using errcode = '42501';
  end if;
  if p_from is not null and p_to is not null and p_to <= p_from then
    raise exception 'BAD_RANGE: 끝 날짜가 시작 날짜보다 뒤여야 합니다' using errcode = '22023';
  end if;

  select coalesce(array_agg(p.id), '{}') into v_test
    from public.profiles p where coalesce(to_jsonb(p)->>'is_test', '') = 'true';

  -- ── 원장 요약: (purchase_id, 그 줄의 회원) 마다 ──
  --   ⚠ 적대 리뷰: 회원은 taam_apply_deposit_delta 로 **₩0·음수 줄에 아무 metadata 나** 실을 수 있다(양수만 상한 검사).
  --   그래서 ① 돈이 실제로 움직인 줄만 센다 — 구매는 amount < 0, 환불은 amount > 0 ② 판매의 주인(티켓 user_id · 초대 invitee)과 같은 회원의 줄만 붙인다.
  --   한 환불이 주머니 둘(멤버십·일반)로 나뉘어도 metadata 는 같은 객체 → 금액은 더하고 agency_held 는 max 로 한 번만.
  with d as (
    select d.metadata->>'purchase_id' as pid, d.user_id as uid, d.amount::bigint as amt, d.created_at, d.metadata m,
           case
             when d.change_type in ('ticket_purchase','ticket_pax_change') and d.amount < 0 then 'buy'   -- 결제(인원 늘림 추가 결제 포함)
             when d.amount <= 0 then 'skip'                                              -- 돈이 안 움직인 줄 · 0원 환불 줄은 환불이 아니다
             when d.change_type = 'ticket_pax_change' then 'pax'
             when d.change_type <> 'ticket_refund' then 'skip'
             when d.metadata ? 'fix' then 'skip'                                         -- 수동 정정 줄 (2026-09-14 이중 차감 등)
             when coalesce(d.metadata->>'reason','') in ('capacity_auto_refund','duplicate_purchase','time_conflict') then 'rev'
             when d.metadata ? 'order_id' and not (d.metadata ? 'refund_type') and not (d.metadata ? 'cancel_refund') then 'rev'  -- 카드 승인 뒤 좌석 상실·예치금 부족 되돌림
             when coalesce(d.metadata->>'cancel_refund','') = 'true' then 'cancel'
             when d.metadata->>'refund_type' = 'penalty' then 'penalty'
             when d.metadata->>'refund_type' = 'returned' then 'ret'
             else 'other'
           end as k
      from public.deposit_transactions d
     where d.change_type in ('ticket_purchase','ticket_refund','ticket_pax_change')
       and coalesce(d.metadata->>'purchase_id','') <> '' and d.user_id is not null
  ), g as (
    select pid, uid,
           -sum(amt) filter (where k = 'buy')                    as buy,
           min(created_at) filter (where k = 'buy')              as buy_at,
           sum(amt) filter (where k = 'rev')                     as rev,
           sum(amt) filter (where k = 'cancel')                  as cancel,
           sum(amt) filter (where k = 'penalty')                 as penalty,
           sum(amt) filter (where k = 'ret')                     as ret,
           min(created_at) filter (where k = 'ret')              as ret_at,
           sum(amt) filter (where k = 'other')                   as other,
           sum(amt) filter (where k = 'pax')                     as pax,
           max(created_at) filter (where k in ('cancel','penalty','ret','other','pax')) as ref_at,
           max(least(greatest(coalesce(public._taam_sr_int(m->>'agency_held'), 0), 0), 999999999999)) filter (where k in ('ret','penalty') and m ? 'agency_held') as ag_held
      from d where k <> 'skip' group by pid, uid
  )
  select coalesce(jsonb_object_agg(pid || '|' || uid, jsonb_strip_nulls(jsonb_build_object(
           'buy', buy, 'buy_at', buy_at, 'rev', rev, 'cancel', cancel, 'penalty', penalty, 'ret', ret, 'ret_at', ret_at,
           'other', other, 'pax', pax, 'ref_at', ref_at, 'ag_held', ag_held))), '{}'::jsonb)
    into v_led from g;

  -- ── 초대 결제 원장: (invite_id, 회원) 마다 — 돈이 빠진 줄(amount < 0)만 ──
  select coalesce(jsonb_object_agg(iid || '|' || uid, jsonb_build_object('buy', buy, 'buy_at', buy_at, 'pids', pids)), '{}'::jsonb)
    into v_iled
    from (select d.metadata->>'invite_id' as iid, d.user_id as uid, -sum(d.amount)::bigint as buy, min(d.created_at) as buy_at,
                 coalesce(jsonb_agg(distinct d.metadata->>'purchase_id') filter (where coalesce(d.metadata->>'purchase_id','') <> ''), '[]'::jsonb) as pids
            from public.deposit_transactions d
           where d.change_type = 'ticket_purchase' and d.amount < 0 and coalesce(d.metadata->>'invite_id','') <> '' and d.user_id is not null
           group by 1, 2) z;

  -- ═══ A. 앱 구매 (회원 · 예치금 / 카드 / 카드+예치금) ═══
  --   확정 구매는 PAYH- id 를 그대로 둔 채 status 만 hold→active 다(PAYC- 는 카드 폴백 INSERT 뿐). 접두어 없는 옛 행도 같다.
  --   ⚠ 적대 리뷰: 회원은 자기 행의 price(홀드 INSERT 때)·extra_data 를 쓸 수 있다. 그래서 금액은 **회원이 못 쓰는 돈 기록**에서만 —
  --     판매액 = 그 회원의 원장 결제(− 카드 되돌림) + 그 회원의 결제된 카드 주문. 돈 기록이 없으면 판매가 아니다(살아 있는 행이면 「확인 필요」로).
  --     extra_data 의 pax_changes·confirmed_at·server_confirmed·guest_reject·deposit_return·agencyFee 는 금액·날짜·상태에 쓰지 않는다.
  with tk as (
    select distinct on (t.purchase_id) t.*
      from public.tickets t
     where coalesce(t.purchase_id,'') <> ''
       and t.purchase_id !~ '^(INV|INVH|LINK|KSK|MAN)-'
       and coalesce(t.ticket_product_id,'') !~ '^inv-'                 -- 옛 앱 INSERT 초대 행
       and lower(coalesce(t.status,'')) not in ('hold','expired','manual','failed')
       and coalesce(t.price,0) > 0
       and t.user_id is not null
       and (t.purchase_id ~ '^PAY' or not (                           -- PAY 는 플래그가 있어도 회원 행 (20261018 규칙)
              coalesce(t.extra_data->>'manualEntry','') in ('true','1') or coalesce(t.extra_data->>'inviteHold','') in ('true','1')
           or coalesce(t.extra_data->>'kashikiri','')   in ('true','1') or coalesce(t.extra_data->>'linkInvite','') in ('true','1')
           or coalesce(t.extra_data->>'invitePaid','')  in ('true','1')))
     order by t.purchase_id, (lower(coalesce(t.status,'')) not in ('cancelled','canceled')) desc, t.created_at desc
  ), po1 as (   -- 한 카드 주문은 한 판매에만 — 같은 order_id 를 둘이 주장하면 먼저 만든 행만
    select distinct on (tk.extra_data->>'order_id') tk.purchase_id as pid, po.*
      from tk join public.payment_orders po on po.order_id = tk.extra_data->>'order_id' and po.user_id = tk.user_id and po.status = 'paid'
     order by tk.extra_data->>'order_id', tk.created_at
  ), b as (
    select t.*, coalesce(t.extra_data,'{}'::jsonb) as x, tp.meal_fee, tp.agency_fee, tp.wine_min,
           to_jsonb(tp) as tpj, to_jsonb(po1) as poj, v_led -> (t.purchase_id || '|' || t.user_id::text) as l,
           pr.display_name as buyer, r.name as rname
      from tk t
      left join public.ticket_products tp on tp.id::text = t.ticket_product_id
      left join po1 on po1.pid = t.purchase_id
      left join public.profiles pr on pr.id = t.user_id
      left join public.restaurants r on r.id::text = coalesce(nullif(t.restaurant_id::text,''), to_jsonb(tp)->>'rest_id')
  ), c as materialized (
    select b.*,
           greatest(coalesce((l->>'buy')::bigint, 0) - coalesce((l->>'rev')::bigint, 0), 0) as dep_ev,
           case when poj is not null then least(coalesce(public._taam_sr_int(poj->>'settle_krw'),
                              case when upper(coalesce(poj->>'currency','KRW')) = 'KRW' then public._taam_sr_int(poj->>'amount') end, 0), 999999999999) else 0 end as card,
           lower(coalesce(status,'')) in ('cancelled','canceled','refunded') as is_cx,
           coalesce(public._taam_pu_visit_date(reservation_date), public._taam_pu_visit_date(tpj->>'date')) as vdate,
           greatest(coalesce(party_size, 1), 1) as pax_n,
           -- 인원 줄임 전 인원 — 표시용(회원이 쓸 수 있는 칸이라 1~99 만 · 금액엔 안 쓴다)
           case when jsonb_typeof(coalesce(extra_data,'{}'::jsonb)->'pax_changes') = 'array'
                 and coalesce(public._taam_sr_int(extra_data->'pax_changes'->0->>'from'), 0) between 1 and 99
                then public._taam_sr_int(extra_data->'pax_changes'->0->>'from')::int end as pax_from
      from b
  ), e as (
    select c.*,
           dep_ev + card as gross,
           coalesce(pax_from, pax_n) as pax0,
           coalesce((l->>'pax')::bigint, 0) as rf_pax,
           -- 「방문 후 반환」은 방문일이 지난 뒤의 환불만 — 그 전의 'returned' 줄은 취소로 센다(회원이 자기 취소 환불에 붙인 라벨로 순판매가 부풀지 않게)
           case when l->>'ret' is not null and (vdate is null or (((l->>'ret_at')::timestamptz) at time zone 'Asia/Seoul')::date >= vdate - 1) then (l->>'ret')::bigint else 0 end as ret_ok,
           case when l->>'ret' is not null and not (vdate is null or (((l->>'ret_at')::timestamptz) at time zone 'Asia/Seoul')::date >= vdate - 1) then (l->>'ret')::bigint else 0 end as ret_early,
           coalesce(public._taam_sr_int(x->'card_refund_pending'->>'amount'), 0) as crp_amt,
           coalesce(x->'card_refund_pending'->>'status', 'pending') as crp_st
      from c
  ), f as (
    select e.*,
           case when l->>'penalty' is not null then 'penalty' when ret_ok > 0 then 'returned' when is_cx then 'cancelled' end as proc,
           least(greatest(crp_amt, 0), card) as crp                                    -- 카드 환불 대기는 카드 몫까지만
      from e
  ), h as materialized (
    select f.*,
           coalesce((l->>'cancel')::bigint,0) + coalesce((l->>'other')::bigint,0) + ret_early + case when proc in ('cancelled','returned') or (proc is null and is_cx) then crp else 0 end as rf_cancel,
           coalesce((l->>'penalty')::bigint,0) + case when proc = 'penalty' then crp else 0 end as rf_penalty,
           case when crp_st <> 'done' then crp else 0 end as rf_card_pending,
           least(coalesce(agency_fee, public._taam_sr_int(x->>'agencyFee'), 0), 99999999)::bigint as ag_per,   -- 회차 요금 먼저(스냅샷은 회원이 쓸 수 있다)
           (l->>'ag_held')::bigint as ag_rec
      from f
  ), k as (
    select h.*, gross - rf_cancel - rf_penalty - rf_pax as net from h
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'k', purchase_id, 'ch', 'app',
      'pm', case when card <= 0 then 'deposit' when dep_ev <= 0 then 'card' else 'mixed' end,
      'st', case when lower(coalesce(status,'')) = 'pending_confirm' then 'guest_pending' else coalesce(proc, 'active') end,
      'x',  case when lower(coalesce(status,'')) = 'pending_confirm' then 'guest_pending' end,
      'paid_at', coalesce(case when poj is not null then public._taam_sr_ts(poj->>'approved_at') end, public._taam_sr_ts(l->>'buy_at'), created_at),
      'visit', vdate,
      'time', coalesce(nullif(visit_time,''), tpj->>'time'),
      'rest_id', coalesce(nullif(restaurant_id::text,''), tpj->>'rest_id'),
      'rest', coalesce(rname, nullif(restaurant_name,''), tpj->>'rest_name'),
      'uid', user_id, 'buyer', coalesce(nullif(btrim(buyer),''), buyer_name),
      'test', user_id = any(v_test),
      'pax', pax_n, 'pax0', case when pax_from is not null and pax_from <> pax_n then pax_from end,
      'cur', case when upper(coalesce(x->>'card_currency','')) ~ '^(USD|JPY)$' and card > 0 then upper(x->>'card_currency') else 'KRW' end,
      'fx_amt', case when upper(coalesce(x->>'card_currency','')) ~ '^(USD|JPY)$' and card > 0 and dep_ev = 0
                     then (select v from (select public._taam_sr_int(x->>'card_amount_fx')::numeric as v) q where v between 0 and 99999999) end,
      'gross', gross,
      'meal', case when meal_fee is not null then meal_fee::bigint * pax0 end,
      'wine', case when wine_min is not null then wine_min::bigint * pax0 end,
      'ag_gross', ag_per * pax0,
      'bd', case when meal_fee is null then 'none'
                 when (coalesce(meal_fee,0) + ag_per + coalesce(wine_min,0))::bigint * pax0 = gross then 'product'
                 else 'mismatch' end,
      'dep', dep_ev, 'card', card,
      'rf_cancel', rf_cancel, 'rf_penalty', rf_penalty, 'rf_pax', rf_pax, 'rf_return', ret_ok,
      'rf_card_pending', rf_card_pending, 'rf_at', l->>'ref_at',
      'net', net, 'held', net - ret_ok,
      -- 대행비: 반환은 기록된 보유액(0 = 돌려줌) · 위약은 기록이 0 보다 클 때만(0 이면 보유 몫을 대행비만큼으로) · 그 밖은 1인 대행비 × 인원 — 언제나 정가·순판매 이하
      'agency', greatest(0, least(case when proc = 'returned' and ag_rec is not null then ag_rec
                                       when proc = 'penalty' and coalesce(ag_rec, 0) > 0 then ag_rec
                                       else ag_per * pax_n end, ag_per * pax0, greatest(net, 0))),
      'ag_state', case when proc = 'returned' and ag_rec is not null then case when ag_rec = 0 then 'waived' else 'kept' end
                       when proc in ('cancelled','penalty') then 'kept' else 'planned' end,
      'visit_st', to_jsonb(k)->>'visit_status',
      'ref', purchase_id,
      'flags', to_jsonb(array_remove(array[
         case when net < 0 then 'net_negative' end,
         case when gross <> coalesce(price, 0) and rf_pax = 0 and pax_from is null then 'price_differs' end,
         case when ret_early > 0 then 'return_before_visit' end,
         case when crp_amt > crp then 'card_refund_capped' end,
         case when pax_from is not null then 'pax_changed' end,
         case when public._taam_sr_int(x->>'agencyFee') is not null and agency_fee is not null and public._taam_sr_int(x->>'agencyFee') <> agency_fee then 'agency_snapshot_differs' end,
         case when purchase_id ~ '^PAYC-' then 'payc_fallback' end
      ], null))
    )) order by purchase_id) filter (where gross > 0), '[]'::jsonb),
    -- 돈 기록이 없는 판매 행 — 합계에 넣지 않고 「확인 필요」로 (취소된 행은 버려진 홀드·되돌린 결제라 조용히 넘긴다)
    coalesce(jsonb_agg(jsonb_build_object('kind', 'app_no_money_record', 'ref', purchase_id, 'at', created_at, 'krw', price,
                                          'note', coalesce(rname, restaurant_name, '') || ' · ' || coalesce(vdate::text, '') || ' · ' || coalesce(status, '')))
             filter (where gross <= 0 and not is_cx and lower(coalesce(status,'')) <> 'pending_confirm'), '[]'::jsonb)
    into v_rows, v_skip from k;
  v_all := v_all || v_rows;
  v_exc := v_exc || v_skip;

  -- ═══ B. 초대 (예치금) — 그 회원(invitee)의 원장 결제가 판매액이다. INV- 행 price · reservation_invites.total_amount 는 회원이 고칠 수 있는 칸이라 금액으로 쓰지 않는다 ═══
  if to_regclass('public.reservation_invites') is not null then
    with i as (
      select i.*, to_jsonb(i) as ij, v_iled -> (i.id::text || '|' || i.invitee_user_id::text) as il
        from public.reservation_invites i where i.paid_at is not null and i.invitee_user_id is not null
    ), j as (
      select i.*, tk.purchase_id as tk_pid, tk.status as tk_status,
             tk.reservation_date as tk_date, tk.party_size as tk_pax, to_jsonb(tk)->>'visit_status' as visit_st,
             tp.agency_fee as tp_agency, tp.meal_fee as tp_meal, tp.wine_min as tp_wine,
             pr.display_name as buyer, r.name as rname,
             -- 이 초대가 만든 INV- 구매 id 전부 (원장 + 티켓 행)
             (select coalesce(jsonb_agg(distinct p), '[]'::jsonb) from (
                select jsonb_array_elements_text(coalesce(i.il->'pids','[]'::jsonb)) as p
                union select tk.purchase_id where tk.purchase_id is not null) z) as pids
        from i
        left join lateral (select * from public.tickets t
                            where t.purchase_id like 'INV-%'
                              and (t.extra_data->>'inviteId' = i.id::text
                                   or (t.extra_data->>'inviteId' is null and t.purchase_id like 'INV-' || left(i.id::text,8) || '-%'))
                            order by (lower(coalesce(t.status,'')) not in ('cancelled','canceled')) desc, t.created_at desc limit 1) tk on true
        left join public.ticket_products tp on tp.id::text = coalesce(nullif(i.ticket_product_id,''), to_jsonb(tk)->>'ticket_product_id')
        left join public.profiles pr on pr.id = i.invitee_user_id
        left join public.restaurants r on r.id::text = i.restaurant_id
    ), s as materialized (   -- 한 번만 센다 — 인라인되면 아래 칸이 참조될 때마다 하위 질의가 다시 돌아 초대 몇 건에 수십 초가 걸렸다
      select j.*,
             (select coalesce(sum((v_led->(p || '|' || j.invitee_user_id::text)->>'cancel')::bigint),0) + coalesce(sum((v_led->(p || '|' || j.invitee_user_id::text)->>'other')::bigint),0) from jsonb_array_elements_text(j.pids) p) as l_cancel,
             (select coalesce(sum((v_led->(p || '|' || j.invitee_user_id::text)->>'penalty')::bigint),0) from jsonb_array_elements_text(j.pids) p) as l_pen,
             (select coalesce(sum((v_led->(p || '|' || j.invitee_user_id::text)->>'ret')::bigint),0) from jsonb_array_elements_text(j.pids) p) as l_ret,
             (select min(v_led->(p || '|' || j.invitee_user_id::text)->>'ret_at') from jsonb_array_elements_text(j.pids) p) as l_ret_at,
             (select coalesce(sum((v_led->(p || '|' || j.invitee_user_id::text)->>'rev')::bigint),0) from jsonb_array_elements_text(j.pids) p) as l_rev,
             (select coalesce(sum((v_led->(p || '|' || j.invitee_user_id::text)->>'pax')::bigint),0) from jsonb_array_elements_text(j.pids) p) as l_pax,
             (select max(v_led->(p || '|' || j.invitee_user_id::text)->>'ref_at') from jsonb_array_elements_text(j.pids) p) as l_at,
             (select max((v_led->(p || '|' || j.invitee_user_id::text)->>'ag_held')::bigint) from jsonb_array_elements_text(j.pids) p) as l_ag,
             greatest(coalesce(j.tk_pax, j.pax, 1), 1) as pax_n,
             coalesce(public._taam_pu_visit_date(j.visit_date), public._taam_pu_visit_date(j.tk_date)) as vdate
        from j
    ), u as materialized (
      select s.*,
             greatest(coalesce((il->>'buy')::bigint, 0) - l_rev, 0) as gross,
             case when l_ret > 0 and (vdate is null or ((l_ret_at::timestamptz) at time zone 'Asia/Seoul')::date >= vdate - 1) then l_ret else 0 end as ret_ok,
             -- 초대마다 협의한 대행비(스냅샷) — 회원이 자기 초대 행을 고칠 수 있으니 연결된 회차가 있으면 회차 대행비를 넘지 않게
             least(case when tp_agency is not null then least(coalesce(agency_fee, tp_agency), tp_agency) else coalesce(agency_fee, 0) end, 99999999)::bigint as ag_per
        from s
    ), u2 as (
      select u.*, case when l_ret > 0 and ret_ok = 0 then l_ret else 0 end as ret_early,
             case when l_pen > 0 then 'penalty'
                  when ret_ok > 0 then 'returned'
                  when lower(coalesce(tk_status,'')) in ('cancelled','canceled') or status = 'cancelled' or l_cancel > 0 or l_ret > 0 then 'cancelled' end as proc
        from u
    ), w as (select u2.*, gross - l_cancel - ret_early - l_pen - l_pax as net from u2)
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'k', 'inv:' || id, 'ch', 'invite', 'pm', 'deposit', 'st', coalesce(proc, 'active'),
        'paid_at', coalesce(public._taam_sr_ts(il->>'buy_at'), paid_at),
        'visit', vdate,
        'time', visit_time, 'rest_id', restaurant_id, 'rest', coalesce(rname, restaurant_name),
        'uid', invitee_user_id, 'buyer', buyer, 'test', invitee_user_id = any(v_test),
        'pax', pax_n, 'cur', 'KRW',
        'gross', gross, 'meal', least(coalesce(meal_fee, tp_meal, 0), 999999999)::bigint * pax_n, 'ag_gross', ag_per * pax_n, 'wine', least(coalesce(wine_min, tp_wine, 0), 999999999)::bigint * pax_n,
        'bd', case when (least(coalesce(meal_fee, tp_meal, 0), 999999999) + ag_per + least(coalesce(wine_min, tp_wine, 0), 999999999))::bigint * pax_n = gross then 'snap' else 'mismatch' end,
        'dep', gross, 'card', 0,
        'rf_cancel', l_cancel + ret_early, 'rf_penalty', l_pen, 'rf_pax', l_pax, 'rf_return', ret_ok, 'rf_card_pending', 0, 'rf_at', l_at,
        'net', net, 'held', net - ret_ok,
        'agency', greatest(0, least(case when proc = 'returned' and l_ag is not null then l_ag
                                         when proc = 'penalty' and coalesce(l_ag, 0) > 0 then l_ag
                                         else ag_per * pax_n end, ag_per * pax_n, greatest(net, 0))),
        'ag_state', case when proc = 'returned' and l_ag is not null then case when l_ag = 0 then 'waived' else 'kept' end
                         when proc in ('cancelled','penalty') then 'kept' else 'planned' end,
        'visit_st', visit_st, 'ref', coalesce(tk_pid, (pids->>0)), 'inv_status', status,
        'flags', to_jsonb(array_remove(array[
           case when tk_pid is null then 'no_ticket_row' end,
           case when gross <> coalesce(total_amount, 0) then 'ledger_mismatch' end,
           case when tp_agency is not null and agency_fee is not null and agency_fee <> tp_agency then 'agency_snapshot_differs' end,
           case when ret_early > 0 then 'return_before_visit' end,
           case when net < 0 then 'net_negative' end
        ], null))
      )) order by paid_at) filter (where gross > 0), '[]'::jsonb),
      -- paid 인데 그 회원의 결제 줄이 없거나 전부 되돌려졌다 — 합계 밖 「확인 필요」
      coalesce(jsonb_agg(jsonb_build_object('kind', case when il is null then 'invite_paid_no_ledger' else 'invite_reversed_still_paid' end,
                                            'ref', id, 'at', paid_at, 'krw', total_amount,
                                            'note', coalesce(restaurant_name, '') || ' · ' || coalesce(visit_date, '') || ' · ' || coalesce(status, '')))
               filter (where gross <= 0 and coalesce(status, '') <> 'cancelled'), '[]'::jsonb)
      into v_rows, v_skip from w;
    v_all := v_all || v_rows;
    v_exc := v_exc || v_skip;

    -- 예외: 예치금은 빠졌는데 초대가 paid 로 안 바뀐 것 (riPay 의 상태 갱신 실패 · console.warn 뿐)
    select coalesce(jsonb_agg(jsonb_build_object('kind','invite_debited_unpaid','ref', i.id, 'at', (v_iled->(i.id::text || '|' || i.invitee_user_id::text))->>'buy_at',
                                                 'krw', (v_iled->(i.id::text || '|' || i.invitee_user_id::text))->>'buy', 'note', coalesce(i.restaurant_name,'') || ' · ' || coalesce(i.visit_date,''))), '[]'::jsonb)
      into v_rows
      from public.reservation_invites i
     where i.paid_at is null and i.invitee_user_id is not null and v_iled ? (i.id::text || '|' || i.invitee_user_id::text)
       and coalesce(((v_iled->(i.id::text || '|' || i.invitee_user_id::text))->>'buy')::bigint, 0)
           - coalesce((select sum(coalesce((v_led->(p || '|' || i.invitee_user_id::text)->>'rev')::bigint,0) + coalesce((v_led->(p || '|' || i.invitee_user_id::text)->>'cancel')::bigint,0))
                         from jsonb_array_elements_text((v_iled->(i.id::text || '|' || i.invitee_user_id::text))->'pids') p), 0) > 0;
    v_exc := v_exc || v_rows;
  end if;

  -- ═══ C. 결제 링크 · 대관 정산 (kashikiri_charges · 카드) — 돈은 청구 행에만 있다. tickets.price(LINK 정가 · KSK 0) 는 쓰지 않는다 ═══
  if to_regclass('public.kashikiri_charges') is not null then
    with c as (
      select c.*, to_jsonb(c) as cj, to_jsonb(e) as ej, to_jsonb(e)->>'venue_id' as venue_id, to_jsonb(e)->>'venue_name' as venue_name,
             public._taam_pu_visit_date(to_jsonb(e)->>'event_date') as event_date,
             coalesce(to_jsonb(c)->>'purpose', case when coalesce(c.link_invite,false) then 'ticket' else 'custom' end) as purp,
             row_number() over (partition by coalesce(c.team_id::text, c.id::text) order by c.created_at, c.id) as team_rn
        from public.kashikiri_charges c
        left join public.kashikiri_events e on e.id = c.event_id
       where c.status in ('paid','refunded')
    ), d as (
      select c.*,
             case when coalesce(c.link_invite,false) or purp = 'ticket' then 'link'
                  when purp = 'membership' then 'x_membership'
                  when c.event_id is null then 'x_custom'
                  when coalesce(c.venue_id,'') ~ '^manual-' and coalesce(ej->>'ticket_product_id','') = '' then 'settle_x'
                  else 'settle' end as cls,
             case when upper(coalesce(c.pay_currency,'KRW')) in ('KRW','USD','JPY') then upper(coalesce(c.pay_currency,'KRW')) else 'KRW' end as cur,
             case when c.status = 'refunded' then coalesce(c.refund_krw,0) else 0 end::bigint as rf
        from c
    ), e as (
      select d.*, tk.purchase_id as tk_pid, tk.party_size as tk_pax, tk.reservation_date as tk_date, tk.visit_time as tk_time,
             tk.restaurant_id as tk_rid, tk.restaurant_name as tk_rname, coalesce(tk.extra_data,'{}'::jsonb) as tx,
             tp.meal_fee, tp.agency_fee, tp.wine_min, kt.pax as team_pax,
             coalesce(d.user_id, case when coalesce(tk.extra_data->>'memberUid','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (tk.extra_data->>'memberUid')::uuid end) as buid
        from d
        left join lateral (select * from public.tickets t where t.purchase_id like 'LINK-%' and t.extra_data->>'chargeId' = d.id::text
                            order by t.created_at desc limit 1) tk on d.cls = 'link'
        left join public.ticket_products tp on tp.id::text = coalesce(tk.ticket_product_id, d.ej->>'ticket_product_id')
        left join public.kashikiri_teams kt on kt.id = d.team_id
       where d.cls in ('link','settle','settle_x')
    ), f as (
      select e.*, pr.display_name as buyer, r.name as rname,
             case when cls = 'link' then greatest(least(coalesce(case when public._taam_sr_int(cj->'payload'->>'pax') between 1 and 99 then public._taam_sr_int(cj->'payload'->>'pax') end,
                                                                 case when tk_pax between 1 and 99 then tk_pax end, 1), 99), 1)   -- 청구 payload(서버가 적음) 먼저
                  when team_rn = 1 then coalesce(team_pax, 1) else 0 end as pax,
             cj->'payload'->'override_parts' as op,
             null::bigint as ag_snap   -- 좌석 행의 agencyFee 는 쓰지 않는다(매장 어드민이 쓸 수 있는 행) — 회차 요금·금액 수정 내역만
        from e
        left join public.profiles pr on pr.id = e.buid
        left join public.restaurants r on r.id::text = coalesce(nullif(e.tk_rid::text,''), e.venue_id)
    ), g as (
      select f.*,
             -- 항목별 금액 수정(override_parts)이 지금 청구액과 맞을 때만 그 내역을 쓴다 (환불 견적과 같은 조건)
             (op is not null and upper(coalesce(op->>'currency','KRW')) = cur
               and (coalesce((op->>'meal')::numeric,0) + coalesce((op->>'agency')::numeric,0) + coalesce((op->>'wine')::numeric,0))
                   * coalesce((op->>'pax')::numeric, pax)
                   = case when cur = 'KRW' then amount_krw::numeric else coalesce(pay_amount, 0) end) as op_ok,
             case when cur = 'KRW' then 1 else coalesce(pay_fx, 0) end as rate
        from f
    ), h as (
      select g.*,
             case when cls <> 'link' then null
                  when op_ok then round((op->>'agency')::numeric * coalesce((op->>'pax')::numeric, pax) * rate)::bigint
                  else coalesce(ag_snap, agency_fee) * pax end as ag_gross,
             case when cls <> 'link' then null
                  when op_ok then round((op->>'meal')::numeric * coalesce((op->>'pax')::numeric, pax) * rate)::bigint
                  else meal_fee::bigint * pax end as meal,
             case when cls <> 'link' then null
                  when op_ok then round((op->>'wine')::numeric * coalesce((op->>'pax')::numeric, pax) * rate)::bigint
                  else wine_min::bigint * pax end as wine,
             coalesce(public._taam_pu_visit_date(tk_date), event_date) as visit
        from g
    )
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'k', 'chg:' || id, 'ch', cls, 'pm', 'card',
        'st', case when status = 'refunded' then 'cancelled' else 'active' end,
        'paid_at', coalesce(approved_at, created_at), 'visit', visit,
        'time', coalesce(nullif(tk_time,''), left(ej->>'event_time', 5)),
        'rest_id', coalesce(nullif(tk_rid::text,''), case when coalesce(venue_id,'') !~ '^manual-' then venue_id end),
        'rest', coalesce(rname, nullif(tk_rname,''), venue_name, cj->>'title'),
        'uid', buid, 'buyer', coalesce(nullif(btrim(buyer),''), nullif(btrim(payer_name),''), label),
        'test', buid is not null and buid = any(v_test),
        'pax', pax, 'cur', cur,
        'fx_amt', case when cur <> 'KRW' then pay_amount end, 'fx_rate', case when cur <> 'KRW' then pay_fx end,
        'fx_refund', case when cur <> 'KRW' and status = 'refunded' then refund_amount end,
        'gross', amount_krw, 'meal', meal, 'wine', wine, 'ag_gross', ag_gross,
        'bd', case when cls <> 'link' then 'none' when op_ok then 'snap'
                   when coalesce(meal,0) + coalesce(ag_gross,0) + coalesce(wine,0) = amount_krw then case when ag_snap is not null then 'snap' else 'product' end
                   else 'mismatch' end,
        'dep', 0, 'card', amount_krw,
        'rf_cancel', rf, 'rf_penalty', 0, 'rf_pax', 0, 'rf_return', 0, 'rf_card_pending', 0, 'rf_at', refunded_at,
        'net', amount_krw - rf, 'held', amount_krw - rf,
        'agency', case when cls = 'link' then least(coalesce(ag_gross,0), greatest(amount_krw - rf, 0)) else 0 end,
        'ag_state', case when cls <> 'link' then 'none' when status = 'refunded' or visit < v_today then 'kept' else 'planned' end,
        'ref', coalesce(tk_pid, order_id, id::text), 'method', method,
        'flags', to_jsonb(array_remove(array[
           case when cls = 'link' and tk_pid is null then 'no_ticket_row' end,
           case when cls = 'link' and coalesce(cj->'payload'->>'price_override','') = 'true' then 'price_override' end,
           case when cls = 'settle_x' then 'settle_unlinked' end,
           case when status = 'refunded' and rf = 0 then 'refunded_zero' end
        ], null))
      )) order by coalesce(approved_at, created_at)), '[]'::jsonb)
      into v_rows from h;
    v_all := v_all || v_rows;

    -- 티켓 판매가 아닌 결제 — 합계엔 안 넣고 같은 기간 참고로만 (멤버십 · 자유 금액)
    select coalesce(jsonb_object_agg(cls, jsonb_build_object('n', n, 'krw', krw)), '{}'::jsonb) into v_xm
      from (select case when coalesce(to_jsonb(c)->>'purpose','custom') = 'membership' then 'membership' else 'custom' end as cls,
                   count(*) as n, sum(c.amount_krw - case when c.status = 'refunded' then coalesce(c.refund_krw,0) else 0 end) as krw
              from public.kashikiri_charges c
             where c.status in ('paid','refunded') and not coalesce(c.link_invite,false)
               and (coalesce(to_jsonb(c)->>'purpose','custom') = 'membership' or c.event_id is null)
               and (coalesce(c.approved_at, c.created_at) at time zone 'Asia/Seoul')::date >= coalesce(p_from, date '2000-01-01')   -- 방문일이 없는 결제라 기준과 무관하게 결제일로
               and (coalesce(c.approved_at, c.created_at) at time zone 'Asia/Seoul')::date < coalesce(p_to, date '2100-01-01')
             group by 1) z;

    -- 예외: 토스는 승인했는데 기록이 pending 으로 남은 청구 (kashikiri-confirm 금액 불일치 · mark_paid 실패)
    select coalesce(jsonb_agg(jsonb_build_object('kind','link_captured_pending','ref', c.id, 'at', c.created_at, 'krw', c.amount_krw,
                                                 'note', left(coalesce(c.fail_reason,''), 80))), '[]'::jsonb)
      into v_rows from public.kashikiri_charges c
     where c.status = 'pending' and c.payment_key is not null;
    v_exc := v_exc || v_rows;
  end if;

  -- ═══ D. 수동 입력 좌석 (MAN- · status manual) — 어드민이 적은 「받은 금액」. 검증 안 된 돈이라 기본 합계 밖 ═══
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'k', t.purchase_id, 'ch', 'man', 'pm', 'offline', 'st', 'active',
      'paid_at', t.created_at, 'visit', coalesce(public._taam_pu_visit_date(t.reservation_date), public._taam_pu_visit_date(to_jsonb(tp)->>'date')),
      'time', nullif(t.visit_time,''), 'rest_id', nullif(t.restaurant_id::text,''), 'rest', coalesce(r.name, t.restaurant_name),
      'buyer', t.buyer_name, 'pax', t.party_size, 'cur', 'KRW', 'gross', coalesce(t.price,0),
      'bd', 'none', 'dep', 0, 'card', 0, 'rf_cancel', 0, 'rf_penalty', 0, 'rf_pax', 0, 'rf_return', 0, 'rf_card_pending', 0,
      'net', coalesce(t.price,0), 'held', coalesce(t.price,0), 'agency', 0, 'ag_state', 'none',
      'ttype', t.extra_data->>'ttype', 'by_role', pr.role, 'ref', t.purchase_id,
      'flags', to_jsonb(array_remove(array['manual_unverified', case when pr.role = 'admin' then 'by_rest_admin' end,
                                           case when coalesce(t.price,0) = 0 then 'zero_amount' end], null))
    )) order by t.created_at), '[]'::jsonb)
    into v_rows
    from public.tickets t
    left join public.ticket_products tp on tp.id::text = t.ticket_product_id
    left join public.profiles pr on pr.id = t.user_id
    left join public.restaurants r on r.id::text = nullif(t.restaurant_id::text,'')
   where t.purchase_id like 'MAN-%' and lower(coalesce(t.status,'')) in ('manual','active');
  v_all := v_all || v_rows;

  select jsonb_build_object('n', count(*), 'krw', coalesce(sum(t.price),0)) into v_skip
    from public.tickets t where t.purchase_id like 'MAN-%' and lower(coalesce(t.status,'')) in ('cancelled','canceled')
     and (t.created_at at time zone 'Asia/Seoul')::date >= coalesce(p_from, date '2000-01-01')   -- 입력일 기준
     and (t.created_at at time zone 'Asia/Seoul')::date < coalesce(p_to, date '2100-01-01');
  v_xm := v_xm || jsonb_build_object('man_cancelled', v_skip);

  -- ═══ E. 수동 기록 (daegwan_manual · 티켓 연결 없음 · 지우면 사라진다) ═══
  if to_regclass('public.daegwan_manual') is not null then
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'k', 'dm:' || m.id, 'ch', 'dm', 'pm', 'offline', 'st', 'active',
        'paid_at', m.created_at, 'visit', m.ymd, 'rest_id', m.venue_id, 'rest', coalesce(r.name, to_jsonb(m)->>'venue_name'),
        'buyer', m.name, 'pax', m.pax, 'cur', 'KRW', 'gross', coalesce(m.amount,0),
        'bd', 'none', 'dep', 0, 'card', 0, 'rf_cancel', 0, 'rf_penalty', 0, 'rf_pax', 0, 'rf_return', 0, 'rf_card_pending', 0,
        'net', coalesce(m.amount,0), 'held', coalesce(m.amount,0), 'agency', 0, 'ag_state', 'none',
        'ttype', to_jsonb(m)->>'ttype', 'by_role', pr.role, 'ref', m.id,
        'flags', to_jsonb(array_remove(array['manual_unverified', case when pr.role = 'admin' then 'by_rest_admin' end,
                                             case when coalesce(m.amount,0) = 0 then 'zero_amount' end], null))
      )) order by m.created_at), '[]'::jsonb)
      into v_rows
      from public.daegwan_manual m
      left join public.profiles pr on pr.id = m.created_by
      left join public.restaurants r on r.id::text = m.venue_id;
    v_all := v_all || v_rows;
  end if;

  -- 예외: 카드는 잡혔는데 티켓이 없다 (승인 뒤 좌석 상실·예치금 부족 + 토스 취소 실패)
  select coalesce(jsonb_agg(jsonb_build_object('kind','card_captured_no_ticket','ref', po.order_id, 'at', coalesce(po.approved_at, po.updated_at),
                                               'krw', coalesce(po.settle_krw, po.amount), 'note', po.fail_reason)), '[]'::jsonb)
    into v_rows from public.payment_orders po
   where po.status = 'paid' and coalesce(po.fail_reason,'') like '%refund_failed';
  v_exc := v_exc || v_rows;

  -- ── 기간·기준 거르기 + 테스트 계정 ──
  with r as (
    select z as o,
           case when v_basis = 'visit' then (z->>'visit')::date
                else (((z->>'paid_at')::timestamptz) at time zone 'Asia/Seoul')::date end as dk,
           coalesce((z->>'test')::boolean, false) as is_test
      from jsonb_array_elements(v_all) z
  ), r2 as (
    select r.*, (p_from is null or dk >= p_from) and (p_to is null or dk < p_to) as in_rng from r
  )
  select jsonb_build_object(
           'ok', true, 'v', 1, 'basis', v_basis, 'from', p_from, 'to', p_to, 'today', v_today, 'generated_at', now(),
           'rows', coalesce(jsonb_agg(o || jsonb_build_object('paid_ymd', to_char((((o->>'paid_at')::timestamptz) at time zone 'Asia/Seoul'), 'YYYY-MM-DD')))
                              filter (where in_rng and (p_include_test or not is_test)), '[]'::jsonb),
           'excluded', v_xm || jsonb_build_object(
              'test', jsonb_build_object('n', count(*) filter (where in_rng and is_test and not p_include_test),
                                         'krw', coalesce(sum((o->>'net')::bigint) filter (where in_rng and is_test and not p_include_test), 0)),
              'no_visit_date', jsonb_build_object('n', count(*) filter (where v_basis = 'visit' and dk is null),
                                                  'krw', coalesce(sum((o->>'net')::bigint) filter (where v_basis = 'visit' and dk is null), 0))),
           'exceptions', v_exc)
    into v_rows
    from r2;
  return v_rows;
end $$;
revoke all on function public.taam_ticket_sales_report(date, date, text, boolean) from public, anon;
grant execute on function public.taam_ticket_sales_report(date, date, text, boolean) to authenticated;
revoke all on function public._taam_sr_int(text) from public, anon;
revoke all on function public._taam_sr_ts(text) from public, anon;

comment on function public.taam_ticket_sales_report(date, date, text, boolean) is
  '티켓 판매 현황(슈퍼어드민) — 판매 하나=결제 하나 · 앱 구매/초대/결제 링크/대관 정산/수동 · 환불은 판매에 붙인다 · KST [from,to) · basis paid|visit. 2026-10-21';

-- ── 확인 — 한 표 (금액은 채널별 합계만 · 이름 없음) ──
drop table if exists _tsr_chk; create temp table _tsr_chk(k text, v text);
insert into _tsr_chk
select '① 보고 함수', case when to_regprocedure('public.taam_ticket_sales_report(date,date,text,boolean)') is not null then '✅' else '❌' end
union all select '② 호출자 판정 _taam_fee_caller_ok', case when to_regprocedure('public._taam_fee_caller_ok()') is not null then '✅' else '❌ 없음 — 20261017_membership_fee_due.sql 먼저' end
union all select '③ 방문일 읽기 _taam_pu_visit_date', case when to_regprocedure('public._taam_pu_visit_date(text)') is not null then '✅' else '❌ 없음 — 20261014_purchase_uniqueness.sql 먼저' end
union all select '④ anon 실행 권한 없음', case when not has_function_privilege('anon', 'public.taam_ticket_sales_report(date,date,text,boolean)', 'execute') then '✅' else '❌' end;
do $do$
declare j jsonb; r record;
begin
  begin
    j := public.taam_ticket_sales_report(null, null, 'paid', false);
  exception when others then
    insert into _tsr_chk values ('⑤ 전체 기간 시험 호출', '⚠ ' || sqlerrm); return;
  end;
  for r in
    select z->>'ch' as ch, count(*) as n, coalesce(sum((z->>'gross')::bigint),0) as g,
           coalesce(sum(coalesce((z->>'rf_cancel')::bigint,0) + coalesce((z->>'rf_penalty')::bigint,0) + coalesce((z->>'rf_pax')::bigint,0)),0) as rf,
           coalesce(sum((z->>'net')::bigint),0) as net
      from jsonb_array_elements(j->'rows') z where z->>'x' is null group by 1 order by 1
  loop
    insert into _tsr_chk values ('⑤ ' || r.ch, r.n || '건 · 판매 ₩' || to_char(r.g, 'FM999,999,999,999') || ' · 환불 ₩' || to_char(r.rf, 'FM999,999,999,999') || ' · 순판매 ₩' || to_char(r.net, 'FM999,999,999,999'));
  end loop;
  insert into _tsr_chk values ('⑥ 확인 필요(예외)', jsonb_array_length(coalesce(j->'exceptions','[]'::jsonb)) || '건');
end $do$;
select k as 항목, v as 결과 from _tsr_chk order by 1;
