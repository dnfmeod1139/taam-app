-- 슈퍼어드민 전용 큐레이션 플래그
-- true  = 회원 비공개 (지도/레스토랑 리스트에서 제외, 슈퍼어드민 "가게 큐레이션 관리"에만 노출)
-- false = 회원 공개 (기존과 동일)
-- 목적: 후보 가게를 먼저 담아두고, 정리되면 토글 OFF 로 회원 공개.
-- ▶ Supabase SQL Editor 에서 실행하세요 (저장소에 두는 것만으로는 반영 안 됨).

ALTER TABLE public.restaurants
  ADD COLUMN IF NOT EXISTS super_admin_only boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.restaurants.super_admin_only IS
  '슈퍼어드민 전용: true면 회원(지도·리스트)에서 숨김, 어드민 큐레이션 관리에만 노출. 정리 후 false로 공개.';

CREATE INDEX IF NOT EXISTS idx_restaurants_super_admin_only
  ON public.restaurants(super_admin_only);
