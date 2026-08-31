-- ═══════════════════════════════════════════════════════════════
-- TAAM — 「돈은 빠졌는데 티켓이 없다」 를 찾아서 되돌린다 (2026-08-31)
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   2026-08-31 09:50, 앱은 taam_purchase_confirm_deposit 을 부르는데 DB 에는
--   그 함수가 아직 없었다. 좌석 전환(hold→active)이 실패했고, 그 다음 블록이
--   예치금은 그대로 차감했다. 결과: **차감 기록은 있는데 티켓이 hold 또는
--   cancelled.**
--
--   ⚠ 최종 상태만 보고는 이 사고와 「회원이 정상 취소한 것」 을 구분할 수 없다.
--     둘 다 status='cancelled' 로 끝난다. 구분은 **환불 기록이 있는지** 로만 된다.
--     그래서 ① 이 먼저다 — 고치기 전에 무엇이 있는지 본다.
--
-- 실행: ① 만 먼저 RUN → 결과를 보고 ② 또는 ③ 을 고른다.
--       ⚠ ②③ 은 돈을 움직인다. ① 없이 돌리지 말 것.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 진단 — 차감은 됐는데 살아 있는 티켓이 없는 구매 (읽기만 한다)
-- ═══════════════════════════════════════════════════════════════
--   최근 3일치만 본다. 한 화면에 나오도록 한 덩어리로 묶었다.
with paid as (
  -- 티켓 구매로 빠져나간 기록 (구매ID 별 합계)
  select dt.user_id,
         dt.metadata->>'purchase_id'          as purchase_id,
         sum(dt.amount) filter (where dt.change_type = 'ticket_purchase')  as 차감액,
         sum(dt.amount) filter (where dt.change_type <> 'ticket_purchase') as 되돌린액,
         count(*)                                                          as 기록수,
         min(dt.created_at)                                                as 처음
    from public.deposit_transactions dt
   where dt.created_at > now() - interval '3 days'
     and dt.metadata->>'purchase_id' is not null
   group by 1, 2
)
select p.purchase_id                                    as "구매ID",
       coalesce(pr.display_name, pr.name, '(이름없음)') as "회원",
       (-p.차감액)                                       as "빠져나간 금액",
       p.되돌린액                                        as "되돌아온 금액",
       coalesce(t.status, '❌ 티켓 행 없음')             as "티켓 상태",
       t.restaurant_name                                as "매장",
       t.reservation_date                               as "방문일",
       t.party_size                                     as "인원",
       t.price                                          as "티켓에 적힌 금액",
       to_char(p.처음, 'MM-DD HH24:MI')                  as "시각",
       case
         when t.id is null                       then '🔴 티켓 행 자체가 없다 — 환불(②) 또는 수동 생성'
         when t.status = 'active' and t.price > 0 then '🟢 정상'
         when t.status = 'active'                then '🟡 확정됐는데 금액이 0 — ③ 으로 금액만 채운다'
         when t.status = 'hold'                  then '🟠 아직 홀드 — ③ 으로 확정할 수 있다'
         when p.되돌린액 > 0                      then '🟢 취소·환불까지 끝난 건'
         else                                         '🔴 돈만 빠졌다 — ② 환불 또는 ③ 복구'
       end                                              as "판정"
  from paid p
  left join public.tickets  t  on t.purchase_id = p.purchase_id
  left join public.profiles pr on pr.id = p.user_id
 where p.차감액 < 0
 order by p.처음 desc;


