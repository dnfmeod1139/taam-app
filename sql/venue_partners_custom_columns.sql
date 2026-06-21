-- ═══════════════════════════════════════════════════════════════
-- TAAM — venue_partners 직접입력(custom) 컬럼 추가 (2026-06-22)
-- ═══════════════════════════════════════════════════════════════
-- 큐레이션(_index.json)에 없는 매장을 앱에서 '직접 입력'으로 파트너 등록할 때
-- 표시용 이름/지역을 저장하는 컬럼. (사진은 기존 request_photo 재사용)
-- ⚠️ 딱 한 번만 RUN 하면 됨. 이후엔 SQL 없이 앱 관리화면에서 매장 추가 가능.
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent).
-- ═══════════════════════════════════════════════════════════════

alter table public.venue_partners add column if not exists custom_name      text;   -- 직접입력 매장명
alter table public.venue_partners add column if not exists custom_sub       text;   -- (구) 지역·장르 — 하위호환
alter table public.venue_partners add column if not exists custom_tabelog   text;   -- 타베로그(또는 외부) 링크
alter table public.venue_partners add column if not exists custom_genre     text;   -- 장르 (예: 스시)
alter table public.venue_partners add column if not exists custom_address   text;   -- 주소/지역
alter table public.venue_partners add column if not exists custom_phone     text;   -- 전화
alter table public.venue_partners add column if not exists custom_desc      text;   -- 소개/한 줄 설명
alter table public.venue_partners add column if not exists custom_map       text;   -- 지도 링크
alter table public.venue_partners add column if not exists custom_instagram text;   -- 인스타그램 링크

do $$ begin raise notice '✅ venue_partners 직접입력 컬럼 추가(custom_*) — 상세와 동일 항목 입력 가능'; end $$;
