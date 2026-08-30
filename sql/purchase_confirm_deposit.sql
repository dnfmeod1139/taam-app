-- ═══════════════════════════════════════════════════════════════
-- TAAM — 예치금 결제 확정을 서버에서 한다 (2026-08-31)
-- 설계: docs/DESIGN_purchase_server_rpc.md 의 2단계
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제였나
--   예치금으로 티켓을 살 때 **앱이 금액을 정한다.**
--
--     var paid = (window._tdPayAmount > 0) ? window._tdPayAmount : (meal+agency+wine)*pax;
--     ... .update({ status:'active', price: paid })
--
--   차감은 어제 서버 RPC 로 옮겼지만(taam_apply_deposit_delta), **차감액과
--   티켓 금액이 서로를 검증하지 않는다.** 1원만 차감하고 price 를 90만원으로
--   적을 수 있고, 그 반대도 된다. 게다가 차감·거래기록·티켓확정이 각각
--   따로 나가서, 중간에 끊기면 돈만 빠지고 예약이 안 생긴다.
--
--   실측해 보니 PAYH- 구매 6건이 **전부 예치금**이고 카드 실적은 0이다.
--   즉 이 경로가 지금 돈이 흐르는 유일한 길이다.
--
-- 무엇을 하나
--   금액 재계산 · 잔액 차감 · 거래기록 · 티켓 확정을 **한 트랜잭션**으로 묶는다.
--   전부 되거나 전부 없던 일이 된다.
--
-- 금액은 서버가 다시 센다
--   ticket_products 의 meal_fee + agency_fee + wine_min 에 인원을 곱한다.
--   앱의 (meal+agency+wine)*pax 와 같은 식이다.
--   ⚠ 실측 결과 지금 있는 모든 구매에서 **앱 금액 = 서버 재계산(0건 불일치)**.
--      그래서 이 검증을 켜도 정상 구매가 막히지 않는다.
--
-- 외화는 막지 않고 건너뛴다
--   USD 회원이 한 명 있다. 외화는 app_config.fx_settings 의 환율이 얽혀 있어
--   서버가 아직 정확히 못 센다. 「원화만 검증, 외화는 거부」로 만들면 그 회원이
--   못 산다 — 그건 안 된다. **못 세면 검증을 건너뛰고 통과시킨다.**
--   지금보다 나쁘지 않고, 회원 27명 중 26명이 즉시 보호된다.
--
-- p_expect_amount 를 받는 이유
--   서버가 계산하는데 앱 값을 왜 받나 — **가격이 바뀐 것을 잡기 위해서다.**
--   회원이 결제창을 열어 둔 사이 어드민이 가격을 고쳤으면, 회원이 본 금액과
--   실제가 다르다. 그냥 서버 값으로 긁으면 **본 적 없는 금액이 빠져나간다.**
--   다르면 멈추고 앱이 다시 보여줘야 한다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
--       ⚠ 이 파일만 올려도 아무 일도 안 난다 — 앱이 불러야 쓰인다.
--          앱은 BUILD 2026.08.31-d 부터 이 함수를 부른다.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 이 티켓의 원화 금액을 서버가 센다
-- ═══════════════════════════════════════════════════════════════
--   못 세면 null 을 준다 (외화·요금 미등록 등). null 이면 검증을 건너뛴다.
create or replace function public.taam_ticket_price_krw(p_ticket_id text, p_pax int)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
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
$$;

comment on function public.taam_ticket_price_krw(text,int) is
  '티켓의 원화 결제액을 서버가 계산한다. 못 세면 null (외화·요금 미등록).';


