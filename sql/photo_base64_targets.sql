-- ═══════════════════════════════════════════════════════════════
-- TAAM — base64 사진 목록을 레스토랑까지 넓힌다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 왜 넓히나
--   셰프 173MB 를 옮기고 나서 부팅 경로를 재 봤더니 이렇게 나왔다.
--
--     restaurants      144행  1,475 kB   ← 회원이 앱 켤 때마다 통째로 받는다
--       └ photo_card   8건에 base64 668 kB   (전체의 45%)
--     ticket_products   32행     15 kB   ← 무시해도 된다
--
--   photo_card 8건만 Storage 로 옮기면 **부팅 쿼리 하나가 45% 줄어든다.**
--   행 수가 적어 금방 끝나는데 효과는 회원 전원에게 매번 돌아온다.
--
--   ⚠ restaurants 는 loadRestaurants() 가 select('*') 로 읽는다.
--     첫 화면이 이 응답을 기다리므로, 여기 든 무게는 곧 스플래시 시간이다.
--
-- 무엇이 달라지나
--   taam_chef_base64_targets() 는 그대로 둔다 (이미 라이브에 있다).
--   새 함수는 chefs + restaurants 를 함께 준다. 앱은 새 것을 먼저 부르고,
--   없으면 옛 것으로 물러난다 — SQL 을 안 돌린 상태에서도 앱이 죽지 않는다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 읽기 전용 함수다.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_photo_base64_targets()
returns table (
  tbl    text,   -- 'chefs' | 'restaurants'
  k1     text,   -- chefs: id      · restaurants: id
  k2     text,   -- chefs: lineage_id · restaurants: null
  label  text,   -- 화면에 보여줄 이름
  field  text,
  bytes  bigint
)
language sql
stable
security definer
set search_path = public
as $$
  -- 슈퍼어드민만. 아니면 빈 목록 (예외를 던지지 않는다)
  select * from (
    -- ── 레스토랑: 부팅 때 전원이 받는다 → 가장 먼저 ──────────────
    select 'restaurants'::text as tbl, r.id::text as k1, null::text as k2,
           coalesce(r.name,'(이름없음)')::text as label,
           'photo_card'::text as field,
           octet_length(r.photo_card)::bigint as bytes
      from public.restaurants r
     where public._taam_uid_is_super() and r.photo_card like 'data:%'
    union all
    select 'restaurants', r.id::text, null, coalesce(r.name,'(이름없음)'),
           'photo_hero', octet_length(r.photo_hero)::bigint
      from public.restaurants r
     where public._taam_uid_is_super() and r.photo_hero like 'data:%'
    union all
    select 'restaurants', r.id::text, null, coalesce(r.name,'(이름없음)'),
           'detail_photos', octet_length(r.detail_photos::text)::bigint
      from public.restaurants r
     where public._taam_uid_is_super() and r.detail_photos::text like '%data:image%'
    -- ── 셰프: 카드 상세에서만 내려간다 ───────────────────────────
    union all
    select 'chefs', c.id::text, c.lineage_id::text, coalesce(c.name,'(이름없음)'),
           'node_photo', octet_length(c.node_photo)::bigint
      from public.chefs c
     where public._taam_uid_is_super() and c.node_photo like 'data:%'
    union all
    select 'chefs', c.id::text, c.lineage_id::text, coalesce(c.name,'(이름없음)'),
           'sec1_data', octet_length(c.sec1_data::text)::bigint
      from public.chefs c
     where public._taam_uid_is_super() and c.sec1_data::text like '%data:image%'
    union all
    select 'chefs', c.id::text, c.lineage_id::text, coalesce(c.name,'(이름없음)'),
           'sec2_data', octet_length(c.sec2_data::text)::bigint
      from public.chefs c
     where public._taam_uid_is_super() and c.sec2_data::text like '%data:image%'
  ) t
  order by case t.tbl when 'restaurants' then 0 else 1 end,
           case t.field when 'photo_card' then 0 when 'photo_hero' then 1
                        when 'node_photo' then 2 else 3 end,
           t.bytes desc
$$;

revoke all on function public.taam_photo_base64_targets() from public;
grant execute on function public.taam_photo_base64_targets() to authenticated;

comment on function public.taam_photo_base64_targets() is
  'base64 사진이 남아 있는 행 목록 (내용 제외) — chefs + restaurants. 슈퍼어드민만.';


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 지금 무엇이 얼마나 남았나
-- ═══════════════════════════════════════════════════════════════
--   ⚠ SQL Editor 는 로그인 세션이 아니라 auth.uid() 가 null 이다.
--     그래서 위 함수는 여기서 0행을 준다 — 정상이다. 앱에서는 보인다.
--     여기서는 원본 테이블을 직접 세서 확인한다.
select 'restaurants.photo_card'  as "항목", count(*) as "건수",
       pg_size_pretty(coalesce(sum(octet_length(photo_card)),0)::bigint) as "크기"
  from public.restaurants where photo_card like 'data:%'
union all
select 'restaurants.photo_hero', count(*),
       pg_size_pretty(coalesce(sum(octet_length(photo_hero)),0)::bigint)
  from public.restaurants where photo_hero like 'data:%'
union all
select 'restaurants.detail_photos', count(*),
       pg_size_pretty(coalesce(sum(octet_length(detail_photos::text)),0)::bigint)
  from public.restaurants where detail_photos::text like '%data:image%'
union all
select 'chefs (전부)', count(*), pg_size_pretty(coalesce(sum(
         coalesce(octet_length(node_photo),0)
       + coalesce(octet_length(sec1_data::text),0)
       + coalesce(octet_length(sec2_data::text),0)),0)::bigint)
  from public.chefs
 where node_photo like 'data:%' or sec1_data::text like '%data:image%'
    or sec2_data::text like '%data:image%'
union all
select '── restaurants 전체 (부팅에 받는 양)', count(*),
       pg_size_pretty(sum(pg_column_size(restaurants.*))::bigint)
  from public.restaurants;


-- ═══════════════════════════════════════════════════════════════
-- 되돌리려면
-- ═══════════════════════════════════════════════════════════════
--   drop function if exists public.taam_photo_base64_targets();
--   앱은 taam_chef_base64_targets() 로 물러난다 (셰프만 처리).
