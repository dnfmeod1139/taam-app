-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 판매 현황 숫자를 원장과 맞춰 본다 (2026-10-21)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 판매 현황(20261021_ticket_sales_report.sql) 첫 라이브 결과가 초대 52건 · 판매 ₩115,800,004 · 환불 ₩3,800,000 이었다.
--     초대 paid 는 46건 ₩103,400,000 — 나머지 6건은 결제 뒤 취소된 초대인데 환불이 작다. 취소의 환불이 보고서가 못 붙인 길
--     (다른 purchase_id · 다른 change_type · 관리자 부여)로 갔다면 순판매가 부풀려 보인다. 앱 구매도 같은 눈으로 본다.
-- 무엇: SELECT 만 한다. 이름·번호·uid·구매 id 를 찍지 않는다(집계만). 결과는 Actions 로그(① SQL migrations).
-- ═══════════════════════════════════════════════════════════════

create or replace function pg_temp.diag_recon()
returns table(sec text, info text)
language plpgsql as $$
declare j jsonb; r record;
begin
  j := public.taam_ticket_sales_report(null, null, 'paid', true);

  drop table if exists _rr;
  create temp table _rr as
    select x->>'k' as k, nullif(x->>'uid','') as uid, x->>'ch' as ch, coalesce(x->>'st','active') as st,
           coalesce((x->>'gross')::numeric,0) as gross, coalesce((x->>'net')::numeric,0) as net,
           coalesce((x->>'rf_cancel')::numeric,0) as rfc, coalesce((x->>'rf_penalty')::numeric,0) as rfp, coalesce((x->>'rf_pax')::numeric,0) as rfx,
           coalesce((x->>'rf_return')::numeric,0) as ret, coalesce((x->>'rf_card_pending')::numeric,0) as cpend,
           coalesce((x->>'ag_gross')::numeric,0) as ag_gross, coalesce((x->>'agency')::numeric,0) as agency,
           nullif(x->>'paid_at','')::timestamptz as paid_at, x->'flags' as flags, x->>'inv_status' as inv_status, x->>'pm' as pm
      from jsonb_array_elements(j->'rows') x;

  -- R1. 보고서 — 채널 × 상태
  for r in select ch, st, count(*) n, sum(gross) g, sum(rfc+rfp+rfx) rf, sum(ret) ret, sum(net) net, sum(cpend) cp
             from _rr group by 1,2 order by 1,2 loop
    sec := 'R1 보고서 ' || r.ch || ' · ' || r.st;
    info := r.n || '건 · 판매 ₩' || to_char(r.g,'FM999,999,999,999') || ' · 환불 ₩' || to_char(r.rf,'FM999,999,999,999') || ' · 반환 ₩' || to_char(r.ret,'FM999,999,999,999')
         || ' · 순 ₩' || to_char(r.net,'FM999,999,999,999') || case when r.cp > 0 then ' · 카드 환불 대기 ₩' || to_char(r.cp,'FM999,999,999,999') else '' end;
    return next;
  end loop;

  -- R2. 취소된 판매가 얼마를 남겼나 — 0(전액 환불) · 대행비 이하(D-31) · 대행비 초과 · 환불 0
  for r in select ch, case when net <= 0 then 'a 남김 0'
                           when rfc + rfp + rfx = 0 then 'd 환불 기록 없음(판매액 전부 남음)'
                           when net <= ag_gross then 'b 대행비 이하 남김'
                           else 'c 대행비 초과 남김' end as b,
                  count(*) n, sum(gross) g, sum(net) net
             from _rr where st = 'cancelled' group by 1,2 order by 1,2 loop
    sec := 'R2 취소 ' || r.ch || ' · ' || r.b; info := r.n || '건 · 판매 ₩' || to_char(r.g,'FM999,999,999,999') || ' · 남은 순 ₩' || to_char(r.net,'FM999,999,999,999'); return next;
  end loop;

  -- 원장 티켓 줄
  drop table if exists _ll;
  create temp table _ll as
    select row_number() over () as rid, d.user_id::text as uid, d.change_type as ct, d.amount::numeric as amt, d.created_at,
           coalesce(d.metadata->>'purchase_id','') as pid, coalesce(d.metadata->>'invite_id','') as iid,
           coalesce(d.metadata->>'refund_type','') as rtype, coalesce(d.metadata->>'reason','') as reason,
           coalesce(d.metadata->>'fix','') as fix, coalesce(d.metadata->>'order_id','') as oid,
           coalesce(d.metadata->>'cancel_refund','') as cref, null::text as m
      from public.deposit_transactions d
     where d.change_type in ('ticket_purchase','ticket_refund','ticket_pax_change');
  update _ll l set m = 'app' from _rr q where q.ch = 'app' and l.pid <> '' and l.pid = q.k and l.uid = q.uid;
  update _ll l set m = 'invite' from _rr q
   where l.m is null and q.ch = 'invite' and l.uid = q.uid
     and (l.iid = substr(q.k, 5) or (l.pid <> '' and l.pid like 'INV-' || left(substr(q.k, 5), 8) || '-%'));

  -- R3. 원장 티켓 줄이 보고서 판매에 붙었나
  for r in select ct, coalesce(m, '안 붙음') m, (amt > 0) pos, count(*) n, sum(amt) s from _ll group by 1,2,3 order by 1,2,3 loop
    sec := 'R3 원장 ' || r.ct || case when r.pos then ' (+)' else ' (−)' end || ' → ' || r.m;
    info := r.n || '줄 · ₩' || to_char(r.s,'FM999,999,999,999'); return next;
  end loop;

  -- R4. 안 붙은 줄 — 왜 안 붙었나 (앞머리 · 티켓 행 · 주인 · 상태 · 환불 종류)
  for r in
    select l.ct, (l.amt > 0) pos,
           coalesce(nullif(substring(l.pid from '^([A-Za-z]+)-'), ''), case when l.pid = '' then '(purchase_id 없음)' else '(앞머리 없음)' end) as pfx,
           case when t.purchase_id is null then '티켓 행 없음'
                when t.user_id::text = l.uid then '티켓 주인 = 줄 주인 · ' || lower(coalesce(t.status,''))
                else '티켓 주인 다름 · ' || lower(coalesce(t.status,'')) end as tk,
           nullif(concat_ws(' ', nullif(l.rtype,''), nullif(l.reason,''), case when l.fix <> '' then 'fix' end, case when l.oid <> '' then 'order' end, case when l.cref <> '' then 'cancel_refund' end), '') as tag,
           count(*) n, sum(l.amt) s
      from _ll l
      left join lateral (select t.* from public.tickets t where l.pid <> '' and t.purchase_id = l.pid order by t.created_at desc limit 1) t on true
     where l.m is null
     group by 1,2,3,4,5 order by 1,2,3,4,5
  loop
    sec := 'R4 안 붙음 ' || r.ct || case when r.pos then ' (+)' else ' (−)' end || ' · ' || r.pfx;
    info := r.tk || coalesce(' · ' || r.tag, '') || ' · ' || r.n || '줄 · ₩' || to_char(r.s,'FM999,999,999,999'); return next;
  end loop;

  -- R5. 취소된 판매 중 환불이 안 붙은 것(R2 d · c) — 같은 회원의 「안 붙은 환불 줄」 · 관리자 부여가 결제 뒤에 있나
  for r in
    select x.ch, x.b, count(*) n, sum(x.net) net,
           count(*) filter (where x.un_rf > 0) n_unrf, sum(x.un_rf) unrf,
           count(*) filter (where x.un_rf_eq) n_unrf_eq,
           count(*) filter (where x.grant_eq) n_grant_eq, count(*) filter (where x.grant_any > 0) n_grant, sum(x.grant_any) grants
      from (
        select q.ch, case when q.rfc + q.rfp + q.rfx = 0 then 'd 환불 기록 없음' else 'c 대행비 초과 남김' end as b, q.net,
               (select coalesce(sum(l.amt),0) from _ll l where l.m is null and l.uid = q.uid and l.ct = 'ticket_refund' and l.amt > 0 and l.created_at >= coalesce(q.paid_at, '-infinity')) as un_rf,
               exists (select 1 from _ll l where l.m is null and l.uid = q.uid and l.ct = 'ticket_refund' and l.amt > 0 and l.created_at >= coalesce(q.paid_at, '-infinity') and l.amt between q.net - q.ag_gross and q.net) as un_rf_eq,
               exists (select 1 from public.deposit_transactions d where d.user_id::text = q.uid and d.change_type = 'admin_grant' and d.amount > 0
                          and d.created_at >= coalesce(q.paid_at, '-infinity') and d.amount between q.net - q.ag_gross and q.net) as grant_eq,
               (select coalesce(sum(d.amount),0) from public.deposit_transactions d where d.user_id::text = q.uid and d.change_type = 'admin_grant' and d.amount > 0
                          and d.created_at >= coalesce(q.paid_at, '-infinity') and d.created_at < coalesce(q.paid_at, '-infinity') + interval '120 days') as grant_any
          from _rr q
         where q.st = 'cancelled' and q.net > 0 and (q.rfc + q.rfp + q.rfx = 0 or q.net > q.ag_gross)
      ) x group by 1,2 order by 1,2
  loop
    sec := 'R5 ' || r.ch || ' · ' || r.b;
    info := r.n || '건 · 남은 순 ₩' || to_char(r.net,'FM999,999,999,999')
         || ' · 같은 회원의 안 붙은 환불 줄 있음 ' || r.n_unrf || '건(₩' || to_char(coalesce(r.unrf,0),'FM999,999,999,999') || ' · 금액 맞음 ' || r.n_unrf_eq || '건)'
         || ' · 결제 뒤 관리자 부여 있음 ' || r.n_grant || '건(₩' || to_char(coalesce(r.grants,0),'FM999,999,999,999') || ' · 금액 맞음 ' || r.n_grant_eq || '건)';
    return next;
  end loop;

  -- R6. 취소된 판매의 상태 출처 — 티켓 행이 취소인가, 초대 상태가 취소인가 (초대만)
  for r in select coalesce(inv_status,'?') s, count(*) n, sum(net) net from _rr where ch = 'invite' and st = 'cancelled' group by 1 order by 1 loop
    sec := 'R6 취소된 초대 · 초대 상태 ' || r.s; info := r.n || '건 · 남은 순 ₩' || to_char(r.net,'FM999,999,999,999'); return next;
  end loop;

  -- R7. 표시(flags) — 채널별 건수
  for r in select ch, f, count(*) n, sum(gross) g from _rr, jsonb_array_elements_text(coalesce(flags,'[]'::jsonb)) f group by 1,2 order by 1,2 loop
    sec := 'R7 표시 ' || r.ch || ' · ' || r.f; info := r.n || '건 · 판매 ₩' || to_char(r.g,'FM999,999,999,999'); return next;
  end loop;

  -- R8. 결제 월별 — 보고서 판매(앱 예치금 몫 + 초대) vs 원장 구매 줄 전체
  for r in
    with a as (select to_char(paid_at at time zone 'Asia/Seoul','YYYY-MM') ym, sum(gross) g, sum(net) net from _rr where ch in ('app','invite') group by 1),
         b as (select to_char(created_at at time zone 'Asia/Seoul','YYYY-MM') ym, -sum(amt) filter (where ct = 'ticket_purchase' and amt < 0) buy,
                      -sum(amt) filter (where ct = 'ticket_purchase' and amt < 0 and m is null) buy_un from _ll group by 1)
    select coalesce(a.ym, b.ym) ym, coalesce(a.g,0) g, coalesce(a.net,0) net, coalesce(b.buy,0) buy, coalesce(b.buy_un,0) buy_un from a full join b on b.ym = a.ym order by 1
  loop
    sec := 'R8 월별 ' || coalesce(r.ym,'?');
    info := '보고서(앱+초대) 판매 ₩' || to_char(r.g,'FM999,999,999,999') || ' · 순 ₩' || to_char(r.net,'FM999,999,999,999')
         || ' · 원장 구매 ₩' || to_char(r.buy,'FM999,999,999,999') || ' (안 붙음 ₩' || to_char(r.buy_un,'FM999,999,999,999') || ')'; return next;
  end loop;

  drop table if exists _rr; drop table if exists _ll;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_recon();
