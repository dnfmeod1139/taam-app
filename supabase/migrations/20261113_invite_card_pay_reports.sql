-- ═══════════════════════════════════════════════════════════════
-- TAAM — 판매 현황: 초대 「예치금 + 카드」의 카드 몫을 센다 (2026-11-13 · 20261113_invite_card_pay.sql 과 한 쌍)
-- ═══════════════════════════════════════════════════════════════
--   판매 현황의 초대 채널은 「받는 회원의 원장 결제 줄」만 판매액으로 셌다(초대는 예치금 전용이었다). 초대 ₩10,500,000 을
--   예치금 ₩8,000,000 + 카드 ₩2,500,000 으로 내면 판매 ₩8,000,000 · 결제수단 「예치금」 · 「⚠ 원장과 다름」으로 보이고,
--   전액 카드로 낸 초대는 줄에서 빠져 「확인 필요 — 결제된 초대인데 예치금 결제 줄이 없다」로 갔다. 카드 환불(대기·완료)도 안 셌다.
--   앱 채널은 INV- 행을 접두어로 빼므로 그 카드 주문은 어디에도 안 세였다(이중 집계가 아니라 빠짐).
--
--   고침(라이브 본문을 pg_get_functiondef 로 읽어 **그 자리만** · 자리마다 정확히 한 곳일 때만 · 표시 INVITE_CARD_20261113):
--     ① 초대마다 「이 초대로 확정된 카드 주문」(payment_orders · purpose invite_topup · paid · inv_settled · 받는 회원 것)의 카드 금액을 붙인다
--        — payment_orders 는 회원이 못 쓰는 표다(「회원이 못 쓰는 기록만 믿는다」 그대로)
--     ② 판매액 = 원장 결제(− 되돌림) + 카드 · 결제수단 예치금 / 카드+예치금 / 카드 · dep · card 칸
--     ③ 카드 환불 = 좌석 행의 card_refund_pending 금액(카드 몫까지만 — 앱 채널과 같은 규칙) → 취소·위약 환불에 더하고, 완료 전이면 「카드 환불 대기」
--     ④ **방문 후 반환**의 카드 몫은 취소가 아니다(적대 리뷰) — 초대는 종전에 결제수단과 무관하게 「방문 후 반환은 순판매에서 안 빼고 따로」였다.
--        카드 몫을 취소 환불로 세면 다녀온 예약의 순판매가 카드 반환분만큼 줄고, 전액 카드 초대는 원장 반환 줄이 없어 「취소」로 분류됐다.
--        → 원장 반환 줄이 있거나(ret_ok), 원장 줄이 없어도 좌석의 슈퍼어드민 처리 기록이 방문 후 반환이면
--          (deposit_return.type = 'returned' · 좌석 열기 아님 · 방문 기록 attended 또는 처리일(KST) ≥ 방문일 − 1 — 둘 다 회원이 못 쓰는 칸)
--          상태는 「반환」 · 카드 몫은 rf_return 에 · 순판매에서 빼지 않는다. 방문 전 반환·좌석 열기·회원 취소는 종전대로 취소.
--        그때 보유 대행비는 원장(agency_held)에 없으면 좌석 처리 기록의 agencyHeld 로(카드 주문이 붙은 초대만) — 전액 카드 반환은 원장 줄이 없어
--        「초대 대행비 × 인원 · 확정」으로 잡혔다(대행비를 면제하고 전액 돌려줘도 · 2차 리뷰).
--   그 밖(대행비 · 조기 반환 · 확인 필요)은 그대로. 예치금만으로 낸 초대는 숫자가 하나도 안 바뀐다(inv_card = null).
--   모양이 다르면(라이브 본문이 예상과 다름) ⚠ 로 두고 건드리지 않는다.
--   회귀: bash sql/_test/t_ticket_sales.sh (V 절)
-- ═══════════════════════════════════════════════════════════════

