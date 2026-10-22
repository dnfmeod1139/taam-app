-- ═══════════════════════════════════════════════════════════════
-- 카드 결제분 환불 — 금액은 서버가 센다 · 티켓의 결제 사실 칸은 회원이 못 바꾼다 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다. 마지막 표에 ❌ 가 없어야 정상.
-- 왜(적대 리뷰 · 재현): 새 Edge toss-card-refund 가 tickets.extra_data.card_refund_pending 의 금액·주문번호를 그대로 믿었다.
--   그 칸은 회원 브라우저가 취소할 때 적고(cancelTicketPurchase) 그 뒤에도 회원이 고칠 수 있다(행 가드는 extra_data 를 안 본다) —
--   ① 취소한 싼 티켓의 대기를 「₩1,700,000 · 살아 있는 비싼 티켓의 주문」으로 바꾸면 슈퍼어드민 클릭 한 번에 그 주문이 카드 환불되고 좌석은 산다.
--   ② 완료(done)를 대기로 되돌리고 금액을 1원 바꾸면 중복 방지 키가 달라져 두 번째 실제 취소가 된다.
-- 무엇:
--   A. trg_taam_guard_ticket_payfacts (tickets BEFORE UPDATE) — 누가 취소하든 취소 순간 extra_data.server_cancelled_at = now()(서버 시각).
--      회원·매장 어드민 세션은 결제 사실 칸(card_refund_pending · server_cancelled_at · order_id · cardPaid · depositUsed · paidBy · card_currency · card_amount_fx)을
--      바꾸지 못한다(되돌림) — 단 카드 환불 대기는 **티켓을 취소하는 바로 그 갱신**에서만 새로 적을 수 있다(표시용 · set_by_role='member').
--      슈퍼어드민이 대기를 새로 적거나 금액을 바꾸면 set_by_role='superadmin'(특별 환불 — 그 금액을 따른다).
--   B. taam_card_refund_quote(purchase_id) — 슈퍼어드민·서버만. 이 구매의 주문을 서버 기록으로 찾고(payment_orders.metadata.hold_purchase_id = 구매 id ·
--      없으면 서버가 적은 order_id 의 홀드 없는 주문) 회원 규정으로 카드 몫을 다시 센다:
--        환불 가능 총액 = 결제(카드 승인 시각) 30분 안 취소 → 총액 · 방문 D-31 이상 전 취소 → 총액 − 대행비 × 인원 · 그 뒤 0  (취소 시각 = 서버 취소 시각 → 첫 환불 원장 → 지금)
--        카드 몫 = clamp(환불 가능 총액 − 예치금으로 낸 돈, 0, 카드 결제액)   (앱과 같다 — 예치금 먼저 돌려준다)
--        목표 = 회원이 적은 대기면 min(대기 금액, 카드 몫) · 슈퍼어드민이 적은 대기면 min(대기 금액, 카드 결제액)
--      Edge 는 토스에 이미 취소된 금액을 빼고(남은 만큼만) 실행한다 — 중복 환불이 원리적으로 안 된다.
-- 회귀: bash sql/_test/t_card_refund_quote.sh
-- ═══════════════════════════════════════════════════════════════

-- ── A. 티켓 결제 사실 칸 ──
create or replace function public.taam_guard_ticket_payfacts()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_keys text[] := array['card_refund_pending','server_cancelled_at','order_id','cardPaid','depositUsed','paidBy','card_currency','card_amount_fx'];
  v_cx   boolean;
  v_old  jsonb; v_new jsonb; k text;
begin
  v_cx := lower(coalesce(new.status, '')) in ('cancelled', 'canceled') and lower(coalesce(old.status, '')) not in ('cancelled', 'canceled');
  if v_cx then
    new.extra_data := coalesce(new.extra_data, '{}'::jsonb) || jsonb_build_object('server_cancelled_at', now());
  end if;
  v_old := coalesce(old.extra_data, '{}'::jsonb); v_new := coalesce(new.extra_data, '{}'::jsonb);

  if v_uid is null then return new; end if;                                                 -- 서버(Edge·SQL Editor)
  if coalesce(public.is_super_admin(v_uid), false) then
    if jsonb_typeof(v_new->'card_refund_pending') = 'object'
       and (v_old->'card_refund_pending' is null
            or (v_new->'card_refund_pending'->>'amount') is distinct from (v_old->'card_refund_pending'->>'amount')) then
      new.extra_data := jsonb_set(v_new, '{card_refund_pending,set_by_role}', '"superadmin"');
    end if;
    return new;
  end if;

  -- 회원·매장 어드민: 결제 사실 칸은 되돌린다
  foreach k in array v_keys loop
    if k = 'server_cancelled_at' and v_cx then continue; end if;
    if k = 'card_refund_pending' and v_cx and v_old->'card_refund_pending' is null then
      if jsonb_typeof(v_new->'card_refund_pending') = 'object' then
        v_new := jsonb_set(v_new, '{card_refund_pending,set_by_role}', '"member"');
      end if;
      continue;
    end if;
    if (v_new->k) is distinct from (v_old->k) then
      if v_old ? k then v_new := jsonb_set(v_new, array[k], v_old->k); else v_new := v_new - k; end if;
    end if;
  end loop;
  new.extra_data := v_new;
  return new;
