-- ═════════════════════════════════════════════════
-- TAAM — 예치금 원장 전수 대사 v2 · 2026-09-28  (읽기만 · 아무것도 바꾸지 않는다)
-- ═════════════════════════════════════════════════
-- v1 결과: 유수봉 저장 잔액 = 원장 합계 (일치). 9/12 사이토 부여·차감 둘 다 원장에 있다.
--          「원장 밖 이동」 52건이 떴는데 대부분 착시였다 — 두 가지 이유.
--   ① 같은 초에 쓰인 두 줄(주머니 보정 쌍·초대 결제 mem/gen 분할)은 id 순서가 실제 순서와 달라
--      +X / −X 로 튀어 보인다. 합치면 0 이다.
--   ② balance_after 가 어떤 행은 **총액**, 어떤 행은 **그 주머니 잔액**이다(작성 경로·시기가 다르다).
--      주머니→총액으로 바뀌는 자리에서 「다른 주머니 잔액」만큼 튄다. 돈이 움직인 게 아니다.
--
-- v2 는 ①을 같은 초끼리 묶어서 지우고, ②를 「기록 방식 차이」로 따로 표시한다.
-- 그래도 남는 ❌ 만 진짜 원장 밖 이동 후보다. 결정적 판정은 여전히 D(저장 잔액 vs 원장 합계)다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   A·잔액   유수봉 저장 잔액 vs 원장 합계
--   B·전체   유수봉 원장 **전부** (시작부터) — 100,631 이 언제 생겼는지 본다
--   D·전수   저장 잔액 ≠ 원장 합계인 회원 (진짜 불일치는 여기 ❌)
--   E2·체인  같은 초 묶음 + 기록 방식 라벨 뒤에 남는 이동 (❌ 만 진짜 후보)
--   G·요약   회원별: 저장−원장 차이 vs ❌ 이동 합계 — 둘이 같으면 설명이 닫힌다
--   H·함수   라이브 RPC 가 balance_after 를 총액으로 쓰는지 (함수 본문 한 줄)
--   S·슈퍼   Super Admin 8/15·8/21 전후 원장 (−1,000 의 출처)
-- ═════════════════════════════════════════════════

