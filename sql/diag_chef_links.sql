-- 계보 노드 링크(타베로그·네이버·티켓) 유실 진단 (2026-09-15)
-- Supabase SQL Editor 에서 RUN. 한 표로 나온다:
--   kind='summary' — 계보별 링크 있음/없음 건수
--   kind='wiped?'  — 링크가 비어 있는데 최근 30일 안에 갱신된 행 (updated_at 이 지워진 날짜다) 최근 40건
select 'summary' as kind, lineage_id, '' as id, '' as name,
       count(*) filter (where nullif(btrim(reserve_url),'') is not null)::text as has_reserve,
       count(*) filter (where nullif(btrim(reserve_url),'') is null)::text as no_reserve,
       count(*) filter (where nullif(btrim(ticket_url),'') is not null)::text as has_ticket,
       '' as updated_kst
  from public.chefs
 group by lineage_id
union all
select 'wiped?', lineage_id, id, coalesce(name,''), '', '', '',
       to_char(updated_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI')
  from (select * from public.chefs
         where nullif(btrim(reserve_url),'') is null
           and updated_at > now() - interval '30 days'
         order by updated_at desc limit 40) x
order by kind desc, updated_kst desc, lineage_id;
