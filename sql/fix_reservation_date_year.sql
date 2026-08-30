-- ═══════════════════════════════════════════════════════════════
-- TAAM — 방문일에 연도 채우기 (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제인가
--   2026.08 이전에 만들어진 예약은 reservation_date 에 'MM.DD' 만 들어 있다.
--   연도를 같이 저장하기 시작한 것이 그때부터다(_tkFullDate).
--
--   연도가 없으면 이런 일이 생긴다.
--     · 재구매 제한이 판정을 못 한다 (_repurchase_audit.sql ③ 에 나온 행들)
--     · 앱이 「가장 가까운 해」로 추측한다 — 대개 맞지만 추측은 추측이다
--     · 어드민 캘린더·필터가 연도로 못 거른다
--
-- 연도는 추측이 아니라 「도출」할 수 있다
--   예약은 만들기 전에 존재할 수 없다. 즉 방문일은 created_at 이후다.
--   그래서 created_at 이후 처음 오는 그 월·일이 정답이다.
--     '04.22' 를 2026-04-21 에 만들었다 → 2026-04-22 (바로 다음 날)
--     '09.11' 을 2026-06-04 에 만들었다 → 2026-09-11
--     '01.25' 를 2026-07-18 에 만들었다 → 2027-01-25
--   ⚠ 당일 예약(만든 날 = 방문일)도 「이후」에 든다. 그래서 >= 로 본다.
--
-- ⚠ make_date(2026, 2, 30) 은 에러로 죽는다. 그래서 월초에서 (일-1) 만큼
--   더한 뒤 달이 그대로인지 확인하는 방식으로 유효한 날만 고른다.
--
-- ⚠ ① 을 먼저 돌려 눈으로 확인한 뒤 ② 를 돌린다. 돈·좌석이 걸린 행이다.
--
-- ⚠ Supabase SQL Editor 는 「마지막 문장의 결과」만 보여준다.
--   이 파일을 통째로 Run 하면 ③ 만 화면에 나오고 ① 미리보기는 안 보인다.
--   블록을 하나씩 드래그해서 선택한 뒤 Run 할 것 (선택 영역만 실행된다).
--
-- 실행: ① 선택 실행 → 눈으로 확인 → ② 의 /* */ 벗기고 선택 실행
--       → ②-2 (초대) 같은 방식 → ③ 선택 실행해서 0 확인
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 미리보기 — 무엇을 어떻게 바꿀 것인가 (아무것도 안 바꾼다)
-- ═══════════════════════════════════════════════════════════════
with bad as (
  select purchase_id, restaurant_name, buyer_name, reservation_date, status,
         (created_at at time zone 'UTC')::date as cdate,
         (regexp_match(reservation_date, '^(\d{1,2})[.\-](\d{1,2})$'))[1]::int as mm,
         (regexp_match(reservation_date, '^(\d{1,2})[.\-](\d{1,2})$'))[2]::int as dd
  from public.tickets
  where reservation_date ~ '^\d{1,2}[.\-]\d{1,2}$'      -- 연도가 없는 것만
    and purchase_id not like 'PAYH-%'                    -- 결제 전 홀드는 예약이 아니다
    and created_at is not null
),
-- 만든 해와 그 다음 해로 각각 만들어 본다.
--   ⚠ 유효성은 「고른 해」로 따져야 한다. 만든 해로만 따지면 2.29 예약이
--     만든 해가 평년이라는 이유로 통째로 빠진다(다음 해가 윤년일 수 있다).
--   월초 + (일-1) 로 만들고 달이 그대로인지 본다 — make_date(y,2,30) 은
--   에러로 죽지만 이 방식은 3월로 넘어갈 뿐이라 조용히 걸러낼 수 있다.
cand as (
  select b.*,
         (make_date(extract(year from b.cdate)::int,     b.mm, 1) + (b.dd - 1)) as c0,
         (make_date(extract(year from b.cdate)::int + 1, b.mm, 1) + (b.dd - 1)) as c1
  from bad b
  where b.mm between 1 and 12 and b.dd between 1 and 31
),
guessed as (
  select c.*,
         case when extract(month from c.c0)::int = c.mm and c.c0 >= c.cdate then c.c0
              when extract(month from c.c1)::int = c.mm and c.c1 >= c.cdate then c.c1
              else null end as vd
  from cand c
)
select purchase_id                                   as "구매번호",
       restaurant_name                               as "매장",
       coalesce(nullif(buyer_name,''), '(이름없음)')  as "회원",
       status                                        as "상태",
       cdate                                         as "만든 날",
       reservation_date                              as "지금 (연도 없음)",
       to_char(vd, 'YYYY.MM.DD')                     as "바꿀 값",
       (vd - cdate)                                  as "만든 날로부터(일)"
from guessed
where vd is not null
order by cdate;

-- 「만든 날로부터(일)」가 음수면 규칙이 깨진 것이다. 그런 행이 있으면 ② 를
-- 돌리지 말고 먼저 알려달라 — 도출이 아니라 추측이 되기 때문이다.
-- ① 결과를 복사해 두면 언제든 되돌릴 수 있다 (바꾸기 전 값이 그 표에 있다).


-- ═══════════════════════════════════════════════════════════════
-- ② 실제로 채운다  ← ① 을 확인한 뒤에만
-- ═══════════════════════════════════════════════════════════════
--   아래 블록의 /* */ 를 벗겨서 실행한다.
/*
with bad as (
  select purchase_id, reservation_date,
         (created_at at time zone 'UTC')::date as cdate,
         (regexp_match(reservation_date, '^(\d{1,2})[.\-](\d{1,2})$'))[1]::int as mm,
         (regexp_match(reservation_date, '^(\d{1,2})[.\-](\d{1,2})$'))[2]::int as dd
  from public.tickets
  where reservation_date ~ '^\d{1,2}[.\-]\d{1,2}$'
    and purchase_id not like 'PAYH-%'
    and created_at is not null
),
cand as (
  select b.*,
         (make_date(extract(year from b.cdate)::int,     b.mm, 1) + (b.dd - 1)) as c0,
         (make_date(extract(year from b.cdate)::int + 1, b.mm, 1) + (b.dd - 1)) as c1
  from bad b
  where b.mm between 1 and 12 and b.dd between 1 and 31
),
guessed as (
  select c.purchase_id,
         case when extract(month from c.c0)::int = c.mm and c.c0 >= c.cdate then c.c0
              when extract(month from c.c1)::int = c.mm and c.c1 >= c.cdate then c.c1
              else null end as vd
  from cand c
)
update public.tickets k
   set reservation_date = to_char(g.vd, 'YYYY.MM.DD')
  from guessed g
 where k.purchase_id = g.purchase_id and g.vd is not null;
*/


-- ═══════════════════════════════════════════════════════════════
-- ②-2 초대(reservation_invites)도 같은 문제가 있다
-- ═══════════════════════════════════════════════════════════════
--   초대는 별도 테이블이고 visit_date 를 따로 갖는다. 앱은 이미 연도를
--   붙여 저장하지만(2026.08 이후), 그 전 초대에는 'MM.DD' 만 있다.
--   먼저 미리보기:
with bad as (
  select id, restaurant_name, visit_date, status,
         (created_at at time zone 'UTC')::date as cdate,
         (regexp_match(visit_date, '^(\d{1,2})[.\-](\d{1,2})$'))[1]::int as mm,
         (regexp_match(visit_date, '^(\d{1,2})[.\-](\d{1,2})$'))[2]::int as dd
  from public.reservation_invites
  where visit_date ~ '^\d{1,2}[.\-]\d{1,2}$' and created_at is not null
),
cand as (
  select b.*,
         (make_date(extract(year from b.cdate)::int,     b.mm, 1) + (b.dd - 1)) as c0,
         (make_date(extract(year from b.cdate)::int + 1, b.mm, 1) + (b.dd - 1)) as c1
  from bad b where b.mm between 1 and 12 and b.dd between 1 and 31
)
select id                                as "초대 id",
       restaurant_name                   as "매장",
       status                            as "상태",
       cdate                             as "만든 날",
       visit_date                        as "지금 (연도 없음)",
       to_char(case when extract(month from c0)::int = mm and c0 >= cdate then c0
                    else c1 end, 'YYYY.MM.DD')  as "바꿀 값"
from cand
where (extract(month from c0)::int = mm and c0 >= cdate)
   or (extract(month from c1)::int = mm and c1 >= cdate)
order by cdate;

--   확인했으면 아래를 벗겨 실행:
/*
with bad as (
  select id, visit_date, (created_at at time zone 'UTC')::date as cdate,
         (regexp_match(visit_date, '^(\d{1,2})[.\-](\d{1,2})$'))[1]::int as mm,
         (regexp_match(visit_date, '^(\d{1,2})[.\-](\d{1,2})$'))[2]::int as dd
  from public.reservation_invites
  where visit_date ~ '^\d{1,2}[.\-]\d{1,2}$' and created_at is not null
),
cand as (
  select b.*,
         (make_date(extract(year from b.cdate)::int,     b.mm, 1) + (b.dd - 1)) as c0,
         (make_date(extract(year from b.cdate)::int + 1, b.mm, 1) + (b.dd - 1)) as c1
  from bad b where b.mm between 1 and 12 and b.dd between 1 and 31
)
update public.reservation_invites v
   set visit_date = to_char(case when extract(month from c.c0)::int = c.mm and c.c0 >= c.cdate then c.c0
                                 else c.c1 end, 'YYYY.MM.DD')
  from cand c
 where v.id = c.id
   and ((extract(month from c.c0)::int = c.mm and c.c0 >= c.cdate)
     or (extract(month from c.c1)::int = c.mm and c.c1 >= c.cdate));
*/


-- ═══════════════════════════════════════════════════════════════
-- ③ 확인 — 연도 없는 행이 0건이어야 한다
-- ═══════════════════════════════════════════════════════════════
select '티켓' as "대상",
       count(*) filter (where reservation_date ~ '^\d{1,2}[.\-]\d{1,2}$')            as "연도 없음",
       count(*) filter (where reservation_date ~ '^\d{4}[.\-]\d{1,2}[.\-]\d{1,2}$')  as "연도 있음",
       count(*) filter (where reservation_date is null)                              as "방문일 없음",
       count(*)                                                                      as "전체"
from public.tickets
where purchase_id not like 'PAYH-%'
union all
select '초대',
       count(*) filter (where visit_date ~ '^\d{1,2}[.\-]\d{1,2}$'),
       count(*) filter (where visit_date ~ '^\d{4}[.\-]\d{1,2}[.\-]\d{1,2}$'),
       count(*) filter (where visit_date is null),
       count(*)
from public.reservation_invites;
