-- 진단(읽기 전용 · 2026-10-30): 앞 진단이 부른 Edge toss-package-pay sweep(request 131)의 응답 — HTTP 200 + {"ok":true,…} 여야 서버 토큰 경로가 산다
select '응답(request 131)' as 항목,
       coalesce((select status_code::text || ' · ' || left(coalesce(content, ''), 160) from net._http_response where id = 131), '⚠ 아직 없음 — 다시 보거나 timeout') as 결과
union all select '최근 toss-package-pay sweep 응답(정보)',
       coalesce((select string_agg(status_code::text || ' ' || left(coalesce(content, ''), 100), ' | ') from (
         select status_code, content from net._http_response where created > now() - interval '1 hour' and content like '%"expired"%' order by created desc limit 3) s), '없음');
