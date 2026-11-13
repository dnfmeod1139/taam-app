-- ═══════════════════════════════════════════════════════════════
-- TAAM — 초대 결제에 「예치금 + 카드」 — 예치금을 먼저 쓰고 모자란 만큼만 카드로 (2026-11-13)
-- ═══════════════════════════════════════════════════════════════
--   초대 결제(riConfirmPay)는 예치금 전용이었다 — 잔액이 모자라면 「예치금 충전(계좌이체)」 안내뿐. 초대 ₩10,500,000 · 잔액 ₩8,000,000 인 회원이
--   「나머지 ₩2,500,000 만 카드로」 낼 길이 없었다(티켓 구매는 처음부터 된다 — 예치금에서 차감, 부족 시 PG 결제로 보강).
--
--   모양은 티켓 패키지의 카드 몫(20261029_ticket_package.sql G·K)과 같다 — 돈·좌석 판단은 전부 서버 함수가 한 트랜잭션으로, Edge(toss-invite-pay)는 토스와만.
--     ① 주문  taam_invite_order_prepare(초대, 회원)  — 서버만. 초대(보냄 · 본인 · 48시간 안 · 판매 티켓 연결 · 살아 있는 초대 홀드)를 잠그고,
--              예치금 먼저(잔액 전부) · 모자란 만큼이 카드 몫 · **좌석 확정을 미리 한 번 돌려 본다**(같은 트리거를 실제로 태우고 되돌린다 —
--              중복 구매·같은 시간대·숨김 회차 같은 거절을 카드 승인 **전에** 안다) · payment_orders(purpose invite_topup · taaminv_…)
--     ② 잡기  taam_invite_order_claim(주문, 결제키…) — 토스 승인 뒤 pending → paid (한 문장 · metadata 합침 · inv_claim 표시)
--     ③ 확정  taam_invite_confirm_card(주문)         — **한 트랜잭션**: 주문·초대 잠금 → 금액 다시(초대 합계 = 예치금 몫 + 카드 몫) → 잔액 잠금 →
--              초대 「결제됨」 → 초대 홀드(INVH-) → 회원 소유 확정 좌석(INV- · 기존 taam_invite_confirm_hold) → 예치금 차감(taam_apply_deposit_delta · 원장)
--              → 좌석 행에 결제 사실(cardPaid · depositUsed · paidBy · order_id · agencyFee) → 주문에 inv_settled
--     ④ 닫기  taam_invite_order_close(주문, 사유)    — 확정이 분명히 거절된 paid 주문을 **토스 취소 전에** canceled 로(이 주문으로 이미 확정됐으면 닫지 않는다)
--     ⑤ 정리  taam_invite_pay_reconcile_list / _kick + 10분 크론 — 확정 안 된 paid · 10분 넘은 pending · 취소 실패를 Edge sweep 이 정리
--
--   지키는 것:
--     · 금액은 서버가 센다 — 카드 몫 = 초대 합계 − 주문 때 잔액. 확정 때 초대 합계·인원이 주문 때와 다르면 PRICE_CHANGED, 잔액이 줄었으면 INSUFFICIENT_DEPOSIT
--       (Edge 가 카드를 전액 취소한다 — 덜 받거나 더 빼지 않는다).
--     · 좌석 행 없는 초대(판매 티켓 미연결 · 홀드 없음)는 카드로 못 낸다(INVITE_NOT_LINKED · HOLD_GONE) — 결제 사실을 적을 좌석 행이 없으면 환불 경로가 카드 몫을 못 찾는다.
--     · 초대 주문은 toss-invite-pay 만 paid 로 만든다(trg_taam_guard_inv_order_claim) — 옛 toss-confirm 이 초대 주문번호를 받아 좌석 없이 paid 로 끝내지 못한다.
--     · 결과를 모르는 카드 주문(unknown: · 확정 안 된 paid)이 있으면 새 주문을 만들지 않는다(PAYMENT_PENDING — 두 번 긁지 않는다).
--     · 실패해도 초대 홀드는 그대로다(초대는 「보냄」 — 다시 결제할 수 있다). 좌석을 푸는 것은 종전대로 초대 취소·회수·48시간 만료뿐.
--     · 예치금만으로 되는 초대는 주문을 만들지 않는다(need_payment=false) — 종전 예치금 경로 그대로.
--   환불은 새로 만들지 않았다 — 확정된 좌석 행은 다른 카드+예치금 구매와 같은 모양이라 회원 취소(예치금 몫은 원장 한도 · 카드 몫은 카드 환불 대기)와
--     슈퍼어드민 「💳 토스 승인취소 실행」(taam_card_refund_quote — 좌석의 order_id 로 주문을 찾고 주문 메타의 total · pax · ticket_id 를 대조한다)이 그대로 돈다.
--   의존(확인 표가 본다): payment_orders · reservation_invites · tickets · taam_invite_confirm_hold · taam_apply_deposit_delta.
--   회귀: bash sql/_test/t_invite_card_pay.sh
-- ═══════════════════════════════════════════════════════════════

drop table if exists _ic;
create temp table _ic(항목 text, 결과 text);

