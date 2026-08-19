-- ═══════════════════════════════════════════════════════════════
-- TAAM — 월별 표지의 「월 글자」 자리 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 무엇을 위한 것인가
--   표지에 크게 얹히는 월 이름(AUGUST)이 놓일 자리를 달마다 정하기 위한 것.
--   사진의 빈 곳은 달마다 다른 데 있어서, 한 자리에 못 박으면 어떤 달은
--   인물 얼굴이나 요리 위에 글자가 얹힌다.
--
--   값은 두 글자다. 앞이 세로, 뒤가 가로.
--     세로  t 위 · m 가운데 · b 아래
--     가로  l 왼 · c 가운데 · r 오른
--   예: 'bl' = 왼쪽 아래(기본, 예전과 같은 자리) · 'tc' = 위 가운데
--
--   컬럼이 없어도 앱은 그냥 돈다 — 코드가 'bl' 로 폴백한다.
-- ═══════════════════════════════════════════════════════════════

alter table public.month_covers
  add column if not exists title_pos text default 'bl';

comment on column public.month_covers.title_pos is
  '표지 월 글자의 자리. 두 글자 — 세로(t/m/b) + 가로(l/c/r). 예: bl(왼쪽 아래·기본), tc(위 가운데). 값이 이상하면 index.html 이 bl 로 돌린다.';

-- ── 확인 ──────────────────────────────────────────────────────
select column_name, data_type, column_default
  from information_schema.columns
 where table_schema = 'public'
   and table_name   = 'month_covers'
   and column_name in ('photo_url','cover_layout','cover_photos','cover_focus','title_pos')
 order by column_name;

do $$ begin raise notice '✅ 월 글자 자리 컬럼 준비 완료'; end $$;
