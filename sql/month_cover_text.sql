-- ═══════════════════════════════════════════════════════════════
-- TAAM — 표지 글자 (월 이름 크기 + 머리말) (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 무엇을 위한 것인가
--   The Gourmand 처럼 제호가 화면 폭을 꽉 채우는 표지를 만들 수 있게 하는 것.
--   그리고 월 이름 말고 「그 달을 한마디로」 하는 머리말을 따로 얹을 수 있게 한다.
--   예: 위에 TEMPURA 를 크게 깔고, 월 이름은 아래로 작게 내린다.
--
--   크기 값 (title_size · headline_size)
--     s     작게   — 글자칸 너비의 7.7%
--     m     보통   — 12%
--     l     크게   — 17%
--     fill  꽉 채움 — 글자가 칸 너비를 정확히 채우도록 재서 맞춘다
--                    (AUGUST 든 SEPTEMBER 든 폭이 같아진다)
--
--   자리 값 (headline_pos) 은 title_pos 와 같은 규칙이다.
--     세로 t 위 · m 가운데 · b 아래  +  가로 l 왼 · c 가운데 · r 오른
--
--   headline 이 비어 있으면 머리말은 아예 그려지지 않는다.
--   컬럼이 없어도 앱은 그냥 돈다 — 코드가 기본값으로 폴백한다.
--
-- 선행: sql/month_cover_title_pos.sql (title_pos)
-- ═══════════════════════════════════════════════════════════════

alter table public.month_covers
  add column if not exists title_size    text default 's',
  add column if not exists headline      text,
  add column if not exists headline_pos  text default 'tl',
  add column if not exists headline_size text default 's';

comment on column public.month_covers.title_size is
  '월 이름 크기. s(작게) / m(보통) / l(크게) / fill(칸 너비를 꽉 채움). 값이 이상하면 index.html 이 s 로 돌린다.';

comment on column public.month_covers.headline is
  '표지 머리말 — 그 달을 한마디로. 비어 있으면 표지에 그려지지 않는다. 예: TEMPURA · 우니의 계절';

comment on column public.month_covers.headline_pos is
  '머리말 자리. title_pos 와 같은 규칙 — 세로(t/m/b) + 가로(l/c/r). 예: tl(왼쪽 위).';

comment on column public.month_covers.headline_size is
  '머리말 크기. title_size 와 같은 규칙 — s / m / l / fill.';

-- ── 확인 ──────────────────────────────────────────────────────
select column_name, data_type, column_default
  from information_schema.columns
 where table_schema = 'public'
   and table_name   = 'month_covers'
   and column_name in ('photo_url','cover_layout','cover_photos','cover_focus',
                       'title_pos','title_size','headline','headline_pos','headline_size')
 order by column_name;

do $$ begin raise notice '✅ 표지 글자 컬럼 준비 완료'; end $$;
