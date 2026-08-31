-- ═══════════════════════════════════════════════════════════════
-- TAAM — 파트너 어드민 매핑이 두 표로 갈라져 있다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제인가
--   「이 사람은 OO매장 어드민이다」를 저장하는 곳이 **둘**이다.
--
--     restaurant_admins   ← tickets RLS 가 본다 (앱에서 예약을 볼 수 있는가)
--                            sql/tickets_admin_rls.sql 의 is_restaurant_admin_of()
--     admin_grants        ← 알림이 본다 (notify-reservation · notify-purchase)
--                            그리고 앱의 _applyServerAdminGrant() 가 어드민 전환에 쓴다
--
--   한쪽에만 들어 있으면 이렇게 갈린다.
--
--     restaurant_admins 만  →  화면은 보이는데 **알림이 안 온다**
--     admin_grants 만       →  알림은 오는데 **화면이 비어 있다**
--
--   파트너십을 맺으면 둘 다 있어야 한다. 매장은 알림을 받고 앱을 열어
--   손님 정보를 봐야 하는데, 지금은 그 두 조건이 서로 다른 표에 달려 있다.
--
-- 이 파일은 **먼저 진단만** 한다. 고치는 SQL 은 아래 ② 에 주석으로 두었다 —
-- 누가 어느 표에 있는지 보고 나서 결정한다.
--
-- 실행: Supabase SQL Editor. ① 은 읽기만 한다.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 진단 — 누가 어느 표에 있나 (읽기만)
-- ═══════════════════════════════════════════════════════════════
with ra as (
  select user_id, restaurant_id::text as rest_id
    from public.restaurant_admins
),
ag as (
  select user_id, coalesce(rest_id, venue_id)::text as rest_id
    from public.admin_grants
   where coalesce(rest_id, venue_id) is not null
),
both as (
  select coalesce(ra.user_id, ag.user_id)  as user_id,
         coalesce(ra.rest_id, ag.rest_id)  as rest_id,
         (ra.user_id is not null)          as in_ra,
         (ag.user_id is not null)          as in_ag
    from ra full outer join ag
      on ra.user_id = ag.user_id and ra.rest_id = ag.rest_id
)
select coalesce(p.display_name, p.phone, b.user_id::text) as "사람",
       coalesce(r.name, b.rest_id)                        as "매장",
       case when b.in_ra then '✅' else '—' end            as "화면(restaurant_admins)",
       case when b.in_ag then '✅' else '—' end            as "알림(admin_grants)",
       case when b.in_ra and b.in_ag then '정상'
            when b.in_ra then '⚠ 알림이 안 간다'
            else            '⚠ 앱에서 예약이 안 보인다' end as "판정"
from both b
left join public.profiles    p on p.id = b.user_id
left join public.restaurants r on r.id::text = b.rest_id
order by 5 desc, 1;


-- ═══════════════════════════════════════════════════════════════
-- ② 맞추기 — 진단을 보고 나서 (⚠ 주석을 벗기고 실행)
-- ═══════════════════════════════════════════════════════════════
--   한쪽에만 있는 매핑을 반대쪽에도 넣는다. **지우지 않는다** —
--   지우면 누군가의 권한이 사라지고, 그건 되돌리기 어렵다.
--
--   ⚠ 두 표의 컬럼 이름이 다르다. 실행 전에 실제 컬럼을 한 번 본다:
--       select column_name, data_type from information_schema.columns
--        where table_schema='public' and table_name in ('restaurant_admins','admin_grants')
--        order by table_name, ordinal_position;
--     (2026-08-31 에 sale_open_at·member_id 타입을 짐작으로 짜다 두 번 깨뜨렸다)
/*
-- 알림만 있고 화면이 없는 사람 → restaurant_admins 에 추가
insert into public.restaurant_admins (user_id, restaurant_id)
select ag.user_id, ag.rest_id::uuid
  from (select user_id, coalesce(rest_id, venue_id)::text as rest_id
          from public.admin_grants
         where coalesce(rest_id, venue_id) is not null) ag
 where not exists (
   select 1 from public.restaurant_admins ra
    where ra.user_id = ag.user_id and ra.restaurant_id::text = ag.rest_id)
on conflict do nothing;

-- 화면만 있고 알림이 없는 사람 → admin_grants 에 추가
insert into public.admin_grants (user_id, rest_id)
select ra.user_id, ra.restaurant_id
  from public.restaurant_admins ra
 where not exists (
   select 1 from public.admin_grants ag
    where ag.user_id = ra.user_id
      and coalesce(ag.rest_id, ag.venue_id)::text = ra.restaurant_id::text)
on conflict do nothing;
*/


-- ═══════════════════════════════════════════════════════════════
-- 앞으로 — 표를 하나로 합칠 것인가
-- ═══════════════════════════════════════════════════════════════
--   지금은 둘 다 유지하고 ② 로 맞추는 게 안전하다. 합치려면
--   RLS 함수(is_restaurant_admin_of)와 Edge Function 두 개, 앱의
--   _applyServerAdminGrant() 를 동시에 바꿔야 하고, 그 사이 어긋나면
--   파트너가 자기 매장을 못 보거나 알림을 못 받는다.
--
--   합칠 때가 되면 admin_grants 쪽으로 모으는 게 낫다 —
--   venue_id/rest_id 를 둘 다 받아 예약(venue)과 티켓(restaurant)을
--   한 표로 덮을 수 있고, 앱이 이미 그걸 읽어 어드민 전환을 한다.