-- ═══════════════════════════════════════════════════════════════
-- ② 예치금 결제 확정 — 전부 되거나 전부 없던 일이 되거나
-- ═══════════════════════════════════════════════════════════════
create or replace function public.taam_purchase_confirm_deposit(
  p_purchase_id   text,
  p_expect_amount bigint,
  p_buyer_name    text default null,
  p_buyer_phone   text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_tk     record;
  v_srv    bigint;
  v_pay    bigint;
  v_mem    bigint;
  v_gen    bigint;
  v_from_m bigint := 0;
  v_from_g bigint := 0;
  v_after  bigint;
  v_rest   text;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if coalesce(p_expect_amount, -1) < 0 then
    raise exception '결제 금액이 올바르지 않습니다' using errcode = '22023';
  end if;

  -- ── 홀드를 잠그고 읽는다 ──────────────────────────────────────
  --   for update 가 핵심이다. 같은 홀드로 두 번 눌러도 하나만 통과한다.
  select * into v_tk
    from public.tickets
   where purchase_id = p_purchase_id
   for update;

  if not found then
    raise exception 'HOLD_NOT_FOUND: 좌석 확보 기록이 없습니다 (다시 시도해주세요)'
      using errcode = 'P0002';
  end if;

  if v_tk.user_id is distinct from v_uid then
    raise exception '내 예약이 아닙니다' using errcode = '42501';
  end if;

  -- 이미 확정된 것을 또 부르면 조용히 성공으로 돌려준다.
  --   네트워크가 끊겨 앱이 다시 부르는 일이 실제로 있다. 그때 두 번 차감하면 안 된다.
  if coalesce(v_tk.status,'') = 'active' then
    return json_build_object('ok', true, 'already', true,
                             'purchase_id', p_purchase_id, 'price', v_tk.price);
  end if;

  if coalesce(v_tk.status,'') <> 'hold' then
    raise exception 'HOLD_GONE: 좌석 확보가 만료되었습니다 (상태: %)', coalesce(v_tk.status,'없음')
      using errcode = 'P0002';
  end if;

  -- ── 금액을 서버가 다시 센다 ──────────────────────────────────
  v_srv := public.taam_ticket_price_krw(v_tk.ticket_product_id::text, v_tk.party_size);

  if v_srv is null then
    -- 못 셌다 (외화·요금 미등록). 검증을 건너뛰고 앱 값을 쓴다.
    --   ⚠ 막지 않는 쪽을 택한 것이다 — 막으면 외화 회원이 못 산다.
    --      대신 흔적을 남겨 나중에 셀 수 있게 한다.
    v_pay := p_expect_amount;
    raise notice '[confirm] 금액 검증 건너뜀 (서버 계산 불가) purchase=% pay=%',
      p_purchase_id, v_pay;
  elsif v_srv <> p_expect_amount then
    -- 회원이 본 금액과 지금 값이 다르다. 긁지 않고 멈춘다.
    raise exception 'PRICE_CHANGED: 금액이 바뀌었습니다 (화면 %원 · 현재 %원)',
      p_expect_amount, v_srv
      using errcode = '22023';
  else
    v_pay := v_srv;
  end if;

  -- ── 잔액을 잠그고 확인한다 ───────────────────────────────────
  select coalesce(membership_deposit_balance,0), coalesce(general_deposit_balance,0)
    into v_mem, v_gen
    from public.profiles
   where id = v_uid
   for update;

  if not found then
    raise exception '회원 정보를 찾을 수 없습니다' using errcode = 'P0002';
  end if;

  if v_mem + v_gen < v_pay then
    raise exception 'INSUFFICIENT_DEPOSIT: 예치금이 부족합니다 (잔액 %원 · 필요 %원)',
      v_mem + v_gen, v_pay
      using errcode = '22023';
  end if;

  -- ── 차감 — 멤버십 먼저, 일반 나중 (앱과 같은 순서) ───────────
  v_from_m := least(v_mem, v_pay);
  v_from_g := v_pay - v_from_m;
  v_after  := (v_mem - v_from_m) + (v_gen - v_from_g);

  update public.profiles
     set membership_deposit_balance = v_mem - v_from_m,
         general_deposit_balance    = v_gen - v_from_g
   where id = v_uid;
  -- deposit_balance 는 sync 트리거가 맞춘다 — 여기서 직접 쓰지 않는다

  v_rest := coalesce(v_tk.restaurant_name, '티켓');

  -- ── 거래기록 — 나간 주머니마다 한 줄 (앱과 같은 모양) ────────
  --   나중에 환불할 때 「어느 주머니에서 나갔는지」를 이 기록으로 찾는다.
  --   한 줄로 뭉치면 _depRefundSplit 이 주머니를 못 가린다.
  if v_from_m > 0 then
    insert into public.deposit_transactions
      (user_id, deposit_type, change_type, amount, balance_after, description, metadata)
    values (v_uid, 'membership', 'ticket_purchase', -v_from_m,
            (v_mem - v_from_m) + v_gen,
            v_rest || ' 티켓 ' || coalesce(v_tk.party_size,1) || '인 구매 (멤버십 예치금)',
            jsonb_build_object('purchase_id', p_purchase_id,
                               'ticket_id', v_tk.ticket_product_id,
                               'restaurant_id', v_tk.restaurant_id,
                               'restaurant_name', v_rest,
                               'party_size', v_tk.party_size,
                               'payment_method', 'deposit_only',
                               'portion', 'membership',
                               'server_confirmed', true));
  end if;

  if v_from_g > 0 then
    insert into public.deposit_transactions
      (user_id, deposit_type, change_type, amount, balance_after, description, metadata)
    values (v_uid, 'general', 'ticket_purchase', -v_from_g, v_after,
            v_rest || ' 티켓 ' || coalesce(v_tk.party_size,1) || '인 구매 (일반 예치금)',
            jsonb_build_object('purchase_id', p_purchase_id,
                               'ticket_id', v_tk.ticket_product_id,
                               'restaurant_id', v_tk.restaurant_id,
                               'restaurant_name', v_rest,
                               'party_size', v_tk.party_size,
                               'payment_method', 'deposit_only',
                               'portion', 'general',
                               'server_confirmed', true));
  end if;

  -- ── 티켓 확정 ────────────────────────────────────────────────
  update public.tickets
     set status     = 'active',
         price      = v_pay,
         buyer_name = coalesce(nullif(p_buyer_name, ''), buyer_name),
         buyer_phone= coalesce(nullif(p_buyer_phone, ''), buyer_phone),
         extra_data = coalesce(extra_data, '{}'::jsonb)
                      || jsonb_build_object('paidBy', 'deposit',
                                            'server_confirmed', true,
                                            'confirmed_at', now())
   where purchase_id = p_purchase_id;

  return json_build_object(
    'ok', true,
    'purchase_id', p_purchase_id,
    'price', v_pay,
    'from_membership', v_from_m,
    'from_general', v_from_g,
    'balance_after', v_after,
    'price_verified', (v_srv is not null)
  );
end;
$$;

revoke all on function public.taam_purchase_confirm_deposit(text, bigint, text, text) from public;
grant execute on function public.taam_purchase_confirm_deposit(text, bigint, text, text) to authenticated;

comment on function public.taam_purchase_confirm_deposit(text, bigint, text, text) is
  '예치금 결제 확정 — 금액 재계산·차감·거래기록·티켓확정을 한 트랜잭션으로. 외화는 검증을 건너뛴다.';


-- ═══════════════════════════════════════════════════════════════
-- ③ 확인
-- ═══════════════════════════════════════════════════════════════
select p.proname                          as "함수",
       pg_get_function_arguments(p.oid)   as "인자",
       case when p.prosecdef then 'DEFINER' else 'INVOKER' end as "권한"
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('taam_purchase_confirm_deposit','taam_ticket_price_krw')
order by 1;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   앱을 옛 빌드로 되돌리면 이 함수는 안 불린다. 함수를 지울 필요도 없다.
--   급하면:  drop function if exists public.taam_purchase_confirm_deposit(text,bigint,text,text);
--
-- ═══════════════════════════════════════════════════════════════
-- 남은 것
-- ═══════════════════════════════════════════════════════════════
--   ⓐ 외화 금액을 서버가 세게 한다 (app_config.fx_settings 의 환율 적용).
--      그때 price_verified 가 false 인 구매를 세어 보면 대상이 나온다.
--   ⓑ 3단계 — INSERT 잠금. 이 RPC 가 라이브에서 확인된 뒤에.
