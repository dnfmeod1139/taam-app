-- ============================================================================
-- 20261116_card_order_settle.sql — 카드 승인 뒤 확정 실패 때 예치금 되돌림 · 결과 모르는 카드 주문 정리 (2026-11-15 카드 후속 · 2026-11-16 적대 리뷰 반영)
-- ============================================================================
-- 왜
--   티켓 부족분 카드 결제(toss-confirm · toss-billing-charge)는 승인 뒤 ① 예치금 차감 → ② 좌석 홀드 → 구매 전환을 한다.
--   ② 가 막히면(좌석 상실 · 재구매 제한 · 중복 · 시간대 · 예치금 부족 …) 뺀 예치금을 되돌리고 카드를 취소한다.
--   종전 Edge 는 「이번 호출이 뺐다고 들은 금액」만 되돌렸다(응답을 잃은 차감은 0 원으로 알았고 · 되돌림 실패를 삼켰다).
--   → 서버 함수 하나가 원장을 근거로 「이 주문으로 빠지고 아직 안 돌아간 예치금」을 센 뒤 그만큼만 되돌린다(멱등).
--
--   ⚠ 2026-11-16 적대 리뷰(배포 전 · 확정 HIGH 2) — 첫 판은 「주문 번호(order_id)가 달린 차감 줄 − 되돌림 줄」을 셌다:
--     CF-1 회원은 자기 원장에 아무 metadata 의 음수 줄을 쓸 수 있다(라이브 taam_apply_deposit_delta 는 회원의 음수 항목을 묻지 않는다).
--          {order_id: 이 주문, purchase_id: FAKE-1} 로 10,000,000 을 빼 두면 카드 승인 뒤 deposit_short 정리가 그 줄을 홀드 구매 id 로 돌려주고,
--          회원은 FAKE-1 로 한 번 더 환불받았다(잔액 두 배 · 재현 repro_mint.sh).
--     CF-2 Edge 가 뺀 직후(티켓은 아직 hold) 회원이 홀드 구매 id 로 스스로 환불(refund_active 는 hold 를 살아 있는 티켓으로 안 본다)
--          → 확정이 막혀 정리가 order_id 로만 세어 또 돌려줬다(두 번 · 재현 repro_race.sh). 성공 길에서는 티켓 + 예치금을 둘 다 가졌다.
--   → 이 판:
--     ① 정리는 **홀드 구매 id 한 통**(purchase_id = p_purchase_id)으로 센다 — 회원 환불 한도(taam_refund_cap · taam_guard_ledger_refund_paid)가
--        보는 바로 그 통이다. 빠진 것 = 그 통의 ticket_purchase 음수 · 돌아간 것 = 그 통의 ticket_refund·ticket_pax_change 양수(주문 번호와 상관없이).
--        다른 구매 id 로 단 위조 줄은 통에 안 들어오고, 통 안의 위조 줄을 돌려주면 회원 자신의 환불 한도가 그만큼 줄어든다(두 번 받을 길이 없다).
--     ② 상한 = **Edge 가 실제로 뺀 금액** — Edge 가 p_cap 으로 넘기고, 서버 기록(payment_orders.metadata.card_dep — 회원은 이 표를 못 쓴다 · RLS 읽기만)과
--        작은 쪽. 차감이 분명히 0(예치금 부족·거절)이면 Edge 는 정리를 부르지 않는다. 차감 응답을 잃었을 때만 「예치금으로 낼 몫(plan)」이 상한.
--        이 주문으로 이미 돌아간 몫(order_id 가 이 주문인 환불 줄)은 상한에서 뺀다. 상한을 정할 근거가 없으면 SETTLE_NO_CAP(SQL Editor 는 p_cap 을 준다).
--     ③ 홀드 구매 id 가 없으면 거절(SETTLE_BAD_ARGS) · 주문이 적은 홀드와 다르면 거절(SETTLE_HOLD_MISMATCH).
--     ④ 이 주문으로 확정된 살아 있는 티켓이 있으면 되돌리지 않는다(SETTLE_TICKET_LIVE — 늦게 커밋된 전환 · 공짜 티켓 방지 · CF-5 방어).
--     ⑤ 회원 세션은 「Edge 가 처리 중인(paid · 결과 미정) 카드 주문」의 홀드 구매 id 로 스스로 환불하지 못한다(trg_taam_guard_ledger_refund_cardpend · CF-2 성공 길).
--        정상 회원 환불(구매 취소)은 그 주문으로 확정된 티켓 행이 있어 그대로 지난다.
--     ⑥ 같은 홀드(또는 같은 회차의 승인된 주문)에 결과를 모르는 카드 주문이 있으면 새 카드 주문을 못 만든다(PAYMENT_PENDING · TOSSRB-2 — 두 번 청구 방지).
--     ⑦ 결과를 모르는(unknown:*) 카드 주문을 10분마다 Edge toss-confirm 의 sweep 이 토스에 조회해 잇거나 정리한다(taam_card_topup_reconcile_list/_kick · CF-6 · TOSSRB-1).
--     ⑧ 슈퍼어드민 알림 「결제 내역에서 이 주문 보기」가 아직 결제 내역에 없는(결과 모름 · pending) 주문도 보이게 — taam_card_order_peek(CFAPP-1).
--
-- 배포 순서: 이 SQL → Edge(toss-order · toss-confirm · toss-billing-charge) → 앱. 워크플로가 SQL → Edge 순서를 지킨다(앱은 Vercel).
--   SQL 만 먼저 가도 안전하다 — 옛 Edge(v27·v23)는 이 함수들을 부르지 않는다. ⑤⑥ 가드는 옛 Edge 의 흐름도 막지 않는다(회원 세션·새 주문 조건만).
-- 되돌리기: drop trigger trg_taam_guard_ledger_refund_cardpend on public.deposit_transactions;
--           drop trigger trg_taam_guard_card_order_pending on public.payment_orders;  select cron.unschedule('taam-card-topup-reconcile');
-- ============================================================================

