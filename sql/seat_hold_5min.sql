-- ═══════════════════════════════════════════════════════════════
-- TAAM — 좌석 홀드 5분 자동 만료 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent)
--
-- 왜 필요한가
--   지금은 "결제하기" 를 눌러도 좌석이 잡히지 않는다. 실제 좌석 차감은
--   구매가 끝나고 tickets INSERT 가 될 때 일어난다.
--   예치금 결제는 0.5초면 끝나 문제가 없지만, 카드는 결제창에서 1~3분이 걸린다.
--   그 사이 예치금 회원이 좌석을 가져가면, 카드 회원은 돈을 내고도 자리가 없다.
--
--   → "결제하기" 를 누른 순간 인원수만큼 좌석을 잡는다(HOLD).
--     예치금이든 카드든 동일하게 적용해 0.001초라도 먼저 누른 사람이 선점한다.
--
-- 홀드는 기존 초대 홀드(INVH-)와 같은 방식이다.
--   tickets 에 status='hold' 행을 넣으면 enforce_ticket_capacity 트리거가
--   원자적으로 검증하고, taam_ticket_sold_slots 가 잔여석에 반영한다.
--   purchase_id 는 최종 구매 ID 를 미리 확정해 넣는다 — 결제가 끝나면 같은 행을
--   status='active' 로 바꾸기만 하면 되므로 좌석이 한 순간도 비지 않는다.
--
-- 이 파일은 "만료 청소" 담당이다. 홀드 생성·전환은 앱에서 한다.
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 만료 스윕 ──
--   결제하기만 누르고 이탈한 홀드를 5분 뒤 풀어준다.
--   created_at 기준이며, 카드 결제창 왕복(보통 1~3분)에 충분한 여유다.
create or replace function public.taam_expire_seat_holds()
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_released int := 0;
begin
  with rel as (
    update public.tickets
       set status = 'cancelled'
     where status = 'hold'
       and purchase_id like 'PAYH-%'
       and created_at < now() - interval '5 minutes'
    returning 1
  )
  select count(*) into v_released from rel;

  return json_build_object('released', v_released, 'at', now());
end;
$$;

grant execute on function public.taam_expire_seat_holds() to authenticated;

comment on function public.taam_expire_seat_holds is
  '결제하기 후 5분 내 완료되지 않은 좌석 홀드(PAYH-)를 해제한다. pg_cron 이 1분마다 호출';

-- ── 2) 1분마다 자동 실행 ──
--   초대 홀드 스윕(taam_expire_invite_holds)은 30분 주기지만,
--   결제 홀드는 5분 만료라 1분 주기여야 체감이 맞는다.
create extension if not exists pg_cron;

select cron.unschedule('taam_expire_seat_holds')
where exists (select 1 from cron.job where jobname = 'taam_expire_seat_holds');

select cron.schedule(
  'taam_expire_seat_holds',
  '* * * * *',                                   -- 매 1분
  $$ select public.taam_expire_seat_holds(); $$
);

-- ── 3) 즉시 해제용 RPC (결제 취소·실패 시 앱에서 호출) ──
--   본인 홀드만 풀 수 있다. 남의 홀드를 풀어 좌석을 빼앗을 수 없게 한다.
create or replace function public.taam_release_seat_hold(p_purchase_id text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_cnt int;
begin
  update public.tickets
     set status = 'cancelled'
   where purchase_id = p_purchase_id
     and status = 'hold'
     and user_id = auth.uid();          -- 본인 홀드만
  get diagnostics v_cnt = row_count;
  return v_cnt > 0;
end;
$$;

grant execute on function public.taam_release_seat_hold(text) to authenticated;

-- ── 4) 확인 ──
select jobname, schedule, active from cron.job where jobname like 'taam_%';

select count(*) filter (where status = 'hold' and purchase_id like 'PAYH-%') as "현재 결제 홀드",
       count(*) filter (where status = 'hold' and purchase_id like 'INVH-%') as "현재 초대 홀드"
from public.tickets;

do $$ begin raise notice '✅ 좌석 홀드 5분 만료 준비 완료 — 홀드 생성/전환은 앱 배포 후 동작'; end $$;
