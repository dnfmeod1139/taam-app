-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 판매 현황이 패키지 카드 결제를 회차마다 센다 (2026-10-29)
-- ═══════════════════════════════════════════════════════════════
--   패키지(20261029_ticket_package.sql)는 카드 주문 하나가 여러 회차(여러 매장)를 낸다. 판매 현황(taam_ticket_sales_report 4차)은
--   「한 카드 주문은 한 판매」로 그 주문 전액을 주문 번호가 적힌 첫 줄에 붙여, 그 매장 판매가 부풀고 카드만으로 낸 다른 회차는
--   「돈 기록 없음」(확인 필요)으로 빠졌다. 카드 환불 대기(첫 카드 줄의 card_refund_pending = 패키지 전체)도 그 줄의 카드 몫으로 잘렸다.
--   → 패키지 주문(purpose package_topup)은 「한 주문 = 한 판매」에서 빼고, 줄마다 카드 몫·카드 환불 몫을 서버 표
--     ticket_package_orders(items[].card · cancel.alloc · card_refund.status)에서 읽는다 — 회원이 못 쓰는 표다.
--   라이브 함수 본문에서 정확히 세 군데만 바꾼다(pg_get_functiondef · 모양이 다르면 ⚠ 로 두고 건드리지 않는다 — 뒤 Edge 배포를 막지 않게).
-- ═══════════════════════════════════════════════════════════════
create temp table if not exists _pkr(항목 text, 결과 text);
truncate _pkr;
do $do$
declare
  v_def text; v_new text;
  a1 text := $a$     order by tk.extra_data->>'order_id', tk.created_at
  ), b as ($a$;
  b1 text := $b$     order by tk.extra_data->>'order_id', tk.created_at
  ), pkx as (   -- 🆕 2026-10-29 패키지 — 한 카드 주문이 여러 회차다. 줄마다 카드 몫·카드 환불 몫은 서버 표가 안다(회원이 못 쓴다)
    select it->>'purchase_id' as pid, o.user_id,
           case when coalesce((it->>'card')::bigint, 0) > 0 and lower(coalesce(po.status, '')) = 'paid'
                then jsonb_build_object('settle_krw', (it->>'card')::bigint, 'currency', 'KRW', 'approved_at', po.approved_at, 'order_id', po.order_id) end as poj,
           case when o.status = 'cancelled' then coalesce((o.cancel->'alloc'->(it->>'purchase_id')->>'card')::bigint, 0) end as crp,
           coalesce(o.card_refund->>'status', 'pending') as crp_st
      from public.ticket_package_orders o
      cross join lateral jsonb_array_elements(o.items) it
      left join public.payment_orders po on po.order_id = o.order_id and po.user_id = o.user_id
     where o.status in ('paid', 'cancelled')
  ), b as ($b$;
  a2 text := $a$from tk join public.payment_orders po on po.order_id = tk.extra_data->>'order_id' and po.user_id = tk.user_id and po.status = 'paid'
$a$;
  b2 text := $b$from tk join public.payment_orders po on po.order_id = tk.extra_data->>'order_id' and po.user_id = tk.user_id and po.status = 'paid'
                                              and po.purpose is distinct from 'package_topup'
$b$;
  a3 text := $a$to_jsonb(tp) as tpj, to_jsonb(po1) as poj,$a$;
  b3 text := $b$to_jsonb(tp) as tpj, coalesce(to_jsonb(po1), pkx.poj) as poj, pkx.crp as pk_crp, pkx.crp_st as pk_crp_st,$b$;
  a4 text := $a$      left join po1 on po1.pid = t.purchase_id
$a$;
  b4 text := $b$      left join po1 on po1.pid = t.purchase_id
      left join pkx on pkx.pid = t.purchase_id and pkx.user_id = t.user_id
$b$;
  a5 text := $a$           coalesce(public._taam_sr_int(x->'card_refund_pending'->>'amount'), 0) as crp_amt,
           coalesce(x->'card_refund_pending'->>'status', 'pending') as crp_st$a$;
  b5 text := $b$           case when pk_crp is not null then pk_crp else coalesce(public._taam_sr_int(x->'card_refund_pending'->>'amount'), 0) end as crp_amt,
           case when pk_crp is not null then pk_crp_st else coalesce(x->'card_refund_pending'->>'status', 'pending') end as crp_st$b$;
  n int;
begin
  if to_regprocedure('public.taam_ticket_sales_report(date, date, text, boolean)') is null then
    insert into _pkr values ('판매 현황 함수', '⚠ 없음 — 건너뜀'); return;
  end if;
  if to_regclass('public.ticket_package_orders') is null then
    insert into _pkr values ('패키지 표', '⚠ 없음 — 20261029_ticket_package.sql 먼저'); return;
  end if;
  v_def := pg_get_functiondef('public.taam_ticket_sales_report(date, date, text, boolean)'::regprocedure);
  if v_def like '%pkx as (%' then insert into _pkr values ('판매 현황 — 패키지 카드 몫', '✅ 이미 새 판'); return; end if;
  foreach v_new in array array[a1, a2, a3, a4, a5] loop
    n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
    if n <> 1 then
      insert into _pkr values ('판매 현황 — 패키지 카드 몫', '⚠ 라이브 본문 모양이 다르다(자리 ' || left(replace(v_new, E'\n', ' '), 40) || '… ' || n || '곳) — 건드리지 않음');
      return;
    end if;
  end loop;
  v_new := replace(replace(replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3), a4, b4), a5, b5);
  execute v_new;
  insert into _pkr values ('판매 현황 — 패키지 카드 몫', '✅ 덧댐(패키지 주문은 줄마다 카드 몫 · 카드 환불 몫)');
exception when others then insert into _pkr values ('판매 현황 — 패키지 카드 몫', '⚠ ' || left(sqlerrm, 160));
end $do$;

select 항목, 결과 from _pkr
union all select '판매 현황 함수가 패키지 몫을 읽는다(정보)',
       case when exists (select 1 from pg_proc where proname = 'taam_ticket_sales_report' and prosrc like '%pkx as (%') then '✅' else '⚠ 아직 — 위 줄' end;
