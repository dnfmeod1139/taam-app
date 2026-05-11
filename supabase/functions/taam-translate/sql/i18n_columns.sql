-- ═══════════════════════════════════════════════════════════════
-- TAAM i18n — 운영 컨텐츠 다국어 컬럼 일괄 추가
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-11
-- 원칙: KO 기본, EN/JP 비어 있으면 KO 폴백 (앱 단의 pickI18nField 가 처리)
-- ═══════════════════════════════════════════════════════════════

-- ── 1. restaurants ──────────────────────────────────────────────
--   기존 컬럼 가정: name (KO), name_en, chef_background_ko, concierge_note,
--                  vibe_tags (text[]), signature_keywords (text[])
--   추가: 일본어 + 영문 한 줄 평/분위기/시그니처
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
  add column if not exists genre_jp                text;

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

-- ── 2. tickets ──────────────────────────────────────────────────
--   기존: ticketGenre, desc (한국어 자유 입력)
--   추가: 영문/일본어 설명
alter table public.tickets
  add column if not exists desc_en   text,
  add column if not exists desc_jp   text;

comment on column public.tickets.desc_en is '티켓 상세 설명 — 영문';
comment on column public.tickets.desc_jp is '티켓 상세 설명 — 일본어';

-- ── 3. splash_settings ──────────────────────────────────────────
--   기존: text1, text2 (KO)
--   추가: 영문/일본어 시작 화면 문구
alter table public.splash_settings
  add column if not exists text1_en   text,
  add column if not exists text1_jp   text,
  add column if not exists text2_en   text,
  add column if not exists text2_jp   text;

comment on column public.splash_settings.text1_en is '시작 화면 첫줄 — 영문 (예: Exclusive)';
comment on column public.splash_settings.text1_jp is '시작 화면 첫줄 — 일본어';
comment on column public.splash_settings.text2_en is '시작 화면 둘째줄 — 영문 (예: Experience)';
comment on column public.splash_settings.text2_jp is '시작 화면 둘째줄 — 일본어';

-- ── 4. chef_lineage_knowledge (선택) ────────────────────────────
--   계보 챗 두뇌 — 향후 영문/일본어 응답 지원용
alter table public.chef_lineage_knowledge
  add column if not exists summary_en  text,
  add column if not exists summary_jp  text,
  add column if not exists full_text_en text,
  add column if not exists full_text_jp text;

comment on column public.chef_lineage_knowledge.summary_en  is '계보 한 줄 요약 — 영문';
comment on column public.chef_lineage_knowledge.summary_jp  is '계보 한 줄 요약 — 일본어';
comment on column public.chef_lineage_knowledge.full_text_en is '계보 챗 풀 텍스트 — 영문 (AI 챗 응답용)';
comment on column public.chef_lineage_knowledge.full_text_jp is '계보 챗 풀 텍스트 — 일본어';

-- ── 5. 자동 번역 상태 추적 (선택) ───────────────────────────────
--   taam-translate Edge Function 이 채울 메타 컬럼
alter table public.restaurants
  add column if not exists i18n_status_en  text default 'pending',
  add column if not exists i18n_status_jp  text default 'pending',
  add column if not exists i18n_updated_at timestamptz;

comment on column public.restaurants.i18n_status_en  is '영문 번역 상태: pending | ai_draft | reviewed | manual';
comment on column public.restaurants.i18n_status_jp  is '일본어 번역 상태: pending | ai_draft | reviewed | manual';
comment on column public.restaurants.i18n_updated_at is '번역 마지막 업데이트 시각';

-- ═══════════════════════════════════════════════════════════════
-- 실행 후 검증:
--   select column_name, data_type from information_schema.columns
--   where table_name = 'restaurants' and column_name like '%_en' or column_name like '%_jp'
--   order by column_name;
-- ═══════════════════════════════════════════════════════════════
