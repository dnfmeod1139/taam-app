-- ═════════════════════════════════════════════════
-- TAAM — 예치금 원장 전수 대사 · 2026-09-28  (읽기만 · 아무것도 바꾸지 않는다)
-- ═════════════════════════════════════════════════
-- 계기: 유수봉 회원 — 9/12 사이토 예치금을 넣었다가 다시 차감했는데 원장에 그 차감이 없다.
--       「잔액은 움직였는데 원장이 안 남는」 모양이 제일 나쁘다. 그 사람만이 아니라 전원을 본다.
--
-- 어떻게 잡나
--   원장의 balance_after 는 RPC 가 「바꾸기 전 총액 + 누적」으로 센 값이다. 그래서
--   balance_after − (원장 amount 누적합) 은 한 회원 안에서 **상수**여야 한다.
--   이 값이 어느 행에서 갑자기 바뀌면, 그 행 직전에 원장 없이 잔액이 움직인 것이다.
--   마지막 상수는 (지금 잔액 − 원장 합계) 와 같아야 한다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 결과는 한 표다 (sec 열로 구간을 가른다).
--   A·잔액   유수봉의 저장 잔액 vs 원장 합계 (주머니별)
--   B·원장   유수봉 원장 (9/1 이후) — note 에 ⚠ 가 있는 줄 직전에 원장 밖 이동이 있었다
--   C·티켓   유수봉 tickets (9/1 이후) — 원장에 결제 행이 있는지
--   D·전수   저장 잔액 ≠ 원장 합계인 회원 전원 (차이 큰 순)
--   E·체인   원장 밖 이동이 감지된 회원 전원 (어느 시각·얼마)
--   F·요약   건수
-- ═════════════════════════════════════════════════

with
target as (
  select p.id, coalesce(p.display_name, p.phone, p.email, '(이름없음)') as who
    from public.profiles p
   where p.display_name ilike '%유수봉%'
),
-- 회원별 저장 잔액
bal as (
  select p.id,
         coalesce(p.display_name, p.phone, p.email, '(이름없음)') as who,
         coalesce(p.membership_deposit_balance,0)::bigint as mem,
         coalesce(p.general_deposit_balance,0)::bigint    as gen,
         coalesce(p.membership_deposit_balance,0)::bigint + coalesce(p.general_deposit_balance,0)::bigint as tot
    from public.profiles p
),
-- 회원별 원장 합계 (주머니별)
led as (
  select d.user_id,
         coalesce(sum(d.amount) filter (where lower(d.deposit_type) = 'membership'), 0)::bigint as mem,
         coalesce(sum(d.amount) filter (where lower(d.deposit_type) = 'general'),    0)::bigint as gen,
         coalesce(sum(d.amount), 0)::bigint as tot,
         count(*) as n
    from public.deposit_transactions d
   group by d.user_id
),
-- 원장 행 + 누적합 + 오프셋(balance_after − 누적)
chain as (
  select d.id, d.user_id, d.created_at, d.deposit_type, d.change_type, d.amount, d.balance_after,
         d.description, d.metadata,
         sum(d.amount) over (partition by d.user_id order by d.created_at, d.id
                             rows between unbounded preceding and current row) as running,
         d.balance_after - sum(d.amount) over (partition by d.user_id order by d.created_at, d.id
                             rows between unbounded preceding and current row) as off
    from public.deposit_transactions d
   where d.balance_after is not null
),
chain2 as (
  select c.*,
         c.off - lag(c.off) over (partition by c.user_id order by c.created_at, c.id) as jump
    from chain c
),
-- 회원별 마지막 오프셋 (= 저장 잔액 − 원장 합계 여야 한다)
lastoff as (
  select distinct on (user_id) user_id, off as last_off
    from chain order by user_id, created_at desc, id desc
),

