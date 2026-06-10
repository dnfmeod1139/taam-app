-- ═══════════════════════════════════════════════════════════════
-- Quest MVP — 시드 5개에 필요한 매장 등록 상태 진단 (2026-05-28)
-- ═══════════════════════════════════════════════════════════════
-- 목적:
--   5개 시드 퀘스트의 대상 매장이 TAAM restaurants 테이블에 등록되어 있는지 확인.
--   미등록 매장은 슈퍼어드민이 먼저 등록해야 퀘스트 작동 가능.
--
-- 시드 퀘스트 매장 목록:
--   1. 「첫걸음」      — 매장 무관 (1곳이라도 방문)
--   2. 「사이토 입문」  — 鮨さいとう, 鮨しゅんじ, 鮨えんどう
--   3. 「藤本 트라이앵글」 — 鮨えんどう, 鮨やすみつ, 蒼 (Ao)
--   4. 「由う 그룹 절반」 — 鮨由う, 鮨在, 鮨結う 翼, 鮨結う 紬, 鮨結う 遥, 佐たけ
--   5. 「鮪 트리니티」   — 鮪 도매상 거래 매장 다수
--
--   이름 패턴 매칭 (이름이 약간 달라도 잡히도록 LIKE 사용)
-- ═══════════════════════════════════════════════════════════════

-- 1) restaurants 테이블 컬럼 확인
select column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='restaurants'
  and column_name in ('id','name','name_en','name_jp','genre','region','address')
order by column_name;

-- 2) 시드 퀘스트 대상 매장 검색
with targets as (
  select * from (values
    ('saito',      '사이토'),
    ('shunji',     '슌지'),
    ('endo',       '엔도'),
    ('yasumitsu',  '야스미츠'),
    ('ao',         '蒼'),
    ('yuu',        '由う'),
    ('zai',        '在'),
    ('yuu_tsubasa','翼'),
    ('yuu_tsumugi','紬'),
    ('yuu_haruka', '遥'),
    ('satake',     '佐たけ'),
    ('aozora',     '青空'),
    ('masuda',     'ます田'),
    ('araki',      'あら輝'),
    ('komada',     'こま田')
  ) as t(slug, search_term)
)
select
  t.slug,
  t.search_term,
  r.id,
  r.name,
  r.name_en,
  r.name_jp,
  case when r.id is null then '❌ 미등록' else '✓ 등록' end as status
from targets t
left join public.restaurants r
  on (
    r.name ilike '%' || t.search_term || '%' or
    r.name_en ilike '%' || t.search_term || '%' or
    r.name_jp ilike '%' || t.search_term || '%'
  )
order by t.slug;

-- 3) restaurants 전체 카운트 (운영 규모 가늠)
select count(*) as total_restaurants from public.restaurants;
