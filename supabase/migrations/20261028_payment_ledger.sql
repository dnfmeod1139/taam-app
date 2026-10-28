-- ═══════════════════════════════════════════════════════════════
-- 💳 결제 내역 (카드 · 예치금) — 슈퍼어드민 보고 RPC + 토스 조회 캐시 (2026-10-28)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 「카드로 결제된 내역이랑 예치금으로 결제된 내역도 보고 싶은데 항목 자세히 — 구매자 · 일시 · 예상 입금일 · 카드 내역 · 취소한다면 취소 연동 · 모든 내역」.
--   지금은 카드 돈이 두 표(payment_orders = 앱 티켓 카드 · kashikiri_charges = 결제 링크·정산·멤버십), 예치금 돈이 원장(deposit_transactions)에 흩어져 있고,
--   취소는 네 곳(payment_orders.metadata.app_cancels · tickets.extra_data.card_refund_pending/card_refund_queue · kashikiri_charges.refund_* · 원장 환불 줄)에,
--   카드 정보(카드사·번호·할부·승인번호)는 앱 카드 결제의 승인 시점 토스 기록(metadata.toss)에만 있다. 입금일(정산)은 어디에도 없다.
--   슈퍼어드민은 RLS 로 남의 payment_orders 를 못 읽는다(payment_orders_select_own) → security definer 보고서 하나로 모은다.
-- 무엇을:
--   ① toss_payment_cache — 토스에서 다시 읽은 결제 정보(지금 상태 · 남은 금액 · 취소 목록 · 카드 · 간편결제 · 영수증)와 정산 줄(매출일 · 지급일 · 수수료 · 지급액).
--      Edge toss-payment-info(슈퍼어드민)만 쓴다(service_role). 회원·anon 은 읽지도 못한다(RLS 켜고 정책 없음 · 권한 회수). **원문이 아니라 고른 칸만** 담는다
--      (토스 Payment 객체에는 secret 같은 칸이 있다 — 그런 것은 캐시에도 보고서에도 싣지 않는다).
--   ② taam_payment_ledger(p_from, p_to, p_include_test) — jsonb 한 덩어리 {card[], dep[], today, generated_at}.
--      card: 결제 하나 = 한 줄(앱 티켓 카드 o: · 결제 링크/정산/멤버십 c:) — 구매자·결제 시각·금액(결제 통화 그대로 + 기록된 원화)·결제키·영수증 URL ·
--            연결 티켓(매장·방문·인원·구매 id·상태)·같이 쓴 예치금·카드 환불 대기/인원 줄임 대기·앱 취소 기록·예치금 환불 줄·
--            승인 시점 토스 기록(snap — 고른 칸) · 캐시(live · settle).
--      dep:  예치금 결제 — (회원, 구매 id) 마다 한 줄(티켓 · 초대 · 인원 늘림 결제 포함) · 관리 차감·옛 멤버십 결제는 줄마다 ·
--            그 구매의 환불·반환·정정 줄(종류 분류) · 연결 티켓/초대 · 같이 낸 카드 주문 · 예치금 부여(입금)·기타 입금 줄(앱이 기본으로 숨긴다).
--      기간은 결제 시각(KST 날짜) 기준 [p_from, p_to) · 둘 다 null 이면 전체. 환불은 결제에 붙는다(환불이 기간 밖이어도).
--      테스트 계정(profiles.is_test)은 기본 제외 — 결제 링크는 회원 user_id 가 테스트 계정일 때만 뺀다(비회원 결제자는 그대로).
-- 원화는 **기록된 값 그대로** — 외화 결제를 오늘 환율로 다시 바꾸지 않는다(CLAUDE.md 「통화」).
-- 호출: 슈퍼어드민 · SQL Editor · service_role 만(_taam_fee_caller_ok) — 그 밖은 FORBIDDEN. anon 실행 권한 없음.
-- 데이터는 바꾸지 않는다(표 하나를 만들 뿐). 회귀: bash sql/_test/t_payment_ledger.sh
-- ═══════════════════════════════════════════════════════════════

-- ── ① 토스 조회 캐시 ──
create table if not exists public.toss_payment_cache (
  payment_key  text primary key,
  src          text not null check (src in ('order','charge')),   -- order = payment_orders.order_id · charge = kashikiri_charges.id
  ref          text not null,
  mid          text,
  info         jsonb,            -- 고른 칸: mId status method currency totalAmount balanceAmount approvedAt card{} easyPay{} cancels[] receiptUrl
  info_at      timestamptz,
  info_error   text,
  settle       jsonb,            -- 정산 줄 배열: [{tx, soldDate, paidOutDate, amount, fee, payOutAmount, cur, cancel}]
  settle_at    timestamptz,
  settle_error text,
  updated_at   timestamptz not null default now()
);
create index if not exists toss_payment_cache_ref_idx on public.toss_payment_cache (src, ref);
alter table public.toss_payment_cache enable row level security;
revoke all on table public.toss_payment_cache from public, anon, authenticated;
comment on table public.toss_payment_cache is
  '토스 결제·정산 조회 캐시 — Edge toss-payment-info(슈퍼어드민)만 쓴다. 회원 접근 없음. 원문이 아니라 고른 칸만(2026-10-28)';

