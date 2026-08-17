-- ═══════════════════════════════════════════════════════════════
-- TAAM — 단일 기기 로그인 면제 플래그 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent — 여러 번 돌려도 안전)
-- ═══════════════════════════════════════════════════════════════
--
-- 왜 필요한가
--   단일 기기 강제는 회원 보호 규칙이지만, 심사자에게는 장애물이 된다.
--   실제로 Apple 은 iPad Pro 와 iPhone 두 기기로 심사했다(리뷰 노트 명시).
--   데모 계정 하나로 두 기기를 오가면 뒤에 연 기기가 앞의 기기를 쫓아내고,
--   리뷰어에게는 "로그인이 자꾸 풀리는 앱" 으로 보인다 → Guideline 2.1 리젝.
--
--   그렇다고 심사용 계정에 super_admin 을 주면 어드민 전체가 열린다.
--   면제만 필요한데 권한까지 주는 셈이라 위험하다.
--   → 역할과 분리된 플래그를 따로 둔다.
--
-- 운영 원칙
--   · 이 플래그는 심사·데모 계정에만 켠다. 일반 회원에게 켜면 규칙이 무너진다.
--   · 심사가 끝나면 되돌린다 (슈퍼어드민 → 회원 관리에서 토글).
-- ═══════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists single_device_exempt boolean not null default false;

comment on column public.profiles.single_device_exempt is
  '단일 기기 로그인 강제 면제. 앱 심사·데모 계정 전용 — 일반 회원에게 켜지 말 것.';

-- 현재 면제된 계정 확인 (심사 끝나면 비어 있어야 정상)
select id, display_name, email, single_device_exempt
from public.profiles
where single_device_exempt = true;

do $$ begin raise notice '✅ profiles.single_device_exempt 준비 완료'; end $$;
