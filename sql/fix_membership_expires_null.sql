-- ═══════════════════════════════════════════════════════════════
-- TAAM — M 등급인데 만료일이 비어 있는 회원 채우기 (2026-08-29)
-- ═══════════════════════════════════════════════════════════════
-- 무슨 일이 있었나
--   슈퍼어드민 「M 등급」 버튼(mmmSaveTier)이 membership_tier 만 쓰고
--   membership_expires_at 을 안 넣었다. 가입 경로 두 곳은 넣는데 이 버튼만
--   빠져 있었다.
--
--   그 결과가 단순한 표시 누락이 아니었다. _refreshUserGrade 는
--   `tier==='M' && expires && 미래` 일 때만 M 으로 치는데, 만료일이 비면
--   M 도 T 도 A 도 아닌 null 로 떨어진다. TIER_RANK 에서 null 은 0 이라
--   A(1) 보다도 아래다 — 등급 제한이 걸린 티켓을 하나도 못 산다.
--   승급해준 회원이 오히려 T 회원보다 못한 상태로 잠겨 있었다.
--
--   앱은 2026.08-29(BUILD -f)부터 두 곳을 고쳤다.
--     · mmmSaveTier 가 M 승급 시 만료일을 같이 쓴다
--     · 만료일이 없거나 지난 M 은 null 이 아니라 T 로 내려앉는다
--   그래서 이 파일을 안 돌려도 앱은 T 로는 돈다. 이 파일은 그 회원들을
--   원래대로 M 으로 되돌리는 것이다.
--
-- 만료일을 2027-12-31 로 넣는다 (사용자 지정, 2026-08-29).
--   가입일+365 로 하면 이창훈·이형주는 남은 기간이 9개월밖에 안 되는데,
--   실제로는 그동안 M 혜택을 못 쓰고 잠겨 있었다. 셋 다 같은 날로 맞춘다.
--
-- ⚠ 위에서 아래로 통째로 돌리는 파일이 아니다.
--   ①(확인) 을 보고, 대상이 맞으면 ②(적용) 의 /* */ 를 벗겨 돌린다.
--
-- 실행: Supabase SQL Editor
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 대상 확인 — M 인데 만료일이 비어 있는 회원 전부
-- ═══════════════════════════════════════════════════════════════
--   특정 3명만 찍지 않고 조건으로 잡는다. 같은 버튼으로 승급된 회원이
--   더 있으면 여기서 같이 드러난다.
select
  left(id::text, 8)                          as "회원ID앞8",
  coalesce(display_name, '(이름없음)')        as "회원",
  membership_tier                            as "등급",
  coalesce(email, '')                        as "이메일",
  to_char(created_at, 'YY-MM-DD')            as "가입일",
  '❌ 만료일 없음 — 등급 제한 티켓이 잠긴다'   as "지금상태",
  '2027-12-31 로 채운다'                      as "할 것"
from public.profiles
where membership_tier = 'M'
  and membership_expires_at is null
  and deleted_at is null
order by created_at;


-- ═══════════════════════════════════════════════════════════════
-- ② 적용 — ① 목록이 맞으면 아래 /* */ 를 벗기고 실행
-- ═══════════════════════════════════════════════════════════════
--   조건이 ① 과 완전히 같다. 이미 만료일이 있는 회원은 손대지 않으므로
--   두 번 돌려도 안전하다(두 번째는 0 rows).
--
--   23:59:59+09 = 한국시간 12월 31일 끝. 그날 하루는 M 으로 남는다.
/*
update public.profiles
   set membership_expires_at = '2027-12-31T23:59:59+09:00'
 where membership_tier = 'M'
   and membership_expires_at is null
   and deleted_at is null
returning left(id::text,8) as "회원ID앞8",
          display_name     as "회원",
          membership_expires_at as "새 만료일";
*/


-- ═══════════════════════════════════════════════════════════════
-- ③ 확인 — 0 rows 면 끝이다
-- ═══════════════════════════════════════════════════════════════
select count(*) as "아직 만료일 없는 M 회원"
from public.profiles
where membership_tier = 'M'
  and membership_expires_at is null
  and deleted_at is null;

-- 전체 M 회원의 만료일 현황
select
  coalesce(display_name, left(id::text,8))                    as "회원",
  case when membership_expires_at is null then '❌ 없음'
       else to_char(membership_expires_at at time zone 'Asia/Seoul', 'YYYY-MM-DD') end as "만료일",
  case when membership_expires_at is null then '등급 산출에서 T 로 내려앉는다'
       when membership_expires_at < now() then '⚠ 이미 지남 — T 로 동작 중'
       else '✅ 유효' end                                      as "판정"
from public.profiles
where membership_tier = 'M' and deleted_at is null
order by membership_expires_at nulls first;


-- ═══════════════════════════════════════════════════════════════
-- ④ 되돌리기 — 잘못 넣었을 때
-- ═══════════════════════════════════════════════════════════════
--   ② 를 돌리기 전 ① 결과를 캡처해 두면 그 회원만 골라 비울 수 있다.
/*
update public.profiles
   set membership_expires_at = null
 where id = '여기에-회원-UUID';
*/
