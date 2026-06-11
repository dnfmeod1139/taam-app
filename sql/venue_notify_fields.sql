-- TAAM 예약 — 어드민 알림 수신처 (알림톡 전화 / LINE ID)
-- 실행: Supabase SQL Editor (idempotent)
alter table public.venue_partners add column if not exists notify_phone   text;  -- 카카오 알림톡 수신 전화번호
alter table public.venue_partners add column if not exists notify_line_id text;  -- LINE 사용자 ID (Messaging API)
