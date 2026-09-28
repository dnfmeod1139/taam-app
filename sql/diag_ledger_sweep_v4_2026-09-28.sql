-- ═════════════════════════════════════════════════
-- TAAM — 예치금 원장 전수 대사 v4 · 2026-09-28  (읽기만 · 아무것도 바꾸지 않는다)
-- ═════════════════════════════════════════════════
-- 무엇을 보나
--   회원마다 「저장 잔액(profiles)」과 「원장 합계(deposit_transactions)」를 주머니별로 맞춰 보고,
--   원장의 balance_after 사슬을 따라가며 「원장 없이 잔액이 움직인 자리」를 찾는다.
--
-- 결과 표 읽는 법 (sec 열)
--   A·잔액   유수봉 저장 잔액 vs 원장 합계 (주머니별)
--   B·전체   유수봉 원장 전부 — 「총액 기록」/「주머니 기록」 표시 (balance_after 를 어떤 뜻으로 썼는지)
--   D·전수   저장 ≠ 원장인 회원 전원 ← **여기가 결정적이다**
--              ❌ 불일치 / ❌ 주머니 하나가 원장보다 적다 / ❌ 합계는 같은데 주머니가 다름  → 돈이 원장 밖에서 움직였다
--              원장 시작 전 잔액 N (정상)  → 8/31 원장 서버화 이전부터 있던 잔액. 손댈 것 없음
--              ⚠ 판정 불가  → 데이터만으로는 「원장 시작 전 잔액」과 「원장 밖 유입」을 가를 수 없다. 부여 이력으로 확인
--   E2·체인  이동이 감지된 시각·금액 (❌ 원장 밖 이동 후보 / ⓘ 기록 방식 차이 / ⚠ 주머니 첫 등장)
--   G·요약   회원별 한 줄 — 차이가 E2 로 설명되는지
--   H·함수   라이브 RPC 가 balance_after 를 총액으로 쓰는지
--   S·슈퍼   Super Admin 8/14~8/23 원장 (v1 에서 발견된 −1,000 의 출처)
--
-- 왜 이렇게 복잡한가
--   balance_after 가 행마다 「총액」이기도 「그 주머니 잔액」이기도 하고(작성 경로가 여러 번 바뀌었다),
--   같은 초에 쓰인 두 줄은 id 순서가 실제 순서와 다르며, 원장 서버화 전부터 있던 잔액(기준선)이 있다.
--   v1 은 이걸 전부 「이동」으로 읽어 52건이 떴다(대부분 착시). v2~v4 는 공격 에이전트 3라운드(도난·착시
--   시드 70여 명)로 검증하며 조였다. 회귀: bash sql/_test/ledger_sweep/t_sweep.sh · t_sweep2.sh (둘 다 ✅ 여야 한다)
--
-- 한계 (정직하게)
--   「원장이 한 번도 안 건드린 주머니에 잔액이 있다」「어떤 주머니의 첫 줄에서 비로소 기준선이 드러난다」는
--   같은 시각의 원장 밖 유입과 데이터가 똑같다. 이런 회원은 ⚠ 판정 불가 로 적는다 — 정상이라고도 이상이라고도 안 한다.
--   그래서 D 의 ⚠ 는 「부여 이력(어드민 메뉴 → 예치금 부여 내역)」으로 사람이 한 번 봐야 한다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 결과는 한 표다.
-- 이력: v1(2026-09-28 아침) → v2(같은 초 묶음·기록 방식) → v3(주머니별 D·첫 묶음·판정 불가)
--       → v4(세 판정자 패치 병합 + 3차 이음새 J1-c/J3-L2/J6/J7/J8). 규칙 태그 [PATCH-n]/[J..] 는 그대로 남겼다.
-- ═════════════════════════════════════════════════
-- v4 (2026-09-28 밤): judge1 구조 + judge0 규칙(J3-P/J3-L/J3-B/J3-F) + judge2 PATCH-11 병합
-- v4-fixed (adv4 판정 뒤): [J1-c] 묶음 안 튐 판정을 id 순이 아니라 「어떤 두 줄이 시작·끝으로 맞는가」로 (BN1)
--   [J3-L2] 늦게 드러난 기준선은 그 주머니가 이 묶음에 없어도 된다 — 원장에 아직 한 줄도 없으면 (BN3 · A1 쌍둥이와 같은 ⚠)
--   [J6] 주머니 하나가 원장보다 적으면 ❌ (R3) — 단, 원장 안의 같은 초 상쇄 쌍(주머니 보정)이 저장 잔액에 반영 안 된 것으로 설명되면 ⚠ (B5 형)
--   [J7] 「기준선?」 합이 최종 차이에 없으면 ❌ (R2)
--   [J8] 주머니 기록 줄이 섞인 회원은 「정상」이라 못 한다 — 도난·되돌림 쌍둥이와 구분 불가 → ⚠ 판정 불가 (R1)
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
         -- [J1-a] 끝이 주머니 수보다 많아도, 시작·끝 잔액이 맞으면 기록 방식 혼재일 뿐 돈은 안 튀었다 (I1 형)
         -- [J1-c] 그 시작·끝을 id 순으로 읽지 않는다 — RPC 의 uuid id 는 쓴 순서와 무관하다 (BN1 형 오탐). 묶음 안 「어떤 두 줄」 s·e 가
         --        e.balance_after − 묶음 합 = s 의 직전 잔액 을 만족하면 총액 사슬의 시작·끝이 있는 것이다. 진짜 묶음 안 도난(Z5 형)은 그런 쌍이 없다.
         (n_rows > 1 and n_final > n_pockets
            and not exists (select 1 from r1 s join r1 e on e.user_id = s.user_id and e.sec = s.sec and e.id <> s.id
                             where s.user_id = q.user_id and s.sec = q.sec
                               and s.balance_after is not null and e.balance_after is not null
                               and e.balance_after - q.grp_amt = s.balance_after - s.amount)) as bad,
         n_final,
         -- [J1-b] 첫 묶음이 사슬이 아닐 때(주머니 기록 쌍): 끝 줄마다 「자기 주머니 원장 시작 전 잔액」 = balance_after − pocket_end 을 더한 값이
         --        총 기준선 후보다. 끝 줄이 주머니마다 하나씩이고 전부 0 이상일 때만 뜻이 있다 (psum_ok).
         psum, (n_final > 1 and coalesce(psum_ge0, false) and n_final_pockets = n_final) as psum_ok,
         -- id 순으로 읽었을 때의 튄 금액 추정 = (마지막 줄이 말하는 묶음 시작 잔액) − (첫 줄의 직전 잔액)
         (last_b - grp_amt) - first_prior as bad_gap,
         what
    from (select user_id, sec, sum(amount) as grp_amt, count(*) as n_rows,
                 count(*) filter (where is_final and balance_after is not null) as n_final,
                 count(distinct pocket) as n_pockets,
                 sum(balance_after - pocket_end) filter (where is_final and balance_after is not null) as psum,
                 bool_and(balance_after - pocket_end >= 0) filter (where is_final and balance_after is not null) as psum_ge0,
                 count(distinct pocket) filter (where is_final and balance_after is not null) as n_final_pockets,
                 (array_agg(balance_after - amount order by id))[1] as first_prior,
                 (array_agg(balance_after order by id desc))[1] as last_b,
                 (array_agg(coalesce(change_type,'?') || coalesce(' · ' || left(description, 34), '') order by id))[1] as what
            from r1 group by user_id, sec) q
),
cands as (
  select r.user_id, r.sec, r.id, r.pocket, r.change_type, r.description, r.balance_after, r.amount,
         r.balance_after - g.run_tot_end as cand,
         r.balance_after - r.run_tot as cand_pos,
         g.run_tot_end - r.pocket_end as other_pocket,
         r.pocket_end, r.is_final
    from r1 r join grp g on g.user_id = r.user_id and g.sec = r.sec
   where r.balance_after is not null
),
walk as (
  -- [PATCH-4] 첫 묶음: 끝 줄의 후보를 먼저 고른다 (끝이 아닌 줄의 후보가 「저장−원장」과 우연히 같아도 뽑히지 않는다)
  select g.user_id, g.gi, g.sec,
         pk.off, pk.off as first_off,
         0::numeric as jump, ''::text as kind, g.what, g.bad, g.bad_gap, (g.n_final > 1) as firstbad,
         ''::text as okind,
         false as hadx,  -- [J3-B] 이 걸음까지 진짜 ❌ 가 한 번이라도 있었나
         false as hadpk  -- [J8] 이 걸음까지 「주머니 기록」으로 삼킨 끝 줄이 있었나 (도난·되돌림 쌍둥이 표식)
    from grp g join bal b on b.id = g.user_id left join led l on l.user_id = g.user_id
    cross join lateral (
      -- [J3] 첫 묶음이 사슬이 아니면(끝이 둘 이상) 후보를 이 순서로 고른다:
      --   ① 주머니 합 psum 이 저장−원장과 같다 (주머니 기록 쌍 + 주머니별 시작 전 잔액 · F2·H1·B6)
      --   ② 어떤 줄의 자리 총액 읽기(cand_pos)가 저장−원장과 같다 (총액 줄이 먼저, 주머니 줄이 뒤 · D1)
      --   ③ 어떤 끝 줄의 묶음 끝 총액 읽기(cand)가 저장−원장과 같다 (종전 규칙)
      --   ④ psum 이 뜻이 있으면 psum   ⑤ 종전 순서(끝 줄 우선 · id 내림차순)
      --   사슬인 첫 묶음(끝 하나)은 종전과 똑같이 ⑤ 로만 간다.
      select case
               when g.n_final > 1 and g.psum_ok and g.psum = (b.tot - coalesce(l.tot,0)) then g.psum
               when g.n_final > 1 and exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec
                                                and c.cand_pos = (b.tot - coalesce(l.tot,0))) then (b.tot - coalesce(l.tot,0))
               when g.n_final > 1 and exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec and c.is_final
                                                and c.cand = (b.tot - coalesce(l.tot,0))) then (b.tot - coalesce(l.tot,0))
               when g.n_final > 1 and g.psum_ok then g.psum
               else (select c.cand from cands c where c.user_id = g.user_id and c.sec = g.sec
                      order by c.is_final desc, case when c.cand = (b.tot - coalesce(l.tot,0)) then 0 else 1 end, c.id desc limit 1)
             end::numeric as off) pk
   where g.gi = 1
  union all
  select g.user_id, g.gi, g.sec,
         pk.off_new, w.first_off,
         (pk.off_new - w.off) as jump, pk.kind,
         g.what, g.bad, g.bad_gap, w.firstbad,
         case when pk.off_new <> w.off then pk.kind else w.okind end as okind,
         (w.hadx or pk.kind = '❌') as hadx,
         (w.hadpk or pk.pk_pocketed) as hadpk
    from walk w join grp g on g.user_id = w.user_id and g.gi = w.gi + 1
    join bal b on b.id = g.user_id left join led l on l.user_id = g.user_id
    cross join lateral (
      select case when keep then w.off
                  when back then w.first_off
                  when pfd is not null then w.off + pfd
                  when pocketed then w.off
                  when p0_late is not null then w.off + p0_late   -- [J3-L] 주머니 기록으로 첫 등장한 주머니의 기준선이 드러남
                  else coalesce(nearest, w.off) end as off_new,
             case when keep then ''
                  when back then '❌'
                  when pfd is not null then '기준선?'
                  when pocketed then '기록방식'
                  when p0_late is not null then '기준선?'
                  when nearest is null or nearest = w.off then ''
                  when ret then '기록방식'
                  when latebase then '기준선?'
                  else '❌' end as kind,
             -- [J8] pocketed 가 실제로 판정을 맡았을 때만 (keep·back·pfd 가 앞서면 삼킨 게 아니다)
             (not keep and not back and pfd is null and pocketed) as pk_pocketed
        from (select
          -- ① 끝 줄 후보가 직전 기준선과 같다 → 이동 없음
          exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec and c.is_final and c.cand = w.off) as keep,
          -- ② 끝 줄 후보가 첫 기준선으로 되돌아온다 → 앞의 ❌ 이동이 되돌려진 것. 주머니 기록보다 먼저 본다 (C6 형)
          --    [J4-a] 단, 되돌릴 것은 ❌ 로 옮긴 기준선뿐이다. 「기준선?」(주머니 첫 등장) 로 옮긴 뒤 다른 주머니의 원장 누적이 0 인 순간에
          --    주머니 기록 줄이 오면 후보가 우연히 첫 기준선과 같아지는데(G1 형), 그건 되돌아온 게 아니라 주머니 기록이다 → 아래 pocketed 로.
          --    [J3-B] 앞의 이동이 「기준선?」(늦게 드러난 기준선)뿐이면 되돌림이 아니다 — 진짜 ❌ 가 한 번은 있었어야 한다 (hadx · BEN2 형). okind 게이트와 함께 본다.
          (w.hadx and w.off <> w.first_off and w.okind = '❌'
             and exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec and c.is_final and c.cand = w.first_off)) as back,
          -- [J4-b] ③′ 주머니 기록 첫 등장: 끝 줄의 주머니 P 에 앞선 원장 행이 없고, 주머니 읽기 d = balance_after − pocket_end 가 양수이며
          --    d = (저장_P − 원장_P) 이고, 지금 기준선 + d = (저장 − 원장) 총 차이일 때 → 첫 묶음이 주머니 기록이어서 P 의 원장 시작 전 잔액이
          --    이제야 드러난 것일 수 있다 (B1·B2 형). PATCH-9(총액 기록 첫 등장)의 주머니 기록 판이다. 같은 시각 원장 밖 유입과 구분이 안 되므로 「기준선?」.
          --    첫 줄이 총액 기록이었다면(기준선이 이미 P 몫을 품고 있다) 마지막 조건이 안 맞아 종전대로 pocketed 로 간다 (B7 형은 그대로).
          (select c.balance_after - c.pocket_end from cands c
            where c.user_id = g.user_id and c.sec = g.sec and c.is_final
              and not exists (select 1 from r0 x where x.user_id = g.user_id and x.pocket = c.pocket and x.sec < g.sec)
              and c.balance_after - c.pocket_end > 0
              and c.balance_after - c.pocket_end = (case when c.pocket = 'membership' then b.mem - coalesce(l.mem,0)
                                                         else b.gen - coalesce(l.gen,0) end)
              and w.off + (c.balance_after - c.pocket_end) = (b.tot - coalesce(l.tot,0))
            order by c.id limit 1)::numeric as pfd,
          -- [PATCH-6] ③ 주머니 기록: 끝 줄의 balance_after − 그 주머니 원장 누적 = 그 주머니의 원장 시작 전 잔액이어야 하고,
          --    그 값은 0 이상 · 총 기준선(w.off) 이하여야 한다 (다른 주머니 몫을 넘을 수 없다). 저장 잔액을 근거로 삼지 않는다.
          --    돈이 안 움직였으니 기준선을 옮기지 않는다.
          --    [J3-P] 그리고 그 값은 「그 주머니의 저장 − 원장」과 같아야 한다. 같지 않으면 이 줄 뒤에 그 주머니에서 돈이 움직였거나
          --    이 줄이 주머니 기록이 아닌 것이다 — 어느 쪽이든 「돈 안 움직임」으로 넘길 수 없다 (B1 형: 기준선 밑에서 빼고 되돌린 것이 통째로 숨었다)
          exists (select 1 from cands c where c.user_id = g.user_id and c.sec = g.sec and c.is_final
                    and c.balance_after - c.pocket_end between 0 and w.off
                    and c.balance_after - c.pocket_end = (case when c.pocket = 'membership' then b.mem - coalesce(l.mem,0)
                                                               else b.gen - coalesce(l.gen,0) end)) as pocketed,
          -- ④ 첫 묶음이 주머니 기록 쌍이라 기준선이 잘못 잡혔을 때, 바로 다음 묶음에서 총액 기록으로 돌아오는 자리만 허용
          (w.gi = 1 and exists (select 1 from cands c0 join cands c on c.user_id = g.user_id and c.sec = g.sec and c.is_final
                                  where c0.user_id = g.user_id and c0.sec = w.sec
                                    and c.cand - w.off = c0.other_pocket
                                    and c0.balance_after = c.cand + c0.pocket_end)) as ret,
          -- [PATCH-9] ⑥ 주머니 첫 등장: 끝 줄의 주머니 P 에 앞선 원장 행이 하나도 없고, 이동량이 (저장_P − 원장_P) 와 같고 양수면
          --    「원장 시작 전 잔액이 이 주머니의 첫 총액 기록에서 비로소 드러난 것」일 수 있다. 같은 시각의 원장 밖 유입과
          --    데이터로는 구분이 안 되므로 ❌ 대신 「기준선?」(판정 불가) 로 적고, D·G 에서 부여 이력 확인을 요구한다.
          --    [J3-L] 첫 등장 주머니는 묶음의 「끝 줄」이 아니어도 된다 (RPC 가 gen→mem 순으로 썼으면 끝 줄은 mem 이다 · BEN4 형).
          --    이동량은 여전히 끝 줄에서 읽고, 그 값이 「첫 등장 주머니의 저장 − 원장」과 같아야 한다.
          --    [J3-L2] 첫 등장 주머니 P 가 이 묶음에 있어야 하는 것도 아니다 — 첫 묶음이 주머니 기록이었으면 P 의 원장 시작 전 잔액은
          --    「그 뒤 처음 나오는 총액 기록 줄」에서 드러나는데, 그 줄이 다른 주머니의 줄일 수 있다 (BN3 형). 조건은 같다:
          --    P 에 앞선 원장 행이 없고, 이동량 = (저장_P − 원장_P) > 0. 첫 묶음이 총액 기록이었다면 이 등식이 성립하지 않아(P 몫이 이미 기준선에 있다) ❌ 로 남는다.
          exists (select 1 from cands c cross join (values ('membership'),('general')) p(pocket)
                   where c.user_id = g.user_id and c.sec = g.sec and c.is_final
                    and not exists (select 1 from r0 x where x.user_id = g.user_id and x.pocket = p.pocket and x.sec < g.sec)
                    and (c.cand - w.off) > 0
                    and (c.cand - w.off) = (case when p.pocket = 'membership' then b.mem - coalesce(l.mem,0)
                                                 else b.gen - coalesce(l.gen,0) end)) as latebase,
          -- [J3-L] ⑥-주머니: 첫 등장 주머니의 끝 줄이 「주머니 기록」이면 balance_after − 주머니 누적 = 그 주머니 기준선. 그 값이 (저장_P − 원장_P) 와
          --    같고 양수면 늦게 드러난 기준선(또는 같은 시각 유입)이다 — 총 기준선에 더하고 「기준선?」 로 적는다 (BEN1 형).
          --    [J4-b] pfd 가 총 차이까지 맞을 때 먼저 잡고, 여기는 pocketed 뒤의 폴백이다.
          (select c.balance_after - c.pocket_end from cands c where c.user_id = g.user_id and c.sec = g.sec and c.is_final
             and not exists (select 1 from r0 x where x.user_id = g.user_id and x.pocket = c.pocket and x.sec < g.sec)
             and c.balance_after - c.pocket_end > 0
             and c.balance_after - c.pocket_end = (case when c.pocket = 'membership' then b.mem - coalesce(l.mem,0)
                                                        else b.gen - coalesce(l.gen,0) end)
           order by c.id desc limit 1)::numeric as p0_late,
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
  select distinct on (user_id) user_id, off as last_off, hadpk from walk order by user_id, gi desc
),
firstoff as (
  select user_id, off as first_off, firstbad from walk where gi = 1
),
-- [J6] 같은 초에 다른 주머니로 정확히 상쇄되는 줄(주머니 보정 쌍 · 초대 분할 등)의 주머니별 합. 이 쌍이 원장에는 있는데 저장 잔액에는
--      반영되지 않았다면 「저장−원장」이 한 주머니는 그만큼 모자라고 다른 주머니는 그만큼 남는다 (B5 형). 그건 ❌ 가 아니라 ⚠ 다.
pairs as (
  select r.user_id,
         coalesce(sum(r.amount) filter (where r.pocket = 'membership'),0)::bigint as mem,
         coalesce(sum(r.amount) filter (where r.pocket = 'general'),0)::bigint    as gen
    from r0 r
   where exists (select 1 from r0 y where y.user_id = r.user_id and y.sec = r.sec and y.id <> r.id
                   and y.pocket <> r.pocket and y.amount = -r.amount)
   group by r.user_id
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
              -- [J6] 주머니 하나가 원장보다 적다 → 원장 시작 전 잔액(0 이상)으로는 설명이 안 된다. 총 차이가 얼마든 mem/gen 사이(또는 밖으로)
              --      원장 밖 이동이 확실하다 (R3 형: 총액 기준선이 있으면 PATCH-7 이 못 보던 자리)
              --      예외 하나: 원장 안의 같은 초 상쇄 쌍(주머니 보정)을 저장 잔액에 반영하지 않은 것으로 두 주머니가 모두 0 이상이 되고,
              --      총 차이도 달리 설명되면(❌ 없음 · 첫 기준선 + 기준선?) ❌ 가 아니라 ⚠ — 쌍이 반영됐는지 확인하라고 한다 (B5 형)
              when (b.mem < coalesce(l.mem,0) or b.gen < coalesce(l.gen,0))
                   and not (pr.user_id is not null
                            and b.mem - coalesce(l.mem,0) + pr.mem >= 0 and b.gen - coalesce(l.gen,0) + pr.gen >= 0
                            and not coalesce(f.firstbad,false)
                            and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                            and (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0)
                                + coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '기준선?'),0))
                   then '❌ 주머니 하나가 원장보다 적다 (저장−원장 mem ' || (b.mem - coalesce(l.mem,0))::text || ' · gen ' || (b.gen - coalesce(l.gen,0))::text
                        || ') — 원장 시작 전 잔액으로 설명 불가 · mem/gen 사이 원장 밖 이동'
              when b.mem < coalesce(l.mem,0) or b.gen < coalesce(l.gen,0)
                   then '⚠ 판정 불가 — 총 차이는 설명되지만 주머니가 어긋난다 (저장−원장 mem ' || (b.mem - coalesce(l.mem,0))::text || ' · gen ' || (b.gen - coalesce(l.gen,0))::text
                        || ') · 원장의 상쇄 쌍(mem ' || pr.mem::text || ' / gen ' || pr.gen::text || ')이 저장 잔액에 반영되지 않았다면 맞는 값 — 보정 기록으로 확인'
              -- [J7] 「기준선?」(주머니 첫 등장에서 드러난 몫)이 있으면 최종 차이는 첫 기준선 + 그 합이어야 한다.
              --      아니면 드러난 돈이 그 뒤 원장 밖으로 빠졌다 (R2 형: 뒤의 주머니 기록 줄이 그 도난을 삼킨다)
              when not coalesce(f.firstbad,false)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and exists (select 1 from jumps j where j.user_id = b.id and j.kind = '기준선?')
                   and (b.tot - coalesce(l.tot,0)) <> coalesce(f.first_off,0)
                       + coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '기준선?'),0)
                   then '❌ 불일치 — 주머니 첫 등장에서 드러난 ' || coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '기준선?'),0)::text
                        || ' 이 최종 차이에 없다 (드러난 뒤 원장 밖으로 빠짐 · E2 참조)'
              -- [PATCH-8] 「원장 시작 전 잔액」은 첫 묶음 기준선(first_off)이고 0 이상이어야 한다. 마지막 기준선(last_off)은 기록방식 이동으로 오염될 수 있다.
              --    [J8] 그리고 주머니 기록으로 삼킨 줄이 하나도 없어야 「정상」이다 (아래)
              when b.tot - coalesce(l.tot,0) = coalesce(f.first_off,0) and coalesce(f.first_off,0) >= 0
                   and not coalesce(f.firstbad,false)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and not coalesce(lo.hadpk,false)
                   then '원장 시작 전 잔액 ' || coalesce(f.first_off,0)::text || ' (정상)'
              -- [J8] 차이는 첫 기준선과 같지만 주머니 기록 줄이 섞여 있다. 그 줄은 「그 순간 다른 주머니 잔액만큼 빼고 뒤에 되돌린」 우회와
              --      데이터로 구분이 안 된다 (R1 형: balance_after − 주머니 누적 = 저장−원장 등식이 되돌림 뒤에도 성립한다) → 정상이라 못 한다
              when b.tot - coalesce(l.tot,0) = coalesce(f.first_off,0) and coalesce(f.first_off,0) >= 0
                   and not coalesce(f.firstbad,false)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   then '⚠ 판정 불가 — 차이가 첫 기준선 ' || coalesce(f.first_off,0)::text || ' 과 같지만 주머니 기록 줄이 섞여 있어 그 앞뒤의 원장 밖 이동·되돌림을 데이터로 배제할 수 없다 (B · 부여 이력으로 확인)'
              -- [J5] 첫 묶음이 사슬이 아니어도(주머니 기록 쌍 · 혼합 기록) 차이가 「후보 기준선 + 기준선? 이동」으로 설명되고 ❌ 이동이 없으면
              --      확정은 못 하지만 불일치도 아니다 → 판정 불가 (F2·H1·D1 · 교차 주머니 첫 묶음 안 우회(C3x)와 데이터로는 구분 불가)
              when coalesce(f.firstbad,false)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and coalesce(f.first_off,0) >= 0
                   and (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0)
                       + coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '기준선?'),0)
                   then '⚠ 판정 불가 — 첫 묶음 줄들이 한 사슬이 아니라 기준선을 확정할 수 없다 (후보 ' || coalesce(f.first_off,0)::text || ' 로는 차이가 설명됨 · E2·B · 부여 이력으로 확인)'
              when coalesce(f.firstbad,false) then '❌ 불일치 — 첫 묶음 줄들이 한 사슬이 아니라 기준선을 확정할 수 없다 (E2·B 참조)'
              -- [PATCH-10] 차이가 「원장이 한 줄도 안 건드린 주머니」에만 있고 다른 주머니는 맞다 → 데이터로는 판정 불가
              --    [J3-F] 건드린 주머니는 「정확히 일치」가 아니라 「첫 기준선만큼 차이」여도 된다 (그 주머니에도 원장 시작 전 잔액이 있는 F2 형)
              when not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and coalesce(f.first_off,0) >= 0
                   and ((coalesce(l.n_mem,0) = 0 and b.mem > 0 and b.gen - coalesce(l.gen,0) = coalesce(f.first_off,0))
                     or (coalesce(l.n_gen,0) = 0 and b.gen > 0 and b.mem - coalesce(l.mem,0) = coalesce(f.first_off,0)))
                   then '⚠ 판정 불가 — 원장이 이 주머니를 한 줄도 안 건드림 (원장 시작 전 잔액이거나 원장 밖 유입 · 부여 이력으로 확인)'
              -- [PATCH-9] 차이 = 첫 기준선 + 「주머니 첫 등장」 이동 → 늦게 드러난 기준선일 수 있다
              when not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0)
                       + coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '기준선?'),0)
                   and coalesce(f.first_off,0) >= 0
                   then '⚠ 판정 불가 — 원장 시작 전 잔액이 주머니 첫 등장에서 늦게 드러났거나 그때 원장 밖 유입 (E2 · 부여 이력으로 확인)'
              else '❌ 불일치 — E2·G 참조' end as note,
         3 as o1, -abs(b.tot - coalesce(l.tot,0)) as o2
    from bal b left join led l on l.user_id = b.id left join firstoff f on f.user_id = b.id left join lastoff lo on lo.user_id = b.id
    left join pairs pr on pr.user_id = b.id
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
         -- [PATCH-11] 원장 행이 0건이면 D 와 같은 판정을 낸다 (종전엔 이 분기가 없어 D 가 「정상」이라 한 회원에게 G 가 ⚠ 를 냈다)
         case when coalesce(l.n,0) = 0 then '✅ 원장 행 0건 (원장 시작 전 잔액 — 정상)'
              when exists (select 1 from jumps j where j.user_id = b.id and j.kind = '❌묶음') then '❌ 같은 초 묶음 안에서 잔액이 튐 — E2·B 참조'
              -- [PATCH-7] 합계가 같은데 주머니가 다르면 mem↔gen 사이 원장 밖 이동 (J6 보다 먼저 — 더 구체적인 말)
              when b.tot = coalesce(l.tot,0) and (b.mem <> coalesce(l.mem,0) or b.gen <> coalesce(l.gen,0))
                   then '❌ 합계는 같은데 주머니가 다름 — mem/gen 사이 원장 밖 이동'
              -- [J6] D 와 같은 식 — 주머니 하나가 원장보다 적으면 ❌. 원장 안 상쇄 쌍 미반영으로 설명되면 ⚠
              when (b.mem < coalesce(l.mem,0) or b.gen < coalesce(l.gen,0))
                   and not (pr.user_id is not null
                            and b.mem - coalesce(l.mem,0) + pr.mem >= 0 and b.gen - coalesce(l.gen,0) + pr.gen >= 0
                            and not coalesce(f.firstbad,false)
                            and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                            and (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0)
                                + coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '기준선?'),0))
                   then '❌ 주머니 하나가 원장보다 적다 — 원장 시작 전 잔액으로 설명 불가 · mem/gen 사이 원장 밖 이동 (D 참조)'
              when b.mem < coalesce(l.mem,0) or b.gen < coalesce(l.gen,0)
                   then '⚠ 판정 불가 — 총 차이는 설명되지만 주머니가 어긋남 · 원장의 상쇄 쌍이 저장 잔액에 반영됐는지 확인 (D 참조)'
              when coalesce(f.firstbad,false) and b.tot <> coalesce(l.tot,0)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and coalesce(f.first_off,0) >= 0
                   and (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0)
                       + coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '기준선?'),0)
                   then '⚠ 판정 불가 — 첫 묶음 줄들이 한 사슬이 아니라 기준선을 확정할 수 없다 (후보로는 설명됨 · B · 부여 이력으로 확인)'
              when coalesce(f.firstbad,false) and b.tot <> coalesce(l.tot,0) then '❌ 첫 묶음 줄들이 한 사슬이 아니라 기준선을 확정할 수 없다 — B 참조'
              when b.tot = coalesce(l.tot,0) and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%') then '✅'
              -- [J5] 「상쇄」를 앞에 둔다 — 요약을 잘라 볼 때도 ❌ 쌍이 되돌려진 회원임이 보여야 한다 (C6·B1c 형)
              when b.tot = coalesce(l.tot,0) then '✅ 상쇄 — 잔액 일치 (❌ 이동이 중간에 되돌려짐 · 손실 없음 · E2 참조)'
              -- [J7] D 와 같은 식 — 「기준선?」 합이 최종 차이에 반영되지 않았다
              when not coalesce(f.firstbad,false)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and exists (select 1 from jumps j where j.user_id = b.id and j.kind = '기준선?')
                   and (b.tot - coalesce(l.tot,0)) <> coalesce(f.first_off,0)
                       + coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind = '기준선?'),0)
                   then '❌ 주머니 첫 등장에서 드러난 몫이 최종 차이에 없다 — 드러난 뒤 원장 밖으로 빠짐 (E2 참조)'
              when (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0) and coalesce(f.first_off,0) >= 0
                   and not coalesce(f.firstbad,false)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and not coalesce(lo.hadpk,false) then '✅ 원장 시작 전 잔액 (정상)'
              -- [J8] D 와 같은 식 — 주머니 기록 줄이 섞여 있으면 정상이라 못 한다
              when (b.tot - coalesce(l.tot,0)) = coalesce(f.first_off,0) and coalesce(f.first_off,0) >= 0
                   and not coalesce(f.firstbad,false)
                   and not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   then '⚠ 판정 불가 — 차이 = 첫 기준선이지만 주머니 기록 줄이 섞여 있다 (도난·되돌림과 구분 불가 · B · 부여 이력으로 확인)'
              when not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and exists (select 1 from jumps j where j.user_id = b.id and j.kind = '기준선?')
                   then '⚠ 판정 불가 — 주머니 첫 등장에서 드러난 차이 (E2 · 부여 이력으로 확인)'
              -- [J3-F] D 의 PATCH-10 과 같은 식 — 건드린 주머니는 첫 기준선만큼 차이여도 된다
              when not exists (select 1 from jumps j where j.user_id = b.id and j.kind like '❌%')
                   and coalesce(f.first_off,0) >= 0
                   and ((coalesce(l.n_mem,0) = 0 and b.mem > 0 and b.gen - coalesce(l.gen,0) = coalesce(f.first_off,0))
                     or (coalesce(l.n_gen,0) = 0 and b.gen > 0 and b.mem - coalesce(l.mem,0) = coalesce(f.first_off,0)))
                   then '⚠ 판정 불가 — 원장이 한 주머니를 한 줄도 안 건드림 (부여 이력으로 확인)'
              when (b.tot - coalesce(l.tot,0)) - coalesce(f.first_off,0)
                   = coalesce((select sum(j.jump) from jumps j where j.user_id = b.id and j.kind like '❌%'),0)
                   then '⚠ 차이 = 원장 시작 전 잔액 + ❌이동 합 (원인 시각은 E2)'
              else '⚠ 차이가 설명되지 않음 — E2·B 를 같이 본다' end as note,
         5 as o1, -abs(b.tot - coalesce(l.tot,0)) as o2
    from bal b left join led l on l.user_id = b.id left join firstoff f on f.user_id = b.id left join lastoff lo on lo.user_id = b.id
    left join pairs pr on pr.user_id = b.id
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