-- ── 안전한 숫자 읽기 (회원이 쓸 수 있는 extra_data · metadata 의 'abc' 한 줄이 보고서 전체를 깨면 안 된다) ──
create or replace function public._taam_pl_num(p text)
returns numeric language sql immutable as $$
  select case when p ~ '^\s*-?\d{1,13}(\.\d+)?\s*$' then round(p::numeric, 2) end
$$;

-- ── 토스 Payment 객체 → 고른 칸 (승인 시점 기록 metadata.toss 와 캐시가 같은 모양) ──
create or replace function public._taam_pl_toss(t jsonb)
returns jsonb language sql immutable as $$
  select case when t is null or jsonb_typeof(t) <> 'object' then null else jsonb_strip_nulls(jsonb_build_object(
    'mId', left(t->>'mId', 40), 'status', left(t->>'status', 30), 'method', left(t->>'method', 30), 'currency', left(t->>'currency', 5),
    'totalAmount', public._taam_pl_num(t->>'totalAmount'), 'balanceAmount', public._taam_pl_num(t->>'balanceAmount'),
    'approvedAt', left(t->>'approvedAt', 40), 'requestedAt', left(t->>'requestedAt', 40), 'type', left(t->>'type', 20),
    'country', left(t->>'country', 5), 'orderName', left(t->>'orderName', 100), 'receiptUrl', left(t->'receipt'->>'url', 400),
    'card', case when jsonb_typeof(t->'card') = 'object' then jsonb_strip_nulls(jsonb_build_object(
        'issuerCode', left(t->'card'->>'issuerCode', 10), 'acquirerCode', left(t->'card'->>'acquirerCode', 10), 'company', left(t->'card'->>'company', 30),
        'number', left(t->'card'->>'number', 30), 'installmentPlanMonths', public._taam_pl_num(t->'card'->>'installmentPlanMonths'),
        'isInterestFree', case when jsonb_typeof(t->'card'->'isInterestFree') = 'boolean' then t->'card'->'isInterestFree' end,
        'interestPayer', left(t->'card'->>'interestPayer', 20), 'approveNo', left(t->'card'->>'approveNo', 20),
        'useCardPoint', case when jsonb_typeof(t->'card'->'useCardPoint') = 'boolean' then t->'card'->'useCardPoint' end,
        'cardType', left(t->'card'->>'cardType', 10), 'ownerType', left(t->'card'->>'ownerType', 10),
        'acquireStatus', left(t->'card'->>'acquireStatus', 20), 'amount', public._taam_pl_num(t->'card'->>'amount'))) end,
    'easyPay', case when jsonb_typeof(t->'easyPay') = 'object' then jsonb_strip_nulls(jsonb_build_object(
        'provider', left(t->'easyPay'->>'provider', 30), 'amount', public._taam_pl_num(t->'easyPay'->>'amount'),
        'discountAmount', public._taam_pl_num(t->'easyPay'->>'discountAmount'))) end,
    'cancels', case when jsonb_typeof(t->'cancels') = 'array' then (
        select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                 'cancelAmount', public._taam_pl_num(c->>'cancelAmount'), 'cancelReason', left(c->>'cancelReason', 200),
                 'canceledAt', left(c->>'canceledAt', 40), 'transactionKey', left(c->>'transactionKey', 80),
                 'cancelStatus', left(c->>'cancelStatus', 20), 'refundableAmount', public._taam_pl_num(c->>'refundableAmount')))), '[]'::jsonb)
          from (select c from jsonb_array_elements(t->'cancels') c where jsonb_typeof(c) = 'object' limit 50) z) end
  )) end
$$;
revoke all on function public._taam_pl_toss(jsonb) from public, anon, authenticated;
revoke all on function public._taam_pl_num(text) from public, anon, authenticated;

