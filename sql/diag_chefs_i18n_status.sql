-- ═══════════════════════════════════════════════════════════════
-- TAAM chefs 테이블 i18n 컬럼 적용 상태 진단 (2026-05-28)
-- ═══════════════════════════════════════════════════════════════
-- 목적:
--   lineage_i18n_columns.sql (2026-05-11) 이 이미 실행됐는지 확인.
--   미실행 상태면 그 SQL 도 함께 실행 필요.
--
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN
-- 기대 결과:
--   ① name_en, name_jp, sub_en, sub_jp, chef_background_en, chef_background_jp,
--     i18n_status_en, i18n_status_jp, i18n_updated_at 컬럼 — 9개 모두 있어야 OK
--   ② 없는 컬럼이 있으면 lineage_i18n_columns.sql 부터 다시 실행
-- ═══════════════════════════════════════════════════════════════

-- 1) i18n 컬럼 존재 여부 체크리스트
select
  column_name,
  data_type,
  '✓ 있음' as status
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'chefs'
  and column_name in (
    'name_en','name_jp',
    'sub_en','sub_jp',
    'chef_background_en','chef_background_jp',
    'i18n_status_en','i18n_status_jp','i18n_updated_at'
  )
order by column_name;

-- 2) 누락 컬럼 (9개 - 위 결과 = 누락 갯수)
with expected as (
  select unnest(array[
    'name_en','name_jp',
    'sub_en','sub_jp',
    'chef_background_en','chef_background_jp',
    'i18n_status_en','i18n_status_jp','i18n_updated_at'
  ]) as col_name
)
select e.col_name as missing_column
from expected e
left join information_schema.columns c
  on c.table_schema = 'public'
 and c.table_name   = 'chefs'
 and c.column_name  = e.col_name
where c.column_name is null;

-- 3) 노드 한국어 데이터 샘플 (번역 대상 양 가늠용)
select
  lineage_id,
  count(*) as node_count,
  count(*) filter (where name_en is not null and name_en <> '') as already_en,
  count(*) filter (where name_jp is not null and name_jp <> '') as already_jp
from public.chefs
group by lineage_id
order by lineage_id;

-- 4) 한 lineage 의 노드 텍스트 미리보기 (sugita 예시)
select id, name, sub_title,
       (sec1_data->>'title') as sec1_title,
       left(sec1_data->>'desc', 80) as sec1_desc_preview,
       (sec2_data->>'title') as sec2_title,
       left(sec2_data->>'desc', 80) as sec2_desc_preview
from public.chefs
where lineage_id = 'sugita'
order by id
limit 8;