-- ── A. payment_orders 용도에 invite_topup ──
do $do$
declare v_def text;
begin
  if to_regclass('public.payment_orders') is null then insert into _ic values ('A payment_orders', '❌ 표 없음'); return; end if;
  select pg_get_constraintdef(c.oid) into v_def from pg_constraint c
   where c.conrelid = 'public.payment_orders'::regclass and c.conname = 'payment_orders_purpose_chk';
  if v_def is null then insert into _ic values ('A payment_orders 용도 제약', '✅ 제약 없음(그대로)'); return; end if;
  if v_def like '%invite_topup%' then insert into _ic values ('A payment_orders 용도 제약', '✅ 이미 있음'); return; end if;
  if v_def not like '%ARRAY[%' then insert into _ic values ('A payment_orders 용도 제약', '❌ 모양이 다르다 — 손으로: ' || left(v_def, 120)); return; end if;
  execute 'alter table public.payment_orders drop constraint payment_orders_purpose_chk';
  execute 'alter table public.payment_orders add constraint payment_orders_purpose_chk ' || replace(v_def, 'ARRAY[', 'ARRAY[''invite_topup''::text, ');
  insert into _ic values ('A payment_orders 용도에 invite_topup', '✅');
exception when others then insert into _ic values ('A payment_orders 용도 제약', '❌ ' || left(sqlerrm, 160));
end $do$;

-- A'. 초대 주문은 toss-invite-pay 만 paid 로 만든다 — 옛 toss-confirm / toss-billing-charge 가 초대 주문번호를 받으면
--     카드는 승인하고 좌석은 확정하지 않은 채 paid 로 끝낸다(용도를 모른다). 그 갱신을 막아 둔다(확정 표시 inv_claim 은 새 함수만 적는다).
create or replace function public.taam_guard_inv_order_claim()
returns trigger language plpgsql as $$
begin
  if new.purpose = 'invite_topup' and new.status = 'paid' and old.status is distinct from 'paid'
     and coalesce(new.metadata->>'inv_claim', '') <> 'toss-invite-pay' then
    raise exception 'INVITE_ORDER_CLAIM: 초대 카드 주문은 toss-invite-pay 로만 확정합니다' using errcode = '42501';
  end if;
  return new;
end $$;
do $do$ begin
  if to_regclass('public.payment_orders') is not null then
    execute 'drop trigger if exists trg_taam_guard_inv_order_claim on public.payment_orders';
    execute 'create trigger trg_taam_guard_inv_order_claim before update of status on public.payment_orders for each row execute function public.taam_guard_inv_order_claim()';
    insert into _ic values ('A'' 초대 주문은 새 함수만 paid 로', '✅');
  end if;
end $do$;

-- ── B. 도우미 ──
-- 서버 호출인가(Edge 의 service_role · SQL Editor) — 로그인 세션은 슈퍼어드민도 아니다(이 함수들은 Edge 만 부른다)
create or replace function public._taam_invpay_server_ok()
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null then return false; end if;
  return session_user = 'postgres'
      or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role';
exception when others then return false;
end $$;
revoke all on function public._taam_invpay_server_ok() from public, anon, authenticated;

