-- ============================================================================
-- 20261116_card_order_settle.sql — 카드 승인 뒤 확정 실패 때 예치금 되돌림을 서버 한 곳에서 (2026-11-15 · 카드 후속)
-- ============================================================================
-- 왜
--   티켓 부족분 카드 결제(toss-confirm · toss-billing-charge)는 승인 뒤 ① 예치금 차감 → ② 좌석 홀드 → 구매 전환을 한다.
--   ② 가 막히면(좌석 상실 · 재구매 제한 · 중복 · 시간대 · 예치금 부족 …) 뺀 예치금을 되돌리고 카드를 취소한다.
--   종전 Edge 는 「이번 호출이 뺐다고 들은 금액」만 되돌렸다:
--     · 차감 응답을 잃으면(실제로는 빠졌는데) 0 원으로 알아 되돌리지 않았다 — 회원 예치금이 사라진다
--     · 되돌림 RPC 가 실패하면 .catch(()=>{}) 로 삼켰다 — 알림도 없다
--     · 되돌림을 다시 시도하면 첫 시도가 실제로 들어갔는지 몰라 두 번 돌려줄 수 있었다
--   → 이 함수 하나가 **원장을 근거로** 「이 주문으로 빠지고 아직 안 돌아간 예치금」을 센 뒤 그만큼만 되돌린다.
--     회원 잔액 줄을 먼저 잠그므로(진행 중인 차감·되돌림이 끝날 때까지 기다린다) 두 번 불러도 두 번 돌려주지 않는다(멱등).
--
-- 무엇
--   taam_card_order_settle(p_order, p_user, p_cap, p_purchase_id, p_code, p_why) → jsonb
--     · 서버만(Edge service_role · SQL Editor) — 로그인 세션은 슈퍼어드민도 FORBIDDEN · anon/authenticated 실행 권한 없음
--     · 주문(payment_orders): 있어야 하고 그 회원 것 · 용도 ticket_topup
--     · 원장(deposit_transactions) 중 metadata.order_id = 이 주문:
--         빠진 것   = change_type ticket_purchase · 음수 · 주머니별
--         돌아간 것 = change_type ticket_refund   · 양수 · 주머니별
--       주머니마다 owed = 빠진 것 − 돌아간 것 (0 미만이면 0)
--     · 상한(p_cap, 없으면 주문 metadata.deposit_used): owed 합이 상한을 넘으면 자른다 — 회원은 자기 원장에 아무 metadata 의 음수 줄을
--       쓸 수 있어(합계 0 이면 잔액은 그대로) 주문 번호를 단 가짜 「차감」 줄로 되돌림을 부풀릴 수 있었다(적대 리뷰 M9).
--       상한은 주문을 만들 때 서버(toss-order)가 적은 「예치금으로 낼 몫」이다. 멤버십 주머니부터 채운다(차감이 멤버십 먼저다).
--     · owed 가 있으면 taam_apply_deposit_delta 로 그 주머니에 ticket_refund 줄(metadata order_id · purchase_id · card_fail_code)을 쓴다
--       ⚠ metadata 에 reason / fix / refund_type / cancel_refund 를 넣지 않는다 — 판매 현황·결제 내역이 그 키로 환불 종류를 가른다(card_auto 로 보여야 한다).
--   돌려주는 값: {ok, refunded_mem, refunded_gen, out_mem, out_gen, in_mem, in_gen, cap, owed_before}
--
-- 앱·라이브 함수 본문은 건드리지 않는다(새 함수 하나). 되돌리기: drop function public.taam_card_order_settle(text, uuid, bigint, text, text, text);
-- ============================================================================

