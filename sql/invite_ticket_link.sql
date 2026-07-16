-- ═══════════════════════════════════════════════════════════════
-- TAAM — 예약 초대 ↔ 판매 티켓 연결 (2026-07-16)
-- ═══════════════════════════════════════════════════════════════
-- 초대 발송 시 '판매 티켓과 연결'을 선택하면 이 컬럼에 티켓 상품 ID 저장.
-- 회원이 초대를 결제하면 tickets 행이 이 ID 로 기록되어:
--   · 좌석 재고에서 자동 차감/카운팅 (앱 판매와 합산)
--   · 좌석 엔진 규칙(정원·허용 인원·1인 한도·조각 방지) 서버 트리거 적용
-- 연결 안 한 초대(기존 방식)는 종전대로 카운팅 제외 (= 관리자 오버라이드).
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent).
-- ═══════════════════════════════════════════════════════════════

alter table public.reservation_invites
  add column if not exists ticket_product_id text;

comment on column public.reservation_invites.ticket_product_id is
  '연결된 판매 티켓(ticket_products.id). 결제 시 이 티켓 좌석에서 차감. null=별도 판매(카운팅 제외).';

do $$ begin raise notice '✅ reservation_invites.ticket_product_id 추가 — 초대·판매 좌석 통합 카운팅'; end $$;
