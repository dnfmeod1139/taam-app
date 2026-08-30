-- ═══════════════════════════════════════════════════════════════
-- TAAM — 재구매 제한을 빠져나간 구매 찾기 (읽기 전용) (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 왜 만들었나
--   앱의 재구매 제한이 연도를 빠뜨리고 판정해, 같은 매장 티켓을 제한
--   기간 안에 두 번 살 수 있었다. 예: 2027.1.23 을 2026.1.23 으로 읽어
--   2027.4.17 과의 간격이 84일이 아니라 449일이 되어 90일 제한을 통과.
--
--   앱은 고쳤지만 이미 들어온 구매는 그대로 남아 있다. 누가 걸렸는지
--   여기서 전부 찾는다.
--
-- ⚠ 이 파일은 아무것도 바꾸지 않는다. 조회만 한다.
--   무엇을 취소·환불할지는 사람이 판단한다 — 돈이 걸린 자리라 자동으로
--   손대지 않는다.
--
-- ⚠ restaurants.id 는 uuid, tickets.restaurant_id 는 text 다. 그냥 join 하면
--   'operator does not exist: uuid = text' 로 죽는다. 양쪽을 ::text 로 맞춘다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 매장별 재구매 제한 설정 — 먼저 무엇이 걸려 있는지 본다
-- ═══════════════════════════════════════════════════════════════
select id                                        as "매장 id",
       name                                      as "매장",
       coalesce(repurchase_day, 0)               as "재구매 제한(일)",
       case when coalesce(repurchase_day,0) = 0 then '제한 없음' else '제한 있음' end as "상태"
from public.restaurants
order by coalesce(repurchase_day,0) desc, name;


-- ═══════════════════════════════════════════════════════════════
-- ② 제한을 빠져나간 구매 쌍
-- ═══════════════════════════════════════════════════════════════
--   방문일 문자열은 'YYYY.M.D' 로 저장된다(_tkFullDate). 'YYYY-MM-DD' 로
--   들어온 것도 있어 둘 다 받는다. 형식이 다르면 null 로 두고 건너뛴다 —
--   못 읽는 값을 억지로 날짜로 만들면 없는 위반이 생긴다.
with t as (
  select k.purchase_id, k.user_id, k.restaurant_id, k.restaurant_name,
         k.buyer_name, k.party_size, k.price, k.status, k.reservation_date,
         case when k.reservation_date ~ '^\d{4}[.\-]\d{1,2}[.\-]\d{1,2}$'
              then to_date(regexp_replace(k.reservation_date, '[.\-]', '.', 'g'), 'YYYY.MM.DD')
              else null end as vd
  from public.tickets k
  where k.purchase_id not like 'PAYH-%'            -- 결제 전 홀드는 구매가 아니다
    and k.status not in ('cancelled','canceled')   -- 취소한 예약은 방문이 아니다
),
pairs as (
  select a.user_id,
         coalesce(a.buyer_name, b.buyer_name)        as buyer_name,
         a.restaurant_name,
         r.repurchase_day,
         a.purchase_id  as pid_a, a.reservation_date as vd_a, a.price as price_a,
         b.purchase_id  as pid_b, b.reservation_date as vd_b, b.price as price_b,
         abs(a.vd - b.vd)                            as gap
  from t a
  join t b
    on a.user_id = b.user_id
   and a.restaurant_id = b.restaurant_id
   and a.purchase_id < b.purchase_id                 -- 같은 쌍을 두 번 세지 않는다
  join public.restaurants r on r.id::text = a.restaurant_id::text
  where a.vd is not null and b.vd is not null
    and coalesce(r.repurchase_day, 0) > 0
    and abs(a.vd - b.vd) < r.repurchase_day
)
select buyer_name                        as "회원",
       restaurant_name                   as "매장",
       repurchase_day                    as "제한(일)",
       gap                               as "실제 간격(일)",
       repurchase_day - gap              as "초과(일)",
       vd_a                              as "방문일 ①",
       vd_b                              as "방문일 ②",
       pid_a                             as "구매번호 ①",
       pid_b                             as "구매번호 ②",
       user_id                           as "회원 id"
from pairs
order by (repurchase_day - gap) desc, buyer_name;

-- 0건이면 빠져나간 구매가 없다는 뜻이다.


-- ═══════════════════════════════════════════════════════════════
-- ③ 방문일을 못 읽은 행 — ②가 건너뛴 것들
-- ═══════════════════════════════════════════════════════════════
--   ②가 「0건」이라고 해서 안심하면 안 된다. 형식이 이상해 판정에서
--   빠진 행이 여기 나온다. 있으면 그 행부터 손으로 확인한다.
select purchase_id          as "구매번호",
       restaurant_name      as "매장",
       buyer_name           as "회원",
       reservation_date     as "방문일 (읽을 수 없음)",
       status               as "상태"
from public.tickets
where purchase_id not like 'PAYH-%'
  and status not in ('cancelled','canceled')
  and (reservation_date is null
       or reservation_date !~ '^\d{4}[.\-]\d{1,2}[.\-]\d{1,2}$')
order by created_at desc
limit 50;


-- ═══════════════════════════════════════════════════════════════
-- ④ 한 회원만 보기 — 이름을 넣어 확인
-- ═══════════════════════════════════════════════════════════════
--   아래 '구자호' 를 보고 싶은 이름으로 바꿔 실행한다.
select k.reservation_date   as "방문일",
       k.restaurant_name    as "매장",
       k.party_size         as "인원",
       k.price              as "금액",
       k.status             as "상태",
       k.purchase_id        as "구매번호",
       coalesce(r.repurchase_day, 0) as "그 매장 제한(일)"
from public.tickets k
left join public.restaurants r on r.id::text = k.restaurant_id::text
where k.buyer_name = '구자호'
  and k.purchase_id not like 'PAYH-%'
order by k.reservation_date;
