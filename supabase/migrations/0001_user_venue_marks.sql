-- ════════════════════════════════════════════════════════════════
-- TAAM Atlas — user_venue_marks
-- Supabase 마이그레이션 0001
-- 생성: 2026-05-07
-- ════════════════════════════════════════════════════════════════
-- 목적: 사용자 개인의 도장깨기(컬렉션·챌린지) 상태 저장
-- 영역: knowledge_base venue 참조 only (티켓·계보·상세화면과 무관)
-- 룰:
--   - kb_venue_id 는 /venues/{id}.json 의 venue_id 와 매칭 (FK 아님 — 정적 파일)
--   - 다른 영역(ticket, lineage chef)과 자동 연결 X
--   - status: 'collection'(맛본곳) | 'challenge'(가고싶은곳)
--   - 행 없음 = 중립 (관심 없음 / 모름)
-- ════════════════════════════════════════════════════════════════

-- ── 테이블 ──
CREATE TABLE IF NOT EXISTS public.user_venue_marks (
    user_id       uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    kb_venue_id   text        NOT NULL,
    status        text        NOT NULL CHECK (status IN ('collection', 'challenge')),
    tasted_at     timestamptz NULL,         -- collection 일 때만 채움
    note_ko       text        NULL,         -- 사용자 개인 메모 (선택)
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id, kb_venue_id)
);

-- ── 인덱스 ──
-- "내 컬렉션 모두" / "내 챌린지 모두" 빠른 조회
CREATE INDEX IF NOT EXISTS idx_user_venue_marks_user_status
    ON public.user_venue_marks(user_id, status);

-- venue 별 통계 ("이 가게는 몇 명이 컬렉션했나" — 추후 사회적 기능용)
CREATE INDEX IF NOT EXISTS idx_user_venue_marks_venue
    ON public.user_venue_marks(kb_venue_id, status);


-- ── updated_at 자동 갱신 트리거 ──
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_user_venue_marks_touch ON public.user_venue_marks;
CREATE TRIGGER trg_user_venue_marks_touch
    BEFORE UPDATE ON public.user_venue_marks
    FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


-- ── Row Level Security ──
ALTER TABLE public.user_venue_marks ENABLE ROW LEVEL SECURITY;

-- 사용자는 자기 자신의 마크만 read 가능
DROP POLICY IF EXISTS "Users can read own venue marks" ON public.user_venue_marks;
CREATE POLICY "Users can read own venue marks"
    ON public.user_venue_marks FOR SELECT
    USING (auth.uid() = user_id);

-- 사용자는 자기 자신의 마크만 insert 가능
DROP POLICY IF EXISTS "Users can insert own venue marks" ON public.user_venue_marks;
CREATE POLICY "Users can insert own venue marks"
    ON public.user_venue_marks FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- 사용자는 자기 자신의 마크만 update 가능
DROP POLICY IF EXISTS "Users can update own venue marks" ON public.user_venue_marks;
CREATE POLICY "Users can update own venue marks"
    ON public.user_venue_marks FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- 사용자는 자기 자신의 마크만 delete 가능
DROP POLICY IF EXISTS "Users can delete own venue marks" ON public.user_venue_marks;
CREATE POLICY "Users can delete own venue marks"
    ON public.user_venue_marks FOR DELETE
    USING (auth.uid() = user_id);


-- ── 코멘트 ──
COMMENT ON TABLE  public.user_venue_marks IS
    'TAAM Atlas 도장깨기 — 사용자 개인 컬렉션·챌린지 상태. knowledge_base venue 참조 (티켓·계보 무관).';
COMMENT ON COLUMN public.user_venue_marks.kb_venue_id IS
    '/venues/{id}.json venue_id 매칭 (정적 파일, FK 아님)';
COMMENT ON COLUMN public.user_venue_marks.status IS
    'collection(맛본곳) | challenge(가고싶은곳)';
COMMENT ON COLUMN public.user_venue_marks.tasted_at IS
    'collection 일 때만 채움 — 방문 일자';
