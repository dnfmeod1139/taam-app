-- ═══════════════════════════════════════════════════════════════
-- 카드 결제분 환불 2차 — 홀드를 만들 때도 결제 사실 칸을 못 적는다 · 방문일은 회차 값 · 주문은 이 티켓의 회차 것만 · 홀드 확정 금액 하한 · 옛 대기 채우기 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다. 마지막 표에 ❌ 가 없어야 정상.
-- 왜(배포 뒤 적대 검증 22 에이전트 · 재현):
--   ① 결제 사실 칸 보호(trg_taam_guard_ticket_payfacts)는 UPDATE 만 봤다 — 회원이 홀드를 **만들 때** extra_data.order_id 에 자기의 다른(홀드 없는) 주문을 적고
--      취소하면, 견적의 PAYC 폴백이 그 주문을 잡아 살아 있는 티켓의 카드 결제를 환불시킬 수 있었다(card_refund_pending.set_by_role='superadmin' 도 만들 때 넣을 수 있었다).
--   ② 방문일을 회원이 홀드 때 적은 reservation_date 에서 먼저 읽어 D-31(대행비 제외 환불) 판정을 속일 수 있었다 — 종전 예치금 환불 한도(taam_refund_cap)도 같은 칸을 본다.
--   ③ (종전부터) toss-order 가 다른 회차의 홀드 id 를 주문에 남기면 toss-confirm 이 그 (비싼) 홀드를 이 (싼) 주문 금액으로 확정할 수 있었다.
--   ④ 이 파일 전에 생긴 카드 환불 대기(라이브 2건)는 서버 취소 시각·적은 사람(set_by_role)이 없어 견적이 「지금 취소」·「회원 대기」로 셌다.
-- 무엇:
--   A. 결제 사실 칸 보호를 INSERT 에도(trg_taam_guard_ticket_payfacts_ins) — 회원·매장 어드민 세션의 INSERT 에서 보호 칸을 지운다 ·
--      회원 홀드(PAYH-)의 reservation_date·visit_time 은 회차(ticket_products) 값으로 맞춘다(종전 예치금 환불 한도의 D-31 판정도 이것으로 바로잡힌다).
--      UPDATE 보호 칸에 super_admin_processed_at/_by · deposit_return 을 더한다(옛 대기의 「슈퍼어드민이 적음」 판정 근거).
--   B. taam_card_refund_quote 2차 — 주문은 메타의 ticket_id 가 이 티켓 회차와 같아야(order_ticket_mismatch) · PAYC 폴백은 PAYC- 행이고 다른 살아 있는 티켓이 그 주문을 안 쓸 때만 ·
--      방문일은 회차 날짜 먼저 · 총액은 주문 메타(서버) 먼저 · 「이 구매에 앱이 이미 한 카드 취소」(payment_orders.metadata.app_cancels)를 돌려준다(Edge 가 그만 뺀다 — 인원 줄임 취소 등 다른 취소는 막지 않고 경고).
--   C. trg_taam_guard_ticket_price_floor — 앱 구매 홀드(PAY*)가 hold → active 가 될 때 금액이 회차 정가 × 인원(taam_ticket_price_krw)보다 작으면 PRICE_BELOW_TICKET
--      (외화 카드 결제는 제외). toss-confirm 은 이 거절을 받으면 그 주문의 회차로 새 행을 넣는 길로 간다(종전 폴백).
--   B'. (배포 전 2차 리뷰) 총액은 지금 티켓 금액과 주문 메타 중 작은 쪽 · 인원은 지금 인원 먼저 · 인원 줄임 환불(예치금 몫 = 서버 원장 ticket_pax_change ·
--      카드 몫 = 처음−지금 금액 − 예치금 몫)을 상한에서 뺀다 · pax_card 를 돌려줘 Edge 가 토스의 「앱 밖 취소」 중 설명되지 않는 몫(상점관리자에서 이미 한 환불)을 뺀다.
--   D. 옛 카드 환불 대기 채우기 — server_cancelled_at = 요청 시각(requested_at · 결제~지금 사이로) · set_by_role = 처리자가 실제 슈퍼어드민이면 superadmin, 아니면 member.
-- 회귀: bash sql/_test/t_card_refund_quote.sh
-- ═══════════════════════════════════════════════════════════════

