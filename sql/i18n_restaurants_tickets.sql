-- ═══════════════════════════════════════════════════════════════
-- TAAM — 레스토랑 · 티켓 다국어 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 실행해도 안전)
--
-- 배경
--   앱의 표시 계층(pickI18nField)은 이미 name_en / name_jp 를 읽도록 되어 있는데
--   restaurants · ticket_products 에 해당 컬럼이 없어 항상 한글만 나왔다.
--   컬럼만 추가하면 표시는 즉시 동작한다 (번역이 없으면 한글 폴백 — 지금과 동일).
--
-- 일본어 검수 게이트
--   일본 매장은 원래 표기가 따로 있어 AI 음차가 틀릴 수 있다.
--   i18n_jp_approved = false 인 동안에는 일본어를 화면에 쓰지 않고 한글로 폴백한다.
--   슈퍼어드민이 검수 후 true 로 바꾸면 그때부터 일본어가 보인다.
--   (chefs 테이블에는 이 컬럼이 없으므로 계보도는 기존 동작 그대로 — 영향 없음)
-- ═══════════════════════════════════════════════════════════════

-- ── 1) restaurants ──
--   genre_en / city_en / country_en / zone_en 은 이미 있음. 나머지를 채운다.
alter table public.restaurants
  add column if not exists name_en          text,
  add column if not exists name_jp          text,
  add column if not exists description_en   text,
  add column if not exists description_jp   text,
  add column if not exists address_en       text,
  add column if not exists address_jp       text,
  add column if not exists genre_jp         text,
  add column if not exists i18n_status_en   text    default 'pending',
  add column if not exists i18n_status_jp   text    default 'pending',
  add column if not exists i18n_jp_approved boolean default false;

comment on column public.restaurants.i18n_jp_approved is
  '일본어 검수 완료 여부. false 면 화면에서 일본어 대신 한글로 폴백';

-- ── 2) ticket_products ──
alter table public.ticket_products
  add column if not exists ticket_desc_en   text,
  add column if not exists ticket_desc_jp   text,
  add column if not exists i18n_status_en   text    default 'pending',
  add column if not exists i18n_status_jp   text    default 'pending',
  add column if not exists i18n_jp_approved boolean default false;

comment on column public.ticket_products.ticket_desc_en is
  '티켓 상세 설명 영문. 비어 있으면 ticket_desc(한글) 폴백';

-- ── 3) 번역 대상 현황 ──
select '레스토랑' as "대상",
       count(*)                                                        as "전체",
       count(*) filter (where coalesce(name_en,'') = '')               as "영문 미번역",
       count(*) filter (where coalesce(name_jp,'') = '')               as "일문 미번역",
       count(*) filter (where i18n_jp_approved)                        as "일문 검수완료"
from public.restaurants
union all
select '티켓',
       count(*),
       count(*) filter (where coalesce(ticket_desc,'') <> '' and coalesce(ticket_desc_en,'') = ''),
       count(*) filter (where coalesce(ticket_desc,'') <> '' and coalesce(ticket_desc_jp,'') = ''),
       count(*) filter (where i18n_jp_approved)
from public.ticket_products;

do $$ begin raise notice '✅ 레스토랑·티켓 다국어 컬럼 준비 완료 — 앱에서 일괄 번역을 실행하세요'; end $$;