with recursive
target as (
  select p.id, coalesce(p.display_name, p.phone, p.email, '(이름없음)') as who
    from public.profiles p where p.display_name ilike '%유수봉%'
),
bal as (
  select p.id, coalesce(p.display_name, p.phone, p.email, '(이름없음)') as who,
         coalesce(p.membership_deposit_balance,0)::bigint as mem,
         coalesce(p.general_deposit_balance,0)::bigint    as gen,
         coalesce(p.membership_deposit_balance,0)::bigint + coalesce(p.general_deposit_balance,0)::bigint as tot
    from public.profiles p
),
led as (
  select d.user_id,
         coalesce(sum(d.amount) filter (where lower(d.deposit_type) = 'membership'), 0)::bigint as mem,
         coalesce(sum(d.amount) filter (where lower(d.deposit_type) = 'general'),    0)::bigint as gen,
         coalesce(sum(d.amount), 0)::bigint as tot, count(*) as n
    from public.deposit_transactions d group by d.user_id
),
-- 원장 행 + 누적(총액·주머니별)
r0 as (
  select d.id, d.user_id, d.created_at, lower(d.deposit_type) as pocket, d.change_type, d.amount, d.balance_after,
         d.description, d.metadata,
         date_trunc('second', d.created_at) as sec,
         sum(d.amount) over (partition by d.user_id order by d.created_at, d.id
                             rows between unbounded preceding and current row) as run_tot,
         sum(d.amount) over (partition by d.user_id, lower(d.deposit_type) order by d.created_at, d.id
                             rows between unbounded preceding and current row) as run_pocket,
         row_number() over (partition by d.user_id order by d.created_at, d.id) as rn
    from public.deposit_transactions d
),
-- 같은 초 묶음 — 한 묶음 안의 줄 순서(id)는 믿지 않는다. 묶음 끝의 원장 누적만 쓴다.
grp as (
  select user_id, sec, row_number() over (partition by user_id order by sec) as gi,
         grp_amt,
         -- 묶음 끝의 원장 누적 = 이 묶음까지의 amount 합 (묶음 안에 음수가 있으면 max(run_tot) 은 틀린다)
         sum(grp_amt) over (partition by user_id order by sec rows between unbounded preceding and current row) as run_tot_end,
         n_rows
    from (select user_id, sec, sum(amount) as grp_amt, count(*) as n_rows from r0 group by user_id, sec) q
),
-- 묶음 안 각 줄의 「오프셋 후보」 = balance_after − 묶음 끝 누적. 마지막에 쓰인 줄의 후보가 진짜 기준선이다.
cands as (
  select r.user_id, r.sec, r.id, r.pocket, r.change_type, r.description, r.balance_after, r.amount,
         r.balance_after - g.run_tot_end as cand,
         -- 이 줄 시점의 다른 주머니 원장 누적 (기록 방식 차이 판별용)
         g.run_tot_end - (select coalesce(sum(x.amount),0) from r0 x
                            where x.user_id = r.user_id and x.pocket = r.pocket and x.sec <= r.sec) as other_pocket
    from r0 r join grp g on g.user_id = r.user_id and g.sec = r.sec
   where r.balance_after is not null
),
-- 회원별로 묶음을 시간순으로 걸으며 기준선(오프셋)을 잇는다.
--   직전 기준선과 같은 후보가 있으면 그걸 고른다(이동 없음). 없으면 가장 가까운 후보를 고르고 그 차이가 「이동」이다.
walk as (
  select g.user_id, g.gi, g.sec,
         (select c.cand from cands c where c.user_id = g.user_id and c.sec = g.sec
           order by case when c.cand = (b.tot - coalesce(l.tot,0)) then 0 else 1 end, c.id desc limit 1)::numeric as off,
         0::numeric as jump, ''::text as kind, ''::text as what
    from grp g join bal b on b.id = g.user_id left join led l on l.user_id = g.user_id
   where g.gi = 1
  union all
  select g.user_id, g.gi, g.sec,
         coalesce((select c.cand from cands c where c.user_id = g.user_id and c.sec = g.sec and c.cand = w.off limit 1),
                  (select c.cand from cands c where c.user_id = g.user_id and c.sec = g.sec order by abs(c.cand - w.off), c.id desc limit 1),
                  w.off)::numeric as off,
         (coalesce((select c.cand from cands c where c.user_id = g.user_id and c.sec = g.sec and c.cand = w.off limit 1),
                  (select c.cand from cands c where c.user_id = g.user_id and c.sec = g.sec order by abs(c.cand - w.off), c.id desc limit 1),
                  w.off) - w.off)::numeric as jump,
         case when exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec and c.cand = w.off) then ''
              when exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec
                            and abs(c.cand - w.off) = abs(c.other_pocket)) then '기록방식'
              when exists (select 1 from cands c0 join cands c on c.user_id = g.user_id and c.sec = g.sec
                            where c0.user_id = g.user_id and c0.sec = w.sec and abs(c.cand - w.off) = abs(c0.other_pocket)) then '기록방식'
              else '❌' end as kind,
         (select coalesce(c.change_type,'?') || coalesce(' · ' || left(c.description, 34), '') from cands c
           where c.user_id = g.user_id and c.sec = g.sec order by c.id limit 1) as what
    from walk w join grp g on g.user_id = w.user_id and g.gi = w.gi + 1
),
jumps as (
  select w.user_id, w.sec, w.jump, w.kind, w.what, w.off
    from walk w where w.jump <> 0
),
lastoff as (
  select distinct on (user_id) user_id, off as last_off from walk order by user_id, gi desc
),