-- ── A. 되돌림 — 홀드 구매 id 한 통 · Edge 가 뺀 만큼까지 · 멱등 ──
create or replace function public.taam_card_order_settle(
  p_order text, p_user uuid, p_cap bigint default null, p_purchase_id text default null, p_code text default null, p_why text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- CARD_SETTLE_20261116 · CARD_SETTLE_V2_20261116
  v_jwt     text := '';
  v_o       record;
  v_pid     text := nullif(btrim(coalesce(p_purchase_id, '')), '');
  v_cd      jsonb;
  v_rec     text;
  v_srv     bigint;
  v_cap     bigint;
  v_out_mem bigint := 0; v_out_gen bigint := 0; v_in_mem bigint := 0; v_in_gen bigint := 0; v_ord_in bigint := 0;
  v_owed    bigint; v_amt bigint; v_mem bigint; v_gen bigint;
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
  -- ③ 홀드 구매 id 없이는 세지 않는다 — 통을 모르면 회원이 단 위조 줄과 Edge 의 줄을 가를 수 없다
  if v_pid is null then
    raise exception 'SETTLE_BAD_ARGS: 홀드 구매 id 가 필요합니다' using errcode = '22023';
  end if;

  select o.order_id, o.user_id, o.purpose, o.status, o.metadata into v_o
    from public.payment_orders o where o.order_id = p_order;
  if not found then raise exception 'ORDER_NOT_FOUND: %', p_order using errcode = 'P0002'; end if;
  if v_o.user_id is distinct from p_user then raise exception 'ORDER_FORBIDDEN: 주문의 회원이 다릅니다' using errcode = '42501'; end if;
  if coalesce(v_o.purpose, '') <> 'ticket_topup' then raise exception 'SETTLE_BAD_PURPOSE: %', v_o.purpose using errcode = '22023'; end if;
  v_cd := case when jsonb_typeof(v_o.metadata->'card_dep') = 'object' then v_o.metadata->'card_dep' else '{}'::jsonb end;
  v_rec := coalesce(nullif(v_o.metadata->>'hold_purchase_id', ''), nullif(v_cd->>'hold', ''));
  if v_rec is not null and v_rec <> v_pid then
    raise exception 'SETTLE_HOLD_MISMATCH: 주문의 홀드와 다릅니다' using errcode = '22023';
  end if;

  -- 회원 잔액 줄을 먼저 잠근다 — 같은 회원의 진행 중인 차감·되돌림(taam_apply_deposit_delta 도 이 줄을 잠근다)이 끝난 뒤에 원장을 센다.
  --   그래야 「응답만 잃은 차감」을 놓치지 않고, 겹친 두 호출이 같은 금액을 두 번 돌려주지 않는다.
  perform 1 from public.profiles where id = p_user for update;
  if not found then raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0002'; end if;

  -- ④ 이 주문으로 확정된 살아 있는 티켓이 있으면 되돌리지 않는다(사람이 봐야 한다 — Edge 는 이 거절을 「예치금 되돌림 실패」 알림으로 올린다)
  if exists (select 1 from public.tickets t
              where t.user_id = p_user and t.extra_data->>'order_id' = p_order
                and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'failed', 'refunded', 'hold')) then
    raise exception 'SETTLE_TICKET_LIVE: 이 주문으로 확정된 티켓이 있습니다' using errcode = 'P0001';
  end if;

  -- ② 상한 — Edge 가 넘긴 값과 서버 기록(card_dep: 뺀 금액 · 차감 결과를 모르면 낼 몫) 중 작은 쪽
  v_srv := case
             when coalesce(v_cd->>'state', '') in ('taken', 'none') and coalesce(v_cd->>'taken', '') ~ '^\d{1,12}$' then (v_cd->>'taken')::bigint
             when coalesce(v_cd->>'plan', '') ~ '^\d{1,12}$' then (v_cd->>'plan')::bigint
             when coalesce(v_o.metadata->>'deposit_used', '') ~ '^\s*\d{1,12}(\.\d+)?\s*$' then round((v_o.metadata->>'deposit_used')::numeric)::bigint
           end;
  v_cap := case when p_cap is null then v_srv when v_srv is null then p_cap else least(p_cap, v_srv) end;
  if v_cap is null then
    raise exception 'SETTLE_NO_CAP: 되돌릴 상한을 정할 근거가 없습니다(p_cap 을 주세요)' using errcode = '22023';
  end if;
  v_cap := greatest(0, v_cap);

  -- ① 홀드 구매 id 한 통 — 빠진 것 · 돌아간 것(주문 번호와 상관없이 · 회원 스스로 받은 환불 포함)
  select coalesce(sum(-d.amount) filter (where d.change_type = 'ticket_purchase' and d.amount < 0 and d.deposit_type = 'membership'), 0),
         coalesce(sum(-d.amount) filter (where d.change_type = 'ticket_purchase' and d.amount < 0 and d.deposit_type = 'general'), 0),
         coalesce(sum(d.amount)  filter (where d.change_type in ('ticket_refund', 'ticket_pax_change') and d.amount > 0 and d.deposit_type = 'membership'), 0),
         coalesce(sum(d.amount)  filter (where d.change_type in ('ticket_refund', 'ticket_pax_change') and d.amount > 0 and d.deposit_type = 'general'), 0)
    into v_out_mem, v_out_gen, v_in_mem, v_in_gen
    from public.deposit_transactions d
   where d.user_id = p_user and d.metadata->>'purchase_id' = v_pid;
  -- 이 주문으로 이미 돌아간 몫 — 상한에서 뺀다(같은 홀드로 두 주문이 차감했어도 주문마다 자기 몫까지만)
  select coalesce(sum(d.amount), 0) into v_ord_in
    from public.deposit_transactions d
   where d.user_id = p_user and d.change_type = 'ticket_refund' and d.amount > 0 and d.metadata->>'order_id' = p_order;

  v_owed := greatest(0, (v_out_mem + v_out_gen) - (v_in_mem + v_in_gen));   -- 합계로 센다 — 주머니마다 따로 세면 다른 주머니로 받은 환불을 놓친다
  v_amt  := least(v_owed, greatest(0, v_cap - v_ord_in));
  v_mem  := least(greatest(0, v_out_mem - v_in_mem), v_amt);                -- 나간 주머니로 · 멤버십 먼저(차감이 멤버십 먼저다)
  v_gen  := least(greatest(0, v_out_gen - v_in_gen), v_amt - v_mem);

  if v_mem + v_gen <= 0 then
    return jsonb_build_object('ok', true, 'refunded_mem', 0, 'refunded_gen', 0, 'out_mem', v_out_mem, 'out_gen', v_out_gen,
                              'in_mem', v_in_mem, 'in_gen', v_in_gen, 'order_in', v_ord_in, 'cap', v_cap, 'owed_before', 0);
  end if;

  v_why := coalesce(nullif(btrim(p_why), ''), '카드 결제 취소 · 예치금 환원');
  -- ⚠ metadata 에 reason / fix / refund_type / cancel_refund 를 넣지 않는다 — 판매 현황·결제 내역이 그 키로 환불 종류를 가른다(card_auto 로 보여야 한다)
  v_md  := jsonb_strip_nulls(jsonb_build_object('order_id', p_order, 'purchase_id', v_pid,
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
                            'in_mem', v_in_mem, 'in_gen', v_in_gen, 'order_in', v_ord_in, 'cap', v_cap, 'owed_before', v_mem + v_gen);
end;
$$;

revoke all on function public.taam_card_order_settle(text, uuid, bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.taam_card_order_settle(text, uuid, bigint, text, text, text) to service_role;

-- ── B. 회원 세션의 「처리 중인 카드 주문」 홀드 환불 막기 (CF-2 성공 길) ──
--   Edge 가 예치금을 뺀 뒤 좌석 전환을 끝내기 전(주문 paid · fail_reason unknown:* 또는 옛 Edge 의 null) 회원이 그 홀드 구매 id 로 스스로 환불하면,
--   전환이 성공해 티켓 + 예치금을 둘 다 갖는다(refund_active 는 hold 를 살아 있는 티켓으로 안 본다 · refund_cap 은 30분 안 전액).
--   → 그 주문으로 확정된 티켓 행(취소됐어도)이 아직 없으면 거절. 서버(Edge 정리)·슈퍼어드민은 그대로.
--   정상 회원 환불 경로(앱 cancelTicketPurchase)는 티켓을 먼저 취소하고 그 티켓 행이 이 주문 번호를 갖고 있다 — 지난다.
create or replace function public.taam_guard_ledger_refund_cardpend()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_pid text; v_o text;
begin
  -- CARD_PEND_GUARD_20261116
  if v_uid is null then return new; end if;
  if exists (select 1 from public.profiles p where p.id = v_uid and p.role in ('super_admin', 'superadmin')) then return new; end if;
  if coalesce(new.change_type, '') <> 'ticket_refund' or coalesce(new.amount, 0) <= 0 then return new; end if;
  v_pid := nullif(btrim(coalesce(new.metadata->>'purchase_id', '')), '');
  if v_pid is null then return new; end if;
  -- 칸은 to_jsonb 로 읽는다(칸이 덜 있는 옛 표·픽스처에서도 회원 환불을 깨지 않게 — 라이브 표엔 다 있다)
  select o.order_id into v_o
    from public.payment_orders o
   where o.user_id = new.user_id and to_jsonb(o)->>'purpose' = 'ticket_topup' and to_jsonb(o)->>'status' = 'paid'
     and (coalesce(to_jsonb(o)->>'fail_reason', '') = '' or to_jsonb(o)->>'fail_reason' like 'unknown:%')
     and (o.metadata->>'hold_purchase_id' = v_pid or o.metadata->'card_dep'->>'hold' = v_pid)
     and not exists (select 1 from public.tickets t
                      where t.user_id = new.user_id and t.extra_data->>'order_id' = o.order_id
                        and lower(coalesce(t.status, '')) <> 'hold')
   limit 1;
  if v_o is not null then
    raise exception 'REFUND_CARD_PENDING: 카드 결제를 확인 중인 구매입니다 — 확인이 끝난 뒤 처리됩니다' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_ledger_refund_cardpend() from public, anon, authenticated;
drop trigger if exists trg_taam_guard_ledger_refund_cardpend on public.deposit_transactions;
create trigger trg_taam_guard_ledger_refund_cardpend before insert on public.deposit_transactions
  for each row execute function public.taam_guard_ledger_refund_cardpend();

-- ── C. 결과 모르는 카드 주문이 있으면 새 카드 주문을 만들지 않는다 (TOSSRB-2) ──
--   같은 홀드에 결과를 모르는 주문(unknown:* · 60분 안)이 있거나, 같은 회차의 주문이 승인됐는데(paid) 결과를 모르면 PAYMENT_PENDING.
--   토스가 그 결제를 늦게 완료하면 두 번 청구된다 — 옛 주문은 10분 정리(⑦)가 잇거나 취소한다. toss-order 가 이 거절을 payment_pending 으로 돌려준다.
create or replace function public.taam_guard_card_order_pending()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_hold text; v_tid text; v_o text;
begin
  -- CARD_ORDER_PENDING_20261116  (칸은 to_jsonb 로 읽는다 — 칸이 덜 있는 옛 표·픽스처에서도 주문 INSERT 를 깨지 않게)
  if coalesce(to_jsonb(new)->>'purpose', '') <> 'ticket_topup' then return new; end if;
  v_hold := nullif(btrim(coalesce(new.metadata->>'hold_purchase_id', '')), '');
  v_tid  := nullif(btrim(coalesce(new.metadata->>'ticket_id', '')), '');
  if v_hold is null and v_tid is null then return new; end if;
  select o.order_id into v_o
    from public.payment_orders o
   where o.user_id = new.user_id and to_jsonb(o)->>'purpose' = 'ticket_topup' and o.order_id <> new.order_id
     and to_jsonb(o)->>'status' in ('pending', 'paid') and coalesce(to_jsonb(o)->>'fail_reason', '') like 'unknown:%'
     and o.created_at > now() - interval '60 minutes'
     and ((v_hold is not null and (o.metadata->>'hold_purchase_id' = v_hold or o.metadata->'card_dep'->>'hold' = v_hold))
          or (v_tid is not null and to_jsonb(o)->>'status' = 'paid' and coalesce(o.metadata->>'ticket_id', o.metadata->'card_dep'->>'tid') = v_tid))
   limit 1;
  if v_o is not null then
    raise exception 'PAYMENT_PENDING: 앞선 카드 결제를 확인 중입니다' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_card_order_pending() from public, anon, authenticated;
drop trigger if exists trg_taam_guard_card_order_pending on public.payment_orders;
create trigger trg_taam_guard_card_order_pending before insert on public.payment_orders
  for each row execute function public.taam_guard_card_order_pending();

-- ── D. 슈퍼어드민 — 결제 내역에 아직 없는 카드 주문 한 건 보기 (CFAPP-1) ──
--   taam_payment_ledger 는 결제키가 있는 승인된 주문만 보여 준다 — 결과를 모르는(pending · unknown:*) 주문은 거기 없다.
--   알림 「결제 내역에서 이 주문 보기」가 「이 기간에 없습니다」로 끝나지 않게, 그 주문의 상태만 돌려준다(결제키는 끝 8자리만).
create or replace function public.taam_card_order_peek(p_order text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v jsonb;
begin
  -- CARD_ORDER_PEEK_20261116
  if v_uid is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.role in ('super_admin', 'superadmin')) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select jsonb_build_object('order_id', o.order_id, 'user_id', o.user_id, 'purpose', o.purpose, 'status', o.status, 'fail_reason', left(coalesce(o.fail_reason, ''), 120),
                            'amount', o.amount, 'currency', o.currency, 'settle_krw', o.settle_krw, 'created_at', o.created_at, 'updated_at', o.updated_at,
                            'approved_at', o.approved_at, 'pk_tail', right(coalesce(o.payment_key, ''), 8),
                            'hold', coalesce(o.metadata->>'hold_purchase_id', o.metadata->'card_dep'->>'hold'),
                            'restaurant_name', coalesce(o.metadata->>'restaurant_name', o.metadata->'card_dep'->>'rname'),
                            'paid_via', o.metadata->>'paid_via', 'name', p.display_name)
    into v
    from public.payment_orders o left join public.profiles p on p.id = o.user_id
   where o.order_id = left(coalesce(p_order, ''), 80);
  return v;
end $$;
revoke all on function public.taam_card_order_peek(text) from public, anon;
grant execute on function public.taam_card_order_peek(text) to authenticated;

-- ── E. 결과를 모르는 카드 주문 정리 — 10분마다 Edge toss-confirm 의 sweep(service_role) (CF-6 · TOSSRB-1) ──
--   lookup : pending · unknown:*(승인 요청이 나갔다) · 5분 지남 → 토스에 주문번호로 조회 — DONE 이면 같은 승인으로 잇고, 결제가 없으면 닫는다
--   resolve: paid · unknown:*(잡은 뒤 함수가 죽었다 · 전환 결과 모름 · 실패 정리 중 끊김) · 10분 지남(함수 벽시계 400초를 넘겼다) → 티켓이 있으면 표시만 지우고,
--            없으면 실패 정리를 이어 간다(예치금 되돌림 · 홀드 반납 · 카드 전액 취소 — 모두 멱등)
--   orphan : 「결제 없음」으로 닫은 주문(swept_no_payment) — 닫은 뒤 3~45분 동안 다시 조회(늦게 완료된 승인이 있으면 취소)
create or replace function public.taam_card_topup_reconcile_list(p_limit int default 15)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_jwt text := '';
begin
  -- CARD_TOPUP_RECONCILE_20261116
  if auth.uid() is not null then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  begin v_jwt := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', ''); exception when others then v_jwt := ''; end;
  if v_jwt <> 'service_role' and session_user <> 'postgres' then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x order by lo, ca), '[]'::jsonb) into v from (
    select (po.status = 'failed') as lo, po.created_at as ca,
           jsonb_build_object('order_id', po.order_id, 'user_id', po.user_id, 'status', po.status, 'fail_reason', po.fail_reason,
                              'currency', po.currency, 'created_at', po.created_at, 'updated_at', po.updated_at,
                              'reconcile', case when po.status = 'pending' then 'lookup' when po.status = 'paid' then 'resolve' else 'orphan' end) as x
      from public.payment_orders po
     where po.purpose = 'ticket_topup' and po.created_at > now() - interval '3 days'
       and ((po.status = 'pending' and coalesce(po.fail_reason, '') like 'unknown:%' and coalesce(po.updated_at, po.created_at) < now() - interval '5 minutes')
         or (po.status = 'paid' and coalesce(po.fail_reason, '') like 'unknown:%' and coalesce(po.updated_at, po.created_at) < now() - interval '10 minutes')
         or (po.status = 'failed' and coalesce(po.fail_reason, '') like 'swept_no_payment%'
             and coalesce(po.updated_at, po.created_at) < now() - interval '3 minutes'
             and coalesce(po.updated_at, po.created_at) > now() - interval '45 minutes'))
     order by (po.status = 'failed'), po.created_at
     limit greatest(1, least(coalesce(p_limit, 15), 50))) s;
  return v;
