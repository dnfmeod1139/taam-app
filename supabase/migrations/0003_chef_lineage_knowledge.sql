-- ════════════════════════════════════════════════════════════════
-- 0003 — 쉐프 계보 챗 두뇌 (계보별 학습 + 매장별 한줄 롤업)
-- ────────────────────────────────────────────────────────────────
-- 목적:
--   1) 슈퍼어드민이 계보 트리별로 자료 + 노트를 입력 → AI 가 정리한
--      `full_text` 를 발행 → taam-chat Edge Function 컨텍스트에 주입.
--   2) 각 매장(restaurant)에는 자기 계보 한줄 요약 (`chef_lineage_text`) 자동 롤업.
--   3) 사용자 쿼리에 계보 키워드 감지 시 → 발행된 모든 계보를 LLM 컨텍스트로 추가.
--
-- 범위 (이번 마이그레이션): 일식 스시 계보 12개만 시드.
--   (라멘 계보는 추후 0004 에서 별도 시드)
-- ════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────
-- 1) chef_lineage_knowledge — 계보 단위 학습 정보 (1 lineage = 1 row)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.chef_lineage_knowledge (
  lineage_id        text PRIMARY KEY,        -- 'sugita', 'kanesaka', 'jiro' ...
  lineage_name_ko   text NOT NULL,           -- '스기타 계보'
  lineage_name_en   text NULL,               -- 'Sugita Lineage'
  lineage_kind      text NOT NULL CHECK (lineage_kind IN ('sushi','ramen')),

  -- 학습 콘텐츠
  summary           text NULL,               -- 한 문단 요약 (검색용)
  full_text         text NULL,               -- 챗 두뇌가 받는 전체 학습 텍스트

  -- 자료 출처 + 큐레이션
  reference_urls    text[] NOT NULL DEFAULT '{}'::text[],
  curator_notes     text NULL,

  -- AI 정리 메타 (Option B — 서버 페치 + Claude 정리 결과 추적)
  ai_model          text NULL,               -- 예: 'claude-sonnet-4-5'
  ai_generated_at   timestamptz NULL,
  ai_token_usage    jsonb NULL,              -- {input, output, cache_read} 등

  -- 메타
  chef_count        int NULL,                -- chef 수 (자동 또는 수동)
  is_published      boolean NOT NULL DEFAULT false,
  last_verified_at  timestamptz NULL,
  last_verified_by  uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.chef_lineage_knowledge IS
  '쉐프 계보별 학습 정보. 1 행 = 1 계보 트리. 슈퍼어드민이 자료 + 노트 입력 → Claude 가 정리 → 발행 시 챗 두뇌에 주입.';
COMMENT ON COLUMN public.chef_lineage_knowledge.full_text IS
  '챗 두뇌(taam-chat Edge Function)에 그대로 주입되는 정리된 계보 텍스트. AI 정리 결과 또는 사람이 직접 작성한 본문.';
COMMENT ON COLUMN public.chef_lineage_knowledge.reference_urls IS
  '참고 자료 URL 배열. AI 정리 시 서버에서 fetch 하여 컨텍스트로 사용.';
COMMENT ON COLUMN public.chef_lineage_knowledge.is_published IS
  'true 일 때만 챗 두뇌 컨텍스트에 포함. false 는 작성 중.';

CREATE INDEX IF NOT EXISTS idx_chef_lineage_knowledge_kind
  ON public.chef_lineage_knowledge(lineage_kind);

CREATE INDEX IF NOT EXISTS idx_chef_lineage_knowledge_published
  ON public.chef_lineage_knowledge(is_published) WHERE is_published = true;

-- updated_at 자동 갱신 트리거
CREATE OR REPLACE FUNCTION public.touch_chef_lineage_knowledge_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_chef_lineage_knowledge_updated_at ON public.chef_lineage_knowledge;
CREATE TRIGGER trg_chef_lineage_knowledge_updated_at
  BEFORE UPDATE ON public.chef_lineage_knowledge
  FOR EACH ROW EXECUTE FUNCTION public.touch_chef_lineage_knowledge_updated_at();

-- RLS
ALTER TABLE public.chef_lineage_knowledge ENABLE ROW LEVEL SECURITY;

-- (a) 발행된 계보는 anon + authenticated 모두 읽기 (챗 두뇌 anon 호출 호환)
DROP POLICY IF EXISTS "Anyone reads published lineage knowledge" ON public.chef_lineage_knowledge;
CREATE POLICY "Anyone reads published lineage knowledge"
  ON public.chef_lineage_knowledge FOR SELECT
  USING (is_published = true);

-- (b) 인증된 사용자는 미발행 행도 읽기 (어드민 편집용 — 클라이언트에서 슈퍼어드민 추가 검증)
DROP POLICY IF EXISTS "Auth users read all lineage knowledge" ON public.chef_lineage_knowledge;
CREATE POLICY "Auth users read all lineage knowledge"
  ON public.chef_lineage_knowledge FOR SELECT
  TO authenticated
  USING (true);

-- (c) 쓰기 — 인증 사용자만 (슈퍼어드민 검증은 클라이언트/Edge Function 측에서)
DROP POLICY IF EXISTS "Auth users insert lineage knowledge" ON public.chef_lineage_knowledge;
CREATE POLICY "Auth users insert lineage knowledge"
  ON public.chef_lineage_knowledge FOR INSERT
  TO authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Auth users update lineage knowledge" ON public.chef_lineage_knowledge;
CREATE POLICY "Auth users update lineage knowledge"
  ON public.chef_lineage_knowledge FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "Auth users delete lineage knowledge" ON public.chef_lineage_knowledge;
CREATE POLICY "Auth users delete lineage knowledge"
  ON public.chef_lineage_knowledge FOR DELETE
  TO authenticated
  USING (true);


-- ─────────────────────────────────────────────
-- 2) restaurants 매장별 계보 한줄 + 동기화 메타
--    chef_lineage_knowledge 발행 시 또는 어드민이 [매장 동기화] 클릭 시 채워짐.
--    챗 두뇌가 매장 컨텍스트를 만들 때 concierge_note 옆에 자동 결합.
-- ─────────────────────────────────────────────
ALTER TABLE public.restaurants
  ADD COLUMN IF NOT EXISTS chef_lineage_text     text        NULL,
  ADD COLUMN IF NOT EXISTS chef_lineage_id       text        NULL,   -- 매장의 주 계보 (chef_lineage_knowledge.lineage_id 참조; FK 는 의도적으로 안 검 — 라멘/일식 혼재 + soft 참조)
  ADD COLUMN IF NOT EXISTS chef_lineage_synced_at timestamptz NULL;

