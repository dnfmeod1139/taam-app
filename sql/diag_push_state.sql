-- ═══════════════════════════════════════════════════════════════
-- 진단 — 푸시가 '누구의 어느 기기'에 실제로 닿는지 (2026-08-27)
-- ═══════════════════════════════════════════════════════════════
-- 읽기 전용. 아무것도 바꾸지 않는다.
--
-- 알림이 안 오는 이유는 셋 중 하나다.
--   ① 그 회원에게 구독이 아예 없다        → 「구독수」 0
--   ② 구독은 있는데 role 이 틀리다         → 「역할일치」 ✗  (role: 스코프 푸시가 건너뜀)
--   ③ 구독도 role 도 맞는데 발송이 실패한다 → 여기선 안 보임. Edge Function Logs 를 볼 것
-- ═══════════════════════════════════════════════════════════════


-- ── ① 사람별 요약 — 구독이 있는지, 종류가 무엇인지, 역할이 맞는지 ──
select
  coalesce(p.display_name, left(p.id::text, 8))          as "회원",
  p.role                                                  as "프로필_역할",
  count(s.id)                                             as "구독수",
  count(*) filter (where s.endpoint like 'apns://%')      as "iOS앱",
  count(*) filter (where s.endpoint like 'fcm://%')       as "안드앱",
  count(*) filter (where s.endpoint not like 'apns://%'
                     and s.endpoint not like 'fcm://%')   as "웹",
  string_agg(distinct coalesce(s.role, '(빈값)'), ', ')    as "구독에_적힌_역할",
  case
    when count(s.id) = 0 then '❌ 구독 없음 — 푸시가 아예 안 감'
    when p.role in ('superadmin','super_admin')
     and coalesce(bool_or(s.role in ('superadmin','super_admin')), false) = false
      then '⚠ 역할 불일치 — role: 푸시에서 빠짐 (부팅 시 user 로 덮인 흔적)'
    else '✅ 정상'
  end                                                     as "판정",
  max(s.last_seen_at)                                     as "마지막_갱신"
from public.profiles p
left join public.push_subscriptions s on s.user_id = p.id
group by p.id, p.display_name, p.role
having count(s.id) > 0 or p.role in ('superadmin','super_admin')
order by (p.role in ('superadmin','super_admin')) desc, count(s.id) desc;


-- ── ② 슈퍼어드민에게 role: 푸시가 실제로 몇 대에 나가는지 ──
--    수정 전(구독 role 만 봄) vs 수정 후(profiles 로도 판정) 를 나란히 비교한다.
--    「수정후」가 「수정전」보다 크면, 그만큼의 기기가 종전엔 조용히 빠져 있었다는 뜻.
select
  (select count(*) from public.push_subscriptions
    where role in ('superadmin','super_admin'))                  as "수정전_대상기기",
  (select count(*) from public.push_subscriptions s
    where s.role in ('superadmin','super_admin')
       or s.user_id in (select id from public.profiles
                         where role in ('superadmin','super_admin'))) as "수정후_대상기기";


-- ── ③ 기기 하나하나 (최근 갱신 순) ──
select
  coalesce(p.display_name, left(s.user_id::text, 8))  as "회원",
  p.role                                              as "프로필_역할",
  s.role                                              as "구독_역할",
  case
    when s.endpoint like 'apns://%' then 'iOS 앱'
    when s.endpoint like 'fcm://%'  then '안드로이드 앱'
    else '웹/PWA'
  end                                                 as "종류",
  s.device_label                                      as "기기",
  left(s.endpoint, 34) || '…'                         as "엔드포인트",
  s.last_seen_at                                      as "마지막_갱신",
  s.created_at                                        as "생성"
from public.push_subscriptions s
left join public.profiles p on p.id = s.user_id
order by s.last_seen_at desc nulls last
limit 50;


-- ── ④ 최근 알림 이력 — taam_notify_admins 가 실제로 쌓고 있는지 ──
select
  n.created_at                                        as "시각",
  coalesce(p.display_name, left(n.user_id::text, 8))  as "받는사람",
  p.role                                              as "역할",
  n.type                                              as "종류",
  left(n.title, 44)                                   as "제목",
  n.seen                                              as "확인됨",
  (n.payload->>'via')                                 as "경로"
from public.notifications n
left join public.profiles p on p.id = n.user_id
order by n.created_at desc
limit 30;
