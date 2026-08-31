-- ═══════════════════════════════════════════════════════════════
-- TAAM — 셰프 사진 base64 정리 · 목록 RPC (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제였나
--   chefs 테이블에 사진이 base64 문자열로 들어가 있다.
--
--     node_photo  base64 75건 = 19 MB   ← 계보도 **첫 화면**에서 전부 내려간다
--     node_photo  URL    77건 = 8 KB    ← 같은 용도인데 2,400배 차이
--     sec1_data   base64 30건 = 18 MB   ← 카드 상세 진입 시 1건씩
--     sec2_data   base64 58건 = 135 MB  ← 카드 상세 진입 시 1건씩
--                              합계 173 MB
--
--   계보도를 열 때마다 19MB 를 받는다. 라이브 콘솔에 뜨던
--   `net::ERR_FAILED 525` 와 그에 딸린 CORS 오류가 이것이다 —
--   엣지가 응답을 끊은 것이고, CORS 메시지는 원인이 아니라 결과다.
--
--   CLAUDE.md 에 「사진은 절대 base64 로 넣지 않는다」고 적혀 있는 그 문제가
--   index.html 이 아니라 **DB 쪽에** 남아 있었다.
--
-- 왜 목록만 서버에서 주나
--   옮기려면 원본이 필요한데, 173MB 를 한 번에 받으면 그 요청이 또 죽는다.
--   그래서 **내용은 빼고 목록만** 준다. 앱이 한 건씩 골라 받아서
--   Storage 로 올리고 URL 로 바꿔 쓴다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 읽기 전용 함수다.
--       그다음 앱에서 슈퍼어드민 → 어드민 메뉴 → 「🖼 셰프 사진 정리」.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_chef_base64_targets()
returns table (
  chef_id    text,
  lineage_id text,
  chef_name  text,
  field      text,
  bytes      bigint
)
language sql
stable
security definer
set search_path = public
as $$
  -- 슈퍼어드민만. 아니면 빈 목록을 준다 (예외를 던지지 않는다 —
  -- 어드민 메뉴가 회원에게 열릴 일은 없지만, 열려도 아무 정보를 안 준다)
  select * from (
    select c.id::text as chef_id, c.lineage_id::text as lineage_id,
           c.name::text as chef_name,
           'node_photo'::text as field,
           octet_length(c.node_photo)::bigint as bytes
      from public.chefs c
     where public._taam_uid_is_super()
       and c.node_photo like 'data:%'
    union all
    select c.id::text, c.lineage_id::text, c.name::text,
           'sec1_data'::text,
           octet_length(c.sec1_data::text)::bigint  -- 컬럼명은 첫 select 것을 따른다
      from public.chefs c
     where public._taam_uid_is_super()
       and c.sec1_data::text like '%data:image%'
    union all
    select c.id::text, c.lineage_id::text, c.name::text,
           'sec2_data'::text,
           octet_length(c.sec2_data::text)::bigint
      from public.chefs c
     where public._taam_uid_is_super()
       and c.sec2_data::text like '%data:image%'
  ) t
  -- node_photo 를 먼저 준다. 첫 화면에서 내려가는 건 그것뿐이라
  -- 그것만 끝내도 계보도가 즉시 가벼워진다.
  order by case t.field when 'node_photo' then 0
                        when 'sec1_data'  then 1
                        else 2 end,
           t.bytes desc
$$;

revoke all on function public.taam_chef_base64_targets() from public;
grant execute on function public.taam_chef_base64_targets() to authenticated;

comment on function public.taam_chef_base64_targets() is
  'base64 사진이 남아 있는 셰프 행 목록 (내용 제외). 슈퍼어드민만. 앱의 셰프 사진 정리 도구가 쓴다.';


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 지금 몇 건이 남았나
-- ═══════════════════════════════════════════════════════════════
select field                                    as "항목",
       count(*)                                 as "건수",
       pg_size_pretty(sum(bytes)::bigint)       as "크기"
from public.taam_chef_base64_targets()
group by field
order by 1;