a as (
  select 'A·잔액' as sec, b.who, '' as at, '저장 mem/gen/합계' as what,
         b.mem::text || ' / ' || b.gen::text || ' / ' || b.tot::text as amount,
         '원장 ' || coalesce(l.mem,0)::text || ' / ' || coalesce(l.gen,0)::text || ' / ' || coalesce(l.tot,0)::text as bal_after,
         '차이 ' || (b.tot - coalesce(l.tot,0))::text as running,
         case when b.tot = coalesce(l.tot,0) then '✅ 일치' else '❌ 저장 잔액 ≠ 원장 합계' end as note,
         0 as o1, 0::bigint as o2
    from target t join bal b on b.id = t.id left join led l on l.user_id = t.id
),
b as (
  select 'B·전체' as sec, t.who,
         to_char(r.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') as at,
         coalesce(r.pocket,'?') || ' · ' || coalesce(r.change_type,'?') || coalesce(' · ' || left(r.description, 44), '') as what,
         r.amount::text as amount, r.balance_after::text as bal_after,
         '총 ' || r.run_tot::text || ' · 주머니 ' || r.run_pocket::text as running,
         case when r.balance_after = r.run_tot then '총액 기록'
              when r.balance_after = r.run_pocket then '주머니 기록'
              else '' end as note,
         1 as o1, r.rn as o2
    from target t join r0 r on r.user_id = t.id
),
d as (
  select 'D·전수' as sec, b.who, '' as at,
         'mem ' || b.mem::text || '/' || coalesce(l.mem,0)::text || ' · gen ' || b.gen::text || '/' || coalesce(l.gen,0)::text || ' (저장/원장)' as what,
         b.tot::text as amount, coalesce(l.tot,0)::text as bal_after, (b.tot - coalesce(l.tot,0))::text as running,
         case when coalesce(l.n,0) = 0 then '원장 행 0건 (원장 시작 전 잔액 — 정상)'
              when b.tot - coalesce(l.tot,0) = coalesce(o.last_off,0) and not exists (select 1 from jumps j where j.user_id = b.id and j.kind = '❌')
                   then '원장 시작 전 잔액 ' || coalesce(o.last_off,0)::text || ' (정상)'
              else '❌ 불일치 — E2·G 참조' end as note,
         3 as o1, -abs(b.tot - coalesce(l.tot,0)) as o2
    from bal b left join led l on l.user_id = b.id left join lastoff o on o.user_id = b.id
   where b.tot <> coalesce(l.tot,0)
),
e as (
  select 'E2·체인' as sec, b.who,
         to_char(j.sec at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') as at,
         '이 묶음 직전 ' || j.jump::text || ' · 묶음: ' || coalesce(j.what,'') as what,
         j.jump::text as amount, '' as bal_after, '기준선 ' || j.off::text as running,
         case when j.kind = '❌' then '❌ 원장 밖 이동 후보' else 'ⓘ 기록 방식 차이 (돈 안 움직임)' end as note,
         4 as o1, extract(epoch from j.sec)::bigint as o2
    from jumps j join bal b on b.id = j.user_id
),
firstoff as (
  select user_id, off as first_off from walk where gi = 1
),
g as (
  select 'G·요약' as sec, b.who, '' as at,
         '저장−원장 ' || (b.tot - coalesce(l.tot,0))::text
           || ' · 원장 시작 전 ' || coalesce(f.first_off,0)::text
           || ' · ❌이동 합 ' || coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '❌'),0)::text
           || ' (' || coalesce((select count(*) from jumps j where j.user_id = b.id and j.kind = '❌'),0)::text || '건)'
           || ' · ⓘ기록방식 ' || coalesce((select count(*) from jumps j where j.user_id = b.id and j.kind <> '❌'),0)::text || '건' as what,
         b.tot::text as amount, coalesce(l.tot,0)::text as bal_after, '' as running,
         case when b.tot = coalesce(l.tot,0) and not exists (select 1 from jumps j where j.user_id = b.id and j.kind = '❌') then '✅'
              when b.tot = coalesce(l.tot,0) then '✅ 잔액 일치 (❌는 중간에 상쇄됨 — 손실 없음)'
              when (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind = '❌') then '✅ 원장 시작 전 잔액 (정상)'
              when (b.tot - coalesce(l.tot,0)) - coalesce(f.first_off,0)
                   = coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '❌'),0)
                   then '⚠ 차이 = 원장 시작 전 잔액 + ❌이동 합 (원인 시각은 E2)'
              else '⚠ 차이가 설명되지 않음 — E2·B 를 같이 본다' end as note,
         5 as o1, -abs(b.tot - coalesce(l.tot,0)) as o2
    from bal b left join led l on l.user_id = b.id left join firstoff f on f.user_id = b.id
   where exists (select 1 from jumps j where j.user_id = b.id) or b.tot <> coalesce(l.tot,0)
),
h as (
  select 'H·함수' as sec, '' as who, '' as at,
         'taam_apply_deposit_delta 의 balance_after 시작값' as what,
         case when pg_get_functiondef(p.oid) like '%v_run := v_mem + v_gen%' then '총액(v_mem+v_gen)'
              when pg_get_functiondef(p.oid) like '%v_run%' then '다른 식 — 본문 확인'
              else 'v_run 없음' end as amount,
         '' as bal_after, '' as running,
         left(regexp_replace(coalesce(substring(pg_get_functiondef(p.oid) from 'v_run\s*:=\s*[^;]+'), '(v_run 대입 없음)'), '\s+', ' ', 'g'), 80) as note,
         6 as o1, 0::bigint as o2
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'taam_apply_deposit_delta'
),
s as (
  select 'S·슈퍼' as sec, b.who,
         to_char(r.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') as at,
         coalesce(r.pocket,'?') || ' · ' || coalesce(r.change_type,'?') || coalesce(' · ' || left(r.description, 44), '')
           || coalesce(' · ' || left(r.metadata->>'purchase_id', 20), '') as what,
         r.amount::text as amount, r.balance_after::text as bal_after,
         '총 ' || r.run_tot::text || ' · 주머니 ' || r.run_pocket::text as running,
         coalesce(left(r.metadata::text, 90), '') as note,
         7 as o1, extract(epoch from r.created_at)::bigint as o2
    from r0 r join bal b on b.id = r.user_id
   where b.who ilike 'Super Admin%' and r.created_at between '2026-08-14' and '2026-08-23'
)
select sec, who, at, what, amount, bal_after, running, note
  from (select * from a union all select * from b union all select * from d union all select * from e
        union all select * from g union all select * from h union all select * from s) x
 order by o1, o2, who;
