-- 연회비 대상 제외 — 운영 결정 2026-10-17 (김우 · 손진범 · 민경만 · 도성국 · 테스트1)
-- 어디서: Supabase SQL Editor, 20261017_membership_fee_exempt.sql 뒤에 RUN. 다섯 줄이 ✅ 켬 또는 ＝ 이미 켜짐 이어야 정상.
-- 이름이 정확히 한 명에게만 맞을 때만 켠다(공백 무시 · 탈퇴 제외). ⚠/❌ 는 회원 원장 연회비 탭의 「대상 제외」 버튼으로.
-- 되돌리기: 같은 탭의 「대상에 포함」 — 또는 update public.profiles set fee_exempt=false, fee_exempt_note=null where id=…
with ex(name) as (values ('김우'), ('손진범'), ('민경만'), ('도성국'), ('테스트1')),
c as (
  select e.name, p.id, p.fee_exempt from ex e
  left join public.profiles p on regexp_replace(coalesce(p.display_name, ''), '\s', '', 'g') = e.name and p.deleted_at is null
),
n as (select name, count(id) as cnt from c group by name),
u as (
  update public.profiles p set fee_exempt = true, fee_exempt_note = '2026-10-17 운영 결정 — 연회비 대상 제외'
    from c join n on n.name = c.name
   where n.cnt = 1 and p.id = c.id and coalesce(p.fee_exempt, false) = false
  returning p.id
)
select e.name as 회원,
       case when n.cnt = 0 then '❌ 못 찾음' when n.cnt > 1 then '⚠ 같은 이름 ' || n.cnt || '명' when u.id is not null then '✅ 켬' else '＝ 이미 켜짐' end as 결과
  from ex e join n on n.name = e.name
  left join c on c.name = e.name and n.cnt = 1
  left join u on u.id = c.id
 order by e.name;
