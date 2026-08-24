-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 판매 오픈 예약 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 무엇을 위한 것인가
--   1년치 예약을 미리 받아 티켓을 전부 등록해 두고, 공개 시점만 골라서 연다.
--     · open      즉시 공개 (기본 — 기존 티켓 전부 이 상태)
--     · draft     비공개 보관 (회원에게 전혀 안 보임, 수동으로 열 때까지)
--     · scheduled 예약 오픈 (sale_open_at 이 되면 자동 공개 — 서버 잡 없이
--                 시간 비교로 판정하므로 누락이 없다)
--   컬럼이 없어도 앱은 기존 동작(전부 공개) 그대로 돈다.
-- ═══════════════════════════════════════════════════════════════

alter table public.ticket_products
  add column if not exists sale_state text;

alter table public.ticket_products
  add column if not exists sale_open_at text;

do $$ begin
  alter table public.ticket_products
    add constraint ticket_products_sale_state_chk check (sale_state in ('open','draft','scheduled'));
exception when duplicate_object then null; end $$;

comment on column public.ticket_products.sale_state is
  '판매 공개 상태. open=공개(기본·NULL 포함) / draft=비공개 보관 / scheduled=예약 오픈(sale_open_at 도달 시 자동 공개).';
comment on column public.ticket_products.sale_open_at is
  '예약 오픈 일시 (로컬 ISO, 예: 2026-09-01T10:00). sale_state=scheduled 일 때만 의미.';

-- ── 확인 ──────────────────────────────────────────────────────
select column_name, data_type from information_schema.columns
 where table_schema='public' and table_name='ticket_products'
   and column_name in ('sale_state','sale_open_at');

do $$ begin raise notice '✅ 티켓 판매 오픈 예약 컬럼 준비 완료 — sale_state · sale_open_at'; end $$;
