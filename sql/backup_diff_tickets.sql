-- ═══════════════════════════════════════════════════════════════
-- TAAM — 어제 백업과 지금을 대조한다 (2026-09-01)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   「9/10 예약이 안 보인다 · 9/11 이 이름없음으로 나온다」를 코드만 보고
--   추측하면 끝이 없다. 어제 taam_backup 에 떠 둔 스냅샷이 있으니 대조한다.
--
-- 무엇을 보나
--   ① 백업 표 이름과 전체 행 수 — 어제 vs 지금
--   ② 이름이 빈 티켓 수 — 어제 vs 지금  (늘었으면 그 사이에 지워진 것)
--   ③④ 9월 예약을 한 줄씩 — 날짜 · purchase_id · 상태 · 이름
--
-- 어떻게 읽나
--   ①의 두 수가 같으면 행은 안 지워졌다.
--   ②가 늘었으면 이름이 지워진 것이고, 그대로면 원래 비어 있던 것이다.
--   ③④를 나란히 보면 그 두 건에 무슨 일이 있었는지 바로 보인다.
--   ⚠ purchase_id 가 PAYH- 로 시작하면 **결제 전 홀드**다. 앱이 일부러
--     화면에서 뺀다(예약이 아니다). 그건 정상 동작이고 버그가 아니다.
--
-- 백업 표 이름에 시각이 붙어 있어서, 이름을 몰라도 되게 가장 최근 것을
-- 스스로 찾는다. 실행: Supabase SQL Editor. **읽기만 한다.**
-- ═══════════════════════════════════════════════════════════════

with bt as (
  select c.relname as t
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'taam_backup' and c.relkind = 'r' and c.relname like 'tickets%'
   order by c.relname desc limit 1
),
q as (
  select bt.t,
    (xpath('/row/n/text()', query_to_xml(
      format('select count(*) n from taam_backup.%I', bt.t), false, true, '')))[1]::text as n_all,
    (xpath('/row/n/text()', query_to_xml(
      format('select count(*) n from taam_backup.%I where coalesce(btrim(buyer_name),'''')=''''', bt.t),
      false, true, '')))[1]::text as n_noname,
    (xpath('/row/n/text()', query_to_xml(
      format('select coalesce(string_agg(reservation_date || ''  '' || coalesce(purchase_id,''-'')
              || ''  '' || coalesce(status,''-'') || ''  이름['' || coalesce(nullif(btrim(buyer_name),''''),''비어있음'') || '']'',
              chr(10) order by reservation_date), ''(없음)'') n
              from taam_backup.%I where reservation_date like ''2026.09%%''', bt.t),
      false, true, '')))[1]::text as sep_rows
  from bt
)
select '① 백업 표'   as "구분", q.t              as "값1",
       q.n_all || ' 행'                          as "어제",
       (select count(*)::text || ' 행' from public.tickets) as "지금"
  from q
union all
select '② 이름 빈 티켓', '(전체)', q.n_noname || ' 건',
       (select count(*)::text || ' 건' from public.tickets
         where coalesce(btrim(buyer_name),'') = '')
  from q
union all
select '③ 9월 · 어제', '', q.sep_rows, ''
  from q
union all
select '④ 9월 · 지금', '', '',
       coalesce(string_agg(reservation_date || '  ' || coalesce(purchase_id,'-')
         || '  ' || coalesce(status,'-') || '  이름[' || coalesce(nullif(btrim(buyer_name),''),'비어있음') || ']',
         chr(10) order by reservation_date), '(없음)')
  from public.tickets where reservation_date like '2026.09%'
 order by 1;
