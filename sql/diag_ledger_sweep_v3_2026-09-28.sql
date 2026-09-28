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
         coalesce(sum(d.amount), 0)::bigint as tot, count(*) as n,
         count(*) filter (where lower(d.deposit_type) = 'membership') as n_mem,
         count(*) filter (where lower(d.deposit_type) = 'general')    as n_gen
    from public.deposit_transactions d group by d.user_id
),
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
-- [PATCH-1] 같은 초 묶음 안의 「사슬」 정보. 줄 A 의 balance_after 를 「직전 잔액(balance_after−amount)」으로 삼는 줄 B 가
--           같은 묶음에 있으면 A 는 B 보다 먼저 쓰인 줄이다. 아무도 이어받지 않는 줄이 묶음의 「끝」이다 (id 순서를 믿지 않아도 된다).
r1 as (
  select r.*,
         not exists (select 1 from r0 y where y.user_id = r.user_id and y.sec = r.sec and y.id <> r.id
                       and y.balance_after - y.amount = r.balance_after) as is_final,
         (select coalesce(sum(x.amount),0) from r0 x
           where x.user_id = r.user_id and x.pocket = r.pocket and x.sec <= r.sec) as pocket_end
    from r0 r
),
grp as (
  select user_id, sec, row_number() over (partition by user_id order by sec) as gi,
         grp_amt,
         sum(grp_amt) over (partition by user_id order by sec rows between unbounded preceding and current row) as run_tot_end,
         n_rows,
         -- [PATCH-2] 묶음 안 불일치: 「끝」이 주머니 수보다 많다 → 주머니별 사슬(주머니 기록 쌍)로도 설명이 안 된다 → 묶음 안에서 잔액이 튀었다
         (n_rows > 1 and n_final > n_pockets) as bad,
         n_final,
         -- id 순으로 읽었을 때의 튄 금액 추정 = (마지막 줄이 말하는 묶음 시작 잔액) − (첫 줄의 직전 잔액)
         (last_b - grp_amt) - first_prior as bad_gap,
         what
    from (select user_id, sec, sum(amount) as grp_amt, count(*) as n_rows,
                 count(*) filter (where is_final and balance_after is not null) as n_final,
                 count(distinct pocket) as n_pockets,
                 (array_agg(balance_after - amount order by id))[1] as first_prior,
                 (array_agg(balance_after order by id desc))[1] as last_b,
                 (array_agg(coalesce(change_type,'?') || coalesce(' · ' || left(description, 34), '') order by id))[1] as what
            from r1 group by user_id, sec) q
),
cands as (
  select r.user_id, r.sec, r.id, r.pocket, r.change_type, r.description, r.balance_after, r.amount,
         r.balance_after - g.run_tot_end as cand,
         g.run_tot_end - r.pocket_end as other_pocket,
         r.pocket_end, r.is_final
    from r1 r join grp g on g.user_id = r.user_id and g.sec = r.sec
   where r.balance_after is not null
),
walk as (
  -- [PATCH-4] 첫 묶음: 끝 줄의 후보를 먼저 고른다 (끝이 아닌 줄의 후보가 「저장−원장」과 우연히 같아도 뽑히지 않는다)
  select g.user_id, g.gi, g.sec,
         pk.off, pk.off as first_off,
         0::numeric as jump, ''::text as kind, g.what, g.bad, g.bad_gap, (g.n_final > 1) as firstbad
    from grp g join bal b on b.id = g.user_id left join led l on l.user_id = g.user_id
    cross join lateral (
      select (select c.cand from cands c where c.user_id = g.user_id and c.sec = g.sec
               order by c.is_final desc, case when c.cand = (b.tot - coalesce(l.tot,0)) then 0 else 1 end, c.id desc limit 1)::numeric as off) pk
   where g.gi = 1
  union all
  select g.user_id, g.gi, g.sec,
         pk.off_new, w.first_off,
         (pk.off_new - w.off) as jump, pk.kind,
         g.what, g.bad, g.bad_gap, w.firstbad
    from walk w join grp g on g.user_id = w.user_id and g.gi = w.gi + 1
    join bal b on b.id = g.user_id left join led l on l.user_id = g.user_id
    cross join lateral (
      select case when keep then w.off
                  when back then w.first_off
                  when pocketed then w.off
                  else coalesce(nearest, w.off) end as off_new,
             case when keep then ''
                  when back then '❌'
                  when pocketed then '기록방식'
                  when nearest is null or nearest = w.off then ''
                  when ret then '기록방식'
                  when latebase then '기준선?'
                  else '❌' end as kind
        from (select
          -- ① 끝 줄 후보가 직전 기준선과 같다 → 이동 없음
          exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec and c.is_final and c.cand = w.off) as keep,
          -- ② 끝 줄 후보가 첫 기준선으로 되돌아온다 → 앞의 ❌ 이동이 되돌려진 것. 주머니 기록보다 먼저 본다 (C6 형)
          (w.off <> w.first_off and exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec and c.is_final and c.cand = w.first_off)) as back,
          -- [PATCH-6] ③ 주머니 기록: 끝 줄의 balance_after − 그 주머니 원장 누적 = 그 주머니의 원장 시작 전 잔액이어야 하고,
          --    그 값은 0 이상 · 총 기준선(w.off) 이하여야 한다 (다른 주머니 몫을 넘을 수 없다). 저장 잔액을 근거로 삼지 않는다.
          --    돈이 안 움직였으니 기준선을 옮기지 않는다.
          exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec and c.is_final
                    and c.balance_after - c.pocket_end between 0 and w.off) as pocketed,
          -- ④ 첫 묶음이 주머니 기록 쌍이라 기준선이 잘못 잡혔을 때, 바로 다음 묶음에서 총액 기록으로 돌아오는 자리만 허용
          (w.gi = 1 and exists (select 1 from cands c0 join cands c on c.user_id = g.user_id and c.sec = g.sec and c.is_final
                                  where c0.user_id = g.user_id and c0.sec = w.sec
                                    and c.cand - w.off = c0.other_pocket
                                    and c0.balance_after = c.cand + c0.pocket_end)) as ret,
          -- [PATCH-9] ⑥ 주머니 첫 등장: 끝 줄의 주머니 P 에 앞선 원장 행이 하나도 없고, 이동량이 (저장_P − 원장_P) 와 같고 양수면
          --    「원장 시작 전 잔액이 이 주머니의 첫 총액 기록에서 비로소 드러난 것」일 수 있다. 같은 시각의 원장 밖 유입과
          --    데이터로는 구분이 안 되므로 ❌ 대신 「기준선?」(판정 불가) 로 적고, D·G 에서 부여 이력 확인을 요구한다.
          exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec and c.is_final
                    and not exists (select 1 from r0 x where x.user_id = g.user_id and x.pocket = c.pocket and x.sec < g.sec)
                    and (c.cand - w.off) > 0
                    and (c.cand - w.off) = (case when c.pocket = 'membership' then b.mem - coalesce(l.mem,0)
                                                 else b.gen - coalesce(l.gen,0) end)) as latebase,
          -- [PATCH-5] ⑤ 후보는 끝 줄에서 고른다 (끝이 없는 순환 묶음 = 역순 쌍만 전체 후보). 「가장 가까운」이 끝이 아닌 줄을 집지 않는다.
          (select c.cand from cands c where c.user_id = g.user_id and c.sec = g.sec
            order by (not c.is_final), abs(c.cand - w.off), c.id desc limit 1)::numeric as nearest
        ) t
    ) pk
),
jumps as (
  select w.user_id, w.sec, w.jump, w.kind, w.what, w.off from walk w where w.jump <> 0
  union all
  -- [PATCH-2] 묶음 안 불일치도 ❌ 로 센다 (금액은 id 순 추정)
  select w.user_id, w.sec, w.bad_gap::numeric, '❌묶음', w.what, w.off from walk w where w.bad
),
lastoff as (
  select distinct on (user_id) user_id, off as last_off from walk order by user_id, gi desc
),
firstoff as (
  select user_id, off as first_off, firstbad from walk where gi = 1
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
              -- [PATCH-7] 합계가 같아도 주머니가 다르면 mem↔gen 사이에 원장 밖 이동이 있다
              when b.tot = coalesce(l.tot,0) then '❌ 합계는 같은데 주머니가 다름 — mem/gen 사이 원장 밖 이동'
              -- [PATCH-8] 「원장 시작 전 잔액」은 첫 묶음 기준선(first_off)이고 0 이상이어야 한다. 마지막 기준선(last_off)은 기록방식 이동으로 오염될 수 있다.
              when b.tot - coalesce(l.tot,0) = coalesce(f.first_off,0) and coalesce(f.first_off,0) >= 0
                   and not coalesce(f.firstbad,false)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   then '원장 시작 전 잔액 ' || coalesce(f.first_off,0)::text || ' (정상)'
              when coalesce(f.firstbad,false) then '❌ 불일치 — 첫 묶음 줄들이 한 사슬이 아니라 기준선을 확정할 수 없다 (E2·B 참조)'
              -- [PATCH-10] 차이가 「원장이 한 줄도 안 건드린 주머니」에만 있고 다른 주머니는 맞다 → 데이터로는 판정 불가
              when not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and ((coalesce(l.n_mem,0) = 0 and b.mem > 0 and b.gen = coalesce(l.gen,0))
                     or (coalesce(l.n_gen,0) = 0 and b.gen > 0 and b.mem = coalesce(l.mem,0)))
                   then '⚠ 판정 불가 — 원장이 이 주머니를 한 줄도 안 건드림 (원장 시작 전 잔액이거나 원장 밖 유입 · 부여 이력으로 확인)'
              -- [PATCH-9] 차이 = 첫 기준선 + 「주머니 첫 등장」 이동 → 늦게 드러난 기준선일 수 있다
              when not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0)
                       + coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '기준선?'),0)
                   and coalesce(f.first_off,0) >= 0
                   then '⚠ 판정 불가 — 원장 시작 전 잔액이 주머니 첫 등장에서 늦게 드러났거나 그때 원장 밖 유입 (E2 · 부여 이력으로 확인)'
              else '❌ 불일치 — E2·G 참조' end as note,
         3 as o1, -abs(b.tot - coalesce(l.tot,0)) as o2
    from bal b left join led l on l.user_id = b.id left join firstoff f on f.user_id = b.id
   where b.tot <> coalesce(l.tot,0) or b.mem <> coalesce(l.mem,0) or b.gen <> coalesce(l.gen,0)
),
e as (
  select 'E2·체인' as sec, b.who,
         to_char(j.sec at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') as at,
         '이 묶음 직전 ' || j.jump::text || ' · 묶음: ' || coalesce(j.what,'') as what,
         j.jump::text as amount, '' as bal_after, '기준선 ' || j.off::text as running,
         case when j.kind = '❌' then '❌ 원장 밖 이동 후보'
              when j.kind = '❌묶음' then '❌ 같은 초 묶음 안에서 잔액이 튐 (금액은 id 순 추정)'
              when j.kind = '기준선?' then '⚠ 주머니 첫 등장 — 원장 시작 전 잔액이 늦게 드러났거나 원장 밖 유입 (판정 불가 · 부여 이력 확인)'
              else 'ⓘ 기록 방식 차이 (돈 안 움직임)' end as note,
         4 as o1, extract(epoch from j.sec)::bigint as o2
    from jumps j join bal b on b.id = j.user_id
),
g as (
  select 'G·요약' as sec, b.who, '' as at,
         '저장−원장 ' || (b.tot - coalesce(l.tot,0))::text
           || ' · 원장 시작 전 ' || coalesce(f.first_off,0)::text
           || ' · ❌이동 합 ' || coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind like '❌%'),0)::text
           || ' (' || coalesce((select count(*) from jumps j where j.user_id = b.id and j.kind like '❌%'),0)::text || '건)'
           || ' · ⓘ기록방식 ' || coalesce((select count(*) from jumps j where j.user_id = b.id and j.kind not like '❌%'),0)::text || '건' as what,
         b.tot::text as amount, coalesce(l.tot,0)::text as bal_after, '' as running,
         case when exists (select 1 from jumps j where j.user_id = b.id and j.kind = '❌묶음') then '❌ 같은 초 묶음 안에서 잔액이 튐 — E2·B 참조'
              when coalesce(f.firstbad,false) and b.tot <> coalesce(l.tot,0) then '❌ 첫 묶음 줄들이 한 사슬이 아니라 기준선을 확정할 수 없다 — B 참조'
              when b.tot = coalesce(l.tot,0) and (b.mem <> coalesce(l.mem,0) or b.gen <> coalesce(l.gen,0))
                   then '❌ 합계는 같은데 주머니가 다름 — mem/gen 사이 원장 밖 이동'
              when b.tot = coalesce(l.tot,0) and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%') then '✅'
              when b.tot = coalesce(l.tot,0) then '✅ 잔액 일치 (❌는 중간에 상쇄됨 — 손실 없음)'
              when (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0) and coalesce(f.first_off,0) >= 0
                   and not coalesce(f.firstbad,false)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%') then '✅ 원장 시작 전 잔액 (정상)'
              when not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and exists (select 1 from jumps j where j.user_id = b.id and j.kind = '기준선?')
                   then '⚠ 판정 불가 — 주머니 첫 등장에서 드러난 차이 (E2 · 부여 이력으로 확인)'
              when not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and ((coalesce(l.n_mem,0) = 0 and b.mem > 0 and b.gen = coalesce(l.gen,0))
                     or (coalesce(l.n_gen,0) = 0 and b.gen > 0 and b.mem = coalesce(l.mem,0)))
                   then '⚠ 판정 불가 — 원장이 한 주머니를 한 줄도 안 건드림 (부여 이력으로 확인)'
              when (b.tot - coalesce(l.tot,0)) - coalesce(f.first_off,0)
                   = coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind like '❌%'),0)
                   then '⚠ 차이 = 원장 시작 전 잔액 + ❌이동 합 (원인 시각은 E2)'
              else '⚠ 차이가 설명되지 않음 — E2·B 를 같이 본다' end as note,
         5 as o1, -abs(b.tot - coalesce(l.tot,0)) as o2
    from bal b left join led l on l.user_id = b.id left join firstoff f on f.user_id = b.id
   where exists (select 1 from jumps j where j.user_id = b.id) or b.tot <> coalesce(l.tot,0)
      or b.mem <> coalesce(l.mem,0) or b.gen <> coalesce(l.gen,0)
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
