-- ═══════════════════════════════════════════════════════════════
-- TAAM — 파트너십 레스토랑 일괄 등록 (2026-06-21)
-- ═══════════════════════════════════════════════════════════════
-- 예약 요청 화면 '파트너십' 탭에 노출되는 매장. venue_id = /venues/{id}.json 슬러그.
-- 사용자가 제공한 큐레이션 35곳 중 큐레이션 인덱스(_index.json)에 존재하는 26곳.
-- (인덱스에 없는 9곳: 우스이/덴푸라모토요시/세이쥬/마에히라/308/긴자우가이/비아/
--  스시사이토 사이드카운터·하나레 → 먼저 venues/ KB 등록 후 별도 추가)
-- idempotent: 재실행해도 안전 (on conflict → is_partner 갱신).
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN.
-- ═══════════════════════════════════════════════════════════════

insert into public.venue_partners (venue_id, is_partner, channel)
select vid, true, 'request_open'
from (values
  ('sugita-tokyo'),  -- 스기타 (스시1위)
  ('amamoto-tokyo'),  -- 텐모토(아마모토)
  ('saito-tokyo'),  -- 스시 사이토
  ('arai-tokyo'),  -- 스시 아라이
  ('sushi-ikko-tokyo'),  -- 스시 잇코(이코우)
  ('shimazu-tokyo'),  -- 시마즈
  ('takamitsu-tokyo'),  -- 스시 타카미츠
  ('akira-tokyo'),  -- 스시 아키라
  ('meino-tokyo'),  -- 스시 메이노
  ('hashimoto-tokyo'),  -- 스시 하시모토
  ('kiyota-hanare-tokyo-b'),  -- 기요타 하나레
  ('takiya-tokyo'),  -- 덴푸라 타키야
  ('asanuma-tokyo'),  -- 덴푸라 아사누마
  ('numata-osaka'),  -- 누마타(덴푸라)
  ('kataori-kanazawa'),  -- 카타오리 (일본전체1위)
  ('shunji-tokyo'),  -- 스시 순지
  ('hato-tokyo'),  -- 하토우
  ('kiu-kyoto'),  -- 키우
  ('ichikawa-tokyo-b'),  -- 스시 이치카와
  ('naruse-shizuoka'),  -- 덴푸라 나루세 (덴푸라1위)
  ('nanachome-tokyo-b'),  -- 나나죠메 (야키토리)
  ('kisanuki-ishikawa'),  -- 키사누키
  ('leffervescence-tokyo'),  -- 레프레상스 L'Effervescence (미슐랭3스타)
  ('yamazaki-tokyo'),  -- 야마자키
  ('tacubo-tokyo'),  -- 타쿠보 TACUBO
  ('hisada-okayama')   -- 스시도코로 히사다
) as t(vid)
on conflict (venue_id) do update
  set is_partner = true,
      updated_at = now();

do $$
declare n int;
begin
  select count(*) into n from public.venue_partners where is_partner = true;
  raise notice '✅ 파트너십 매장 등록 완료 — 현재 is_partner=true: % 곳', n;
end $$;