COMMENT ON COLUMN public.restaurants.chef_lineage_text IS
  '매장 쉐프의 계보 한줄 요약. chef_lineage_knowledge 에서 파생. 챗 두뇌 컨텍스트에 자동 포함.';
COMMENT ON COLUMN public.restaurants.chef_lineage_id IS
  'chef_lineage_knowledge.lineage_id soft reference. 같은 계보 매장 그룹 쿼리용.';

CREATE INDEX IF NOT EXISTS idx_restaurants_chef_lineage_id
  ON public.restaurants(chef_lineage_id) WHERE chef_lineage_id IS NOT NULL;


-- ─────────────────────────────────────────────
-- 3) 시드 — 일식 스시 계보 12개 (빈 행만, 학습은 어드민 UI 에서)
--    실제 콘텐츠는 슈퍼어드민이 [학습] 버튼 → 자료 입력 → AI 정리 → 발행 후 채워짐.
-- ─────────────────────────────────────────────
INSERT INTO public.chef_lineage_knowledge
  (lineage_id, lineage_name_ko, lineage_name_en, lineage_kind)
VALUES
  ('sugita',   '스기타 계보',     'Sugita Lineage',      'sushi'),
  ('kanesaka', '카네사카 계보',   'Kanesaka Lineage',    'sushi'),
  ('kyubey',   '큐베이 계보',     'Kyubey Lineage',      'sushi'),
  ('saito',    '사이토 계보',     'Saito Lineage',       'sushi'),
  ('umi',      '우미 계보',       'Umi Lineage',         'sushi'),
  ('jiro',     '지로 계보',       'Jiro Lineage',        'sushi'),
  ('arai',     '아라이 계보',     'Arai Lineage',        'sushi'),
  ('sho',      '스시 쇼 계보',    'Sushisho Lineage',    'sushi'),
  ('new9',     '기요타 계보',     'Kiyota Lineage',      'sushi'),
  ('new10',    '아라키 계보',     'Araki Lineage',       'sushi'),
  ('new11',    '미타니 계보',     'Mitani Lineage',      'sushi'),
  ('new12',    '요시타케 계보',   'Yoshitake Lineage',   'sushi')
ON CONFLICT (lineage_id) DO NOTHING;


-- ─────────────────────────────────────────────
-- 4) 챗 두뇌가 사용할 발행 계보 뷰
--    Edge Function 에서 키워드 매칭 시 SELECT * FROM v_published_chef_lineages
-- ─────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_published_chef_lineages AS
SELECT
  lineage_id, lineage_name_ko, lineage_name_en, lineage_kind,
  summary, full_text, reference_urls,
  chef_count, last_verified_at
FROM public.chef_lineage_knowledge
WHERE is_published = true
ORDER BY lineage_kind, lineage_name_ko;

COMMENT ON VIEW public.v_published_chef_lineages IS
  'taam-chat Edge Function 이 계보 키워드 감지 시 조회하는 발행 계보 목록.';


-- ─────────────────────────────────────────────
-- 검증 쿼리 (마이그레이션 후 수동 실행용)
-- ─────────────────────────────────────────────
-- ① 시드 결과 (예상: sushi=12)
-- SELECT lineage_kind, count(*) FROM public.chef_lineage_knowledge GROUP BY lineage_kind;
--
-- ② 컬럼 추가 확인
-- SELECT column_name, data_type
-- FROM information_schema.columns
-- WHERE table_name = 'restaurants' AND column_name LIKE 'chef_lineage%';
--
-- ③ RLS 정책 확인
-- SELECT polname, polcmd FROM pg_policy
-- WHERE polrelid = 'public.chef_lineage_knowledge'::regclass;