end $$;
comment on function public.taam_guard_ticket_payfacts() is
  '티켓 결제 사실 칸 보호 — 취소 순간 server_cancelled_at · 회원·매장 어드민은 결제 사실 칸을 못 바꾼다(카드 환불 대기는 취소하는 그 갱신에서만 · set_by_role) · 슈퍼어드민 대기는 superadmin. 2026-10-22';
drop trigger if exists trg_taam_guard_ticket_payfacts on public.tickets;
create trigger trg_taam_guard_ticket_payfacts
  before update on public.tickets
  for each row execute function public.taam_guard_ticket_payfacts();

-- ── B. 서버 견적 ──
create or replace function public.taam_card_refund_quote(p_purchase_id text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  t record; po record; tp jsonb;
  v_crp jsonb; v_card bigint; v_total bigint; v_dep bigint; v_dep_back bigint;
  v_paid_at timestamptz; v_cx_at timestamptz; v_vd date; v_pax int; v_ag bigint; v_ref bigint; v_pol text; v_cap bigint;
  v_pend bigint; v_role text; v_target bigint;
begin
  if not coalesce(public._taam_fee_caller_ok(), false) then
    raise exception 'FORBIDDEN: 슈퍼어드민만 볼 수 있습니다' using errcode = '42501';
  end if;
  select * into t from public.tickets where purchase_id = p_purchase_id order by created_at desc nulls last limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'ticket_not_found'); end if;
  v_crp := t.extra_data->'card_refund_pending';
  if v_crp is null or jsonb_typeof(v_crp) <> 'object' then return jsonb_build_object('ok', false, 'error', 'not_pending'); end if;
  if v_crp->>'status' = 'done' then return jsonb_build_object('ok', false, 'error', 'already_done'); end if;
  if lower(coalesce(t.status, '')) in ('active', 'hold', 'pending_confirm', 'manual') then
    return jsonb_build_object('ok', false, 'error', 'ticket_active', 'status', t.status);
  end if;

  -- 이 구매의 주문 — 서버 기록으로만 (회원이 적은 주문번호는 쓰지 않는다)
  select * into po from public.payment_orders p
   where p.status = 'paid' and p.metadata->>'hold_purchase_id' = p_purchase_id
   order by p.approved_at desc nulls last limit 1;
  if po.order_id is null and coalesce(t.extra_data->>'order_id', '') <> '' then        -- 홀드 없이 만든 폴백 행(PAYC-) — order_id 는 서버가 적었고 회원은 못 바꾼다
    select * into po from public.payment_orders p
     where p.status = 'paid' and p.order_id = t.extra_data->>'order_id' and coalesce(p.metadata->>'hold_purchase_id', '') = ''
     limit 1;
  end if;
  if po.order_id is null then return jsonb_build_object('ok', false, 'error', 'no_order_for_purchase'); end if;
  if po.user_id is distinct from t.user_id then return jsonb_build_object('ok', false, 'error', 'owner_mismatch'); end if;
  if upper(coalesce(po.currency, 'KRW')) <> 'KRW' then return jsonb_build_object('ok', false, 'error', 'currency_not_supported', 'currency', po.currency); end if;
  if po.payment_key is null then return jsonb_build_object('ok', false, 'error', 'no_toss_payment'); end if;

  v_card  := greatest(coalesce(po.amount, 0), 0)::bigint;
  v_total := coalesce(nullif(t.price, 0)::bigint, public._taam_sr_int(po.metadata->>'total'), v_card);
  select coalesce(-sum(d.amount), 0) into v_dep from public.deposit_transactions d
   where d.user_id = t.user_id and d.change_type = 'ticket_purchase' and d.amount < 0 and d.metadata->>'purchase_id' = p_purchase_id;
  select coalesce(sum(d.amount), 0), min(d.created_at) into v_dep_back, v_cx_at from public.deposit_transactions d
   where d.user_id = t.user_id and d.change_type = 'ticket_refund' and d.amount > 0 and d.metadata->>'purchase_id' = p_purchase_id;
  v_paid_at := coalesce(po.approved_at, po.created_at);
  v_cx_at := coalesce(public._taam_sr_ts(t.extra_data->>'server_cancelled_at'), v_cx_at, now());
  select to_jsonb(x) into tp from public.ticket_products x where x.id::text = t.ticket_product_id::text;
  v_vd  := coalesce(public._taam_pu_visit_date(t.reservation_date), public._taam_pu_visit_date(tp->>'date'));
  v_pax := greatest(coalesce(t.party_size, public._taam_sr_int(po.metadata->>'pax')::int, 1), 1);
  v_ag  := coalesce(public._taam_sr_int(po.metadata->>'agency_fee'), public._taam_sr_int(tp->>'agency_fee'), 0) * v_pax;

  if v_paid_at is not null and v_cx_at - v_paid_at <= interval '30 minutes' then
    v_ref := v_total; v_pol := 'full_30min';
  elsif v_vd is null or v_vd - (v_cx_at at time zone 'Asia/Seoul')::date >= 31 then
    v_ref := greatest(0, v_total - v_ag); v_pol := 'd31';
  else
    v_ref := 0; v_pol := 'none';
  end if;
  v_cap := greatest(0, least(v_card, v_ref - v_dep));                                      -- 예치금 먼저 돌려주고 나머지가 카드 몫 (앱과 같다)
  v_pend := greatest(coalesce(public._taam_sr_int(v_crp->>'amount'), 0), 0);
  v_role := coalesce(nullif(v_crp->>'set_by_role', ''), 'member');
  v_target := case when v_role = 'superadmin' then least(v_pend, v_card) else least(v_pend, v_cap) end;

  return jsonb_build_object('ok', true, 'order_id', po.order_id, 'payment_key', po.payment_key, 'paid_via', po.metadata->>'paid_via',
    'card_paid', v_card, 'card_cap', v_cap, 'target', v_target, 'pending', v_pend, 'set_by_role', v_role,
    'policy', v_pol, 'refundable', v_ref, 'dep_paid', v_dep, 'dep_refunded', v_dep_back, 'total', v_total,
    'paid_at', v_paid_at, 'cancel_at', v_cx_at, 'visit', v_vd, 'user_id', t.user_id, 'restaurant_name', t.restaurant_name,
    'ticket_status', t.status, 'crp_order_id', v_crp->>'order_id');