end $$;
revoke all on function public.taam_card_topup_reconcile_list(int) from public, anon, authenticated;
grant execute on function public.taam_card_topup_reconcile_list(int) to service_role;

-- 부르는 법은 taam_invite_pay_reconcile_kick 과 같다(app_config.restock_push 의 Vault 시크릿 이름·URL · 함수 이름만 바꿔 쓴다 · 키 값은 Vault 에만)
create or replace function public.taam_card_topup_reconcile_kick()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_cfg jsonb; v_name text; v_url text; v_jwt text; v_req bigint;
begin
  if jsonb_array_length(public.taam_card_topup_reconcile_list(1)) = 0 then
    return jsonb_build_object('ok', true, 'skipped', 'nothing');
  end if;
  if to_regclass('public.app_config') is null then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  select value::jsonb into v_cfg from public.app_config where key = 'restock_push';
  v_name := v_cfg->>'vault_secret'; v_url := v_cfg->>'url';
  if coalesce(v_name, '') = '' or coalesce(v_url, '') = '' then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  v_url := regexp_replace(v_url, '/functions/v1/[^/]+$', '/functions/v1/toss-confirm');
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return jsonb_build_object('ok', false, 'reason', 'no_pg_net'); end if;
  begin
    select decrypted_secret into v_jwt from vault.decrypted_secrets where name = v_name limit 1;
  exception when others then v_jwt := null; end;
  if coalesce(v_jwt, '') = '' then return jsonb_build_object('ok', false, 'reason', 'no_secret'); end if;
  select net.http_post(url := v_url, headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt),
                       body := jsonb_build_object('action', 'sweep'), timeout_milliseconds := 55000) into v_req;
  return jsonb_build_object('ok', true, 'request_id', v_req);
