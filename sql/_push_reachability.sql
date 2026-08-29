-- ═══════════════════════════════════════════════════════════════
-- TAAM — 푸시 알림을 받을 수 있는 회원 / 못 받는 회원 (2026-08-29)
-- ═══════════════════════════════════════════════════════════════
-- 읽기 전용. 한 줄도 바꾸지 않는다.
--
-- 왜 필요한가
--   "알림이 안 온다" 는 말은 원인이 최소 네 가지다. 어느 쪽인지 모르면
--   고칠 수가 없다. 이 파일은 회원 한 명마다 그 이유를 대준다.
--
-- 못 받는 이유 (send-push 코드 기준)
--   ① 등록된 기기가 없다 — push_subscriptions 에 행이 아예 없다.
--      알림 권한을 안 줬거나, 웹 브라우저에서 거부했거나,
--      옛 안드로이드 빌드(1010 이하)라 FCM 등록을 통째로 건너뛴 경우.
--   ② 회원이 스스로 껐다 — profiles.notif_prefs.
--      ⚠ 이 설정은 '개인 알림(uid/user)' 에만 적용된다.
--        운영 공지(role:/all:/topic:)는 그대로 간다. 그래서 슈퍼어드민이
--        보내는 티켓 오픈 공지는 이 회원에게도 도착한다.
--   ③ 기기가 오래됐다 — 마지막 접속이 오래 전이면 토큰이 만료됐을 수 있다.
--      무효 토큰은 발송 시도 때 서버가 자동으로 지우므로, 이 목록은
--      '아직 시도해보지 않은' 잠재 불량이다.
--   ④ 등급·역할과 무관 — 푸시는 등급을 보지 않는다. T 든 M 이든 똑같다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN → 표 세 개.
--   ① 회원별 판정   ② 요약   ③ 기기 상세
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 회원별 — 받을 수 있나, 못 받으면 왜
-- ═══════════════════════════════════════════════════════════════
with s as (
  select
    user_id,
    count(*)                                                          as devices,
    count(*) filter (where endpoint like 'fcm://%')                   as android,
    count(*) filter (where endpoint like 'apns://%')                  as ios,
    count(*) filter (where endpoint like 'http%')                     as web,
    max(last_seen_at)                                                 as last_seen
  from public.push_subscriptions
  group by user_id
),
p as (
  select
    pr.id, pr.display_name, pr.role, pr.membership_tier, pr.created_at,
    coalesce(pr.notif_prefs, '{}'::jsonb) as np
  from public.profiles pr
)
select
  coalesce(p.display_name, '(이름없음)')                              as "회원",
  coalesce(p.membership_tier, '-')                                    as "등급",
  coalesce(s.devices, 0)                                              as "기기",
  case when coalesce(s.android,0) > 0 then 'A' else '' end
    || case when coalesce(s.ios,0) > 0 then 'i' else '' end
    || case when coalesce(s.web,0) > 0 then 'W' else '' end           as "종류",
  case when s.last_seen is null then '-'
       else to_char(s.last_seen, 'MM-DD') end                         as "마지막",
  -- 회원이 끈 항목 (없으면 빈칸)
  case when p.np->>'all' = 'false' then '전체 꺼짐'
       else nullif(array_to_string(array(
              select k from jsonb_each_text(p.np) as e(k,v) where v = 'false'
            ), ','), '') end                                          as "끈항목",
  case
    when coalesce(s.devices, 0) = 0
      then '❌ 등록된 기기 없음 — 알림 권한 미허용 또는 옛 앱'
    when p.np->>'all' = 'false'
      then '⚠ 회원이 알림을 껐음 — 개인 알림만 차단, 운영 공지는 감'
    when s.last_seen < now() - interval '60 days'
      then '⚠ 60일 넘게 접속 없음 — 토큰이 만료됐을 수 있음'
    else '✅ 받을 수 있음'
  end                                                                 as "판정"
from p
left join s on s.user_id = p.id
order by
  case
    when coalesce(s.devices, 0) = 0                        then 0
    when p.np->>'all' = 'false'                            then 1
    when s.last_seen < now() - interval '60 days'          then 2
    else 9
  end,
  p.created_at desc;


-- ═══════════════════════════════════════════════════════════════
-- ② 요약 — 몇 명이 어느 상태인가
-- ═══════════════════════════════════════════════════════════════
with s as (
  select user_id, count(*) as devices, max(last_seen_at) as last_seen
  from public.push_subscriptions group by user_id
),
p as (
  select pr.id, coalesce(pr.notif_prefs,'{}'::jsonb) as np from public.profiles pr
),
j as (
  select p.id, coalesce(s.devices,0) as devices, s.last_seen, p.np from p left join s on s.user_id = p.id
)
select '✅ 받을 수 있음' as "상태", count(*) as "인원",
       '기기가 등록돼 있고 알림을 켜둔 회원' as "뜻"
  from j where devices > 0 and np->>'all' is distinct from 'false'
         and (last_seen is null or last_seen >= now() - interval '60 days')
union all
select '❌ 등록된 기기 없음', count(*),
       '알림 권한 미허용 · 웹에서 거부 · 옛 안드로이드 빌드(1010 이하)'
  from j where devices = 0
union all
select '⚠ 회원이 알림을 껐음', count(*),
       '개인 알림만 차단됨 — 운영 공지(role/all/topic)는 그대로 간다'
  from j where devices > 0 and np->>'all' = 'false'
union all
select '⚠ 60일 넘게 접속 없음', count(*),
       '토큰이 만료됐을 수 있다 — 실제 발송 때 무효면 자동 삭제된다'
  from j where devices > 0 and np->>'all' is distinct from 'false'
         and last_seen < now() - interval '60 days'
union all
select '— 전체 회원', count(*), '' from j;


-- ═══════════════════════════════════════════════════════════════
-- ③ 기기 상세 — 누가 어떤 기기로 등록해 뒀나
-- ═══════════════════════════════════════════════════════════════
--   같은 회원이 폰·PC 를 각각 등록하면 여러 줄이 된다. 정상이다.
--   role 은 '구독을 저장한 그 시점' 값이라 지금 역할과 다를 수 있다 —
--   send-push 는 그래서 role 과 profiles 를 함께 본다.
select
  coalesce(pr.display_name, '(이름없음)')             as "회원",
  case
    when ps.endpoint like 'fcm://%'  then 'Android 앱'
    when ps.endpoint like 'apns://%' then 'iOS 앱'
    else '웹 브라우저'
  end                                                 as "기기종류",
  coalesce(ps.device_label, '')                       as "기기이름",
  coalesce(ps.role, '')                               as "저장시역할",
  to_char(ps.created_at,  'MM-DD HH24:MI')            as "등록",
  to_char(ps.last_seen_at,'MM-DD HH24:MI')            as "마지막접속",
  case when ps.last_seen_at < now() - interval '60 days'
       then '⚠ 오래됨' else '' end                    as "비고",
  left(coalesce(ps.user_agent, ''), 48)               as "UA앞48"
from public.push_subscriptions ps
left join public.profiles pr on pr.id = ps.user_id
order by pr.display_name nulls last, ps.last_seen_at desc;
