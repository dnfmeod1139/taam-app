-- ════════════════════════════════════════════════════════════════
-- 0002 — 챗 두뇌 + 노드 미노출 정보 팝업 + 솔드아웃 알림 구독
-- ════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────
-- 1) chefs.node_hidden_show_info — 미노출 노드의 정보 팝업 활성화 옵션
--    nodeHidden=true 인 노드여도 클릭 시 간이 정보 팝업 (사진 + 레스토랑/티켓 버튼) 표시
-- ─────────────────────────────────────────────
ALTER TABLE public.chefs
  ADD COLUMN IF NOT EXISTS node_hidden_show_info boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.chefs.node_hidden_show_info IS
  '미노출 노드 클릭 시 정보 팝업 표시 여부. true 면 일반 사용자도 팝업으로 레스토랑 정보 + TAAM 티켓 버튼 확인 가능 (단, node_hidden = true 일 때만 의미 있음).';

-- ─────────────────────────────────────────────
-- 2) user_ticket_waitlist — 솔드아웃 매장 알림 구독
--    매장 다음 티켓 업로드 시 푸시 알림 발송 대상
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_ticket_waitlist (
  user_id     uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rest_id     uuid        NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  rest_name   text        NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  notified_at timestamptz NULL,        -- 알림 발송 시각 (재구독 가능)

  PRIMARY KEY (user_id, rest_id)
);

CREATE INDEX IF NOT EXISTS idx_user_ticket_waitlist_user
  ON public.user_ticket_waitlist(user_id);

CREATE INDEX IF NOT EXISTS idx_user_ticket_waitlist_rest
  ON public.user_ticket_waitlist(rest_id) WHERE notified_at IS NULL;

-- RLS
ALTER TABLE public.user_ticket_waitlist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users read own waitlist" ON public.user_ticket_waitlist;
CREATE POLICY "Users read own waitlist"
  ON public.user_ticket_waitlist FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users insert own waitlist" ON public.user_ticket_waitlist;
CREATE POLICY "Users insert own waitlist"
  ON public.user_ticket_waitlist FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users delete own waitlist" ON public.user_ticket_waitlist;
CREATE POLICY "Users delete own waitlist"
  ON public.user_ticket_waitlist FOR DELETE
  USING (auth.uid() = user_id);

-- ─────────────────────────────────────────────
-- 3) (선택) 새 티켓 등록 시 알림 트리거 — 추후 Edge Function 으로 이관 권장
--    아래는 SKELETON: ticket_products INSERT 시 해당 rest_id 의 waitlist 에 notified_at 마킹.
--    실제 푸시 발송은 native (FCM/APN) 또는 Edge Function 에서 처리.
-- ─────────────────────────────────────────────
-- (예시 트리거 — 활성화하려면 주석 해제)
/*
CREATE OR REPLACE FUNCTION public.mark_waitlist_for_notify()
RETURNS trigger AS $$
BEGIN
  -- 새 티켓이 등록되면 해당 rest_id 의 미알림 waitlist 모두 notified_at 마킹
  -- (실제 푸시 알림은 Edge Function 또는 cron 에서 notified_at IS NULL 인 row 처리)
  UPDATE public.user_ticket_waitlist
  SET notified_at = now()
  WHERE rest_id = NEW.rest_id
    AND notified_at IS NULL;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_ticket_products_notify_waitlist ON public.ticket_products;
CREATE TRIGGER trg_ticket_products_notify_waitlist
  AFTER INSERT ON public.ticket_products
  FOR EACH ROW EXECUTE FUNCTION public.mark_waitlist_for_notify();
*/