end $$;
revoke all on function public.taam_card_topup_reconcile_kick() from public, anon, authenticated;

drop table if exists _cos;
create temp table _cos(항목 text, 결과 text);
do $do$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('taam-card-topup-reconcile'); exception when others then null; end;
    perform cron.schedule('taam-card-topup-reconcile', '*/10 * * * *', $job$ select public.taam_card_topup_reconcile_kick(); $job$);
    insert into _cos values ('⑨ 결과 모르는 카드 주문 정리 — 10분 크론 taam-card-topup-reconcile', '✅');
  else
    insert into _cos values ('⑨ 결과 모르는 카드 주문 정리 — 10분 크론', '⚠ pg_cron 없음 — 함수만 설치(정리는 회원 재접속으로)');
  end if;
exception when others then insert into _cos values ('⑨ 크론 등록', '⚠ ' || left(sqlerrm, 160));
end $do$;

-- ── 확인 (한 표) — ❌ 가 한 줄도 없어야 정상 · 건수만(공개 로그) ──
select 항목 as what, 결과 as result from _cos
union all
select '① taam_card_order_settle 2판(서버 전용 · 홀드 구매 id 한 통 · Edge 가 뺀 만큼까지 · 멱등)',
       case when exists (select 1 from pg_proc where oid = to_regprocedure('public.taam_card_order_settle(text,uuid,bigint,text,text,text)')
                          and prosrc like '%CARD_SETTLE_V2_20261116%' and prosecdef) then '✅' else '❌' end
