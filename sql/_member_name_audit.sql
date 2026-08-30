-- ═══════════════════════════════════════════════════════════════
-- TAAM — 알림에 이름이 제대로 나가는가 (읽기 전용) (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 왜 만들었나
--   알림 문구에서 이름을 찾는 순서를 앱·서버 양쪽에서 이렇게 고쳤다.
--     ① profiles.display_name
--     ② (구매 알림) 그 구매에 적힌 tickets.buyer_name
--     ③ 연락처 뒷자리 → 「회원 1111」
--     ④ 그것도 없으면 「회원」
--
--   코드는 고쳤지만, ①이 비어 있는 회원은 여전히 ③이나 ④로 나간다.
--   즉 「전 회원에게 적용됐나」는 코드가 아니라 데이터를 봐야 안다.
--   이 파일이 회원별로 「지금 알림에 뭐라고 나갈지」를 그대로 계산해 보여준다.
--
-- ⚠ 아무것도 바꾸지 않는다. 조회만 한다.
--
-- ⚠ Supabase SQL Editor 는 마지막 문장의 결과만 보여준다.
--   블록을 하나씩 드래그해 선택하고 Run 할 것.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 한눈에 — 몇 명이 제대로 나가고 몇 명이 안 나가나
-- ═══════════════════════════════════════════════════════════════
select
  count(*)                                                          as "전체 회원",
  count(*) filter (where nullif(btrim(coalesce(display_name,'')),'') is not null)
                                                                    as "이름 있음 (정상)",
  count(*) filter (where nullif(btrim(coalesce(display_name,'')),'') is null
                     and nullif(btrim(coalesce(phone,'')),'') is not null)
                                                                    as "번호로 대체 (회원 1234)",
  count(*) filter (where nullif(btrim(coalesce(display_name,'')),'') is null
                     and nullif(btrim(coalesce(phone,'')),'') is null)
                                                                    as "⚠ 그냥 「회원」"
from public.profiles
where deleted_at is null;


-- ═══════════════════════════════════════════════════════════════
-- ② 회원별로 — 지금 알림에 뭐라고 나갈지 그대로 계산한다
-- ═══════════════════════════════════════════════════════════════
--   앱(_taamMyName · _taamWhoName)과 서버(notifyAdmins)의 순서를 그대로 옮겼다.
--   「알림에 나갈 이름」이 실제 이름이 아니면 손볼 대상이다.
with p as (
  select id, display_name, phone, email, membership_tier, created_at,
         nullif(btrim(coalesce(display_name,'')),'')                as nm,
         right(regexp_replace(coalesce(phone,''), '[^0-9]', '', 'g'), 4) as tail
  from public.profiles
  where deleted_at is null
)
select
  case when nm is not null then '정상'
       when tail <> ''     then '번호로 대체'
       else '⚠ 이름 없음' end                       as "상태",
  coalesce(nm, '(비어 있음)')                        as "저장된 이름",
  coalesce(nm, case when tail <> '' then '회원 ' || tail else '회원' end)
                                                     as "알림에 나갈 이름",
  coalesce(phone, '(없음)')                          as "연락처",
  coalesce(email, '(없음)')                          as "이메일",
  coalesce(membership_tier, '-')                     as "등급",
  (created_at at time zone 'UTC')::date              as "가입일"
from p
-- 손볼 대상을 위로
order by (nm is not null), (tail <> ''), created_at desc;


-- ═══════════════════════════════════════════════════════════════
-- ③ 구매 알림은 한 번 더 기회가 있다 — tickets.buyer_name
-- ═══════════════════════════════════════════════════════════════
--   프로필 이름이 비어도, 그 사람이 산 티켓에 이름이 적혀 있으면
--   구매 알림에는 그 이름이 나간다(서버 폴백 ②).
--   여기 「쓸 수 있는 이름」이 있는 회원은 그 값을 프로필에 옮겨주면
--   모든 알림에서 이름이 나온다.
with p as (
  select id, phone, nullif(btrim(coalesce(display_name,'')),'') as nm
  from public.profiles where deleted_at is null
)
select
  p.id                                               as "회원 id",
  coalesce(p.phone, '(없음)')                        as "연락처",
  (select string_agg(distinct nullif(btrim(k.buyer_name),''), ' / ')
     from public.tickets k
    where k.user_id::text = p.id::text
      and nullif(btrim(coalesce(k.buyer_name,'')),'') is not null)
                                                     as "구매에 적힌 이름",
  (select count(*) from public.tickets k
    where k.user_id::text = p.id::text
      and k.purchase_id not like 'PAYH-%')           as "구매 건수"
from p
where p.nm is null
order by 4 desc;

-- 「구매에 적힌 이름」이 있으면 그 값을 프로필에 넣으면 된다.
-- 슈퍼어드민 → 회원 탭에서 그 회원을 열어 이름을 입력하면 끝이다.
-- (여기서 직접 UPDATE 하지 않는다 — 어느 이름이 맞는지는 사람이 판단한다)


-- ═══════════════════════════════════════════════════════════════
-- ④ 최근 알림에 실제로 뭐라고 나갔나 (notifications 에 남은 이력)
-- ═══════════════════════════════════════════════════════════════
--   고친 뒤에 나간 알림 제목에 「회원이」·「회원님이」가 남아 있으면
--   아직 못 고친 경로가 있다는 뜻이다.
select
  (created_at at time zone 'UTC')                    as "시각",
  type                                               as "종류",
  title                                              as "제목",
  case when title ~ '회원(이|님이)\s' then '⚠ 이름 없이 나감' else '정상' end as "판정"
from public.notifications
order by created_at desc
limit 40;
