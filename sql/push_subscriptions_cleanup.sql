-- ═══════════════════════════════════════════════════════════════
-- 푸시 구독 정리 (2026-08-27)
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   같은 기기가 재설치·재등록할 때마다 행이 새로 쌓인다. 죽은 토큰을 지우는
--   조건이 404/410 뿐이라(FCM 은 400 INVALID_ARGUMENT 로도 알려준다) 옛 행이
--   영원히 남는다. 실제로 한 테스트 계정에 5월부터 쌓인 안드로이드 구독이 11건
--   있었다 — 발송할 때마다 11번 시도하고 대부분 실패한다.
--   실패 수가 부풀면 '진짜 실패' 를 알아볼 수 없다.
--
--   ⚠ user_agent='capacitor-web' 인 행은 특히 위험하다.
--     플랫폼 감지가 'web' 으로 떨어진 순간에 저장된 것이라 엔드포인트 스킴이
--     틀어져 있을 수 있다(iOS 토큰이 fcm:// 로 박힘). 그 기기는 구독이 있어
--     보이지만 알림은 영영 못 받는다. 지우면 다음 실행에 올바로 다시 등록된다.
--
-- 실행: ① 미리보기 → 눈으로 확인 → ② 정리
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 미리보기 — 무엇이 지워지는지
-- ═══════════════════════════════════════════════════════════════
with ranked as (
  select
    s.*,
    coalesce(p.display_name, left(s.user_id::text, 8)) as who,
    case
      when s.endpoint like 'apns://%' then 'ios'
      when s.endpoint like 'fcm://%'  then 'android'
      else 'web'
    end as kind,
    row_number() over (
      partition by s.user_id,
        case when s.endpoint like 'apns://%' then 'ios'
             when s.endpoint like 'fcm://%'  then 'android'
             else 'web' end
      order by coalesce(s.last_seen_at, s.created_at) desc
    ) as rn
  from public.push_subscriptions s
  left join public.profiles p on p.id = s.user_id
)
select
  who                                         as "회원",
  kind                                        as "종류",
  user_agent                                  as "UA",
  coalesce(last_seen_at, created_at)          as "마지막_갱신",
  rn                                          as "최신순위",
  case
    when user_agent = 'capacitor-web' then '🗑 플랫폼 미확정 — 스킴 틀어졌을 수 있음'
    when rn > 1                      then '🗑 같은 기기의 옛 구독'
    when coalesce(last_seen_at, created_at) < now() - interval '90 days'
                                     then '🗑 90일 이상 미갱신'
    else '✅ 유지'
  end                                         as "판정"
from ranked
order by who, kind, rn;


-- ═══════════════════════════════════════════════════════════════
-- ② 정리 — ① 을 확인한 뒤에 실행
-- ═══════════════════════════════════════════════════════════════
-- 지우는 대상
--   · user_agent='capacitor-web'  (스킴이 틀어졌을 수 있는 행)
--   · 같은 회원 · 같은 종류에서 최신 1건을 뺀 나머지
--   · 90일 이상 갱신 안 된 행
-- 남기는 것
--   · 회원×종류별 가장 최근 구독 1건
--
-- 지워도 안전하다 — 회원이 앱/웹을 다시 열면 부팅 시 자동으로 재등록된다.
with ranked as (
  select
    s.id, s.user_agent, s.last_seen_at, s.created_at,
    row_number() over (
      partition by s.user_id,
        case when s.endpoint like 'apns://%' then 'ios'
             when s.endpoint like 'fcm://%'  then 'android'
             else 'web' end
      order by coalesce(s.last_seen_at, s.created_at) desc
    ) as rn
  from public.push_subscriptions s
)
delete from public.push_subscriptions t
using ranked r
where t.id = r.id
  and (
        r.user_agent = 'capacitor-web'
     or r.rn > 1
     or coalesce(r.last_seen_at, r.created_at) < now() - interval '90 days'
  );


-- ═══════════════════════════════════════════════════════════════
-- ③ 확인 — 정리 후 사람별 구독 현황
-- ═══════════════════════════════════════════════════════════════
select
  coalesce(p.display_name, left(p.id::text, 8))       as "회원",
  p.role                                              as "역할",
  count(s.id)                                         as "구독수",
  count(*) filter (where s.endpoint like 'apns://%')  as "iOS앱",
  count(*) filter (where s.endpoint like 'fcm://%')   as "안드앱",
  count(*) filter (where s.endpoint not like 'apns://%'
                     and s.endpoint not like 'fcm://%') as "웹"
from public.profiles p
left join public.push_subscriptions s on s.user_id = p.id
group by p.id, p.display_name, p.role
having count(s.id) > 0
order by count(s.id) desc;
