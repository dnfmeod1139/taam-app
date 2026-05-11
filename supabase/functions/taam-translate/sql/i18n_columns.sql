    -- ═══════════════════════════════════════════════════════════════
-- TAAM i18n — 운영 컨텐츠 다국어 컬럼 일괄 추가 (안전 버전)
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-11
-- 원칙:
--   1. 테이블이 없으면 자동 skip (DO 블록 + to_regclass 검사)
--   2. 컬럼이 이미 있으면 자동 skip (add column if not exists)
--   3. KO 기본, EN/JP 비어있으면 KO 폴백 (앱 단의 pickI18nField 가 처리)
-- ═══════════════════════════════════════════════════════════════

-- ── 1. restaurants ──────────────────────────────────────────────
do $$
begin
  if to_regclass('public.restaurants') is not null then
    alter table public.restaurants
      add column if not exists name_jp                 text,
      add column if not exists chef_name_jp            text,
      add column if not exists chef_name_en            text,
      add column if not exists concierge_note_en       text,
      add column if not exists concierge_note_jp       text,
      add column if not exists vibe_tags_en            text[] default array[]::text[],
      add column if not exists vibe_tags_jp            text[] default array[]::text[],
      add column if not exists signature_keywords_en   text[] default array[]::text[],
      add column if not exists signature_keywords_jp   text[] default array[]::text[],
      add column if not exists address_en              text,
      add column if not exists address_jp              text,
      add column if not exists genre_en                text,
      add column if not exists genre_jp                text,
      add column if not exists i18n_status_en          text default 'pending',
      add column if not exists i18n_status_jp          text default 'pending',
      add column if not exists i18n_updated_at         timestamptz;

    -- 코멘트
    comment on column public.restaurants.name_jp              is '레스토랑 일본어 이름 (예: 정식당 → ジョンシクダン)';
    comment on column public.restaurants.chef_name_jp         is '쉐프 이름 일본어 표기';
    comment on column public.restaurants.chef_name_en         is '쉐프 이름 로마자 (예: 안성재 → Sungjae Ahn)';
    comment on column public.restaurants.concierge_note_en    is '한 줄 평 — 영문 (Description / Highlights)';
    comment on column public.restaurants.concierge_note_jp    is '한 줄 평 — 일본어';
    comment on column public.restaurants.vibe_tags_en         is '분위기 태그 — 영문 (e.g. modern, intimate)';
    comment on column public.restaurants.vibe_tags_jp         is '분위기 태그 — 일본어 (e.g. モダン, 静か)';
    comment on column public.restaurants.signature_keywords_en is '시그니처 키워드 — 영문';
    comment on column public.restaurants.signature_keywords_jp is '시그니처 키워드 — 일본어';
    comment on column public.restaurants.address_en           is '주소 — 영문 (Google Maps 표기 기준)';
    comment on column public.restaurants.address_jp           is '주소 — 일본어';
    comment on column public.restaurants.genre_en             is '장르 — 영문 (Sushi/Tempura 등)';
    comment on column public.restaurants.genre_jp             is '장르 — 일본어 (寿司/天ぷら 등)';
    comment on column public.restaurants.i18n_status_en       is '영문 번역 상태: pending | ai_draft | reviewed | manual';
    comment on column public.restaurants.i18n_status_jp       is '일본어 번역 상태: pending | ai_draft | reviewed | manual';
    comment on column public.restaurants.i18n_updated_at      is '번역 마지막 업데이트 시각';

    raise notice '✓ restaurants 테이블 i18n 컬럼 추가 완료';
  else
    raise notice '⏭ restaurants 테이블 없음 — skip';
  end if;
end $$;

-- ── 2. tickets ──────────────────────────────────────────────────
do $$
begin
  if to_regclass('public.tickets') is not null then
    alter table public.tickets
      add column if not exists desc_en   text,
      add column if not exists desc_jp   text;

    comment on column public.tickets.desc_en is '티켓 상세 설명 — 영문';
    comment on column public.tickets.desc_jp is '티켓 상세 설명 — 일본어';

    raise notice '✓ tickets 테이블 i18n 컬럼 추가 완료';
  else
    raise notice '⏭ tickets 테이블 없음 — skip';
  end if;
end $$;

-- ── 3. splash_settings ──────────────────────────────────────────
-- 참고: TAAM 은 splash 설정을 IDB(localStorage)로 운영. 테이블이 없으면 자동 skip.
do $$
begin
  if to_regclass('public.splash_settings') is not null then
    alter table public.splash_settings
      add column if not exists text1_en   text,
      add column if not exists text1_jp   text,
      add column if not exists text2_en   text,
      add column if not exists text2_jp   text;

    comment on column public.splash_settings.text1_en is '시작 화면 첫줄 — 영문 (예: Exclusive)';
    comment on column public.splash_settings.text1_jp is '시작 화면 첫줄 — 일본어';
    comment on column public.splash_settings.text2_en is '시작 화면 둘째줄 — 영문 (예: Experience)';
    comment on column public.splash_settings.text2_jp is '시작 화면 둘째줄 — 일본어';

    raise notice '✓ splash_settings 테이블 i18n 컬럼 추가 완료';
  else
    raise notice '⏭ splash_settings 테이블 없음 — IDB 운영 중. skip';
  end if;
end $$;

-- ── 4. chef_lineage_knowledge ───────────────────────────────────
do $$
begin
  if to_regclass('public.chef_lineage_knowledge') is not null then
    alter table public.chef_lineage_knowledge
      add column if not exists summary_en   text,
      add column if not exists summary_jp   text,
      add column if not exists full_text_en text,
      add column if not exists full_text_jp text;

    comment on column public.chef_lineage_knowledge.summary_en   is '계보 한 줄 요약 — 영문';
    comment on column public.chef_lineage_knowledge.summary_jp   is '계보 한 줄 요약 — 일본어';
    comment on column public.chef_lineage_knowledge.full_text_en is '계보 챗 풀 텍스트 — 영문 (AI 챗 응답용)';
    comment on column public.chef_lineage_knowledge.full_text_jp is '계보 챗 풀 텍스트 — 일본어';

    raise notice '✓ chef_lineage_knowledge 테이블 i18n 컬럼 추가 완료';
  else
    raise notice '⏭ chef_lineage_knowledge 테이블 없음 — skip';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 실행 후 검증 — restaurants i18n 컬럼 목록 확인:
--   select column_name, data_type from information_schema.columns
--   where table_name = 'restaurants'
--     and (column_name like '%_en' or column_name like '%_jp')
--   order by column_name;
-- ═══════════════════════════════════════════════════════════════

    