-- 초대 「결제됨」 + 초대 홀드 → 회원 소유 확정 좌석. 홀드가 없으면 HOLD_GONE(새 좌석을 넣지 않는다 — 정원 검사를 카드 승인 뒤로 미루지 않는다).
--   주문 만들기(미리 돌려 보기 — 되돌린다)와 확정(실제)이 **같은 함수**를 부른다 — 둘이 다른 식으로 갈리지 않게.
create or replace function public._taam_invpay_seat(p_inv uuid, p_pid text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_cf jsonb; v_n int;
begin
  update public.reservation_invites set status = 'paid', paid_at = now() where id = p_inv and status = 'sent';
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'INVITE_CLOSED: 결제할 수 없는 초대입니다' using errcode = 'P0002'; end if;
  v_cf := public.taam_invite_confirm_hold(p_inv::text, p_pid)::jsonb;
  if coalesce(v_cf->>'converted', '') <> 'true' then
    raise exception 'HOLD_GONE: 초대 좌석(홀드)을 찾지 못했습니다 — 초대한 관리자에게 문의해 주세요' using errcode = 'P0002';
  end if;
  return v_cf;
end $$;
revoke all on function public._taam_invpay_seat(uuid, text) from public, anon, authenticated;

-- ── C. 주문 만들기 — 서버만 ──
create or replace function public.taam_invite_order_prepare(p_invite text, p_uid uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  inv public.reservation_invites%rowtype; v_hold uuid; v_total bigint; v_pax int;
  v_mem bigint; v_gen bigint; v_bal bigint; v_dep bigint; v_card bigint; v_oid text; v_pid text; v_ms bigint;
begin
  if not public._taam_invpay_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_uid is null or coalesce(p_invite, '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'INVITE_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into inv from public.reservation_invites where id = p_invite::uuid for update;
  if not found or inv.invitee_user_id is distinct from p_uid then raise exception 'INVITE_NOT_FOUND' using errcode = 'P0002'; end if;
  if coalesce(inv.status, '') = 'paid' then raise exception 'INVITE_PAID: 이미 결제된 초대입니다' using errcode = 'P0002'; end if;
  if coalesce(inv.status, '') <> 'sent' then
    raise exception 'INVITE_CLOSED: 결제할 수 없는 초대입니다 (상태 %)', coalesce(inv.status, '없음') using errcode = 'P0002';
  end if;
  if coalesce(inv.ticket_product_id::text, '') = '' then
    raise exception 'INVITE_NOT_LINKED: 판매 티켓에 연결되지 않은 초대는 카드로 결제할 수 없습니다' using errcode = '22023';
  end if;
  -- 48시간 만료(30분마다 도는 스윕이 초대를 expired 로 · 홀드를 취소로) — 카드창에 있는 동안 만료되지 않게 15분 여유를 둔다
  if inv.created_at < now() - interval '47 hours 45 minutes' then
    raise exception 'INVITE_EXPIRED: 초대가 만료되었거나 곧 만료됩니다 — 초대한 관리자에게 다시 요청해 주세요' using errcode = 'P0002';
  end if;
  v_total := coalesce(inv.total_amount, 0)::bigint; v_pax := coalesce(inv.pax, 0);
  if v_total <= 0 or v_pax <= 0 then raise exception 'PRICE_NOT_SET: 초대 금액이 없습니다' using errcode = '22023'; end if;
  if to_regprocedure('public.taam_rate_hit(text, integer, interval)') is not null then
    if not public.taam_rate_hit('inv_prepare:' || p_uid::text, 20, interval '1 hour') then
      raise exception 'RATE_LIMITED: 잠시 뒤 다시 시도해 주세요' using errcode = '42501';
    end if;
  end if;
  -- 살아 있는 초대 홀드(이 초대의 것)
  select t.id into v_hold from public.tickets t
   where coalesce(t.status, '') = 'hold' and t.purchase_id like 'INVH-%' and t.extra_data->>'inviteId' = inv.id::text
   order by t.created_at desc limit 1 for update;
  if v_hold is null then
    raise exception 'HOLD_GONE: 초대 좌석(홀드)을 찾지 못했습니다 — 초대한 관리자에게 문의해 주세요' using errcode = 'P0002';
  end if;
  -- 결과를 모르는 카드 주문이 있으면 새로 만들지 않는다 — 덮어 닫으면 늦게 완료된 그 승인을 정리 크론이 못 보고, 확정 안 된 paid 위에 또 긁으면 두 번 결제다
  if exists (select 1 from public.payment_orders o
              where o.purpose = 'invite_topup' and o.user_id = p_uid and o.metadata->>'invite_id' = inv.id::text
                and ((o.status = 'pending' and coalesce(o.fail_reason, '') like 'unknown:%')
                  or (o.status = 'paid' and coalesce(o.metadata->>'inv_settled', '') <> 'true'))) then
    raise exception 'PAYMENT_PENDING: 앞 카드 결제를 확인하는 중입니다 — 잠시 뒤 다시 시도해 주세요' using errcode = '22023';
  end if;

  -- 이 초대에 되돌려지지 않은 예치금 결제가 있다 — 예치금 결제(riConfirmPay: 차감 → 결제됨 → 확정)가 도는 중이거나 도중에 끊겨 남은 것.
  --   그 위에 카드를 받으면 두 번 내게 된다. 카드 주문을 만들지 않는다(예치금 결제가 끝나면 초대가 「결제됨」이 되고, 남은 것이면 TAAM 이 정리한다).
  if public._taam_invite_net_paid(inv.id, p_uid) > 0 then
    raise exception 'INVITE_DEPOSIT_PAID: 이 초대에 예치금 결제가 진행 중이거나 기록이 남아 있습니다 — 잠시 뒤 다시 확인해 주세요' using errcode = '22023';
  end if;

  select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0) into v_mem, v_gen from public.profiles where id = p_uid;
  if not found then raise exception 'INVITE_NOT_FOUND' using errcode = 'P0002'; end if;
  -- 음수 주머니(원장 RPC 는 0 에서 멈추므로 손으로 고친 DB 에서만 생긴다)는 여기서 멈춘다 — 확정의 잔액 검사·원장 RPC 가 거절해 「승인 → 자동 취소」가 반복된다
  if v_mem < 0 or v_gen < 0 then
    raise exception 'INSUFFICIENT_DEPOSIT: 예치금 잔액을 확인할 수 없습니다 — TAAM 에 문의해 주세요' using errcode = '22023';
  end if;
  v_bal := v_mem + v_gen;
  v_dep := least(v_bal, v_total);
  v_card := v_total - v_dep;
  if v_card <= 0 then
    return jsonb_build_object('ok', true, 'need_payment', false, 'total', v_total, 'balance', v_bal);
  end if;
  if v_card < 100 then   -- 토스 최소 금액 — 예치금을 그만큼 덜 쓴다
    v_card := least(100, v_total); v_dep := v_total - v_card;
  end if;

  v_ms := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  v_pid := 'INV-' || left(inv.id::text, 8) || '-' || v_ms;

  -- 좌석 확정을 미리 돌려 본다 — 실제 확정과 같은 함수·같은 트리거(중복 구매·같은 시간대·숨김 회차·패키지 …)를 태우고 되돌린다.
  --   여기서 거절되면 그 오류가 그대로 나간다(카드 승인 전). 통과하면 표식 예외로 블록을 되돌린다.
  begin
    perform public._taam_invpay_seat(inv.id, v_pid);
    raise exception 'TAAM_INVPAY_DRYRUN' using errcode = 'TDRY1';
  exception when sqlstate 'TDRY1' then null;
  end;

  v_oid := 'taaminv_' || v_ms || '_' || (floor(random() * 100000))::int;
  -- 같은 초대의 결제 안 된 옛 주문은 닫는다(카드창을 두 번 열어 두 번 결제되지 않게 — 닫힌 주문은 잡히지 않고, 늦게 온 그 승인은 Edge 가 취소한다)
  update public.payment_orders set status = 'failed', fail_reason = 'superseded'
   where purpose = 'invite_topup' and status = 'pending' and user_id = p_uid and metadata->>'invite_id' = inv.id::text;
  insert into public.payment_orders(order_id, user_id, purpose, amount, currency, settle_krw, status, metadata)
  values (v_oid, p_uid, 'invite_topup', v_card, 'KRW', v_card, 'pending',
          jsonb_build_object('invite_id', inv.id::text, 'purchase_id', v_pid, 'ticket_id', inv.ticket_product_id::text,
                             'title', coalesce(inv.restaurant_name, '') || ' 예약 초대', 'restaurant_name', inv.restaurant_name,
                             'visit_date', inv.visit_date, 'visit_time', inv.visit_time,
                             'pax', v_pax, 'total', v_total, 'deposit_used', v_dep, 'balance_at_order', v_bal));
  -- ⚠ 메타에 agency_fee 를 적지 않는다 — 카드 환불 견적(taam_card_refund_quote)은 메타에 없으면 **회차 대행비**를 쓴다. 회원 취소의 앱 계산
  --   (calculateTicketRefund)과 예치금 환불 한도(taam_refund_cap)도 회차 대행비라, 한 취소 안에서 예치금 몫과 카드 몫이 같은 대행비로 세어진다.
  --   (hold_purchase_id 도 적지 않는다 — 견적은 그 값이 있으면 좌석의 구매 id 와 같아야 하는데, 홀드 id(INVH-)는 확정 뒤 INV- 로 바뀐다)
  return jsonb_build_object('ok', true, 'need_payment', true, 'order_id', v_oid, 'amount', v_card, 'total', v_total, 'deposit_used', v_dep,
                            'balance', v_bal, 'title', coalesce(inv.restaurant_name, '') || ' 예약 초대');
end $$;

-- ── D. 토스 승인 뒤 주문을 paid 로 — 한 문장(metadata 를 덮지 않고 합친다 · pending 일 때만 · 확정 표시 inv_claim). 못 잡으면 지금 상태를 돌려준다 ──
create or replace function public.taam_invite_order_claim(p_order text, p_payment_key text, p_method text, p_receipt text, p_approved_at timestamptz, p_toss jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_st text; v_n int;
begin
  if not public._taam_invpay_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.payment_orders
     set status = 'paid', payment_key = p_payment_key, method = left(p_method, 40), receipt_url = left(p_receipt, 400),
         approved_at = coalesce(p_approved_at, now()),
         fail_reason = null,   -- 승인 전에 붙인 「결과 모름」 표시(unknown:approving)는 여기서 지운다 — 잡혔으면 더는 모르는 주문이 아니다
         metadata = coalesce(metadata, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('toss', p_toss, 'paid_via', 'window', 'inv_claim', 'toss-invite-pay'))
   where order_id = p_order and purpose = 'invite_topup' and status = 'pending';
  get diagnostics v_n = row_count;
  select status into v_st from public.payment_orders where order_id = p_order;
  return jsonb_build_object('claimed', v_n = 1, 'status', v_st);
end $$;

-- ── E. 확정 — 한 트랜잭션 ──
create or replace function public.taam_invite_confirm_card(p_order text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  po public.payment_orders%rowtype; inv public.reservation_invites%rowtype;
  v_total bigint; v_card bigint; v_dep bigint; v_mem bigint; v_gen bigint; v_m bigint; v_g bigint;
  v_pid text; v_meta jsonb; v_ent jsonb := '[]'::jsonb; v_rest text; v_n int; v_bal json;
begin
  if not public._taam_invpay_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into po from public.payment_orders where order_id = p_order for update;
  if not found or po.purpose <> 'invite_topup' then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;
  -- 이 결제로 이미 확정된 초대(그 뒤 좌석이 취소됐어도)는 다시 불러도 「이미」 — 오류로 돌리면 Edge 가 카드를 전액 취소해 환불 규정을 비켜 간다
  if coalesce(po.metadata->>'inv_settled', '') = 'true' then
    return jsonb_build_object('ok', true, 'already', true, 'invite_id', po.metadata->>'invite_id', 'purchase_id', po.metadata->>'purchase_id',
                              'total', (po.metadata->>'total')::bigint, 'deposit_used', (po.metadata->>'deposit_used')::bigint,
                              'card_paid', coalesce(po.settle_krw, po.amount),
                              'rest_name', po.metadata->>'restaurant_name', 'date', po.metadata->>'visit_date', 'time', po.metadata->>'visit_time',
                              'pax', (po.metadata->>'pax')::int,
                              'host_user_id', (select i.host_user_id from public.reservation_invites i where i.id::text = po.metadata->>'invite_id'));
  end if;
  if po.status <> 'paid' then raise exception 'ORDER_NOT_PAID' using errcode = 'P0002'; end if;

  -- 잠금 순서: 주문 → 회원 잔액 → 초대. 예치금 결제(taam_apply_deposit_delta 가 잔액을 잠그고 → 원장 트리거가 초대를 잠근다)와 같은 순서라 서로 물리지 않는다
  select coalesce(membership_deposit_balance, 0), coalesce(general_deposit_balance, 0) into v_mem, v_gen
    from public.profiles where id = po.user_id for update;
  if not found then raise exception 'INVITE_NOT_FOUND' using errcode = 'P0002'; end if;

  select * into inv from public.reservation_invites where id::text = po.metadata->>'invite_id' for update;
  if not found then raise exception 'INVITE_NOT_FOUND' using errcode = 'P0002'; end if;
  if inv.invitee_user_id is distinct from po.user_id then raise exception 'FORBIDDEN: 내 초대가 아닙니다' using errcode = '42501'; end if;
  if coalesce(inv.status, '') = 'paid' then
    raise exception 'ORDER_SUPERSEDED: 이미 다른 결제로 확정된 초대입니다' using errcode = 'P0002';
  end if;
  if coalesce(inv.status, '') <> 'sent' then
    raise exception 'INVITE_CLOSED: 결제할 수 없는 초대입니다 (상태 %)', coalesce(inv.status, '없음') using errcode = 'P0002';
  end if;

  v_total := coalesce(inv.total_amount, 0)::bigint;
  v_card  := coalesce(po.settle_krw, po.amount)::bigint;
  v_dep   := v_total - v_card;
  if v_total <= 0 or v_dep < 0
     or v_total is distinct from (po.metadata->>'total')::bigint
     or coalesce(inv.pax, 0) is distinct from (po.metadata->>'pax')::int
     or v_dep is distinct from (po.metadata->>'deposit_used')::bigint then
    raise exception 'PRICE_CHANGED: 초대 금액이 바뀌었습니다 (지금 %원 · 주문 때 %원 · 카드 %원)', v_total, po.metadata->>'total', v_card using errcode = '22023';
  end if;
  v_pid := nullif(po.metadata->>'purchase_id', '');
  if v_pid is null then raise exception 'ORDER_NOT_FOUND' using errcode = 'P0002'; end if;

  -- 주문과 확정 사이에 예치금 결제가 끼어들었다(다른 기기 · 입금 반영 뒤) — 그 차감이 원장에 있으면 이 카드는 받지 않는다(Edge 가 취소한다 · 두 번 내지 않게)
  if public._taam_invite_net_paid(inv.id, po.user_id) > 0 then
    raise exception 'ORDER_SUPERSEDED: 이 초대에 예치금 결제가 먼저 들어왔습니다' using errcode = 'P0002';
  end if;
  if v_mem + v_gen < v_dep then
    raise exception 'INSUFFICIENT_DEPOSIT: 예치금이 부족합니다 (잔액 %원 · 필요 %원)', v_mem + v_gen, v_dep using errcode = '22023';
  end if;
  v_m := least(greatest(v_mem, 0), v_dep); v_g := v_dep - v_m;   -- 멤버십 먼저
  if v_g > v_gen then raise exception 'INSUFFICIENT_DEPOSIT: 예치금이 부족합니다' using errcode = '22023'; end if;

  -- ① 초대 「결제됨」 + 홀드 → 회원 소유 확정 좌석
  perform public._taam_invpay_seat(inv.id, v_pid);

  -- ② 예치금 몫 차감 — 잔액과 원장을 한 번에(종전 초대 결제와 같은 원장 모양 + 주문 번호)
  v_rest := coalesce(nullif(inv.restaurant_name, ''), '레스토랑');
  v_meta := jsonb_build_object('purchase_id', v_pid, 'invite_id', inv.id::text, 'restaurant', v_rest, 'pax', inv.pax,
                               'visit_date', inv.visit_date, 'visit_time', inv.visit_time, 'source', 'reservation_invite',
                               'payment_method', 'card+deposit', 'order_id', p_order, 'server_confirmed', true);
  if v_m > 0 then
    v_ent := v_ent || jsonb_build_object('deposit_type', 'membership', 'change_type', 'ticket_purchase', 'amount', -v_m,
                                         'description', '초대 결제 (멤버십) · ' || v_rest, 'metadata', v_meta);
  end if;
  if v_g > 0 then
    v_ent := v_ent || jsonb_build_object('deposit_type', 'general', 'change_type', 'ticket_purchase', 'amount', -v_g,
                                         'description', '초대 결제 (일반) · ' || v_rest, 'metadata', v_meta);
  end if;
  if v_dep > 0 then
    v_bal := public.taam_apply_deposit_delta(po.user_id, -v_m, -v_g, v_ent);
  end if;

  -- ③ 좌석 행에 결제 사실 — 환불 경로(회원 취소의 카드 몫 · 카드 환불 견적)가 이 칸을 본다
  update public.tickets
     set extra_data = coalesce(extra_data, '{}'::jsonb)
                      || jsonb_build_object('paidBy', case when v_dep > 0 then 'card+deposit' else 'card' end,
                                            'depositUsed', v_dep, 'cardPaid', v_card, 'order_id', p_order,
                                            'agencyFee', coalesce(inv.agency_fee, 0), 'server_confirmed', true)
   where purchase_id = v_pid and coalesce(status, '') = 'active' and user_id = po.user_id;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'HOLD_GONE: 확정된 좌석 행을 찾지 못했습니다' using errcode = 'P0002'; end if;

  -- ④ 주문에 확정 표시
  update public.payment_orders
     set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('inv_settled', true, 'settled_at', now())
   where order_id = p_order;

  return jsonb_build_object('ok', true, 'invite_id', inv.id::text, 'purchase_id', v_pid, 'total', v_total, 'deposit_used', v_dep, 'card_paid', v_card,
                            'mem', v_m, 'gen', v_g, 'balance_after', (v_mem + v_gen) - v_dep,
                            'rest_name', v_rest, 'date', inv.visit_date, 'time', inv.visit_time, 'pax', inv.pax, 'host_user_id', inv.host_user_id);
end $$;

-- ── F. 확정이 분명히 거절된 카드 주문을 닫는다 — **토스 승인 취소 전에**. 주문 줄을 잠그고(확정 함수와 같은 순서) 이 주문으로
--      이미 확정됐으면 닫지 않는다(settled). 닫힌 주문은 확정 함수가 ORDER_NOT_PAID 로 거절하므로 「취소하는 사이 다른 호출이 확정」하는 경주가 없다 ──
create or replace function public.taam_invite_order_close(p_order text, p_reason text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare po public.payment_orders%rowtype;
begin
  if not public._taam_invpay_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into po from public.payment_orders where order_id = p_order and purpose = 'invite_topup' for update;
  if not found then return jsonb_build_object('closed', false, 'status', null); end if;
  if coalesce(po.metadata->>'inv_settled', '') = 'true' then
    return jsonb_build_object('closed', false, 'settled', true, 'status', po.status);
  end if;
  if po.status <> 'paid' then return jsonb_build_object('closed', false, 'status', po.status); end if;
  update public.payment_orders set status = 'canceled', fail_reason = left(coalesce(p_reason, 'closed'), 60) || '_canceling' where order_id = p_order;
  return jsonb_build_object('closed', true, 'status', 'canceled');
end $$;
-- 결제 완료 알림은 주문마다 한 번 — 확정된 주문에 「알렸다」 표시를 한 문장으로 붙이고, 이번 호출이 붙였을 때만 true(그때 Edge 가 알림을 보낸다).
--   확정은 됐는데 응답을 잃은 경우(다음 호출은 「이미」로 온다)에도 알림이 빠지지 않고, 겹친 호출이 두 번 보내지도 않는다.
create or replace function public.taam_invite_order_notified(p_order text)
returns boolean language plpgsql volatile security definer set search_path = public as $$
declare v_n int;
begin
  if not public._taam_invpay_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update public.payment_orders
     set metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('inv_notified', true)
   where order_id = p_order and purpose = 'invite_topup'
     and coalesce(metadata->>'inv_settled', '') = 'true' and coalesce(metadata->>'inv_notified', '') <> 'true';
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;
revoke all on function public.taam_invite_order_prepare(text, uuid), public.taam_invite_confirm_card(text), public.taam_invite_order_close(text, text),
                       public.taam_invite_order_claim(text, text, text, text, timestamptz, jsonb), public.taam_invite_order_notified(text)
  from public, anon, authenticated;
insert into _ic values ('C~F 서버 함수(주문 · 잡기 · 확정 · 닫기) — service_role 만', '✅');

-- ── F'. 「보냄」이 아닌 초대에는 회원이 예치금 결제(차감)를 못 한다 ──
--   종전 예치금 결제는 ① 차감(RPC) ② 초대 「결제됨」 ③ 좌석 확정이 따로따로다. 카드 확정이 그 사이에 초대를 「결제됨」으로 바꾸면
--   ①은 이미 빠졌는데 ②③ 이 조용히 지나가(이미 결제됨 · 이미 확정) 두 번 내게 된다. 차감 줄이 들어오는 순간 초대를 잠그고(share) 상태를 본다 —
--   카드 확정(초대를 for update 로 쥔다)이 먼저면 끝날 때까지 기다렸다가 「결제됨」을 보고 거절하고, 차감이 먼저면 카드 확정이 그 차감을 보고 물러난다.
--   회원 세션만 본다(서버·슈퍼어드민은 그대로) · 초대 id 가 원장 메타에 있을 때만 · 판정을 못 하면 막지 않는다(결제를 이 가드가 깨뜨리지 않게).
create or replace function public.taam_guard_ledger_invite_open()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_iid text; v_st text; v_bad boolean := false;
begin
  if v_uid is null then return new; end if;
  if new.change_type is distinct from 'ticket_purchase' or coalesce(new.amount, 0) >= 0 then return new; end if;
  v_iid := nullif(new.metadata->>'invite_id', '');
  if v_iid is null or v_iid !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return new; end if;
  begin
    if coalesce(public.is_super_admin(v_uid), false) then return new; end if;
    select i.status into v_st from public.reservation_invites i where i.id = v_iid::uuid for share;
    v_bad := found and coalesce(v_st, '') <> 'sent';
  exception when others then
    raise warning 'taam_guard_ledger_invite_open: % — 막지 않는다', sqlerrm;
    return new;
  end;
  if v_bad then
    raise exception 'INVITE_CLOSED: 이미 처리된 초대입니다 (상태 %) — 예치금을 빼지 않았습니다', coalesce(v_st, '없음') using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_ledger_invite_open() from public, anon, authenticated;
do $do$ begin
  if to_regclass('public.deposit_transactions') is not null and to_regclass('public.reservation_invites') is not null then
    execute 'drop trigger if exists trg_taam_guard_ledger_invite_open on public.deposit_transactions';
    execute 'create trigger trg_taam_guard_ledger_invite_open before insert on public.deposit_transactions for each row execute function public.taam_guard_ledger_invite_open()';
    insert into _ic values ('F'' 원장 가드 — 「보냄」이 아닌 초대에는 회원 예치금 결제를 받지 않는다', '✅');
  else
    insert into _ic values ('F'' 원장 가드', '❌ 표 없음');
  end if;
end $do$;

-- ── F''. 확정된 좌석이 살아 있는 초대는 받는 회원이 「결제됨」에서 다른 상태로 못 바꾼다 ──
--   카드 확정은 서버(Edge · 정리 크론)가 회원 화면과 따로 돈다. 회원이 「초대 취소」를 누른 순간(앱이 읽은 상태는 「보냄」) 서버 확정이 먼저 끝나면
--   앱의 갱신이 초대를 「취소」로 바꿔 — 좌석은 확정·돈은 빠졌는데 초대장(캘린더가 그리는 표)은 취소인 모양이 된다.
--   좌석을 취소하면(구매 내역) 초대장은 서버가 맞춘다(trg_taam_invite_sync_on_seat_cancel) — 초대장만 따로 바꿀 일이 없다.
--   받는 회원 세션만 본다 · 좌석이 없는 「결제됨」(종전 결제의 되돌림: 결제됨 → 보냄)은 그대로.
create or replace function public.taam_guard_invite_seat_live()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_live boolean := false;
begin
  if v_uid is null then return new; end if;
  if coalesce(old.status, '') <> 'paid' or new.status is not distinct from old.status then return new; end if;
  if v_uid is distinct from old.invitee_user_id or v_uid = old.host_user_id then return new; end if;
  begin
    if coalesce(public.is_super_admin(v_uid), false) then return new; end if;
    v_live := exists (select 1 from public.tickets t
                       where t.purchase_id like 'INV-%' and t.extra_data->>'inviteId' = old.id::text
                         and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'refunded', 'expired', 'failed'));
  exception when others then
    raise warning 'taam_guard_invite_seat_live: % — 막지 않는다', sqlerrm;
    return new;
  end;
  if v_live then
    raise exception 'INVITE_HAS_SEAT: 이미 결제되어 좌석이 확정된 초대입니다 — 취소는 구매 내역에서 해 주세요' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_invite_seat_live() from public, anon, authenticated;
do $do$ begin
  if to_regclass('public.reservation_invites') is not null and to_regclass('public.tickets') is not null then
    execute 'drop trigger if exists trg_taam_guard_invite_seat_live on public.reservation_invites';
    execute 'create trigger trg_taam_guard_invite_seat_live before update of status on public.reservation_invites for each row execute function public.taam_guard_invite_seat_live()';
    insert into _ic values ('F'''' 초대장 가드 — 좌석이 확정된 초대는 받는 회원이 「결제됨」에서 못 바꾼다', '✅');
  else
    insert into _ic values ('F'''' 초대장 가드', '❌ 표 없음');
  end if;
end $do$;

-- ── G. 결과를 모르는 카드 주문 정리 — 10분마다 Edge toss-invite-pay 의 sweep(service_role) ──
--   confirm: paid 인데 확정 표시가 없다(3분 지남) · lookup: 10분 넘은 pending · cancel: 취소 실패(_refund_failed)·도중 끊김(_canceling)
create or replace function public.taam_invite_pay_reconcile_list(p_limit int default 15)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public._taam_invpay_server_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x order by ca), '[]'::jsonb) into v from (
    select po.created_at as ca,
           jsonb_build_object('order_id', po.order_id, 'user_id', po.user_id, 'amount', po.amount, 'status', po.status, 'payment_key', po.payment_key,
                              'fail_reason', po.fail_reason, 'created_at', po.created_at, 'approved_at', po.approved_at,
                              'metadata', jsonb_build_object('invite_id', po.metadata->>'invite_id', 'purchase_id', po.metadata->>'purchase_id',
                                                             'title', po.metadata->>'title', 'pax', po.metadata->'pax', 'total', po.metadata->'total',
                                                             'deposit_used', po.metadata->'deposit_used'),
                              'reconcile', case when po.status = 'paid' then 'confirm' when po.status = 'pending' then 'lookup'
                                                when po.status = 'failed' then 'orphan' else 'cancel' end) as x
      from public.payment_orders po
     where po.purpose = 'invite_topup' and po.created_at > now() - interval '3 days'
       and ((po.status = 'paid' and coalesce(po.metadata->>'inv_settled', '') <> 'true'
             and coalesce(po.approved_at, po.created_at) < now() - interval '3 minutes')
         -- pending: 승인 요청이 나간 주문(unknown: 표시)은 3분 뒤부터 · 표시 없는 주문(결제창이 아직 열려 있을 수 있다)은 40분 뒤에야
         or (po.status = 'pending' and coalesce(po.fail_reason, '') like 'unknown:%' and coalesce(po.updated_at, po.created_at) < now() - interval '3 minutes')
         or (po.status = 'pending' and coalesce(po.fail_reason, '') not like 'unknown:%' and po.created_at < now() - interval '40 minutes')
         or (po.status = 'canceled' and (po.fail_reason like '%refund_failed' or po.fail_reason like '%canceling'))
         -- failed: 닫힌 주문에 토스 승인이 남아 있을 수 있다(잡기 실패 뒤 취소 실패 · 옛 함수가 승인만 한 경우) — 취소 실패는 3일, 그 밖은 닫힌 뒤 3분~90분 동안 주문번호로 조회
         or (po.status = 'failed' and (po.fail_reason like '%refund_failed'
                                       or (coalesce(po.fail_reason, '') <> 'expired'   -- expired = 토스에 조회해 승인이 없다고 확인하고 닫은 주문 — 다시 보지 않는다
                                           and coalesce(po.updated_at, po.created_at) < now() - interval '3 minutes'
                                           and coalesce(po.updated_at, po.created_at) > now() - interval '90 minutes'))))
     order by po.created_at
     limit greatest(1, least(coalesce(p_limit, 15), 50))) s;
  return v;
end $$;
revoke all on function public.taam_invite_pay_reconcile_list(int) from public, anon, authenticated;

-- 부르는 법은 taam_package_reconcile_kick 과 같다(app_config.restock_push 의 Vault 시크릿 이름·URL · 함수 이름만 바꿔 쓴다 · 키 값은 Vault 에만)
create or replace function public.taam_invite_pay_reconcile_kick()
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_cfg jsonb; v_name text; v_url text; v_jwt text; v_req bigint;
begin
  if jsonb_array_length(public.taam_invite_pay_reconcile_list(1)) = 0 then
    return jsonb_build_object('ok', true, 'skipped', 'nothing');
  end if;
  if to_regclass('public.app_config') is null then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  select value::jsonb into v_cfg from public.app_config where key = 'restock_push';
  v_name := v_cfg->>'vault_secret'; v_url := v_cfg->>'url';
  if coalesce(v_name, '') = '' or coalesce(v_url, '') = '' then return jsonb_build_object('ok', false, 'reason', 'no_config'); end if;
  v_url := regexp_replace(v_url, '/functions/v1/[^/]+$', '/functions/v1/toss-invite-pay');
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return jsonb_build_object('ok', false, 'reason', 'no_pg_net'); end if;
  begin
    select decrypted_secret into v_jwt from vault.decrypted_secrets where name = v_name limit 1;
  exception when others then v_jwt := null; end;
  if coalesce(v_jwt, '') = '' then return jsonb_build_object('ok', false, 'reason', 'no_secret'); end if;
  select net.http_post(url := v_url, headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt),
                       body := jsonb_build_object('action', 'sweep'), timeout_milliseconds := 55000) into v_req;
  return jsonb_build_object('ok', true, 'request_id', v_req);
end $$;
revoke all on function public.taam_invite_pay_reconcile_kick() from public, anon, authenticated;
do $do$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('taam-invite-pay-reconcile'); exception when others then null; end;
    perform cron.schedule('taam-invite-pay-reconcile', '*/10 * * * *', $job$ select public.taam_invite_pay_reconcile_kick(); $job$);
    insert into _ic values ('G 결과 모르는 카드 주문 정리 — 10분 크론', '✅');
  else
    insert into _ic values ('G 결과 모르는 카드 주문 정리 — 10분 크론', '⚠ pg_cron 없음 — 함수만 설치(정리는 회원 재접속으로)');
  end if;
exception when others then insert into _ic values ('G 크론 등록', '⚠ ' || left(sqlerrm, 160));
end $do$;

-- ── 확인 (하나로 · ❌ 가 없어야 정상 · 건수만 — 공개 로그) ──
select 항목, 결과 from _ic
union all select '함수 12개', case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in (
         'taam_guard_inv_order_claim', '_taam_invpay_server_ok', '_taam_invpay_seat', 'taam_invite_order_prepare', 'taam_invite_order_claim',
         'taam_invite_confirm_card', 'taam_invite_order_close', 'taam_invite_pay_reconcile_list', 'taam_invite_pay_reconcile_kick', 'taam_guard_ledger_invite_open',
         'taam_invite_order_notified', 'taam_guard_invite_seat_live')) = 12
       then '✅' else '❌ 빠진 함수가 있다' end
