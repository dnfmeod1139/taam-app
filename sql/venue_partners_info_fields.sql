-- ═══════════════════════════════════════════════════════════════
-- TAAM 예약 — venue_partners 정보 필드 추가 (매장 소개·예약 안내)
-- 작성: 2026-06-10
-- 실행: Supabase SQL Editor (idempotent)
-- ═══════════════════════════════════════════════════════════════
-- 어드민이 예약 관리 화면에서 매장 소개/예약 안내를 기재 → 회원 요청 화면에 표시.
alter table public.venue_partners add column if not exists intro             text;  -- 매장 소개 (회원 노출)
alter table public.venue_partners add column if not exists reservation_notes text;  -- 예약 안내·주의사항 (회원 노출)