-- ── ② 보고서 ──
create or replace function public.taam_payment_ledger(
  p_from date default null, p_to date default null, p_include_test boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public set jit = off   -- 표가 작다 — JIT 컴파일(수 초)이 실행보다 비싸다(3차 리뷰)
as $$
declare
  v_test uuid[];
  v_rf   jsonb := '{}'::jsonb;    -- (회원|구매 id) → 예치금 환불·반환·정정 줄(+)
  v_dpo  jsonb := '{}'::jsonb;    -- (회원|주문) → 카드 주문과 같이 뺀 예치금
  v_plain jsonb := '{}'::jsonb;   -- (회원|구매 id) → 주문 없는(예치금만) 결제 줄이 있다 — 한 번만 세어 둔다(줄마다 하위 질의로 세면 계획 비용이 폭증해 JIT 가 매번 2초씩 돌았다 · 3차 리뷰)
  v_card jsonb := '[]'::jsonb;
  v_chg  jsonb := '[]'::jsonb;
  v_dep  jsonb := '[]'::jsonb;
  v_in   jsonb := '[]'::jsonb;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then
    raise exception 'FORBIDDEN: 슈퍼어드민만 볼 수 있습니다' using errcode = '42501';
  end if;
  if p_from is not null and p_to is not null and p_to <= p_from then
    raise exception 'BAD_RANGE: 끝 날짜가 시작 날짜보다 뒤여야 합니다' using errcode = '22023';
  end if;

  select coalesce(array_agg(p.id), '{}') into v_test
    from public.profiles p where coalesce(to_jsonb(p)->>'is_test', '') = 'true';

  -- ── 예치금 환불·반환·정정 줄(+) — (회원, 구매 id) 마다 · 종류는 판매 현황(20261022_ticket_sales_report4.sql)과 같은 분류 ──
  select coalesce(jsonb_object_agg(k, arr), '{}'::jsonb) into v_rf
    from (select d.user_id::text || '|' || (d.metadata->>'purchase_id') as k,
                 jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'at', d.created_at, 'amt', d.amount, 'pocket', d.deposit_type, 'type', d.change_type,
                   'k', case
                          when d.metadata ? 'fix' then 'fix'
                          when coalesce(d.metadata->>'reason','') in ('capacity_auto_refund','duplicate_purchase','time_conflict','invite_closed') then 'auto'
                          when d.metadata ? 'order_id' and not (d.metadata ? 'refund_type') and not (d.metadata ? 'cancel_refund') then 'card_auto'
                          when d.change_type = 'ticket_pax_change' then 'pax'
                          when coalesce(d.metadata->>'cancel_refund','') = 'true' then 'cancel'
                          when d.metadata->>'refund_type' = 'penalty' then 'penalty'
                          when d.metadata->>'refund_type' = 'returned' then 'returned'
                          else 'other' end,
                   'reason', left(d.metadata->>'reason', 40), 'policy', left(d.metadata->>'policy', 40),
                   'by', left(coalesce(d.metadata->>'cancelled_by', d.metadata->>'processed_by', d.metadata->>'actor_role'), 40),
                   'agency_held', public._taam_pl_num(d.metadata->>'agency_held'), 'penalty', public._taam_pl_num(d.metadata->>'penalty_amt'),
                   'desc', left(d.description, 140), 'order_id', left(d.metadata->>'order_id', 80))) order by d.created_at) as arr
            from public.deposit_transactions d
           where d.amount > 0 and coalesce(d.metadata->>'purchase_id','') <> '' and d.user_id is not null
           group by 1) z;

  -- ── 카드 주문과 같이 뺀 예치금 — (회원, 주문) 마다 ──
  select coalesce(jsonb_object_agg(k, jsonb_build_object('dep', dep, 'mem', mem, 'gen', gen, 'pid', pid)), '{}'::jsonb) into v_dpo
    from (select d.user_id::text || '|' || (d.metadata->>'order_id') as k,
                 -sum(d.amount) as dep, -sum(d.amount) filter (where d.deposit_type = 'membership') as mem,
                 -sum(d.amount) filter (where d.deposit_type <> 'membership') as gen, max(d.metadata->>'purchase_id') as pid
            from public.deposit_transactions d
           where d.amount < 0 and d.change_type = 'ticket_purchase' and coalesce(d.metadata->>'order_id','') <> '' and d.user_id is not null
           group by 1) z;

  select coalesce(jsonb_object_agg(k, true), '{}'::jsonb) into v_plain
    from (select distinct d.user_id::text || '|' || (d.metadata->>'purchase_id') as k
            from public.deposit_transactions d
           where d.amount < 0 and d.user_id is not null and coalesce(d.metadata->>'purchase_id','') <> '' and coalesce(d.metadata->>'order_id','') = ''
             and d.change_type in ('ticket_purchase','ticket_pax_change','reservation_payment')) z;

  -- ═══ 카드 A. 앱 티켓 카드 결제 (payment_orders) ═══
  --   승인된 것만(결제키가 있고 pending·failed 가 아님). 자동 취소(좌석 만료·예치금 부족)는 canceled 로 남는다.
  --   티켓은 서버가 적은 extra_data.order_id 로 먼저 잇는다(toss-confirm 이 metadata 를 {toss} 로 덮어 hold_purchase_id 가 없다) → 홀드 id → 원장의 주문 줄.
  select coalesce(jsonb_agg(x.r order by x.at desc), '[]'::jsonb) into v_card
    from (
      select coalesce(o.approved_at, o.created_at) as at, jsonb_strip_nulls(jsonb_build_object(
        'k', 'o:' || o.order_id, 'src', 'order',
        'ch', case when coalesce(o.metadata->>'paid_via','') = 'billing_key' then 'billing' else 'card' end,
        'order_id', o.order_id, 'st', lower(coalesce(o.status,'')), 'fail', left(o.fail_reason, 80), 'purpose', o.purpose,
        'cur', upper(coalesce(o.currency,'KRW')), 'amt', o.amount,
        'krw', coalesce(o.settle_krw, case when upper(coalesce(o.currency,'KRW')) = 'KRW' then o.amount end),
        'fx', public._taam_pl_num(to_jsonb(o)->>'fx_rate'),
        'pkey', o.payment_key, 'method', left(o.method, 30), 'receipt', left(to_jsonb(o)->>'receipt_url', 400),
        'at', coalesce(o.approved_at, o.created_at), 'created', o.created_at,
        'uid', o.user_id, 'buyer', coalesce(nullif(btrim(pr.display_name),''), nullif(btrim(t.buyer_name),'')),
        'phone', to_jsonb(pr)->>'phone', 'email', to_jsonb(pr)->>'email', 'tier', to_jsonb(pr)->>'membership_tier',
        'test', case when o.user_id = any(v_test) then true end,
        'rest', coalesce(rs.name, nullif(t.restaurant_name,''), to_jsonb(tp)->>'rest_name', o.metadata->>'restaurant_name', o.metadata->'toss'->>'orderName'),
        'visit', coalesce(public._taam_pu_visit_date(tp.date), public._taam_pu_visit_date(t.reservation_date)),
        'vtime', coalesce(nullif(t.visit_time,''), tp.time),
        'pax', coalesce(t.party_size, public._taam_pl_num(o.metadata->>'pax')),
        'pid', t.purchase_id, 'tst', lower(t.status), 'tprice', t.price,
        'card_paid', public._taam_pl_num(t.extra_data->>'cardPaid'), 'dep_used', public._taam_pl_num(t.extra_data->>'depositUsed'),
        'crp', case when jsonb_typeof(t.extra_data->'card_refund_pending') = 'object' then jsonb_strip_nulls(jsonb_build_object(
                 'status', left(t.extra_data->'card_refund_pending'->>'status', 20), 'amount', public._taam_pl_num(t.extra_data->'card_refund_pending'->>'amount'),
                 'via', left(t.extra_data->'card_refund_pending'->>'via', 20), 'requested_at', left(t.extra_data->'card_refund_pending'->>'requested_at', 40),
                 'refunded_at', left(t.extra_data->'card_refund_pending'->>'refunded_at', 40),
                 'refunded_amount', public._taam_pl_num(t.extra_data->'card_refund_pending'->>'refunded_amount'),
                 'reason', left(t.extra_data->'card_refund_pending'->>'reason', 120), 'policy', left(t.extra_data->'card_refund_pending'->>'policy', 40),
                 'set_by_role', left(t.extra_data->'card_refund_pending'->>'set_by_role', 20), 'toss_tx', left(t.extra_data->'card_refund_pending'->>'toss_tx', 80))) end,
        'crq', case when jsonb_typeof(t.extra_data->'card_refund_queue') = 'array' then (
                 select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('amount', public._taam_pl_num(q->>'amount'), 'status', left(q->>'status', 20),
                                   'requested_at', left(q->>'requested_at', 40), 'reason', left(q->>'reason', 120))))
                   from (select q from jsonb_array_elements(t.extra_data->'card_refund_queue') q where jsonb_typeof(q) = 'object' limit 20) z) end,
        't_cancel_at', coalesce(left(t.extra_data->>'server_cancelled_at', 40), left(t.extra_data->>'cancelled_at', 40)),
        't_cancel_reason', left(t.extra_data->>'cancel_reason', 120), 't_cancel_role', left(t.extra_data->>'cancelled_by_role', 20),
        'dep', public._taam_pl_num(v_dpo->(o.user_id::text || '|' || o.order_id)->>'dep'),
        'dep_mem', public._taam_pl_num(v_dpo->(o.user_id::text || '|' || o.order_id)->>'mem'),
        'dep_gen', public._taam_pl_num(v_dpo->(o.user_id::text || '|' || o.order_id)->>'gen'),
        'app_cancels', case when jsonb_typeof(o.metadata->'app_cancels') = 'array' then (
                 select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('amount', public._taam_pl_num(a->>'amount'), 'at', left(a->>'at', 40),
                                   'tx', left(a->>'tx', 80), 'policy', left(a->>'policy', 40), 'pid', left(a->>'purchase_id', 120),
                                   'by', (select nullif(btrim(pb.display_name),'') from public.profiles pb where pb.id::text = a->>'by'))))
                   from (select a from jsonb_array_elements(o.metadata->'app_cancels') a where jsonb_typeof(a) = 'object' limit 20) z) end,
        'snap', public._taam_pl_toss(o.metadata->'toss'),
        'mid', coalesce(pc.mid, left(o.metadata->'toss'->>'mId', 40))
      ) || jsonb_build_object(   -- jsonb_build_object 는 인자 100개까지 — 둘로 나눈다
        -- 예치금 환불 줄: 연결 티켓의 구매 id, 없으면(자동 취소된 주문) 이 주문의 예치금 줄 구매 id — 다른 주문 몫(order_id 다름)은 앱이 거른다
        'rf', coalesce(case when t.purchase_id is not null then v_rf->(t.user_id::text || '|' || t.purchase_id) end,
                       v_rf->(o.user_id::text || '|' || (v_dpo->(o.user_id::text || '|' || o.order_id)->>'pid'))),
        'dep_pid', v_dpo->(o.user_id::text || '|' || o.order_id)->>'pid',
        't_order', left(t.extra_data->>'order_id', 80),
        -- 같은 구매 id 에 주문 없는(예치금만) 결제 줄이 있나 — 주문 표시 없는 환불 줄은 그쪽 몫이다(2차 리뷰)
        'plain', case when v_plain ? (o.user_id::text || '|' || coalesce(t.purchase_id, v_dpo->(o.user_id::text || '|' || o.order_id)->>'pid', '')) then true end,
        'live', pc.info, 'live_at', pc.info_at, 'live_err', pc.info_error,
        'settle', pc.settle, 'settle_at', pc.settle_at, 'settle_err', pc.settle_error, 'cache_at', pc.updated_at,
        'bk', case when bk.id is not null then jsonb_strip_nulls(jsonb_build_object('company', left(bk.card_company, 30), 'number', left(bk.card_number, 30), 'type', left(bk.card_type, 20))) end
      )) as r
        from public.payment_orders o
        left join public.profiles pr on pr.id = o.user_id
        left join public.toss_payment_cache pc on pc.payment_key = o.payment_key
        left join public.billing_keys bk on bk.id::text = o.metadata->>'billing_key_id'
        left join lateral (
          select t.* from public.tickets t
           where t.user_id = o.user_id
             and (t.extra_data->>'order_id' = o.order_id
                  or ((t.purchase_id = nullif(o.metadata->>'hold_purchase_id','') or t.purchase_id = (v_dpo->(o.user_id::text || '|' || o.order_id)->>'pid'))
                      -- 같은 홀드에 다른 카드 결제가 붙어 확정됐으면 그 티켓은 그 주문 것이다(자동 취소된 앞 시도에 잇지 않는다 · 리뷰)
                      and coalesce(t.extra_data->>'order_id', '') in ('', o.order_id)
                      -- 자동 취소된 주문은 그 홀드가 예치금만으로 다시 결제되지 않았을 때만 — 다시 낸 결제(주문 없는 예치금 줄)의 티켓에 잇지 않는다(2차 리뷰)
                      and (lower(coalesce(o.status, '')) <> 'canceled' or not (v_plain ? (o.user_id::text || '|' || t.purchase_id)))))
           order by (t.extra_data->>'order_id' = o.order_id) desc nulls last, (lower(coalesce(t.status,'')) in ('active','used')) desc, t.created_at
           limit 1) t on true
        left join public.ticket_products tp on tp.id::text = coalesce(t.ticket_product_id::text, o.metadata->>'ticket_id')
        left join public.restaurants rs on rs.id::text = coalesce(nullif(t.restaurant_id::text,''), tp.rest_id::text, o.metadata->>'restaurant_id')
       where nullif(o.payment_key,'') is not null
         and lower(coalesce(o.status,'')) not in ('pending','failed','ready','expired')
         and (coalesce(p_include_test,false) or not (o.user_id = any(v_test)))
         and (p_from is null or (coalesce(o.approved_at, o.created_at) at time zone 'Asia/Seoul')::date >= p_from)
         and (p_to   is null or (coalesce(o.approved_at, o.created_at) at time zone 'Asia/Seoul')::date <  p_to)
    ) x;

  -- ═══ 카드 B. 결제 링크 · 링크 초대 · 대관 정산 · 멤버십 · 자유 금액 (kashikiri_charges) ═══
  --   카드 정보는 이 표에 없다 — 토스에서 다시 읽은 캐시(live)로만 보인다. 실제 결제자는 payer_name/phone, 회원은 user_id.
  select coalesce(jsonb_agg(x.r order by x.at desc), '[]'::jsonb) into v_chg
      from (
        select coalesce(c.approved_at, c.created_at) as at, jsonb_strip_nulls(jsonb_build_object(
          'k', 'c:' || c.id::text, 'src', 'charge', 'charge_id', c.id,
          'ch', case when coalesce(to_jsonb(c)->>'purpose','') = 'membership' then 'membership'
                     when coalesce((to_jsonb(c)->>'link_invite')::boolean, false) or coalesce(to_jsonb(c)->>'purpose','') = 'ticket' then 'link'
                     when c.event_id is not null then 'settle' else 'custom' end,
          'purpose', to_jsonb(c)->>'purpose', 'order_id', c.order_id, 'st', lower(coalesce(c.status,'')), 'fail', left(c.fail_reason, 80),
          'cur', upper(coalesce(c.pay_currency,'KRW')), 'amt', coalesce(c.pay_amount, c.amount_krw), 'krw', c.amount_krw, 'fx', c.pay_fx,
          'pkey', c.payment_key, 'method', left(c.method, 30), 'receipt', left(to_jsonb(c)->>'receipt_url', 400),
          'at', coalesce(c.approved_at, c.created_at), 'created', c.created_at,
          'uid', cu.id, 'buyer', nullif(btrim(pr.display_name),''), 'phone', to_jsonb(pr)->>'phone', 'email', to_jsonb(pr)->>'email',
          'tier', to_jsonb(pr)->>'membership_tier', 'test', case when cu.id = any(v_test) then true end,
          'payer', left(nullif(btrim(c.payer_name),''), 60), 'payer_phone', left(to_jsonb(c)->>'payer_phone', 30), 'label', left(c.label, 80),
          'title', left(to_jsonb(c)->>'title', 120), 'subtitle', left(to_jsonb(c)->>'subtitle', 160),
          'rest', coalesce(rs.name, e.venue_name, to_jsonb(tp)->>'rest_name'),
          'visit', coalesce(e.event_date, public._taam_pu_visit_date(tp.date), public._taam_pu_visit_date(s.reservation_date)),
          'vtime', coalesce(to_char(e.event_time, 'HH24:MI'), nullif(s.visit_time,''), tp.time),
          'pax', coalesce(s.party_size, public._taam_pl_num(to_jsonb(c)->'payload'->>'pax')),
          'pid', s.purchase_id, 'tst', lower(s.status),
          'rf_krw', c.refund_krw, 'rf_amt', c.refund_amount, 'rf_at', c.refunded_at, 'rf_reason', left(c.cancel_reason, 160),
          'note', left(a.note, 400), 'fee_rec', mf.amount_krw,
          'price_override', case when coalesce(to_jsonb(c)->'payload'->>'price_override','') = 'true' then true end,
          'mid', pc.mid, 'live', pc.info, 'live_at', pc.info_at, 'live_err', pc.info_error,
          'settle', pc.settle, 'settle_at', pc.settle_at, 'settle_err', pc.settle_error, 'cache_at', pc.updated_at
        )) as r
          from public.kashikiri_charges c
          -- 대관 정산 청구의 user_id 는 「구매자 불러오기」로 어드민 uid 가 실릴 수 있다 — 회원(role user)일 때만 회원으로 본다(리뷰: 어드민이 회원으로 보이고 테스트 계정이면 손님 결제가 통째로 숨었다)
          left join public.profiles pu on pu.id = c.user_id
          cross join lateral (select case when c.event_id is not null and not coalesce((to_jsonb(c)->>'link_invite')::boolean, false)
                                               and coalesce(pu.role, '') <> 'user' then null else c.user_id end as id) cu
          left join public.profiles pr on pr.id = cu.id
          left join public.kashikiri_events e on e.id = c.event_id
          left join public.toss_payment_cache pc on pc.payment_key = c.payment_key
          left join lateral (select t.* from public.tickets t
                              where t.extra_data->>'chargeId' = c.id::text and coalesce(t.purchase_id,'') ~ '^(LINK|KSK)-'
                              order by (lower(coalesce(t.status,'')) in ('active','manual','used')) desc, t.created_at desc limit 1) s on true
          left join public.ticket_products tp on tp.id::text = coalesce(s.ticket_product_id::text, to_jsonb(e)->>'ticket_product_id')
          left join public.restaurants rs on rs.id::text = coalesce(nullif(s.restaurant_id::text,''), tp.rest_id::text, e.venue_id)
          left join lateral (select ca.note from public.kashikiri_charge_admin ca where ca.charge_id = c.id limit 1) a on true
          left join lateral (select f.amount_krw from public.membership_fees f where f.source = 'pay_link' and f.source_ref = c.id::text limit 1) mf on true
         where (nullif(c.payment_key,'') is not null or lower(coalesce(c.status,'')) in ('paid','refunded'))
           and (coalesce(p_include_test,false) or not coalesce(cu.id = any(v_test), false))
           and (p_from is null or (coalesce(c.approved_at, c.created_at) at time zone 'Asia/Seoul')::date >= p_from)
           and (p_to   is null or (coalesce(c.approved_at, c.created_at) at time zone 'Asia/Seoul')::date <  p_to)
      ) x;

  -- ═══ 예치금 결제 ═══
  --   (회원, 구매 id) 마다 한 줄 — 티켓 결제 · 초대 결제 · 인원 늘림 추가 결제. 구매 id 가 없는 줄(관리 차감·옛 멤버십 결제 등)은 줄마다.
  --   돈이 실제로 빠진 줄(amount < 0)만 결제로 센다.
  select coalesce(jsonb_agg(x.r order by x.at desc), '[]'::jsonb) into v_dep
    from (
      select g.at, jsonb_strip_nulls(jsonb_build_object(
        'k', g.gk, 'kind', g.kind, 'at', g.at, 'last_at', g.last_at, 'n', g.n,
        'uid', g.uid, 'buyer', coalesce(nullif(btrim(pr.display_name),''), nullif(btrim(t.buyer_name),'')),
        'phone', to_jsonb(pr)->>'phone', 'email', to_jsonb(pr)->>'email', 'tier', to_jsonb(pr)->>'membership_tier',
        'test', case when g.uid = any(v_test) then true end,
        'pay', g.pay, 'mem', g.mem, 'gen', g.gen, 'ctypes', g.ctypes,
        'pid', g.pid, 'order_id', g.order_id, 'invite_id', g.invite_id, 'desc', g.descr,
        'fee', case when g.fee then true end, 'by_name', g.by_name,
        'fx_cur', g.fx_cur, 'fx_amt', g.fx_amt,
        'rest', coalesce(rs.name, nullif(t.restaurant_name,''), to_jsonb(tp)->>'rest_name', iv.restaurant_name, g.m_rest),
        'visit', coalesce(public._taam_pu_visit_date(tp.date), public._taam_pu_visit_date(t.reservation_date), public._taam_pu_visit_date(iv.visit_date), public._taam_pu_visit_date(g.m_visit)),
        'vtime', coalesce(nullif(t.visit_time,''), tp.time, nullif(iv.visit_time,''), g.m_vtime),
        'pax', coalesce(t.party_size, iv.pax, public._taam_pl_num(g.m_pax)),
        'tpid', t.purchase_id, 'tst', lower(t.status), 'tprice', t.price, 't_order', left(t.extra_data->>'order_id', 80),
        'card_paid', public._taam_pl_num(t.extra_data->>'cardPaid'),
        'ret', case when jsonb_typeof(t.extra_data->'deposit_return') = 'object' then jsonb_strip_nulls(jsonb_build_object(
                 'type', left(t.extra_data->'deposit_return'->>'type', 20), 'returnAmt', public._taam_pl_num(t.extra_data->'deposit_return'->>'returnAmt'),
                 'penaltyAmt', public._taam_pl_num(t.extra_data->'deposit_return'->>'penaltyAmt'), 'agencyHeld', public._taam_pl_num(t.extra_data->'deposit_return'->>'agencyHeld'),
                 'extraDeduct', public._taam_pl_num(t.extra_data->'deposit_return'->>'extraDeduct'))) end,
        't_cancel_at', coalesce(left(t.extra_data->>'server_cancelled_at', 40), left(t.extra_data->>'cancelled_at', 40)),
        't_cancel_reason', left(t.extra_data->>'cancel_reason', 120),
        'inv_st', lower(iv.status), 'inv_total', iv.total_amount, 'inv_host', nullif(btrim(ph.display_name),''),
        'plain', case when g.order_id is not null and v_plain ? (g.uid::text || '|' || coalesce(g.pid, '')) then true end,
        'ord_st', case when g.order_id is not null then (select lower(po.status) from public.payment_orders po where po.order_id = g.order_id) end,
        'rf', case when g.pid is not null then v_rf->(g.uid::text || '|' || g.pid) end
      )) as r
        from (
          select d.gk, min(d.uid::text)::uuid as uid, min(d.pid) as pid,
                 case when bool_or(coalesce(d.pid,'') like 'INV-%' or coalesce(d.metadata->>'invite_id','') <> '') then 'invite'
                      when bool_or(d.change_type in ('ticket_purchase','ticket_pax_change','reservation_payment')) then 'ticket'
                      when bool_or(d.change_type = 'admin_deduct') then 'deduct'
                      when bool_or(d.change_type = 'membership_payment') then 'membership'
                      else 'other' end as kind,
                 min(d.created_at) as at, max(d.created_at) as last_at, count(*) as n,
                 -sum(d.amount) as pay, -sum(d.amount) filter (where d.deposit_type = 'membership') as mem,
                 -sum(d.amount) filter (where coalesce(d.deposit_type,'') <> 'membership') as gen,
                 jsonb_agg(distinct d.change_type) as ctypes,
                 max(d.metadata->>'order_id') as order_id, max(d.metadata->>'invite_id') as invite_id,
                 left((array_agg(d.description order by d.created_at))[1], 160) as descr,
                 bool_or(d.metadata ? 'membership_fee') as fee,
                 max(left(d.metadata->>'granted_by_name', 40)) as by_name,
                 max(left(d.metadata->>'fx_currency', 5)) as fx_cur, max(public._taam_pl_num(d.metadata->>'fx_amount')) as fx_amt,
                 max(d.metadata->>'restaurant_name') as m_rest, max(d.metadata->>'visit_date') as m_visit,
                 max(d.metadata->>'visit_time') as m_vtime, max(coalesce(d.metadata->>'party_size', d.metadata->>'pax')) as m_pax
            from (select dt.*, dt.user_id as uid, nullif(dt.metadata->>'purchase_id','') as pid,
                         -- 카드와 같이 낸 줄은 주문마다 따로 — 자동 취소된 앞 시도와 같은 홀드로 다시 낸 결제가 한 줄로 합쳐지지 않게(리뷰)
                         case when coalesce(dt.metadata->>'purchase_id','') <> '' and dt.change_type in ('ticket_purchase','ticket_pax_change','reservation_payment')
                              then 'p:' || dt.user_id::text || '|' || (dt.metadata->>'purchase_id') || coalesce('|' || nullif(dt.metadata->>'order_id',''), '')
                              else 'd:' || dt.id::text end as gk
                    from public.deposit_transactions dt
                   where dt.amount < 0 and dt.user_id is not null) d
           group by d.gk
        ) g
        left join public.profiles pr on pr.id = g.uid
        left join lateral (select t.* from public.tickets t
                            -- 남의 초대 id 를 자기 원장 줄에 적어도 그 초대·티켓이 붙지 않게 — 초대받은 회원이 이 줄의 회원일 때만(리뷰)
                            where g.pid is not null and t.purchase_id = g.pid
                              and (t.user_id = g.uid
                                   or (g.pid like 'INV-%' and g.invite_id is not null and t.extra_data->>'inviteId' = g.invite_id
                                       and exists (select 1 from public.reservation_invites i2 where i2.id::text = g.invite_id and i2.invitee_user_id = g.uid)))
                            order by (t.user_id = g.uid) desc, (lower(coalesce(t.status,'')) in ('active','used')) desc, t.created_at limit 1) t on true
        left join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
        left join public.restaurants rs on rs.id::text = coalesce(nullif(t.restaurant_id::text,''), tp.rest_id::text)
        left join public.reservation_invites iv on g.invite_id is not null and iv.id::text = g.invite_id and iv.invitee_user_id = g.uid
        left join public.profiles ph on ph.id = iv.host_user_id
       where (coalesce(p_include_test,false) or not (g.uid = any(v_test)))
         and (p_from is null or (g.at at time zone 'Asia/Seoul')::date >= p_from)
         and (p_to   is null or (g.at at time zone 'Asia/Seoul')::date <  p_to)
    ) x;

  -- ═══ 예치금 입금 — 부여(입금)·옛 충전 · 결제에 붙지 않는 환불·기타(+) ═══
  --   구매 id 가 있는 환불은 위 결제 줄에 붙는다 — 그 결제(같은 회원·같은 구매 id 의 음수 줄)가 없을 때만 여기 따로.
  select coalesce(jsonb_agg(x.r order by x.at desc), '[]'::jsonb) into v_in
    from (
      select d.created_at as at, jsonb_strip_nulls(jsonb_build_object(
        'k', 'd:' || d.id::text, 'kind', case when d.change_type in ('admin_grant','user_charge') then 'grant' else 'in_other' end,
        'at', d.created_at, 'uid', d.user_id, 'buyer', nullif(btrim(pr.display_name),''), 'phone', to_jsonb(pr)->>'phone',
        'email', to_jsonb(pr)->>'email', 'tier', to_jsonb(pr)->>'membership_tier', 'test', case when d.user_id = any(v_test) then true end,
        'in', d.amount, 'pocket', d.deposit_type, 'ctype', d.change_type, 'desc', left(d.description, 160),
        'pid', nullif(d.metadata->>'purchase_id',''), 'by_name', left(d.metadata->>'granted_by_name', 40),
        'fx_cur', left(d.metadata->>'fx_currency', 5), 'fx_amt', public._taam_pl_num(d.metadata->>'fx_amount'),
        'fx_rate', public._taam_pl_num(d.metadata->>'fx_rate'), 'fx_base', public._taam_pl_num(d.metadata->>'fx_base'),
        'fx_margin', public._taam_pl_num(d.metadata->>'fx_margin_pct'), 'fix', case when d.metadata ? 'fix' then true end
      )) as r
        from public.deposit_transactions d
        left join public.profiles pr on pr.id = d.user_id
       where d.amount > 0 and d.user_id is not null
         and (coalesce(d.metadata->>'purchase_id','') = ''
              or not exists (select 1 from public.deposit_transactions x
                              where x.user_id = d.user_id and x.amount < 0 and x.metadata->>'purchase_id' = d.metadata->>'purchase_id'
                                and x.change_type in ('ticket_purchase','ticket_pax_change','reservation_payment')))
         and (coalesce(p_include_test,false) or not (d.user_id = any(v_test)))
         and (p_from is null or (d.created_at at time zone 'Asia/Seoul')::date >= p_from)
         and (p_to   is null or (d.created_at at time zone 'Asia/Seoul')::date <  p_to)
    ) x;

  return jsonb_build_object('ok', true, 'v', 1,
    'today', (now() at time zone 'Asia/Seoul')::date, 'generated_at', now(),
    'from', p_from, 'to', p_to,
    'card', v_card || v_chg,
    'dep', v_dep || v_in);
