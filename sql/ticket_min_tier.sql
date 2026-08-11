-- ═══════════════════════════════════════════════════════════════
-- TAAM — 티켓별 이용 등급 제한 (minTier) + A 등급 신설 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent)
--   · ticket_products.min_tier : '' | 'A' | 'T' | 'M'  (null/'' = 전체 공개)
--   · 위계 M > T > A — 선택 등급 이상만 상세 열람·구매 가능
--   · 기존 '등급별 우선 공개'(grade_open 시간차)와는 독립된 별개 축
-- ═══════════════════════════════════════════════════════════════

alter table public.ticket_products
  add column if not exists min_tier text;

comment on column public.ticket_products.min_tier is
  '티켓 이용 최소 등급. null/빈값=전체 공개, A/T/M = 해당 등급 이상만 이용 가능 (M>T>A).';

-- 값 검증 제약 (기존 데이터 영향 없음 — null 허용)
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'ticket_products_min_tier_chk'
  ) then
    alter table public.ticket_products
      add constraint ticket_products_min_tier_chk
      check (min_tier is null or min_tier in ('', 'A', 'T', 'M'));
  end if;
end $$;

-- 초대 코드 등급에 A 허용 (기존 제약이 M/T 만 허용하면 교체)
do $$
begin
  if exists (
    select 1 from pg_constraint where conname = 'invite_codes_invitee_tier_chk'
  ) then
    alter table public.invite_codes drop constraint invite_codes_invitee_tier_chk;
  end if;
  alter table public.invite_codes
    add constraint invite_codes_invitee_tier_chk
    check (invitee_tier is null or invitee_tier in ('A', 'T', 'M'));
exception when others then
  null;   -- 컬럼/테이블 구조가 다르면 건너뜀 (앱단 검증으로 충분)
end $$;

do $$ begin raise notice '✅ ticket_products.min_tier + A 등급 허용 설치 완료'; end $$;
