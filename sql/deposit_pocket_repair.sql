-- ═══════════════════════════════════════════════════════════════
-- 예치금 주머니 보정 — 일반으로 잘못 간 환불을 멤버십으로 되돌린다
-- 2026-08-28
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   종전 코드는 티켓 환불을 '전액 일반 예치금' 으로 넣었다. 차감은 멤버십에서
--   먼저 하는데 환불은 일반으로 들어가니, 구매·취소를 반복할수록 멤버십 예치금이
--   일반으로 옮겨갔다. 합계는 보존되지만 멤버십의 성격(연회비 90% 환급분)이 사라진다.
--   코드는 고쳤다(_depRefundSplit). 이 파일은 '이미 옮겨간 것' 을 되돌린다.
--
-- 어떻게
--   구매(purchase_id)별로 '멤버십에서 나간 비율' 을 계산해, 그 비율만큼만
--   일반 → 멤버십으로 옮긴다. 잔액을 임의로 덮어쓰지 않는다 —
--   거래기록이 근거이므로 나중에 되짚을 수 있다.
--
--   ⚠ 총액은 한 원도 바뀌지 않는다. 주머니만 옮긴다.
--   ⚠ 옮길 금액이 현재 일반 잔액보다 크면 일반 잔액까지만 옮긴다
--     (이미 쓴 돈을 만들어내지 않는다).
--
-- 실행: ① 미리보기 → 눈으로 확인 → ② 보정 → ③ 확인
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 미리보기 — 누가 얼마나 영향받았는지
-- ═══════════════════════════════════════════════════════════════
with refund_g as (
  -- 일반으로 들어간 티켓 환불 (구매건별)
  select user_id,
         metadata->>'purchase_id' as pid,
         sum(amount)              as ref_amt
    from public.deposit_transactions
   where change_type = 'ticket_refund'
     and deposit_type = 'general'
     and metadata->>'purchase_id' is not null
   group by 1, 2
),
purch as (
  -- 그 구매가 '어느 주머니에서' 나갔는지
  select user_id,
         metadata->>'purchase_id' as pid,
         sum(case when deposit_type = 'membership' then abs(amount) else 0 end) as mem_out,
         sum(abs(amount))                                                       as tot_out
    from public.deposit_transactions
   where change_type = 'ticket_purchase'
     and metadata->>'purchase_id' is not null
   group by 1, 2
),
calc as (
  select r.user_id,
         sum(round(r.ref_amt * p.mem_out::numeric / nullif(p.tot_out, 0)))::bigint as to_move
    from refund_g r
    join purch p on p.user_id = r.user_id and p.pid = r.pid
   where p.mem_out > 0
   group by r.user_id
)
select
  coalesce(pr.display_name, left(c.user_id::text, 8)) as "회원",
  pr.membership_deposit_balance                       as "현재_멤버십",
  pr.general_deposit_balance                          as "현재_일반",
  c.to_move                                           as "옮길금액",
  least(c.to_move, pr.general_deposit_balance)        as "실제_옮길금액",
  pr.membership_deposit_balance
    + least(c.to_move, pr.general_deposit_balance)    as "보정후_멤버십",
  pr.general_deposit_balance
    - least(c.to_move, pr.general_deposit_balance)    as "보정후_일반",
  case when c.to_move > pr.general_deposit_balance
       then '⚠ 일반 잔액이 부족 — 남은 만큼만 옮김'
       else '✅ 전액 복원 가능' end                     as "비고"
from calc c
join public.profiles pr on pr.id = c.user_id
where c.to_move > 0
order by c.to_move desc;


-- ═══════════════════════════════════════════════════════════════
-- ② 보정 — ① 을 확인한 뒤 실행
-- ═══════════════════════════════════════════════════════════════
-- 잔액을 옮기고, 그 사실을 거래기록으로 남긴다 (근거 없는 잔액 변경 금지).
do $$
declare
  r        record;
  v_move   bigint;
  v_n      int := 0;
  v_sum    bigint := 0;
begin
  for r in
    with refund_g as (
      select user_id, metadata->>'purchase_id' as pid, sum(amount) as ref_amt
        from public.deposit_transactions
       where change_type = 'ticket_refund' and deposit_type = 'general'
         and metadata->>'purchase_id' is not null
       group by 1, 2
    ),
    purch as (
      select user_id, metadata->>'purchase_id' as pid,
             sum(case when deposit_type = 'membership' then abs(amount) else 0 end) as mem_out,
             sum(abs(amount)) as tot_out
        from public.deposit_transactions
       where change_type = 'ticket_purchase'
         and metadata->>'purchase_id' is not null
       group by 1, 2
    ),
    calc as (
      select rf.user_id,
             sum(round(rf.ref_amt * p.mem_out::numeric / nullif(p.tot_out, 0)))::bigint as to_move
        from refund_g rf
        join purch p on p.user_id = rf.user_id and p.pid = rf.pid
       where p.mem_out > 0
       group by rf.user_id
    )
    select c.user_id, c.to_move,
           pr.display_name, pr.membership_deposit_balance as mem, pr.general_deposit_balance as gen
      from calc c
      join public.profiles pr on pr.id = c.user_id
     where c.to_move > 0
  loop
    -- 이미 쓴 돈을 만들어내지 않는다
    v_move := least(r.to_move, r.gen);
    if v_move <= 0 then
      raise notice '건너뜀 % — 일반 잔액 0', coalesce(r.display_name, left(r.user_id::text,8));
      continue;
    end if;

    update public.profiles
       set membership_deposit_balance = membership_deposit_balance + v_move,
           general_deposit_balance    = general_deposit_balance    - v_move,
           deposit_balance            = membership_deposit_balance + general_deposit_balance
     where id = r.user_id;

    -- 근거를 남긴다 — 잔액만 바뀌고 기록이 없으면 다음 사람이 되짚을 수 없다
    insert into public.deposit_transactions
      (user_id, deposit_type, change_type, amount, balance_after, description, metadata)
    values
      (r.user_id, 'general', 'pocket_adjust', -v_move, r.mem + r.gen,
       '예치금 주머니 보정 — 일반 → 멤버십 (환불 출처 복원)',
       jsonb_build_object('reason','refund_pocket_repair','moved',v_move,'to','membership')),
      (r.user_id, 'membership', 'pocket_adjust',  v_move, r.mem + r.gen,
       '예치금 주머니 보정 — 일반 → 멤버십 (환불 출처 복원)',
       jsonb_build_object('reason','refund_pocket_repair','moved',v_move,'from','general'));

    raise notice '보정 % — 멤버십 % → % · 일반 % → %',
      coalesce(r.display_name, left(r.user_id::text,8)),
      r.mem, r.mem + v_move, r.gen, r.gen - v_move;
    v_n := v_n + 1;
    v_sum := v_sum + v_move;
  end loop;

  raise notice '───────── %명 보정 · 총 ₩% 이동 (총액 변동 없음) ─────────', v_n, v_sum;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- ③ 확인 — 보정 후 잔액
-- ═══════════════════════════════════════════════════════════════
select
  display_name                as "회원",
  currency                    as "통화",
  membership_deposit_balance  as "멤버십",
  general_deposit_balance     as "일반",
  deposit_balance             as "합계",
  membership_deposit_balance + general_deposit_balance as "검산(멤버십+일반)"
from public.profiles
where coalesce(deposit_balance, 0) > 0
   or coalesce(membership_deposit_balance, 0) > 0
   or coalesce(general_deposit_balance, 0) > 0
order by deposit_balance desc;
