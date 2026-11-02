-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원이 쓴 환불 기록은 「완료」·「₩0 처리」 모양이 될 수 없다 (2026-11-01 · 회원 원장 「반환 · 대행비」 3차 리뷰)
-- ═══════════════════════════════════════════════════════════════
--   원장 「반환 · 대행비」 탭은 두 칸을 보고 「돌아간 돈」·「카드 환불 대기」를 센다. 둘 다 회원이 앱 없이 쓸 수 있는 모양이 남아 있었다.
--
--   A. tickets.extra_data.card_refund_pending — 결제 사실 칸 가드(20261022_card_refund_quote2.sql A)는 회원·매장 어드민 세션이
--      **취소하는 그 갱신에서만** 이 칸을 쓰게 하고 set_by_role 'member' 를 찍는다. 그런데 내용은 보지 않아 회원이 처음부터
--      {status:'done', done_by, toss_tx, via:'toss_api'} 를 적으면 「카드 환불 완료」로 보였다(2차 리뷰 #2).
--      2차 반영은 앱이 set_by_role 'superadmin' 일 때만 완료를 믿게 했는데, 정상 완료 경로 둘(Edge toss-card-refund = service_role ·
--      슈퍼어드민 「완료 표시」 = 금액을 안 바꿔 가드가 안 찍는다) 다 그 값을 'member' 로 남겨 **정상 완료가 전부 「대기」로** 보였다(3차 리뷰 · 회귀).
--      → 회원·매장 어드민 세션이 만드는 대기는 언제나 `status:'pending'` 이고 완료 칸(done_by · refunded_* · toss_* · via · requested_amount · policy)을 지운다.
--        취소한 뒤로는 결제 사실 칸 가드가 그 칸을 못 바꾸게 하므로, 「완료」는 슈퍼어드민·서버만 만든다 → 앱은 status 'done' 을 다시 믿는다.
--        별도 트리거(종전 가드 본문은 안 건드린다) · 예외를 내지 않는다(취소를 막지 않는다 — 실패하면 손대지 않고 통과).
--
--   B. deposit_transactions — taam_apply_deposit_delta 는 회원 호출에서 **양수 항목만** 검사하고 원장 가드들도 amount <= 0 이면 바로 통과시킨다.
--      그래서 회원이 자기 원장에 ₩0(또는 음수) ticket_refund 줄을 metadata 아무거나(refund_type 'returned' · agency_held · card_refund_pending)로 쓸 수 있었고,
--      원장 탭이 그 줄로 살아 있는 티켓을 「반환됨」으로, 자기 취소를 「방문 완료 반환」으로 보였다(3차 리뷰 · 돈은 안 움직인다).
--      ₩0 ticket_refund 를 쓰는 정상 경로는 슈퍼어드민 「환불 없음 처리」(전액 위약) 하나뿐이고, 회원 앱·Edge·서버 함수(패키지 취소)는 언제나 양수만 쓴다.
--      → 로그인 호출자가 슈퍼어드민이 아니면 amount <= 0 인 ticket_refund 줄을 LEDGER_REFUND_NONPOSITIVE(42501)로 거절한다 — RPC 안에서 나는 예외라 그 호출 전체가 롤백된다.
--        서버(SQL Editor · Edge service_role · 크론 = auth.uid() null)·슈퍼어드민은 그대로. 20261018_ledger_admin_type_guard 와 같은 덧대기 방식.
--
--   회귀: bash sql/_test/t_refund_facts_guard.sh
-- ═══════════════════════════════════════════════════════════════

-- ── A. 회원·매장 어드민이 만드는 카드 환불 대기는 언제나 「대기」 ──
create or replace function public.taam_guard_ticket_crp_member()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_crp jsonb;
  v_done_keys text[] := array['done_by','done_at','refunded_at','refunded_amount','requested_amount','toss_tx','toss_canceled_at','toss_balance_after','via','policy'];
begin
  if v_uid is null then return new; end if;                                   -- 서버(service_role · SQL Editor · Edge)는 그대로
  if coalesce(public.is_super_admin(v_uid), false) then return new; end if;  -- 슈퍼어드민 「완료 표시」·반환 화면은 그대로
  v_crp := new.extra_data -> 'card_refund_pending';
  if v_crp is null or jsonb_typeof(v_crp) <> 'object' then return new; end if;
  if (old.extra_data -> 'card_refund_pending') is not distinct from v_crp then return new; end if;   -- 이 갱신이 바꾼 것만 본다
  if (v_crp ->> 'status') is not distinct from 'pending' and not (v_crp ?| v_done_keys) then return new; end if;
  new.extra_data := jsonb_set(new.extra_data, '{card_refund_pending}', (v_crp - v_done_keys) || jsonb_build_object('status', 'pending'));
  return new;
exception when others then
  raise warning 'taam_guard_ticket_crp_member: % — 손대지 않고 통과', sqlerrm;
  return new;   -- 취소를 막지 않는다
end $$;
comment on function public.taam_guard_ticket_crp_member() is
  '회원·매장 어드민 세션이 쓰는 tickets.extra_data.card_refund_pending 은 status pending 으로 · 완료 칸은 지운다(완료는 슈퍼어드민·서버만). 예외 없음. 2026-11-01';

drop trigger if exists trg_taam_guard_ticket_crp_member on public.tickets;
create trigger trg_taam_guard_ticket_crp_member
  before update of extra_data on public.tickets
  for each row execute function public.taam_guard_ticket_crp_member();

-- ── B. 회원 세션은 ₩0·음수 환불 줄을 쓸 수 없다 ──
create or replace function public.taam_guard_ledger_refund_nonpos()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is not null
     and not coalesce(public.is_super_admin(auth.uid()), false)
     and coalesce(new.change_type, '') = 'ticket_refund'
     and coalesce(new.amount, 0) <= 0 then
    raise exception 'LEDGER_REFUND_NONPOSITIVE: 0원·음수 환불 줄(₩%)은 슈퍼어드민만 쓸 수 있습니다', coalesce(new.amount, 0)
      using errcode = '42501';
  end if;
  return new;
end $$;
comment on function public.taam_guard_ledger_refund_nonpos() is
  '회원 세션(auth.uid() 있고 슈퍼어드민 아님)이 amount <= 0 인 ticket_refund 원장 줄을 쓰면 거절(42501). 서버·슈퍼어드민은 그대로. 2026-11-01';

drop trigger if exists trg_taam_guard_ledger_refund_nonpos on public.deposit_transactions;
create trigger trg_taam_guard_ledger_refund_nonpos
  before insert on public.deposit_transactions
  for each row execute function public.taam_guard_ledger_refund_nonpos();

-- ── 확인 — 한 표 (❌ 가 없어야 정상 · 건수 줄은 정보) ──
select '① 트리거 trg_taam_guard_ticket_crp_member (before update of extra_data on tickets)' as 항목,
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgname = 'trg_taam_guard_ticket_crp_member' and c.relname = 'tickets' and not t.tgisinternal) then '✅' else '❌' end as 결과
union all select '② 트리거 trg_taam_guard_ledger_refund_nonpos (before insert on deposit_transactions)',
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgname = 'trg_taam_guard_ledger_refund_nonpos' and c.relname = 'deposit_transactions' and not t.tgisinternal) then '✅' else '❌' end
union all select '③ is_super_admin(uuid) 존재 · 결제 사실 칸 가드(taam_guard_ticket_payfacts) 공존',
       case when to_regprocedure('public.is_super_admin(uuid)') is null then '❌ is_super_admin 없음'
            when to_regproc('public.taam_guard_ticket_payfacts') is null then '⚠ 결제 사실 칸 가드 없음 — 20261022_card_refund_quote2.sql 먼저(이 파일만으로는 취소 뒤 변경을 못 막는다)'
            else '✅' end
