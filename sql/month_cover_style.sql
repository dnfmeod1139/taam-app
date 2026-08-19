-- ═══════════════════════════════════════════════════════════════
-- TAAM — 표지 글자의 글자체 · 색 · 미세조정 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 무엇을 위한 것인가
--   표지 글자(월 이름 · 머리말)의 모든 설정을 한 칸에 모아 둔다.
--   컬럼을 하나씩 늘리면 설정이 늘 때마다 SQL 을 또 돌려야 한다.
--   jsonb 한 칸이면 다음 설정이 생겨도 SQL 없이 앱만 고치면 된다.
--
--   생김새
--     {
--       "mon": { "pos":"bl", "size":"fill", "font":"bodoni", "color":"w", "dx":0, "dy":0 },
--       "hl":  { "text":"TEMPURA", "pos":"tl", "size":"m", "font":"oswald", "color":"k",
--                "dx":-3.5, "dy":2 }
--     }
--
--   mon = 월 이름 (글자는 달력이 정한다 — text 는 무시된다)
--   hl  = 머리말 (text 가 비면 표지에 그려지지 않는다)
--
--   pos    자리 아홉 칸. 세로(t/m/b) + 가로(l/c/r). 예: bl(왼쪽 아래)
--   size   s(작게) / m(보통) / l(크게) / fill(칸 너비를 꽉 채움)
--   font   bodoni(세리프) / oswald(산세리프) / cormorant(가는 세리프)
--   color  w(흰색) / k(검정)
--   dx·dy  아홉 칸에서 더 미세하게. 표지 상자의 폭/높이 대비 % (-40 ~ 40).
--          가로는 폭 기준, 세로는 높이 기준. 편집 화면에서 글자를 끌면 여기에 쌓인다.
--
--   값이 없거나 이상하면 앱이 기본값으로 돌린다 — 이 컬럼이 없어도 앱은 그냥 돈다.
--   예전 컬럼(title_pos · title_size · headline …)은 그대로 두고 폴백으로 쓴다.
--   저장할 때는 둘 다 쓰므로, 이 SQL 을 안 돌려도 자리·크기·머리말은 계속 저장된다.
--
-- 선행: sql/month_cover_title_pos.sql · sql/month_cover_text.sql
-- ═══════════════════════════════════════════════════════════════

alter table public.month_covers
  add column if not exists cover_text jsonb;

comment on column public.month_covers.cover_text is
  '표지 글자 설정 전체. {"mon":{pos,size,font,color,dx,dy},"hl":{text,pos,size,font,color,dx,dy}}. pos=자리 아홉 칸(t/m/b + l/c/r), size=s/m/l/fill, font=bodoni/oswald/cormorant, color=w/k, dx·dy=상자 폭·높이 대비 % 미세조정(-40~40). 없으면 title_pos 등 예전 컬럼으로 폴백한다.';

-- ── 확인 ──────────────────────────────────────────────────────
select column_name, data_type, column_default
  from information_schema.columns
 where table_schema = 'public'
   and table_name   = 'month_covers'
   and column_name in ('photo_url','cover_layout','cover_photos','cover_focus',
                       'title_pos','title_size','headline','headline_pos','headline_size',
                       'cover_text')
 order by column_name;

do $$ begin raise notice '✅ 표지 글자 설정 컬럼 준비 완료'; end $$;