drop table if exists _taam_icr;
create temp table _taam_icr(st text, note text);
do $b$
declare
  v_oid oid := to_regprocedure('public.taam_ticket_sales_report(date,date,text,boolean)');
  v_def text; v_new text; n int; i int; v_i text;
  c_old text[] := array[
    -- 1 초대 좌석 칸(j) — 카드 주문 · 카드 환불 대기
    $q$tp.agency_fee as tp_agency, tp.meal_fee as tp_meal, tp.wine_min as tp_wine,$q$,
    -- 2 초대마다 확정된 카드 주문
    $q$left join public.profiles pr on pr.id = i.invitee_user_id$q$,
    -- 3 판매액
    $q$greatest(coalesce((il->>'buy')::bigint, 0) - l_rev, 0) as gross,$q$,
    -- 4 순판매
    $q$w as (select u2.*, gross - l_cancel - ret_early - l_pen - l_pax as net from u2)$q$,
    -- 5 결제수단
    $q$'k', 'inv:' || id, 'ch', 'invite', 'pm', 'deposit',$q$,
    -- 6 예치금·카드 칸
    $q$'dep', gross, 'card', 0,$q$,
    -- 7 환불 칸 · 보유
    $q$'rf_cancel', l_cancel + ret_early, 'rf_penalty', l_pen, 'rf_pax', l_pax, 'rf_return', ret_ok, 'rf_card_pending', 0, 'rf_at', l_at,
        'net', net, 'held', net - ret_ok,$q$,
    -- 8 상태 — 방문 후 반환
    $q$                  when ret_ok > 0 then 'returned'
                  when lower(coalesce(tk_status,'')) in ('cancelled','canceled') or status = 'cancelled' or l_cancel > 0 or l_ret > 0 then 'cancelled' end as proc$q$,
    -- 9 보유 대행비 기록 — 원장에 없으면(전액 카드 반환은 원장 줄이 없다) 좌석의 처리 기록
    $q$             (select max((v_led->(p || '|' || j.invitee_user_id::text)->>'ag_held')::bigint) from jsonb_array_elements_text(j.pids) p) as l_ag,$q$
  ];
  c_new text[] := array[
    $q$tp.agency_fee as tp_agency, tp.meal_fee as tp_meal, tp.wine_min as tp_wine,
             ipo.card as inv_card, tk.extra_data->'card_refund_pending' as tk_crp /* INVITE_CARD_20261113 */,
             tk.extra_data->'deposit_return'->>'type' as tk_dr_type, tk.extra_data->>'super_admin_processed_at' as tk_proc_at, tk.extra_data->'deposit_return' as tk_dr,$q$,
    $q$left join lateral (select least(coalesce(po.settle_krw, po.amount, 0), 999999999999)::bigint as card
                             from public.payment_orders po
                            where po.purpose = 'invite_topup' and po.status = 'paid' and po.user_id = i.invitee_user_id
                              and po.metadata->>'invite_id' = i.id::text and coalesce(po.metadata->>'inv_settled', '') = 'true'
                            order by po.approved_at desc nulls last limit 1) ipo on true
        left join public.profiles pr on pr.id = i.invitee_user_id$q$,
    $q$greatest(coalesce((il->>'buy')::bigint, 0) - l_rev, 0) as dep_ev,
             greatest(coalesce((il->>'buy')::bigint, 0) - l_rev, 0) + coalesce(inv_card, 0) as gross,
             least(greatest(coalesce(public._taam_sr_int(tk_crp->>'amount'), 0), 0), coalesce(inv_card, 0)) as crp,   -- 카드 환불(대기·완료)은 카드 몫까지만
             coalesce(tk_crp->>'status', 'pending') as crp_st,
             -- 좌석의 슈퍼어드민 처리 기록이 「방문 후 반환」인가(원장 반환 줄이 없는 전액 카드 초대용 · 둘 다 보호 칸)
             coalesce(coalesce(tk_dr_type, '') = 'returned' and coalesce(tk_seat_open, '') <> 'true'
                      and (coalesce(visit_st, '') = 'attended' or vdate is null
                           or ((public._taam_sr_ts(tk_proc_at)) at time zone 'Asia/Seoul')::date >= vdate - 1), false) as seat_ret,$q$,
    $q$w as (select u2.*, gross - l_cancel - ret_early - l_pen - l_pax - case when proc = 'returned' then 0 else crp end as net from u2)$q$,
    $q$'k', 'inv:' || id, 'ch', 'invite', 'pm', case when coalesce(inv_card, 0) <= 0 then 'deposit' when dep_ev <= 0 then 'card' else 'mixed' end,$q$,
    $q$'dep', dep_ev, 'card', coalesce(inv_card, 0),$q$,
    $q$'rf_cancel', l_cancel + ret_early + case when proc in ('penalty', 'returned') then 0 else crp end, 'rf_penalty', l_pen + case when proc = 'penalty' then crp else 0 end, 'rf_pax', l_pax, 'rf_return', ret_ok + case when proc = 'returned' then crp else 0 end, 'rf_card_pending', case when crp_st <> 'done' then crp else 0 end, 'rf_at', l_at,
        'net', net, 'held', net - ret_ok - case when proc = 'returned' then crp else 0 end,$q$,
    $q$                  when ret_ok > 0 or (l_ret = 0 and crp > 0 and seat_ret) then 'returned'
                  when lower(coalesce(tk_status,'')) in ('cancelled','canceled') or status = 'cancelled' or l_cancel > 0 or l_ret > 0 then 'cancelled' end as proc$q$,
    -- 카드 주문이 붙은 초대만(예치금만 낸 초대는 숫자가 그대로) · 슈퍼어드민 반환 기록(deposit_return — 보호 칸)의 agencyHeld. 면제(0)도 기록이다
    $q$             coalesce((select max((v_led->(p || '|' || j.invitee_user_id::text)->>'ag_held')::bigint) from jsonb_array_elements_text(j.pids) p),
                      case when j.inv_card is not null and coalesce(j.tk_dr_type, '') = 'returned' and jsonb_typeof(j.tk_dr) = 'object' and j.tk_dr ? 'agencyHeld'
                           then least(greatest(coalesce(public._taam_sr_int(j.tk_dr->>'agencyHeld'), 0), 0), 999999999999) end) as l_ag,$q$
  ];
