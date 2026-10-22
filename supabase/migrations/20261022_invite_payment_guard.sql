-- ═══════════════════════════════════════════════════════════════
-- 초대 결제 보안 — 받는 회원은 금액을 못 바꾸고, 결제가 원장에 있어야 「결제됨」·좌석 확정이 된다 · 살아 있는 티켓은 회원이 스스로 환불 못 한다 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). 마지막 표에 ❌ 가 없어야 정상.
-- 왜(라이브 진단 20261022_diag_invite_guard.sql):
--   ① reservation_invites 의 UPDATE 정책(resinv_update)은 받는 회원에게 자기 초대 행의 **모든 칸**을 허용하고 트리거가 없다 —
--      total_amount · pax · meal_fee · agency_fee · invitee_user_id · ticket_product_id … 앱 riPay 는 그 행의 total_amount 로 예치금을 뺀다
--      → 회원이 합계를 낮춰 덜 내거나, 인원을 늘려 같은 값에 좌석을 더 받을 수 있었다.
--   ② 확정 RPC taam_invite_confirm_hold 는 초대 status='paid' 만 보고 원장 결제를 확인하지 않는다 → 회원이 status 를 'paid' 로 바꾸고 부르면 돈 없이 좌석 확정.
--   ③ 회원 환불(taam_apply_deposit_delta → taam_refund_cap)은 티켓이 취소됐는지 보지 않는다 → 결제 30분 안(또는 D-31 이전)에 RPC 로 직접 환불받고
--      티켓은 살아 있는 모양이 됐다(초대 INV- · 앱 구매 PAYH- 공통). 앱의 정상 취소는 티켓을 먼저 취소하고 환불한다(cancelTicketPurchase).
--   지금까지 악용 흔적은 없다 — paid 초대 46건 전부 원장 결제 = 초대 합계(진단 E).
-- 무엇(전부 덧대기 · 라이브 함수 본문은 건드리지 않는다):
--   A. trg_taam_guard_invite_row (reservation_invites BEFORE UPDATE) — 받는 회원 본인 세션이면 status · paid_at · cancelled_at · invitee_seen 만 바뀐다
--      (나머지 칸은 되돌림 — 같은 UPDATE 의 다른 칸을 날리지 않게 예외 대신). status 를 'paid' 로 바꾸려면 원장 순결제(이 초대의 결제 − 환불) ≥ 초대 합계
--      (INVITE_NOT_PAID) · 취소·만료된 초대는 되살리지 못한다(INVITE_CLOSED). 보낸 사람(host) · 슈퍼어드민 · 서버(auth.uid() null)는 그대로.
--   B. trg_taam_guard_invite_paid_seat (tickets BEFORE INSERT/UPDATE OF status) — 초대 좌석(extra_data.inviteId)이 받는 회원 본인 세션에서 active 가 될 때
--      원장 순결제 ≥ 초대 합계여야 한다(INVITE_NOT_PAID) — 「결제 → 스스로 환불 → 확정」을 막는다. 어드민·서버 확정은 그대로.
--   C. trg_taam_guard_ledger_refund_active (deposit_transactions BEFORE INSERT) — 회원 세션의 양수 ticket_refund 는 그 구매의 티켓(본인 소유)이
--      살아 있으면(active · completed · manual · pending_confirm …) REFUND_TICKET_ACTIVE — 먼저 취소. 홀드·취소·만료·티켓 없음(초대 확정 실패 되돌림)은 그대로.
--      인원 줄임 환불(ticket_pax_change · 서버 함수) · 슈퍼어드민 · 서버(Edge·SQL Editor)는 그대로.
-- 회귀: bash sql/_test/t_invite_guard.sh
-- ═══════════════════════════════════════════════════════════════

-- 이 초대에 받는 회원이 실제로 낸 돈 − 그 결제의 환불 (원장 · 회원이 못 지우는 기록)
create or replace function public._taam_invite_net_paid(p_inv uuid, p_uid uuid)
returns bigint
language sql stable security definer set search_path = public
as $$
  with b as (
    select -d.amount::bigint as amt, nullif(d.metadata->>'purchase_id', '') as pid
      from public.deposit_transactions d
     where d.user_id = p_uid and d.change_type = 'ticket_purchase' and d.amount < 0
       and (d.metadata->>'invite_id' = p_inv::text
            or coalesce(d.metadata->>'purchase_id', '') like 'INV-' || left(p_inv::text, 8) || '-%')
  ), r as (
    select d.amount::bigint as amt
      from public.deposit_transactions d
     where d.user_id = p_uid and d.change_type = 'ticket_refund' and d.amount > 0
       and (d.metadata->>'invite_id' = p_inv::text
            or d.metadata->>'purchase_id' in (select pid from b where pid is not null))
  )
  select coalesce((select sum(amt) from b), 0) - coalesce((select sum(amt) from r), 0)
