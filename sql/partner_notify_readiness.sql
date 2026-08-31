-- ═══════════════════════════════════════════════════════════════
-- TAAM — 파트너 알림이 실제로 나갈 준비가 됐나 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 왜 이걸 먼저 보나
--   notify-purchase 를 배포했지만, 이 함수가 알림을 보내려면 매장마다
--   조건이 넷 다 맞아야 한다. 하나라도 비면 조용히 skip 된다 —
--   결제 테스트를 해봐야 아는 게 아니라, 여기서 미리 다 보인다.
--
--     admin_grants        → 앱 푸시 수신자 (없으면 admins:0, 아무도 못 받는다)
--     restaurant_admins   → 파트너가 앱에서 그 예약을 볼 수 있는가 (tickets RLS)
--     notify_phone        → 알림톡 수신처
--     notify_line_id      → LINE 수신처
--
--   ⚠ 앞의 둘이 **다른 표**다. 한쪽만 있으면 이렇게 갈린다.
--       admin_grants 만      → 알림은 오는데 앱을 열면 예약이 비어 있다
--       restaurant_admins 만 → 화면은 보이는데 알림이 안 온다
--
-- 실행: Supabase SQL Editor. **읽기만 한다** — 아무것도 안 바꾼다.
--
-- ⚠ 「column ... does not exist」가 나오면 그 표의 준비 SQL 을 먼저 돌린다:
--     notify_phone / notify_line_id  →  sql/venue_notify_fields.sql
--     restaurant_admins              →  sql/tickets_admin_rls.sql
-- ═══════════════════════════════════════════════════════════════

with r as (
  select id::text as rid, name from public.restaurants
),
ra as (
  select restaurant_id::text as rid, count(*) as n
    from public.restaurant_admins
   group by 1
),
ag as (
  select coalesce(rest_id, venue_id)::text as rid, count(*) as n
    from public.admin_grants
   where coalesce(rest_id, venue_id) is not null
   group by 1
),
vp as (
  select venue_id::text as rid,
         nullif(btrim(coalesce(notify_phone, '')), '')   as phone,
         nullif(btrim(coalesce(notify_line_id, '')), '') as line
    from public.venue_partners
),
all_rid as (
  select rid from ra
  union
  select rid from ag
  union
  select rid from vp
)
select coalesce(r.name, x.rid)                                as "매장",
       coalesce(ag.n, 0)                                      as "푸시(admin_grants)",
       coalesce(ra.n, 0)                                      as "화면(restaurant_admins)",
       case when vp.phone is null then '—' else '설정됨' end  as "알림톡",
       case when vp.line  is null then '—' else '설정됨' end  as "LINE",
       case
         when coalesce(ag.n, 0) = 0 and coalesce(ra.n, 0) = 0
           then '연결 안 됨 — 파트너 계정을 먼저 붙인다'
         when coalesce(ag.n, 0) = 0
           then '⚠ admins:0 — 결제해도 아무도 알림을 못 받는다'
         when coalesce(ra.n, 0) = 0
           then '⚠ 알림은 가는데 앱에서 예약이 안 보인다'
         when vp.phone is null and vp.line is null
           then '앱 푸시만 나간다 (알림톡·LINE 수신처 없음)'
         else '정상'
       end                                                    as "판정"
  from all_rid x
  left join r  on r.rid  = x.rid
  left join ra on ra.rid = x.rid
  left join ag on ag.rid = x.rid
  left join vp on vp.rid = x.rid
 order by 6, 1;
