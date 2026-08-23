-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 해외 정가 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 무엇을 위한 것인가
--   통화 지정(profiles.currency)된 해외 회원에게는 환산값(≈$102)이 아니라
--   깔끔하게 확정한 외화 정가($100 · ¥15,000)를 보여주고 적용한다.
--   환율은 매일 움직이므로 환산으로는 깔끔한 숫자가 유지될 수 없다 —
--   티켓마다 슈퍼어드민이 확정한 값을 저장하는 것이 유일한 방법이다.
--
--   생김새 (1인 기준 정수)
--     { "usd": { "meal": 300, "agency": 100, "wine": 50 },
--       "jpy": { "meal": 45000, "agency": 15000, "wine": 8000 } }
--
--   값이 없는 칸은 앱이 환산(≈) 표시로 폴백한다 — 이 컬럼이 없어도 앱은 그냥 돈다.
--   티켓 편집 화면의 「제안값 채우기」가 적용환율 기준 제안을 채워주고,
--   슈퍼어드민이 깔끔한 숫자로 다듬어 저장한다.
--
--   기존 overseas_agency_usd(해외 대행비 예외)는 USD 대행비의 폴백으로 계속 쓴다.
-- ═══════════════════════════════════════════════════════════════

alter table public.ticket_products
  add column if not exists ovs_prices jsonb;

comment on column public.ticket_products.ovs_prices is
  '해외 정가(1인). {"usd":{meal,agency,wine},"jpy":{meal,agency,wine}}. 슈퍼어드민이 확정한 값 — 지정 통화 회원에게 이 금액이 그대로 표시·적용된다. 빈 칸은 환산(≈) 폴백.';

-- ── 확인 ──────────────────────────────────────────────────────
select column_name, data_type from information_schema.columns
 where table_schema='public' and table_name='ticket_products'
   and column_name in ('ovs_prices','overseas_agency_usd');

do $$ begin raise notice '✅ 티켓 해외 정가 컬럼 준비 완료 — ticket_products.ovs_prices'; end $$;