union all
select '② 되돌림 — anon · authenticated 실행 불가 · service_role 실행 가능',
       case when to_regprocedure('public.taam_card_order_settle(text,uuid,bigint,text,text,text)') is null then '❌'
            when not has_function_privilege('anon', 'public.taam_card_order_settle(text,uuid,bigint,text,text,text)', 'execute')
             and not has_function_privilege('authenticated', 'public.taam_card_order_settle(text,uuid,bigint,text,text,text)', 'execute')
             and has_function_privilege('service_role', 'public.taam_card_order_settle(text,uuid,bigint,text,text,text)', 'execute') then '✅' else '❌' end
union all
select '③ 의존 함수 taam_apply_deposit_delta(uuid,bigint,bigint,jsonb)',
       case when to_regprocedure('public.taam_apply_deposit_delta(uuid,bigint,bigint,jsonb)') is not null then '✅' else '❌' end
union all
select '④ 트리거 trg_taam_guard_ledger_refund_cardpend(처리 중 카드 주문의 홀드 회원 환불 막기)',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ledger_refund_cardpend' and not tgisinternal and tgenabled <> 'D') then '✅' else '❌' end
union all
select '⑤ 트리거 trg_taam_guard_card_order_pending(결과 모르는 주문이 있으면 새 카드 주문 막기)',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_card_order_pending' and not tgisinternal and tgenabled <> 'D') then '✅' else '❌' end
union all
select '⑥ 정리 목록·킥 — 회원·비로그인 실행 불가',
       case when to_regprocedure('public.taam_card_topup_reconcile_list(int)') is null or to_regprocedure('public.taam_card_topup_reconcile_kick()') is null then '❌'
            when has_function_privilege('authenticated', 'public.taam_card_topup_reconcile_list(int)', 'execute')
              or has_function_privilege('anon', 'public.taam_card_topup_reconcile_list(int)', 'execute')
              or has_function_privilege('authenticated', 'public.taam_card_topup_reconcile_kick()', 'execute')
              or has_function_privilege('anon', 'public.taam_card_topup_reconcile_kick()', 'execute') then '❌ 열려 있다' else '✅' end
union all
select '⑦ taam_card_order_peek — anon 실행 불가(로그인 세션은 슈퍼어드민만 답한다)',
       case when to_regprocedure('public.taam_card_order_peek(text)') is null then '❌'
            when has_function_privilege('anon', 'public.taam_card_order_peek(text)', 'execute') then '❌ 열려 있다' else '✅' end
union all
select '⑧ 정보 — 승인 뒤 확정 실패로 남은 카드 주문(자동 취소 실패)',
       (select count(*)::text from public.payment_orders o where to_jsonb(o)->>'purpose' = 'ticket_topup' and coalesce(to_jsonb(o)->>'fail_reason', '') like '%refund_failed')
union all
select '⑧ 정보 — 결과를 모르는 카드 주문(unknown:)',
       (select count(*)::text from public.payment_orders o where to_jsonb(o)->>'purpose' = 'ticket_topup' and coalesce(to_jsonb(o)->>'fail_reason', '') like 'unknown:%');