-- ── A. 결제 사실 칸 — UPDATE(보호 칸 늘림) ──
create or replace function public.taam_guard_ticket_payfacts()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_keys text[] := array['card_refund_pending','server_cancelled_at','order_id','cardPaid','depositUsed','paidBy','card_currency','card_amount_fx',
                         'super_admin_processed_at','super_admin_processed_by','deposit_return'];
  v_cx   boolean;
  v_old  jsonb; v_new jsonb; k text;
begin
  v_cx := lower(coalesce(new.status, '')) in ('cancelled', 'canceled') and lower(coalesce(old.status, '')) not in ('cancelled', 'canceled');
  if v_cx then
    new.extra_data := coalesce(new.extra_data, '{}'::jsonb) || jsonb_build_object('server_cancelled_at', now());
  end if;
  v_old := coalesce(old.extra_data, '{}'::jsonb); v_new := coalesce(new.extra_data, '{}'::jsonb);

  if v_uid is null then return new; end if;
  if coalesce(public.is_super_admin(v_uid), false) then
    if jsonb_typeof(v_new->'card_refund_pending') = 'object'
       and (v_old->'card_refund_pending' is null
            or (v_new->'card_refund_pending'->>'amount') is distinct from (v_old->'card_refund_pending'->>'amount')) then
      new.extra_data := jsonb_set(v_new, '{card_refund_pending,set_by_role}', '"superadmin"');
    end if;
    return new;
  end if;

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

-- ── A. 결제 사실 칸 — INSERT ──
create or replace function public.taam_guard_ticket_payfacts_ins()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_keys text[] := array['card_refund_pending','server_cancelled_at','order_id','cardPaid','depositUsed','paidBy','card_currency','card_amount_fx',
                         'super_admin_processed_at','super_admin_processed_by','deposit_return'];
  k text; v_tp jsonb;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if new.extra_data is not null and jsonb_typeof(new.extra_data) = 'object' then
    foreach k in array v_keys loop new.extra_data := new.extra_data - k; end loop;
  end if;
  -- 회원 홀드의 방문일·시간은 회차 값 — 환불 규정(D-31)·견적이 이 칸을 읽는다
  if coalesce(new.purchase_id, '') like 'PAYH-%' and coalesce(new.ticket_product_id::text, '') <> '' then
    select to_jsonb(tp) into v_tp from public.ticket_products tp where tp.id::text = new.ticket_product_id::text;
    if v_tp is not null and coalesce(v_tp->>'date', '') ~ '^\d{4}[.\-/]\d{1,2}[.\-/]\d{1,2}' then
      new.reservation_date := v_tp->>'date';
      if coalesce(v_tp->>'time', '') <> '' then new.visit_time := v_tp->>'time'; end if;
    end if;
  end if;
  return new;
end $$;
comment on function public.taam_guard_ticket_payfacts_ins() is
  '티켓 INSERT: 회원·매장 어드민 세션은 결제 사실 칸을 못 적는다(지움) · 회원 홀드(PAYH-)의 방문일·시간은 회차 값. 2026-10-22 2차';
drop trigger if exists trg_taam_guard_ticket_payfacts_ins on public.tickets;
create trigger trg_taam_guard_ticket_payfacts_ins
  before insert on public.tickets
  for each row execute function public.taam_guard_ticket_payfacts_ins();

-- ── C. 홀드 확정 금액 하한 ──
create or replace function public.taam_guard_ticket_price_floor()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_min bigint;
begin
  if lower(coalesce(old.status, '')) <> 'hold' or lower(coalesce(new.status, '')) <> 'active' then return new; end if;
  if coalesce(new.purchase_id, '') !~ '^PAY' then return new; end if;
  if coalesce(new.extra_data->>'card_currency', '') <> '' then return new; end if;              -- 외화 카드 결제는 원화 정가와 단위가 다르다
  begin
    v_min := public.taam_ticket_price_krw(new.ticket_product_id::text, greatest(coalesce(new.party_size, 1), 1));
  exception when others then return new; end;
  if v_min is not null and coalesce(new.price, 0) < v_min then
    raise exception 'PRICE_BELOW_TICKET: 확정 금액 %원이 이 회차 % 명 정가 %원보다 작습니다', coalesce(new.price, 0), new.party_size, v_min
      using errcode = '22023';
  end if;
  return new;
