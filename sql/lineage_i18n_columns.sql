-- ═══════════════════════════════════════════════════════════════
-- TAAM 계보도 i18n — chefs 테이블 다국어 컬럼 추가
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-11
-- 적용 후: PWA 에서 영어/일본어 토글하면 노드 이름이 자동으로 EN/JA 표시
-- ═══════════════════════════════════════════════════════════════

do $$
begin
  if to_regclass('public.chefs') is not null then
    alter table public.chefs
      -- 가게/계보 노드 이름 (예: "스기타" → "Sugita" / "すぎた")
      add column if not exists name_en   text,
      add column if not exists name_jp   text,
      -- 부제 (셰프명, 예: "杉田 孝明" → "Takaaki Sugita" / "杉田 孝明")
      add column if not exists sub_en    text,
      add column if not exists sub_jp    text,
      -- 셰프 소개·배경 (chef detail 화면에서 사용)
      add column if not exists chef_background_en  text,
      add column if not exists chef_background_jp  text,
      -- AI 번역 상태 메타
      add column if not exists i18n_status_en  text default 'pending',
      add column if not exists i18n_status_jp  text default 'pending',
      add column if not exists i18n_updated_at timestamptz;

    comment on column public.chefs.name_en is '노드 이름 — 영문 (예: Sugita, Kanesaka)';
    comment on column public.chefs.name_jp is '노드 이름 — 일본어 (예: すぎた, かねさか)';
    comment on column public.chefs.sub_en  is '셰프명 — 영문 (Takaaki Sugita)';
    comment on column public.chefs.sub_jp  is '셰프명 — 일본어 (杉田 孝明)';
    comment on column public.chefs.chef_background_en is '셰프 소개 — 영문';
    comment on column public.chefs.chef_background_jp is '셰프 소개 — 일본어';
    comment on column public.chefs.i18n_status_en is '영문 번역 상태: pending | ai_draft | reviewed | manual';
    comment on column public.chefs.i18n_status_jp is '일본어 번역 상태';

    raise notice '✓ chefs 테이블 i18n 컬럼 추가 완료';
  else
    raise notice '⏭ chefs 테이블 없음 — skip';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 확인 쿼리 (실행 후):
--   select id, lineage_id, name, name_en, name_jp, sub, sub_en, sub_jp
--   from public.chefs
--   where lineage_id = 'sugita'
--   order by id
--   limit 10;
-- ═══════════════════════════════════════════════════════════════