union all select '④ 정보 — 회원이 취소하며 만든 대기(set_by_role member)인데 지금 「완료」인 줄 수 (정상 완료 + 옛 위조가 섞인다 · 처리자·토스 거래키가 없는 줄)',
       (select count(*) from public.tickets t
         where t.extra_data -> 'card_refund_pending' ->> 'status' = 'done'
           and t.extra_data -> 'card_refund_pending' ->> 'set_by_role' = 'member'
           and coalesce(t.extra_data -> 'card_refund_pending' ->> 'done_by', '') = ''
           and coalesce(t.extra_data -> 'card_refund_pending' ->> 'toss_tx', '') = '')::text
union all select '⑤ 정보 — 슈퍼어드민이 아닌 회원 원장의 0원·음수 ticket_refund 줄 중 「슈퍼어드민 처리」 표시가 없는 것 (회원이 직접 썼을 수 있는 모양)',
       (select count(*) from public.deposit_transactions d
         where d.change_type = 'ticket_refund' and coalesce(d.amount, 0) <= 0
           and coalesce(d.metadata ->> 'processed_by', '') <> 'super_admin'
           and nullif(d.metadata ->> 'server_caller', '') is null
           and not exists (select 1 from public.profiles p where p.id = d.user_id and p.role in ('superadmin','super_admin')))::text;