begin
  if v_oid is null then insert into _taam_icr values ('⚠', '판매 현황 함수가 없다 — 건너뜀'); return; end if;
  if to_regclass('public.payment_orders') is null then insert into _taam_icr values ('⚠', 'payment_orders 가 없다 — 건너뜀'); return; end if;
  v_def := pg_get_functiondef(v_oid);
  if position('INVITE_CARD_20261113' in v_def) > 0 then insert into _taam_icr values ('✅', '이미 새 판'); return; end if;
  for i in 1 .. array_length(c_old, 1) loop
    n := (length(v_def) - length(replace(v_def, c_old[i], ''))) / length(c_old[i]);
    if n <> 1 then
      insert into _taam_icr values ('⚠', format('모양이 다르다(자리 %s — %s곳 · 1곳이어야) — 건드리지 않음', i, n));
      return;
    end if;
  end loop;
  v_new := v_def;
  for i in 1 .. array_length(c_old, 1) loop v_new := replace(v_new, c_old[i], c_new[i]); end loop;
  begin
    execute v_new;
  exception when others then
    insert into _taam_icr values ('⚠', '덧댄 본문을 올리지 못했다 — 옛 본문 그대로: ' || left(sqlerrm, 160));
    return;
  end;
  -- 덧댄 본문이 실제로 도는지 한 번 불러 본다 — 실행에서 터지면 옛 본문으로 되돌린다(판매 현황 화면이 통째로 죽는 것보다 카드 몫이 빠진 옛 숫자가 낫다)
  begin
    perform public.taam_ticket_sales_report(null, null, 'paid', false);
    insert into _taam_icr values ('✅', '덧댐 — 초대 9곳 · 실행 확인');
  exception when others then
    if sqlerrm ~* 'FORBIDDEN|슈퍼어드민|권한' then
      insert into _taam_icr values ('✅', '덧댐 — 초대 9곳 (실행 확인은 건너뜀 — 이 세션은 보고서를 부를 권한이 없다)');
    else
      v_i := left(sqlerrm, 160);
      execute v_def;
      insert into _taam_icr values ('⚠', '덧댄 본문이 실행에서 실패 — 옛 본문으로 되돌림: ' || v_i);
    end if;
  end;
end $b$;

-- 덧댄 뒤에도 보고서가 도는지 한 번 불러 본다(실패해도 이 파일을 멈추지 않는다 — 결과만 적는다)
drop table if exists _taam_icr_run;
create temp table _taam_icr_run(note text);
do $c$
declare r jsonb;
begin
  if to_regprocedure('public.taam_ticket_sales_report(date,date,text,boolean)') is null then
    insert into _taam_icr_run values ('— 함수 없음'); return;
  end if;
  r := public.taam_ticket_sales_report(null, null, 'paid', false);
  insert into _taam_icr_run values (case when (r->>'ok') = 'true' then '✅ ' || jsonb_array_length(coalesce(r->'rows', '[]'::jsonb))::text || '줄'
                                         else '⚠ ok 아님' end);
exception when others then
  insert into _taam_icr_run values ('⚠ 불러 보지 못함: ' || left(sqlerrm, 160));
end $c$;

-- ── 확인 — 한 표 (건수만 · 공개 로그) ──
select '① 판매 현황 — 초대의 카드 몫' as 항목, (select st || ' ' || note from _taam_icr limit 1) as 결과
union all
select '② 덧댄 뒤에도 보고서가 돈다(정보 — 줄 수)', (select note from _taam_icr_run limit 1)
union all
select '③ 정보 — 확정된 초대 카드 주문 수', case when to_regclass('public.payment_orders') is null then '—'
       else (select count(*)::text from public.payment_orders where purpose = 'invite_topup' and status = 'paid' and coalesce(metadata->>'inv_settled', '') = 'true') end;