end $$;
comment on function public.taam_guard_ticket_price_floor() is
  '앱 구매 홀드(PAY*)가 hold→active 될 때 금액 ≥ 회차 정가×인원(taam_ticket_price_krw) — 다른 회차 홀드를 싼 주문으로 확정하는 길을 막는다. 외화 제외. 2026-10-22';
drop trigger if exists trg_taam_guard_ticket_price_floor on public.tickets;
create trigger trg_taam_guard_ticket_price_floor
  before update of status on public.tickets
  for each row execute function public.taam_guard_ticket_price_floor();

-- ── B. 서버 견적 2차 ──
create or replace function public.taam_card_refund_quote(p_purchase_id text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  t record; po record; tp jsonb;
  v_crp jsonb; v_card bigint; v_total bigint; v_dep bigint; v_dep_back bigint;
  v_mt bigint; v_pr bigint; v_pax_dep bigint := 0; v_pax_card bigint := 0;
  v_paid_at timestamptz; v_cx_at timestamptz; v_vd date; v_pax int; v_ag bigint; v_ref bigint; v_pol text; v_cap bigint;
  v_pend bigint; v_role text; v_target bigint; v_done_pid bigint := 0; v_done_all bigint := 0;
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

  -- 이 구매의 주문 — 서버 기록으로만 · 주문의 회차가 이 티켓 회차와 같아야 한다
  select * into po from public.payment_orders p
   where p.status = 'paid' and p.metadata->>'hold_purchase_id' = p_purchase_id
   order by p.approved_at desc nulls last limit 1;
  if po.order_id is null and t.purchase_id like 'PAYC-%' and coalesce(t.extra_data->>'order_id', '') <> '' then
    -- 홀드 없이 만든 폴백 행 — order_id 는 서버(toss-confirm)가 적었다(회원은 INSERT·UPDATE 모두 못 적는다) · 다른 살아 있는 티켓이 그 주문을 쓰면 안 된다
    select * into po from public.payment_orders p
     where p.status = 'paid' and p.order_id = t.extra_data->>'order_id' and coalesce(p.metadata->>'hold_purchase_id', '') = ''
       and not exists (select 1 from public.tickets o where o.id <> t.id and o.extra_data->>'order_id' = p.order_id
                          and lower(coalesce(o.status, '')) not in ('cancelled', 'canceled', 'expired', 'failed'))
     limit 1;
  end if;
  if po.order_id is null then return jsonb_build_object('ok', false, 'error', 'no_order_for_purchase'); end if;
  if coalesce(po.metadata->>'ticket_id', '') <> '' and po.metadata->>'ticket_id' <> coalesce(t.ticket_product_id::text, '') then
    return jsonb_build_object('ok', false, 'error', 'order_ticket_mismatch');
  end if;
  if po.user_id is distinct from t.user_id then return jsonb_build_object('ok', false, 'error', 'owner_mismatch'); end if;
  if upper(coalesce(po.currency, 'KRW')) <> 'KRW' then return jsonb_build_object('ok', false, 'error', 'currency_not_supported', 'currency', po.currency); end if;
  if po.payment_key is null then return jsonb_build_object('ok', false, 'error', 'no_toss_payment'); end if;

  v_card  := greatest(coalesce(po.amount, 0), 0)::bigint;
  -- 총액 = 지금 티켓 금액과 주문 메타 중 **작은 쪽**(2차 리뷰) — 인원 줄임(taam_change_party_size)은 price·party_size 를 줄이고 주문 메타는 처음 그대로라,
  --   메타를 먼저 쓰면 줄인 뒤의 취소에서 상한이 처음 금액으로 부풀었다. price·party_size 는 회원이 못 바꾸는 칸(행 가드) · 확정되지 않은 홀드의 price 는 메타가 막는다.
  v_mt := public._taam_sr_int(po.metadata->>'total');
  v_pr := nullif(t.price, 0)::bigint;
  v_total := least(coalesce(v_mt, v_pr, v_card), coalesce(v_pr, v_mt, v_card));
  select coalesce(-sum(d.amount), 0) into v_dep from public.deposit_transactions d
   where d.user_id = t.user_id and d.change_type = 'ticket_purchase' and d.amount < 0 and d.metadata->>'purchase_id' = p_purchase_id;
  -- 인원 줄임 환불 — 예치금 몫은 서버 원장(ticket_pax_change · 회원은 못 쓴다), 카드 몫 = (처음 금액 − 지금 금액) − 예치금 몫. 회원이 쓸 수 있는 card_refund_queue 는 믿지 않는다
  select coalesce(sum(d.amount), 0) into v_pax_dep from public.deposit_transactions d
   where d.user_id = t.user_id and d.change_type = 'ticket_pax_change' and d.amount > 0 and d.metadata->>'purchase_id' = p_purchase_id;
  v_pax_card := greatest(0, coalesce(v_mt, v_pr, 0) - coalesce(v_pr, v_mt, 0) - v_pax_dep);
  v_dep := greatest(0, v_dep - v_pax_dep);   -- 티켓에 남아 있는 예치금 몫
  select coalesce(sum(d.amount), 0), min(d.created_at) into v_dep_back, v_cx_at from public.deposit_transactions d
   where d.user_id = t.user_id and d.change_type = 'ticket_refund' and d.amount > 0 and d.metadata->>'purchase_id' = p_purchase_id;
  v_paid_at := coalesce(po.approved_at, po.created_at);
  v_cx_at := coalesce(public._taam_sr_ts(t.extra_data->>'server_cancelled_at'), v_cx_at, now());
  select to_jsonb(x) into tp from public.ticket_products x where x.id::text = t.ticket_product_id::text;
  v_vd  := coalesce(public._taam_pu_visit_date(tp->>'date'), public._taam_pu_visit_date(t.reservation_date));     -- 회차 날짜(서버)가 먼저
  v_pax := greatest(coalesce(nullif(t.party_size, 0), public._taam_sr_int(po.metadata->>'pax')::int, 1), 1);   -- 지금 인원(인원 줄임 뒤)이 먼저 · 회원이 못 바꾼다
  v_ag  := coalesce(public._taam_sr_int(po.metadata->>'agency_fee'), public._taam_sr_int(tp->>'agency_fee'), 0) * v_pax;

  if v_paid_at is not null and v_cx_at - v_paid_at <= interval '30 minutes' then
    v_ref := v_total; v_pol := 'full_30min';
  elsif v_vd is null or v_vd - (v_cx_at at time zone 'Asia/Seoul')::date >= 31 then
    v_ref := greatest(0, v_total - v_ag); v_pol := 'd31';
  else
    v_ref := 0; v_pol := 'none';
  end if;
  v_cap := greatest(0, least(v_card - v_pax_card, v_ref - v_dep));   -- 인원 줄임으로 이미 돌려준(또는 돌려줄) 카드 몫은 뺀다
  v_pend := greatest(coalesce(public._taam_sr_int(v_crp->>'requested_amount'), public._taam_sr_int(v_crp->>'amount'), 0), 0);
  v_role := coalesce(nullif(v_crp->>'set_by_role', ''), 'member');
  v_target := case when v_role = 'superadmin' then least(v_pend, greatest(0, v_card - v_pax_card)) else least(v_pend, v_cap) end;
  -- 이 구매에 앱이 이미 한 카드 취소 (Edge 가 적은 기록) · 이 주문에 앱이 한 취소 전부
  select coalesce(sum((x->>'amount')::numeric) filter (where x->>'purchase_id' = p_purchase_id), 0), coalesce(sum((x->>'amount')::numeric), 0)
    into v_done_pid, v_done_all
    from jsonb_array_elements(case when jsonb_typeof(po.metadata->'app_cancels') = 'array' then po.metadata->'app_cancels' else '[]'::jsonb end) x;

  return jsonb_build_object('ok', true, 'order_id', po.order_id, 'payment_key', po.payment_key, 'paid_via', po.metadata->>'paid_via',
    'card_paid', v_card, 'card_cap', v_cap, 'target', v_target, 'pending', v_pend, 'set_by_role', v_role,
    'policy', v_pol, 'refundable', v_ref, 'dep_paid', v_dep, 'dep_refunded', v_dep_back, 'total', v_total,
    'paid_at', v_paid_at, 'cancel_at', v_cx_at, 'visit', v_vd, 'user_id', t.user_id, 'restaurant_name', t.restaurant_name,
    'ticket_status', t.status, 'crp_order_id', v_crp->>'order_id', 'done_for_purchase', v_done_pid, 'app_cancelled_order', v_done_all,
    'pax_card', v_pax_card, 'pax_dep', v_pax_dep);
end $$;
revoke all on function public.taam_card_refund_quote(text) from public, anon;
grant execute on function public.taam_card_refund_quote(text) to authenticated, service_role;

-- ── D. 옛 카드 환불 대기 채우기 (이 파일 전에 생긴 것 · 한 번) ──
drop table if exists _crq2_fill; create temp table _crq2_fill(id uuid, role text);
insert into _crq2_fill
select t.id,
       case when coalesce(t.extra_data->>'super_admin_processed_at', '') <> ''
             and exists (select 1 from public.profiles p where p.id::text = t.extra_data->>'super_admin_processed_by' and p.role in ('superadmin', 'super_admin'))
            then 'superadmin' else 'member' end
  from public.tickets t
 where jsonb_typeof(t.extra_data->'card_refund_pending') = 'object'
   and coalesce(t.extra_data->'card_refund_pending'->>'status', '') <> 'done'
   and coalesce(t.extra_data->'card_refund_pending'->>'set_by_role', '') = '';
update public.tickets t
   set extra_data = jsonb_set(
         case when coalesce(t.extra_data->>'server_cancelled_at', '') = '' and public._taam_sr_ts(t.extra_data->'card_refund_pending'->>'requested_at') is not null
              then t.extra_data || jsonb_build_object('server_cancelled_at',
                     least(now(), greatest(t.created_at, public._taam_sr_ts(t.extra_data->'card_refund_pending'->>'requested_at'))))
              else t.extra_data end,
         '{card_refund_pending,set_by_role}', to_jsonb(f.role))
  from _crq2_fill f
 where f.id = t.id;

-- ── 확인 — 한 표 ──
drop table if exists _crq2_chk; create temp table _crq2_chk(k text, v text);
insert into _crq2_chk
select '① INSERT 가드 trg_taam_guard_ticket_payfacts_ins',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ticket_payfacts_ins' and tgrelid = 'public.tickets'::regclass and not tgisinternal) then '✅' else '❌' end
union all select '② 확정 금액 하한 trg_taam_guard_ticket_price_floor · taam_ticket_price_krw',
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_ticket_price_floor' and tgrelid = 'public.tickets'::regclass and not tgisinternal)
             and to_regprocedure('public.taam_ticket_price_krw(text,integer)') is not null then '✅' else '❌' end
union all select '③ 견적 2차 (order_ticket_mismatch · done_for_purchase)',
       case when (select prosrc from pg_proc where oid = 'public.taam_card_refund_quote(text)'::regprocedure) like '%done_for_purchase%' then '✅' else '❌' end
union all select '④ 옛 카드 환불 대기 채움 (정보)', (select count(*) || '건 (슈퍼어드민 ' || count(*) filter (where role = 'superadmin') || ')' from _crq2_fill)
union all select '⑤ 회원 홀드·구매의 방문일이 회차 날짜와 다른 행 (정보 · 살아 있는 PAYH-)',
       (select count(*) from public.tickets t join public.ticket_products tp on tp.id::text = t.ticket_product_id::text
         where t.purchase_id like 'PAYH-%' and lower(coalesce(t.status,'')) in ('active','hold','completed')
           and public._taam_pu_visit_date(t.reservation_date) is distinct from public._taam_pu_visit_date(tp.date))::text || '건'
union all select '⑥ 살아 있는 앱 구매 중 금액 < 회차 정가×인원 (정보 · 외화 제외)',
       (select count(*) from public.tickets t
         where t.purchase_id ~ '^PAY' and lower(coalesce(t.status,'')) = 'active' and coalesce(t.extra_data->>'card_currency','') = ''
           and coalesce(t.price,0) < coalesce(public.taam_ticket_price_krw(t.ticket_product_id::text, greatest(coalesce(t.party_size,1),1)), 0))::text || '건';
select k as 항목, v as 결과 from _crq2_chk order by 1;
