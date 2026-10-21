-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 판매 현황 「전체 기간」이 실제로 언제부터 언제까지인가 (2026-10-21)
-- ═══════════════════════════════════════════════════════════════
-- 왜: 전체 기간 합계(판매 ₩202,054,604)를 알려 드리자 「언제부터 언제까지야?」. 채널별 첫·마지막 결제일(KST)과 방문일 범위를 본다.
-- 무엇: SELECT 만. 날짜·건수·합계만(이름·번호·uid·구매 id 없음). 결과는 Actions 로그.
-- ═══════════════════════════════════════════════════════════════

create or replace function pg_temp.diag_range()
returns table(sec text, info text)
language plpgsql as $$
declare j jsonb; r record;
begin
  j := public.taam_ticket_sales_report(null, null, 'paid', false);
  for r in
    with x as (
      select z->>'ch' ch, z->>'paid_ymd' pd, z->>'visit' vd, coalesce((z->>'gross')::numeric,0) g, coalesce((z->>'net')::numeric,0) net
        from jsonb_array_elements(j->'rows') z where z->>'x' is null)
    select '1 ' || ch as k, count(*) n, min(pd) p0, max(pd) p1, min(vd) v0, max(vd) v1, sum(g) g, sum(net) net from x group by ch
    union all
    select '0 기본 채널(앱·초대·링크·정산) 합', count(*), min(pd), max(pd), min(vd), max(vd), sum(g), sum(net) from x where ch in ('app','invite','link','settle')
    union all
    select '0 전 채널 합', count(*), min(pd), max(pd), min(vd), max(vd), sum(g), sum(net) from x
    order by 1
  loop
    sec := r.k;
    info := r.n || '건 · 결제일 ' || coalesce(r.p0,'?') || ' ~ ' || coalesce(r.p1,'?') || ' · 방문일 ' || coalesce(r.v0,'?') || ' ~ ' || coalesce(r.v1,'?')
         || ' · 판매 ₩' || to_char(r.g,'FM999,999,999,999') || ' · 순 ₩' || to_char(r.net,'FM999,999,999,999');
    return next;
  end loop;
  -- 기본 채널 결제 월별 (건수 · 판매 · 순판매)
  for r in
    select substr(z->>'paid_ymd',1,7) ym, count(*) n, sum(coalesce((z->>'gross')::numeric,0)) g, sum(coalesce((z->>'net')::numeric,0)) net
      from jsonb_array_elements(j->'rows') z
     where z->>'x' is null and z->>'ch' in ('app','invite','link','settle')
     group by 1 order by 1
  loop
    sec := '2 월별 ' || coalesce(r.ym,'?'); info := r.n || '건 · 판매 ₩' || to_char(r.g,'FM999,999,999,999') || ' · 순 ₩' || to_char(r.net,'FM999,999,999,999'); return next;
  end loop;
  sec := '3 기준 시각'; info := to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI') || ' KST'; return next;
end $$;

select sec as 구간, info as 내용 from pg_temp.diag_range();