-- ── A · 유수봉 잔액 ──────────────────────────────────────────
a as (
  select 'A·잔액' as sec, b.who,
         '' as at,
         '저장 mem/gen/합계' as what,
         b.mem::text || ' / ' || b.gen::text || ' / ' || b.tot::text as amount,
         '원장 ' || coalesce(l.mem,0)::text || ' / ' || coalesce(l.gen,0)::text || ' / ' || coalesce(l.tot,0)::text as bal_after,
         '차이 ' || (b.tot - coalesce(l.tot,0))::text as running,
         case when b.tot = coalesce(l.tot,0) then '✅ 일치'
              else '❌ 저장 잔액 ≠ 원장 합계 — 원장 밖 이동 ' || (b.tot - coalesce(l.tot,0))::text end as note,
         0 as ord1, 0::bigint as ord2
    from target t join bal b on b.id = t.id left join led l on l.user_id = t.id
),
-- ── B · 유수봉 원장 (9/1 이후) ───────────────────────────────
b as (
  select 'B·원장' as sec, t.who,
         to_char(c.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') as at,
         coalesce(c.deposit_type,'?') || ' · ' || coalesce(c.change_type,'?')
           || coalesce(' · ' || left(c.description, 40), '')
           || coalesce(' · ' || left(c.metadata->>'purchase_id', 24), '') as what,
         c.amount::text as amount,
         c.balance_after::text as bal_after,
         c.running::text as running,
         case when c.jump is not null and c.jump <> 0
              then '⚠ 이 줄 직전에 원장 밖 이동 ' || c.jump::text
              else '' end as note,
         1 as ord1, extract(epoch from c.created_at)::bigint as ord2
    from target t join chain2 c on c.user_id = t.id
   where c.created_at >= '2026-09-01'
),
-- ── C · 유수봉 티켓 (9/1 이후) ───────────────────────────────
c as (
  select 'C·티켓' as sec, t.who,
         to_char(k.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') as at,
         coalesce(k.restaurant_name,'?') || ' · ' || coalesce(k.reservation_date,'?') || ' · ' || coalesce(k.status,'?')
           || ' · ' || coalesce(k.party_size::text,'?') || '명' as what,
         coalesce(k.price,0)::text as amount,
         coalesce(k.purchase_id,'') as bal_after,
         '' as running,
         case when k.status in ('cancelled','hold') then '(원장 대상 아님)'
              when exists (select 1 from public.deposit_transactions d
                            where d.user_id = t.id and d.change_type = 'ticket_purchase'
                              and d.metadata->>'purchase_id' = k.purchase_id)
                   then '✅ 결제 원장 있음'
              when k.purchase_id like 'MAN-%' or k.purchase_id like 'INV%' then '(수동·초대 — 원장 없음이 정상)'
              else '❌ 결제 원장 없음' end as note,
         2 as ord1, extract(epoch from k.created_at)::bigint as ord2
    from target t join public.tickets k on k.user_id = t.id
   where k.created_at >= '2026-09-01'
),
-- ── D · 전수: 저장 잔액 ≠ 원장 합계 ───────────────────────────
d as (
  select 'D·전수' as sec, b.who,
         '' as at,
         'mem ' || b.mem::text || '/' || coalesce(l.mem,0)::text
           || ' · gen ' || b.gen::text || '/' || coalesce(l.gen,0)::text
           || ' (저장/원장)' as what,
         b.tot::text as amount,
         coalesce(l.tot,0)::text as bal_after,
         (b.tot - coalesce(l.tot,0))::text as running,
         case when coalesce(l.n,0) = 0 then '원장 행 0건 (옛 잔액)'
              when exists (select 1 from chain2 j where j.user_id = b.id and j.jump is not null and j.jump <> 0)
                   then '❌ 원장 밖 이동 있음 — E 에서 시각·금액'
              when b.tot - coalesce(l.tot,0) = coalesce(o.last_off, 0) then '원장 이전 잔액 ' || coalesce(o.last_off,0)::text || ' (원장 시작 전 잔액 — 정상)'
              else '❌ 마지막 원장 뒤에 잔액이 또 움직임 (오프셋 ' || coalesce(o.last_off,0)::text || ' vs 차이 ' || (b.tot - coalesce(l.tot,0))::text || ')' end as note,
         3 as ord1, -abs(b.tot - coalesce(l.tot,0)) as ord2
    from bal b left join led l on l.user_id = b.id left join lastoff o on o.user_id = b.id
   where b.tot <> coalesce(l.tot,0)
),
-- ── E · 전수: 원장 밖 이동이 감지된 회원 ────────────────────────
e as (
  select 'E·체인' as sec, b.who,
         to_char(c.created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') as at,
         '이 행 직전에 ' || c.jump::text || ' 이동 · 다음 원장: ' || coalesce(c.change_type,'?')
           || coalesce(' · ' || left(c.description, 30), '') as what,
         c.jump::text as amount,
         c.balance_after::text as bal_after,
         c.running::text as running,
         '⚠ 원장 없이 잔액이 움직였다' as note,
         4 as ord1, extract(epoch from c.created_at)::bigint as ord2
    from chain2 c join bal b on b.id = c.user_id
   where c.jump is not null and c.jump <> 0
),
-- ── F · 요약 ────────────────────────────────────────────────
f as (
  select 'F·요약' as sec, '' as who, '' as at,
         '잔액≠원장 회원 ' || (select count(*) from d)::text
           || ' · 원장 밖 이동 ' || (select count(*) from e)::text || '건 ('
           || (select count(distinct who) from e)::text || '명)' as what,
         '' as amount, '' as bal_after, '' as running,
         case when (select count(*) from e) = 0 and (select count(*) from d where note like '❌%') = 0
              then '✅ 원장 밖 이동 없음' else '❌ 위 D·E 를 본다' end as note,
         5 as ord1, 0::bigint as ord2
)
select sec, who, at, what, amount, bal_after, running, note
  from (select * from a union all select * from b union all select * from c
        union all select * from d union all select * from e union all select * from f) x
 order by ord1, ord2, who;
