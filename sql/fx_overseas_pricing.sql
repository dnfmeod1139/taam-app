-- ═══════════════════════════════════════════════════════════════
-- TAAM — 해외 회원 통화 표시 · 해외 대행비 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 실행해도 안전)
--
-- 설계 원칙
--   · 원장(정산·차감·환불)은 원화 단일. 통화를 이중으로 두지 않는다.
--   · 해외 회원 화면에는 USD 를 병기한다. 식사비·주류비는 참고 환산값.
--   · 대행비만 해외 요율(원화 ÷ 1,000 = USD)을 적용한다. 매장 몫에는 마진을 붙이지 않는다.
--   · 적용 환율 = 은행 매매기준율 × (1 - 마진%). 마진이 환율 변동·송금 수수료를 흡수한다.
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 환율/해외요율 설정 (app_config) ──
--   base_rate      : 은행 매매기준율 (슈퍼어드민이 주기적으로 갱신)
--   margin_pct     : 당사 마진 (%). 적용환율 = base_rate × (1 - margin_pct/100)
--   agency_divisor : 대행비 환산 제수. 원화 ÷ 1000 = USD (₩100,000 → $100)
--   step_usd       : 식사비·주류비 USD 올림 단위
--   enabled        : false 면 전 회원에게 원화만 표시 (즉시 롤백 스위치)
insert into public.app_config (key, value, updated_at)
values (
  'fx_settings',
  jsonb_build_object(
    'base_rate',      1410,      -- 매매기준율 (2026-08 기준 예시 — 실제 값으로 갱신)
    'margin_pct',     3.5,       -- 당사 마진
    'agency_divisor', 1000,      -- 대행비: 원화 ÷ 1000 = USD
    'step_usd',       5,         -- 식사비·주류비 올림 단위
    'enabled',        true
  ),
  now()
)
on conflict (key) do nothing;   -- 이미 있으면 기존 설정 보존

-- ── 2) 티켓별 해외 대행비 예외 (USD) ──
--   비워두면(NULL) agency_fee ÷ agency_divisor 로 자동 계산.
--   특정 티켓만 다른 금액을 받고 싶을 때 값을 넣는다.
alter table public.ticket_products
  add column if not exists overseas_agency_usd integer;

comment on column public.ticket_products.overseas_agency_usd is
  '해외 회원 대행비(USD, 1인). NULL 이면 agency_fee ÷ 1000 자동 계산';

-- ── 3) 확인 ──
select
  key,
  value->>'base_rate'      as "기준율",
  value->>'margin_pct'     as "마진(%)",
  round((value->>'base_rate')::numeric * (1 - (value->>'margin_pct')::numeric / 100), 2) as "적용환율",
  value->>'agency_divisor' as "대행비 제수",
  value->>'step_usd'       as "올림단위",
  value->>'enabled'        as "활성"
from public.app_config
where key = 'fx_settings';

select count(*) as "ticket_products 행 수",
       count(overseas_agency_usd) as "해외 대행비 예외 지정된 티켓"
from public.ticket_products;

do $$ begin raise notice '✅ 해외 통화 설정 완료 — app_config.fx_settings + ticket_products.overseas_agency_usd'; end $$;
