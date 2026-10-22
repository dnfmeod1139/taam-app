-- ═══════════════════════════════════════════════════════════════
-- 진단(읽기 전용) — 라이브 중복 가드(taam_guard_purchase_unique) 본문이 저장소 20261014 판과 md5 가 다르다(efee83c2… ≠ 7e6c53a6…) — 본문을 줄 단위로 본다 (2026-10-22)
-- 무엇: SELECT 만 · 함수 코드 줄만(데이터 없음). 줄 끝 \r(CRLF) 여부도 센다.
-- ═══════════════════════════════════════════════════════════════
select 0 as 줄, 'len=' || length(prosrc) || ' · lines=' || (select count(*) from regexp_split_to_table(prosrc, E'\n')) || ' · CR=' || (length(prosrc) - length(replace(prosrc, E'\r', ''))) as 코드
  from pg_proc where oid = to_regprocedure('public.taam_guard_purchase_unique()')
union all
select n::int, replace(l, E'\r', '⏎')
  from pg_proc p, regexp_split_to_table(p.prosrc, E'\n') with ordinality as s(l, n)
 where p.oid = to_regprocedure('public.taam_guard_purchase_unique()')
order by 1;
