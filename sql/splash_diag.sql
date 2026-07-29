-- ═══════════════════════════════════════════════════════════════
-- TAAM — 시작화면(스플래시) 배경 공유 진단
-- Supabase SQL Editor 에서 실행 (읽기 전용 — 데이터 변경 없음)
-- 목적:
--   ① app_config 에 splash_settings 행이 실제로 저장돼 있는지 + 이미지 크기
--   ② app_config 를 anon/authenticated(=일반 회원)가 SELECT 할 수 있는지 (RLS)
-- ═══════════════════════════════════════════════════════════════

-- ── ① 저장된 스플래시 설정 확인 ──
--   bg_base64_len 이 크면(예: 100만↑) 옛 무압축 버전. NULL/0 이면 사진 없음.
--   행이 아예 없으면 → 서버에 저장된 적 없음(회원 화면엔 기본 배경).
select
  key,
  (value->>'text1')                              as text1,
  (value->>'text2')                              as text2,
  length(value->>'bg')                           as bg_base64_len,   -- 사진 데이터 길이(문자수)
  pg_size_pretty(length(value::text)::bigint)    as row_size,        -- 전체 행 크기
  left(coalesce(value->>'bg',''), 30)            as bg_prefix,       -- 'data:image/jpeg;base64,...' 여야 정상
  updated_at
from public.app_config
where key = 'splash_settings';

-- ── ② RLS(행 수준 보안) 활성화 여부 ──
select relname as table_name, relrowsecurity as rls_enabled
from pg_class
where relname = 'app_config';

-- ── ③ SELECT 정책 목록 — 누가 읽을 수 있는지 ──
--   roles 에 {public} 또는 {anon, authenticated} 가 있고 cmd 가 SELECT/ALL 이면
--   일반 회원도 읽을 수 있음(=공유 정상). 없으면 회원이 못 읽어 공유 안 됨.
select policyname, roles, cmd, qual
from pg_policies
where schemaname = 'public' and tablename = 'app_config'
order by cmd, policyname;

-- ───────────────────────────────────────────────────────────────
-- (참고) ③ 결과에 회원 읽기 정책이 없다면 아래를 실행해 공개 읽기 허용:
--   ※ app_config 는 캐러셀/광고팝업/스플래시 등 '전 회원 공유 설정' 저장소라 공개 읽기가 맞음.
-- ───────────────────────────────────────────────────────────────
-- alter table public.app_config enable row level security;
-- drop policy if exists "app_config public read" on public.app_config;
-- create policy "app_config public read"
--   on public.app_config for select to public using ( true );