$$;
revoke all on function public._taam_invite_net_paid(uuid, uuid) from public, anon, authenticated;
comment on function public._taam_invite_net_paid(uuid, uuid) is
  '초대 순결제 = 받는 회원 원장의 이 초대 결제(ticket_purchase, invite_id 또는 INV-앞8자리) − 그 결제의 환불. 초대 가드 A·B 가 쓴다. 2026-10-22';

-- ── A. 초대 행 ──
create or replace function public.taam_guard_invite_row()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_net bigint;
begin
  if v_uid is null then return new; end if;                                       -- 서버 · SQL Editor
  if coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if v_uid is distinct from old.invitee_user_id or v_uid = old.host_user_id then return new; end if;   -- 받는 회원 본인 세션만 (보낸 사람은 그대로)

  -- 받는 회원이 바꿀 수 있는 칸만 남기고 나머지는 되돌린다 (표에 칸이 늘어도 기본은 「못 바꿈」)
  new := jsonb_populate_record(new, to_jsonb(old) - array['status', 'paid_at', 'cancelled_at', 'invitee_seen']);

  if new.status is distinct from old.status then
    if lower(coalesce(old.status, '')) in ('cancelled', 'canceled', 'expired') then
      raise exception 'INVITE_CLOSED: 취소·만료된 초대는 되살릴 수 없습니다 (상태 %)', old.status using errcode = '42501';
    end if;
    if lower(coalesce(new.status, '')) = 'paid' then
      v_net := public._taam_invite_net_paid(old.id, old.invitee_user_id);
      if v_net < coalesce(old.total_amount, 0) then
        raise exception 'INVITE_NOT_PAID: 결제가 확인되지 않았습니다 (원장 결제 %원 · 초대 합계 %원)', v_net, coalesce(old.total_amount, 0)
          using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end $$;
comment on function public.taam_guard_invite_row() is
  '초대 행: 받는 회원 세션은 status·paid_at·cancelled_at·invitee_seen 만(나머지 되돌림) · paid 는 원장 순결제 ≥ 합계 · 취소·만료 되살리기 금지. 2026-10-22';
drop trigger if exists trg_taam_guard_invite_row on public.reservation_invites;
create trigger trg_taam_guard_invite_row
  before update on public.reservation_invites
  for each row execute function public.taam_guard_invite_row();

-- ── B. 초대 좌석 확정 ──
create or replace function public.taam_guard_invite_paid_seat()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_inv record; v_net bigint;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if lower(coalesce(new.status, '')) <> 'active' then return new; end if;
  if tg_op = 'UPDATE' and lower(coalesce(old.status, '')) = 'active' then return new; end if;   -- 이미 확정된 행의 다른 갱신은 그대로
  if coalesce(new.extra_data->>'inviteId', '') = '' then return new; end if;
  begin
    select i.id, i.invitee_user_id, i.total_amount into v_inv
      from public.reservation_invites i where i.id::text = new.extra_data->>'inviteId';
  exception when others then return new; end;
  if v_inv.id is null then return new; end if;
  if v_uid is distinct from v_inv.invitee_user_id then return new; end if;        -- 받는 회원 본인 세션의 확정만 (보낸 어드민 경로는 그대로)
  v_net := public._taam_invite_net_paid(v_inv.id, v_inv.invitee_user_id);
  if v_net < coalesce(v_inv.total_amount, 0) then
    raise exception 'INVITE_NOT_PAID: 초대 결제가 확인되지 않아 좌석을 확정하지 않습니다 (원장 결제 %원 · 초대 합계 %원)', v_net, coalesce(v_inv.total_amount, 0)
      using errcode = '42501';
  end if;
  return new;
end $$;
comment on function public.taam_guard_invite_paid_seat() is
  '초대 좌석(extra_data.inviteId)이 받는 회원 세션에서 active 가 될 때 원장 순결제 ≥ 초대 합계여야 한다. 2026-10-22';
