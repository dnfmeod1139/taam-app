-- ═══════════════════════════════════════════════════════════════
-- TAAM — 월별 표지 분할 컷 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 무엇을 위한 것인가
--   표지를 사진 한 장이 아니라 만화 컷처럼 2·3·다분할로 나눠 쓰기 위한 것.
--   컷 모양은 코드가 갖고 있고(레이아웃 키), DB 는 「어떤 레이아웃인지」와
--   「각 컷에 어떤 사진이 들어가는지」만 기억한다.
--
--   기존 photo_url 은 그대로 둔다 — 1컷(single) 일 때 쓰는 값이고,
--   분할 레이아웃에서도 첫 컷의 폴백으로 쓰인다. 예전 데이터가 깨지지 않는다.
-- ═══════════════════════════════════════════════════════════════

alter table public.month_covers
  add column if not exists cover_layout text default 'single',
  add column if not exists cover_photos jsonb default '[]'::jsonb;

comment on column public.month_covers.cover_layout is
  '표지 컷 레이아웃 키. single(1컷) / two(2분할) / three(3분할) / multi(다분할). 실제 컷 모양은 index.html 의 MAG_LAYOUTS 가 갖는다.';

comment on column public.month_covers.cover_photos is
  '컷별 사진 URL 배열. 예: ["https://…/a.jpg","https://…/b.jpg"]. 컷 수보다 모자라면 앞의 것으로 채우고, photo_url 을 마지막 폴백으로 쓴다.';

-- ── 확인 ──────────────────────────────────────────────────────
select column_name, data_type, column_default
  from information_schema.columns
 where table_schema = 'public'
   and table_name   = 'month_covers'
   and column_name in ('photo_url','cover_layout','cover_photos')
 order by column_name;

do $$ begin raise notice '✅ 표지 분할 컷 컬럼 준비 완료'; end $$;