end $$;
revoke all on function public.taam_card_refund_quote(text) from public, anon;
grant execute on function public.taam_card_refund_quote(text) to authenticated, service_role;
comment on function public.taam_card_refund_quote(text) is
  '카드 결제분 환불 견적 — 이 구매의 주문(hold_purchase_id)·원장·서버 취소 시각으로 회원 규정 카드 몫을 다시 센다. 슈퍼어드민·서버만. 2026-10-22';

-- ── 확인 — 한 표 ──
drop table if exists _crq_chk; create temp table _crq_chk(k text, v text);
insert into _crq_chk
select '① 트리거 trg_taam_guard_ticket_payfacts (tickets)',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ticket_payfacts' and tgrelid = 'public.tickets'::regclass and not tgisinternal) then '✅' else '❌' end
union all select '② 견적 함수 · 의존 함수(_taam_fee_caller_ok · _taam_sr_int · _taam_sr_ts · _taam_pu_visit_date)',
       case when to_regprocedure('public.taam_card_refund_quote(text)') is not null and to_regprocedure('public._taam_fee_caller_ok()') is not null
             and to_regprocedure('public._taam_sr_int(text)') is not null and to_regprocedure('public._taam_sr_ts(text)') is not null
             and to_regprocedure('public._taam_pu_visit_date(text)') is not null then '✅' else '❌' end
union all select '③ anon 실행 권한 없음', case when not has_function_privilege('anon', 'public.taam_card_refund_quote(text)', 'execute') then '✅' else '❌' end
union all select '④ 지금 카드 환불 대기 (정보)',
       (select count(*) from public.tickets where jsonb_typeof(extra_data->'card_refund_pending') = 'object' and coalesce(extra_data->'card_refund_pending'->>'status','') <> 'done')::text || '건';
select k as 항목, v as 결과 from _crq_chk order by 1;