drop trigger if exists trg_taam_guard_invite_paid_seat on public.tickets;
create trigger trg_taam_guard_invite_paid_seat
  before insert or update of status on public.tickets
  for each row execute function public.taam_guard_invite_paid_seat();

-- ── C. 살아 있는 티켓의 회원 환불 ──
create or replace function public.taam_guard_ledger_refund_active()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_pid text;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if coalesce(new.change_type, '') <> 'ticket_refund' or coalesce(new.amount, 0) <= 0 then return new; end if;
  v_pid := nullif(btrim(coalesce(new.metadata->>'purchase_id', '')), '');
  if v_pid is null then return new; end if;
  if exists (select 1 from public.tickets t
              where t.purchase_id = v_pid and t.user_id = new.user_id
                and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'hold', 'failed', 'refunded')) then
    raise exception 'REFUND_TICKET_ACTIVE: 티켓이 살아 있는 구매는 환불할 수 없습니다 — 먼저 취소해 주세요 (구매 %)', v_pid
      using errcode = '42501';
  end if;
  return new;
end $$;
comment on function public.taam_guard_ledger_refund_active() is
  '회원 세션의 양수 ticket_refund 는 그 구매의 본인 티켓이 살아 있으면 거절(먼저 취소). 홀드·취소·만료·티켓 없음은 그대로. 2026-10-22';
drop trigger if exists trg_taam_guard_ledger_refund_active on public.deposit_transactions;
create trigger trg_taam_guard_ledger_refund_active
  before insert on public.deposit_transactions
  for each row execute function public.taam_guard_ledger_refund_active();

-- ── 확인 — 한 표 ──
drop table if exists _tig_chk; create temp table _tig_chk(k text, v text);
insert into _tig_chk
select '① 트리거 A trg_taam_guard_invite_row (reservation_invites)',
       case when exists (select 1 from pg_trigger t where t.tgname = 'trg_taam_guard_invite_row' and t.tgrelid = 'public.reservation_invites'::regclass and not t.tgisinternal) then '✅' else '❌' end
union all select '② 트리거 B trg_taam_guard_invite_paid_seat (tickets)',
       case when exists (select 1 from pg_trigger t where t.tgname = 'trg_taam_guard_invite_paid_seat' and t.tgrelid = 'public.tickets'::regclass and not t.tgisinternal) then '✅' else '❌' end
union all select '③ 트리거 C trg_taam_guard_ledger_refund_active (deposit_transactions)',
       case when exists (select 1 from pg_trigger t where t.tgname = 'trg_taam_guard_ledger_refund_active' and t.tgrelid = 'public.deposit_transactions'::regclass and not t.tgisinternal) then '✅' else '❌' end
union all select '④ is_super_admin(uuid) 존재', case when to_regprocedure('public.is_super_admin(uuid)') is not null then '✅' else '❌' end
union all select '⑤ 지금 paid 초대 중 원장 순결제 < 합계 (정보 · 0 이어야 깨끗)',
       (select count(*) from public.reservation_invites i
         where i.status = 'paid' and i.invitee_user_id is not null
           and public._taam_invite_net_paid(i.id, i.invitee_user_id) < coalesce(i.total_amount, 0))::text || '건'
union all select '⑥ 지금 살아 있는 초대 좌석 중 원장 순결제 < 합계 (정보)',
       (select count(*) from public.tickets t join public.reservation_invites i on i.id::text = t.extra_data->>'inviteId'
         where lower(coalesce(t.status,'')) = 'active' and i.invitee_user_id is not null
           and public._taam_invite_net_paid(i.id, i.invitee_user_id) < coalesce(i.total_amount, 0))::text || '건'
union all select '⑦ 살아 있는 티켓인데 회원 환불 줄이 있는 구매 (정보 · 방문 후 반환 등 어드민 처리 포함)',
       (select count(distinct d.metadata->>'purchase_id') from public.deposit_transactions d join public.tickets t
           on t.purchase_id = d.metadata->>'purchase_id' and t.user_id = d.user_id
         where d.change_type = 'ticket_refund' and d.amount > 0
           and lower(coalesce(t.status,'')) not in ('cancelled','canceled','expired','hold','failed','refunded'))::text || '건';
select k as 항목, v as 결과 from _tig_chk order by 1;