-- ═══════════════════════════════════════════════════════════════
-- ② 되돌린다 — 빠진 돈을 그대로 넣어 준다
-- ═══════════════════════════════════════════════════════════════
--   티켓을 살릴 수 없을 때(행이 없다·좌석이 이미 남에게 갔다) 쓴다.
--   나간 주머니 그대로 되돌린다 — 멤버십에서 나갔으면 멤버십으로.
--
--   ⚠ 아래 두 줄의 '여기에_구매ID' 를 ① 결과에서 복사해 넣고 RUN.
/*
do $$
declare
  v_pid text := '여기에_구매ID';          -- ← ① 에서 복사
  v_uid uuid;
  v_m   bigint := 0;
  v_g   bigint := 0;
  v_mb  bigint;
  v_gb  bigint;
begin
  -- 이 구매로 나간 금액을 주머니별로 센다
  select dt.user_id,
         coalesce(sum(-dt.amount) filter (where dt.deposit_type = 'membership'), 0),
         coalesce(sum(-dt.amount) filter (where dt.deposit_type = 'general'),    0)
    into v_uid, v_m, v_g
    from public.deposit_transactions dt
   where dt.metadata->>'purchase_id' = v_pid
     and dt.change_type = 'ticket_purchase'
   group by dt.user_id;

  if v_uid is null then
    raise exception '그 구매ID 로 차감 기록이 없습니다: %', v_pid;
  end if;

  -- 이미 되돌렸으면 두 번 넣지 않는다
  if exists (select 1 from public.deposit_transactions
              where metadata->>'purchase_id' = v_pid
                and change_type in ('ticket_refund','admin_adjust')) then
    raise exception '이미 되돌린 기록이 있습니다: % — 중복 환불 방지', v_pid;
  end if;

  update public.profiles
     set membership_deposit_balance = coalesce(membership_deposit_balance,0) + v_m,
         general_deposit_balance    = coalesce(general_deposit_balance,0)    + v_g
   where id = v_uid
   returning membership_deposit_balance, general_deposit_balance into v_mb, v_gb;

  if v_m > 0 then
    insert into public.deposit_transactions
      (user_id, deposit_type, change_type, amount, balance_after, description, metadata)
    values (v_uid, 'membership', 'ticket_refund', v_m, v_mb + v_gb,
            '좌석 전환 실패 복구 — 멤버십 예치금 반환',
            jsonb_build_object('purchase_id', v_pid, 'portion', 'membership',
                               'reason', 'seat_hold_convert_failed',
                               'rescued_at', now()));
  end if;

  if v_g > 0 then
    insert into public.deposit_transactions
      (user_id, deposit_type, change_type, amount, balance_after, description, metadata)
    values (v_uid, 'general', 'ticket_refund', v_g, v_mb + v_gb,
            '좌석 전환 실패 복구 — 일반 예치금 반환',
            jsonb_build_object('purchase_id', v_pid, 'portion', 'general',
                               'reason', 'seat_hold_convert_failed',
                               'rescued_at', now()));
  end if;

  raise notice '복구 완료 % — 멤버십 +% · 일반 +% · 잔액 %', v_pid, v_m, v_g, v_mb + v_gb;
end $$;
*/


-- ═══════════════════════════════════════════════════════════════
-- ③ 살린다 — 홀드가 아직 있으면 예약을 확정해 준다
-- ═══════════════════════════════════════════════════════════════
--   돈은 이미 나갔으니 차감하지 않는다. **티켓만** 확정한다.
--   ⚠ 좌석이 그 사이 남에게 팔렸으면 쓰면 안 된다 — ② 로 환불한다.
/*
update public.tickets t
   set status = 'active',
       price  = coalesce(nullif(t.price, 0), (
                  select -sum(dt.amount) from public.deposit_transactions dt
                   where dt.metadata->>'purchase_id' = t.purchase_id
                     and dt.change_type = 'ticket_purchase')),
       extra_data = coalesce(t.extra_data, '{}'::jsonb)
                    || jsonb_build_object('paidBy', 'deposit',
                                          'rescued', true,
                                          'rescued_at', now())
 where t.purchase_id = '여기에_구매ID'        -- ← ① 에서 복사
   and t.status in ('hold', 'cancelled')
returning t.purchase_id, t.status, t.price, t.restaurant_name, t.reservation_date;
*/


-- ═══════════════════════════════════════════════════════════════
-- 재발 방지
-- ═══════════════════════════════════════════════════════════════
--   ⓐ 앱(BUILD 2026.08.31-f 이후)은 함수가 없으면 예전 경로로 내려간다.
--      → 「함수 미설치」 로는 다시 이 사고가 나지 않는다.
--   ⓑ 그래도 순서는 지킨다: **SQL 을 먼저 넣고 앱을 배포한다.**
--      앱이 DB 보다 앞서면 언제나 이런 틈이 생긴다.