union all select '의존 — taam_invite_confirm_hold(text, text) · taam_apply_deposit_delta(uuid, bigint, bigint, jsonb) · _taam_invite_net_paid(uuid, uuid, text)',
       case when to_regprocedure('public.taam_invite_confirm_hold(text, text)') is not null
             and to_regprocedure('public.taam_apply_deposit_delta(uuid, bigint, bigint, jsonb)') is not null
             and to_regprocedure('public._taam_invite_net_paid(uuid, uuid, text)') is not null then '✅' else '❌ 없다 — 확정이 돌지 않는다' end
union all select '회원·비로그인이 서버 함수를 못 부른다',
       case when has_function_privilege('authenticated', 'public.taam_invite_order_prepare(text, uuid)', 'execute')
              or has_function_privilege('authenticated', 'public.taam_invite_confirm_card(text)', 'execute')
              or has_function_privilege('authenticated', 'public.taam_invite_order_claim(text, text, text, text, timestamptz, jsonb)', 'execute')
              or has_function_privilege('authenticated', 'public.taam_invite_order_close(text, text)', 'execute')
              or has_function_privilege('authenticated', 'public.taam_invite_order_notified(text)', 'execute')
              or has_function_privilege('anon', 'public.taam_invite_order_prepare(text, uuid)', 'execute')
              or has_function_privilege('anon', 'public.taam_invite_pay_reconcile_kick()', 'execute')
            then '❌ 열려 있다' else '✅' end
union all select 'A'' 트리거 trg_taam_guard_inv_order_claim',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_inv_order_claim' and not tgisinternal) then '✅' else '❌' end
union all select '정보 — 지금 초대 카드 주문 수', (select count(*) from public.payment_orders where purpose = 'invite_topup')::text
union all select '정보 — 지금 「보냄」 초대 중 판매 티켓 연결 · 홀드 있음(카드로 낼 수 있는 초대) 수',
       (select count(*) from public.reservation_invites i where i.status = 'sent' and coalesce(i.ticket_product_id::text, '') <> ''
          and exists (select 1 from public.tickets t where t.status = 'hold' and t.purchase_id like 'INVH-%' and t.extra_data->>'inviteId' = i.id::text))::text;