end $$;
revoke all on function public.taam_payment_ledger(date, date, boolean) from public, anon;
grant execute on function public.taam_payment_ledger(date, date, boolean) to authenticated;

-- ── 확인 (하나로 합친다 — SQL Editor 는 마지막 결과만 보여 준다 · ❌ 가 없어야 정상 · 이름·금액은 찍지 않는다) ──
create temp table _plk(seq serial, 항목 text, 결과 text);
insert into _plk(항목, 결과) values
 ('① 캐시 표 toss_payment_cache', case when to_regclass('public.toss_payment_cache') is not null then '✅' else '❌' end),
 ('② 캐시 표 회원 접근 막힘(RLS 켬 · authenticated 권한 없음)',
   case when (select relrowsecurity from pg_class where oid = 'public.toss_payment_cache'::regclass)
         and not has_table_privilege('authenticated', 'public.toss_payment_cache', 'select') then '✅' else '❌' end),
 ('③ RPC taam_payment_ledger', case when to_regprocedure('public.taam_payment_ledger(date,date,boolean)') is not null then '✅' else '❌' end),
 ('④ 기대는 함수 — _taam_fee_caller_ok · _taam_pu_visit_date',
   case when to_regproc('public._taam_fee_caller_ok') is not null and to_regproc('public._taam_pu_visit_date') is not null then '✅' else '❌' end),
 ('⑤ anon 실행 권한 없음', case when not has_function_privilege('anon', 'public.taam_payment_ledger(date,date,boolean)', 'execute') then '✅' else '❌' end);
do $do$
declare j jsonb;
begin
  j := public.taam_payment_ledger(null, null, true);   -- SQL Editor·워크플로(postgres 세션)는 _taam_fee_caller_ok 를 통과한다
  -- 공개 저장소라 Actions 로그도 공개 — 건수·종류별 분포도 찍지 않는다(리뷰). 돌았는지만
  insert into _plk(항목, 결과) values ('⑥ 전체 기간 실행', case when jsonb_typeof(j->'card') = 'array' and jsonb_typeof(j->'dep') = 'array' then '✅' else '❌' end);
  insert into _plk(항목, 결과) values ('⑦ 카드 줄에 secret 칸 없음',
    case when position('"secret"' in (j->'card')::text) = 0 then '✅' else '❌' end);
exception when others then insert into _plk(항목, 결과) values ('⑥ 전체 기간 실행', '❌ ' || left(sqlerrm, 160));
end $do$;
select 항목, 결과 from _plk order by seq;
