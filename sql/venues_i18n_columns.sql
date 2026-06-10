-- ═══════════════════════════════════════════════════════════════
-- TAAM Atlas — venues 테이블 다국어 컬럼 추가
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-13
-- 적용 후: PWA 에서 영어/일본어 토글하면 Atlas 핀 상세 시트의
--          매장 이름·요약·시그니처가 자동으로 EN/JA 표시
-- 원칙:
--   1. 테이블이 없으면 자동 skip (DO 블록 + to_regclass 검사)
--   2. 컬럼이 이미 있으면 자동 skip (add column if not exists)
--   3. KO 기본, EN/JP 비어있으면 KO 폴백 (앱 단의 pickI18nField 가 처리)
-- ═══════════════════════════════════════════════════════════════

do $$
begin
  if to_regclass('public.venues') is not null then
    alter table public.venues
      -- 매장명 (예: 스기타 → Sugita / すぎた)
      add column if not exists name_jp                  text,
      -- (name_en 은 보통 이미 존재 — Tabelog/공식 영문명. 없을 때만 add)
      add column if not exists name_en                  text,

      -- 스타일 요약 (1~2문장: "미니멀한 카운터 8석에서...")
      add column if not exists style_summary_en         text,
      add column if not exists style_summary_jp         text,

      -- 홀리스틱 시그니처 (시그니처 메뉴/특징 한 줄)
      add column if not exists holistic_signature_en    text,
      add column if not exists holistic_signature_jp    text,

      -- 동네 (예: 신토미 → Shintomi / 新富) — Atlas 메타에 표시
      add column if not exists neighborhood_en          text,
      add column if not exists neighborhood_jp          text,

      -- AI 번역 상태 메타
      add column if not exists i18n_status_en           text default 'pending',
      add column if not exists i18n_status_jp           text default 'pending',
      add column if not exists i18n_updated_at          timestamptz;

    comment on column public.venues.name_jp                is '매장명 — 일본어 (예: すぎた, かねさか)';
    comment on column public.venues.name_en                is '매장명 — 영문 (예: Sugita, Kanesaka)';
    comment on column public.venues.style_summary_en       is 'Atlas 스타일 요약 — 영문 (1~2 문장)';
    comment on column public.venues.style_summary_jp       is 'Atlas 스타일 요약 — 일본어';
    comment on column public.venues.holistic_signature_en  is '홀리스틱 시그니처 — 영문 (한 줄)';
    comment on column public.venues.holistic_signature_jp  is '홀리스틱 시그니처 — 일본어';
    comment on column public.venues.neighborhood_en        is '동네 — 영문 표기 (예: Shintomi, Roppongi)';
    comment on column public.venues.neighborhood_jp        is '동네 — 일본어 표기 (예: 新富, 六本木)';
    comment on column public.venues.i18n_status_en         is '영문 번역 상태: pending | ai_draft | reviewed | manual';
    comment on column public.venues.i18n_status_jp         is '일본어 번역 상태';

    raise notice '✓ venues 테이블 i18n 컬럼 추가 완료';
  else
    raise notice '⏭ venues 테이블 없음 — skip';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 확인 쿼리 (실행 후):
--   select column_name, data_type
--   from information_schema.columns
--   where table_name = 'venues'
--     and (column_name like '%_en' or column_name like '%_jp' or column_name like '%i18n%')
--   order by column_name;
--
-- 샘플 데이터 확인:
--   select venue_id, name_ko, name_en, name_jp,
--          style_summary_ko, style_summary_en, style_summary_jp,
--          holistic_signature_ko, holistic_signature_en, holistic_signature_jp
--   from public.venues
--   where name_ko ilike '%스기타%' or name_en ilike '%sugita%'
--   limit 5;
-- ═══════════════════════════════════════════════════════════════
