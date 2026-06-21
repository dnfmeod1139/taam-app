-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓 캘린더 v2 (날짜→매장별) 보강 컬럼 (2026-06-19)
-- ═══════════════════════════════════════════════════════════════
-- 데이터는 유지하고 컬럼만 추가 (idempotent). Supabase SQL Editor 에서 RUN.
-- ═══════════════════════════════════════════════════════════════

-- 정원/일정: 시간 + 매장명(예약 없는 빈 일정도 매장명 표시용)
alter table public.daegwan_capacity add column if not exists stime      text;   -- 시간 (예: '18:00' 또는 '점심')
alter table public.daegwan_capacity add column if not exists venue_name text;   -- 매장명 스냅샷

-- 수동 예약: 티켓 유형 (초대/오프라인)
alter table public.daegwan_manual   add column if not exists ttype      text not null default '오프라인';  -- '초대' | '오프라인'
alter table public.daegwan_manual   add column if not exists venue_name text;

do $$ begin raise notice '✅ 티켓 캘린더 v2 보강 컬럼 추가 (stime/venue_name/ttype)'; end $$;