create or replace function public.taam_card_order_settle(
  p_order text, p_user uuid, p_cap bigint default null, p_purchase_id text default null, p_code text default null, p_why text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- CARD_SETTLE_20261116
  v_jwt     text := '';
  v_o       record;
  v_out_mem bigint := 0; v_out_gen bigint := 0; v_in_mem bigint := 0; v_in_gen bigint := 0;
  v_mem     bigint; v_gen bigint; v_cap bigint; v_meta_cap text;
  v_md      jsonb;
  v_entries jsonb := '[]'::jsonb;
  v_why     text;
begin
  -- 서버만 — 로그인 세션(회원·매장 어드민·슈퍼어드민)은 부르지 못한다. 실행 권한도 service_role 에만 준다.
  if auth.uid() is not null then
    raise exception 'FORBIDDEN: 서버 전용 함수입니다' using errcode = '42501';
  end if;
  begin v_jwt := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', ''); exception when others then v_jwt := ''; end;
  if v_jwt <> 'service_role' and session_user <> 'postgres' then
    raise exception 'FORBIDDEN: 서버 전용 함수입니다' using errcode = '42501';
  end if;
  if coalesce(btrim(p_order), '') = '' or p_user is null then
    raise exception 'SETTLE_BAD_ARGS: 주문·회원이 필요합니다' using errcode = '22023';
  end if;

  select o.order_id, o.user_id, o.purpose, o.status, o.metadata into v_o
    from public.payment_orders o where o.order_id = p_order;
  if not found then raise exception 'ORDER_NOT_FOUND: %', p_order using errcode = 'P0002'; end if;
  if v_o.user_id is distinct from p_user then raise exception 'ORDER_FORBIDDEN: 주문의 회원이 다릅니다' using errcode = '42501'; end if;
  if coalesce(v_o.purpose, '') <> 'ticket_topup' then raise exception 'SETTLE_BAD_PURPOSE: %', v_o.purpose using errcode = '22023'; end if;

  -- 회원 잔액 줄을 먼저 잠근다 — 같은 회원의 진행 중인 차감·되돌림(taam_apply_deposit_delta 도 이 줄을 잠근다)이 끝난 뒤에 원장을 센다.
  --   그래야 「응답만 잃은 차감」을 놓치지 않고, 겹친 두 호출이 같은 금액을 두 번 돌려주지 않는다.
  perform 1 from public.profiles where id = p_user for update;
  if not found then raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0002'; end if;

  select coalesce(sum(-d.amount) filter (where d.change_type = 'ticket_purchase' and d.amount < 0 and d.deposit_type = 'membership'), 0),
         coalesce(sum(-d.amount) filter (where d.change_type = 'ticket_purchase' and d.amount < 0 and d.deposit_type = 'general'), 0),
         coalesce(sum(d.amount)  filter (where d.change_type = 'ticket_refund'   and d.amount > 0 and d.deposit_type = 'membership'), 0),
         coalesce(sum(d.amount)  filter (where d.change_type = 'ticket_refund'   and d.amount > 0 and d.deposit_type = 'general'), 0)
    into v_out_mem, v_out_gen, v_in_mem, v_in_gen
    from public.deposit_transactions d
   where d.user_id = p_user and d.metadata->>'order_id' = p_order;

  v_mem := greatest(0, v_out_mem - v_in_mem);
  v_gen := greatest(0, v_out_gen - v_in_gen);

  -- 상한 — Edge 가 넘긴 값(주문을 만들 때 서버가 적은 예치금 몫), 없으면 주문 metadata.deposit_used
  v_meta_cap := v_o.metadata->>'deposit_used';
  v_cap := coalesce(p_cap, case when v_meta_cap ~ '^\s*\d{1,12}(\.\d+)?\s*$' then round(v_meta_cap::numeric)::bigint end);
  if v_cap is not null then
    v_cap := greatest(0, v_cap);
    -- 이미 돌아간 몫도 상한에서 뺀다(상한은 「이 주문으로 돌려줄 수 있는 전부」)
    v_cap := greatest(0, v_cap - (v_in_mem + v_in_gen));
    v_mem := least(v_mem, v_cap);
    v_gen := least(v_gen, greatest(0, v_cap - v_mem));
  end if;

  if v_mem + v_gen <= 0 then
    return jsonb_build_object('ok', true, 'refunded_mem', 0, 'refunded_gen', 0, 'out_mem', v_out_mem, 'out_gen', v_out_gen,
                              'in_mem', v_in_mem, 'in_gen', v_in_gen, 'cap', v_cap, 'owed_before', 0);
  end if;

  v_why := coalesce(nullif(btrim(p_why), ''), '카드 결제 취소 · 예치금 환원');
  v_md  := jsonb_strip_nulls(jsonb_build_object('order_id', p_order, 'purchase_id', nullif(btrim(coalesce(p_purchase_id, '')), ''),
                                                'card_fail_code', left(nullif(btrim(coalesce(p_code, '')), ''), 60), 'settle', 'taam_card_order_settle'));
  if v_mem > 0 then
    v_entries := v_entries || jsonb_build_array(jsonb_build_object('deposit_type', 'membership', 'change_type', 'ticket_refund', 'amount', v_mem,
                                                                   'description', v_why, 'metadata', v_md));
  end if;
  if v_gen > 0 then
    v_entries := v_entries || jsonb_build_array(jsonb_build_object('deposit_type', 'general', 'change_type', 'ticket_refund', 'amount', v_gen,
                                                                   'description', v_why, 'metadata', v_md));
  end if;
  perform public.taam_apply_deposit_delta(p_user, v_mem, v_gen, v_entries);

  return jsonb_build_object('ok', true, 'refunded_mem', v_mem, 'refunded_gen', v_gen, 'out_mem', v_out_mem, 'out_gen', v_out_gen,
                            'in_mem', v_in_mem, 'in_gen', v_in_gen, 'cap', v_cap, 'owed_before', v_mem + v_gen);
end;
$$;

revoke all on function public.taam_card_order_settle(text, uuid, bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.taam_card_order_settle(text, uuid, bigint, text, text, text) to service_role;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 ──
select '① taam_card_order_settle 있음 (서버 전용 · 원장 근거 · 멱등)' as what,
       case when exists (select 1 from pg_proc where oid = to_regprocedure('public.taam_card_order_settle(text,uuid,bigint,text,text,text)')
                          and prosrc like '%CARD_SETTLE_20261116%' and prosecdef) then '✅' else '❌' end as result
union all
select '② anon · authenticated 실행 불가 · service_role 실행 가능',
       case when to_regprocedure('public.taam_card_order_settle(text,uuid,bigint,text,text,text)') is null then '❌'
            when not has_function_privilege('anon', 'public.taam_card_order_settle(text,uuid,bigint,text,text,text)', 'execute')
             and not has_function_privilege('authenticated', 'public.taam_card_order_settle(text,uuid,bigint,text,text,text)', 'execute')
             and has_function_privilege('service_role', 'public.taam_card_order_settle(text,uuid,bigint,text,text,text)', 'execute') then '✅' else '❌' end
union all
select '③ 의존 함수 taam_apply_deposit_delta(uuid,bigint,bigint,jsonb)',
       case when to_regprocedure('public.taam_apply_deposit_delta(uuid,bigint,bigint,jsonb)') is not null then '✅' else '❌' end
union all
select '④ 승인 뒤 확정 실패로 남은 카드 주문 — 자동 취소 실패(정보)',
       (select count(*)::text from public.payment_orders where purpose = 'ticket_topup' and coalesce(fail_reason, '') like '%refund_failed')
union all
select '⑤ 결과를 모르는 카드 주문(unknown:) (정보)',
       (select count(*)::text from public.payment_orders where purpose = 'ticket_topup' and coalesce(fail_reason, '') like 'unknown:%');
