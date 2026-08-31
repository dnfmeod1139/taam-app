-- ═══════════════════════════════════════════════════════════════
-- TAAM — base64 사진이 남은 곳을 **컬럼을 짚지 않고** 찾는다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 왜 다시 만드나
--   컬럼 이름을 하나씩 적어서 찾다가 계속 놓쳤다.
--     1차: chefs.node_photo · sec1_data · sec2_data     → 173MB 발견
--     2차: restaurants.photo_card · photo_hero · detail_photos → 661kB 발견
--     3차: 정리하고 다시 재 보니 **restaurants.image_url 이 669kB**
--          — 아무도 이 컬럼을 후보에 넣지 않았다.
--
--   같은 실수를 세 번 했다. 이제 **컬럼 목록을 짜지 않는다.**
--   information_schema 로 텍스트·JSON 계열 컬럼을 전부 훑어서
--   값이 'data:image' 로 시작하거나 그 문자열을 품은 것을 찾는다.
--   컬럼이 새로 생겨도 자동으로 잡힌다.
--
-- 왜 목록만 서버에서 주나
--   원본을 다 받으면 그 요청이 죽는다(처음에 173MB 였다).
--   내용은 빼고 **어디에 몇 바이트가 있는지만** 준다. 앱이 한 건씩
--   골라 받아서 Storage 로 올리고 URL 로 바꿔 쓴다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 읽기 전용 함수다.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_photo_base64_targets()
returns table (
  tbl    text,   -- 'restaurants' | 'chefs'
  k1     text,   -- 기본키 (chefs 는 id)
  k2     text,   -- chefs 만: lineage_id
  label  text,   -- 화면에 보여줄 이름
  field  text,
  bytes  bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c record;
  v_key2 text;
begin
  -- 슈퍼어드민만. 아니면 아무것도 주지 않는다 (예외를 던지지 않는다)
  if not public._taam_uid_is_super() then
    return;
  end if;

  for c in
    select col.table_name, col.column_name
      from information_schema.columns col
     where col.table_schema = 'public'
       and col.table_name in ('restaurants', 'chefs')
       -- 텍스트·JSON·배열 계열만. 숫자·불리언·날짜에는 사진이 못 들어간다.
       and (col.data_type in ('text', 'character varying', 'jsonb', 'json')
            or col.data_type = 'ARRAY')
       -- 기본키·식별자는 건드리지 않는다
       and col.column_name not in ('id', 'lineage_id')
     order by col.table_name, col.column_name
  loop
    v_key2 := case when c.table_name = 'chefs' then 'lineage_id::text' else 'null::text' end;

    -- 값 안에 data:image 가 있는 행만. 크기는 그 컬럼의 실제 길이.
    return query execute format(
      'select %L::text, t.id::text, %s, coalesce(t.name, %L)::text, %L::text,
              octet_length(t.%I::text)::bigint
         from public.%I t
        where t.%I::text like %L',
      c.table_name, v_key2, '(이름없음)', c.column_name,
      c.column_name, c.table_name, c.column_name, '%data:image%'
    );
  end loop;
end;
$$;

revoke all on function public.taam_photo_base64_targets() from public;
grant execute on function public.taam_photo_base64_targets() to authenticated;

comment on function public.taam_photo_base64_targets() is
  'base64 사진이 남은 행·컬럼 목록 (내용 제외). 컬럼을 짚지 않고 전부 훑는다. 슈퍼어드민만.';


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 지금 어디에 얼마나 남았나 (SQL Editor 용 · 함수를 안 거친다)
-- ═══════════════════════════════════════════════════════════════
--   ⚠ SQL Editor 는 auth.uid() 가 null 이라 위 함수는 여기서 0행을 준다.
--     그래서 같은 방식으로 직접 훑는다.
--   ⚠ 임시 테이블은 psql 자동커밋에서 문장이 끝나면 사라진다. 한 문장으로 센다.
with cols as (
  select c.table_name, c.column_name
    from information_schema.columns c
   where c.table_schema = 'public'
     and c.table_name in ('restaurants','chefs','ticket_products','profiles')
     and (c.data_type in ('text','character varying','jsonb','json') or c.data_type = 'ARRAY')
     and c.column_name not in ('id','lineage_id')
),
scan as (
  select cols.table_name, cols.column_name,
         query_to_xml(format(
           'select count(*) as n, coalesce(sum(octet_length(%I::text)),0) as b
              from public.%I where %I::text like %L',
           cols.column_name, cols.table_name, cols.column_name, '%data:image%'),
           false, true, '') as x
    from cols
)
select table_name                                        as "테이블",
       column_name                                       as "컬럼",
       (xpath('/row/n/text()', x))[1]::text::bigint       as "건수",
       pg_size_pretty((xpath('/row/b/text()', x))[1]::text::bigint) as "크기"
from scan
where (xpath('/row/n/text()', x))[1]::text::bigint > 0
order by (xpath('/row/b/text()', x))[1]::text::bigint desc;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   drop function if exists public.taam_photo_base64_targets();
--   앱은 taam_chef_base64_targets() 로 물러난다 (셰프만 처리).
