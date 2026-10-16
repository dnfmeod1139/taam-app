-- ═══════════════════════════════════════════════════════════════
-- 앱 이전 가입자의 실제 멤버십 가입일 — 운영 목록 그대로 (2026-10-15)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 붙여 RUN. 먼저 supabase/migrations/20261015_membership_joined.sql 이 돌아 있어야 한다.
-- 무엇을: 아래 목록의 이름을 profiles.display_name(공백 제거)과 맞춰 membership_joined_at 을 적는다.
--   · 탈퇴 처리(deleted_at)된 계정은 후보에서 뺀다. 이름이 정확히 한 명에게만 맞을 때만 적는다. 두 명 이상이면 ⚠ 로 건너뛴다(엉뚱한 사람에게 적지 않게) — 회원 원장에서 손으로 넣는다.
--   · 이미 다른 날짜가 적혀 있으면 이 목록의 날짜로 덮는다(목록이 기준). 같은 날짜면 그대로.
-- 결과 읽는 법: 한 줄에 한 이름. ✅ 적음 / ＝ 이미 같음 / ⚠ 여러 명 / ❌ 못 찾음. ❌·⚠ 는 회원 원장 헤더의 「실제 가입일」에서 직접 적는다.
-- ⚠ 「6/5일 남기욱」은 목록에서 5/4 와 5/6 사이에 있어 5/5 의 오타일 수 있다 — 적힌 대로 2026-06-05 로 넣었다. 다르면 원장에서 고친다.
-- ═══════════════════════════════════════════════════════════════
with want(name, d) as (values
  ('이지형', date '2024-12-05'),
  ('임태규', date '2024-12-11'),
  ('이지영', date '2024-12-15'),
  ('구자호', date '2024-12-20'),
  ('김지훈', date '2025-01-20'),
  ('유수봉', date '2025-07-16'),
  ('이윤석', date '2025-08-02'),
  ('이항비', date '2025-10-21'),
  ('김진현', date '2026-05-02'),
  ('이형주', date '2026-05-03'),
  ('송다솜', date '2026-05-04'),
  ('남기욱', date '2026-06-05'),
  ('박영준', date '2026-05-06'),
  ('이창훈', date '2026-05-18'),
  ('한문일', date '2026-05-20'),
  ('최정우', date '2026-10-14'),
  ('강지헌', date '2026-10-13'),
  ('권한진', date '2026-10-12'),
  ('장동진', date '2026-10-12'),
  ('김세민', date '2026-10-12'),
  ('안가람', date '2026-10-07'),
  ('김민혁', date '2026-10-02')
),
cand as (
  select w.name, w.d, p.id, p.display_name, p.created_at, p.membership_joined_at as cur
    from want w
    left join public.profiles p
      on regexp_replace(coalesce(p.display_name, ''), '\s', '', 'g') = w.name
     and p.deleted_at is null          -- 탈퇴 처리된 계정은 후보에서 뺀다 (같은 이름의 산 계정을 ⚠ 로 막지 않게 · 적대 리뷰 2026-10-15)
),
cnt as (
  select name, d, count(id) as n from cand group by name, d
),
upd as (
  update public.profiles p
     set membership_joined_at = c.d
    from cand c join cnt on cnt.name = c.name
   where cnt.n = 1 and p.id = c.id
     and p.membership_joined_at is distinct from c.d
  returning p.id, p.membership_joined_at
)
select
  w.name as 이름,
  to_char(w.d, 'YYYY-MM-DD') as 실제_가입일,
  case when cnt.n = 0 then '❌ 못 찾음 — 원장에서 직접'
       when cnt.n > 1 then '⚠ 같은 이름 ' || cnt.n || '명 — 원장에서 직접'
       when u.id is not null then '✅ 적음'
       else '＝ 이미 같음' end as 결과,
  coalesce(to_char(c.created_at at time zone 'Asia/Seoul', 'YYYY-MM-DD'), '') as 앱_가입일,
  coalesce(c.display_name, '') as 표시_이름
from want w
join cnt on cnt.name = w.name
left join cand c on c.name = w.name and cnt.n = 1
left join upd u on u.id = c.id
order by w.d, w.name;
