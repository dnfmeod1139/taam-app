-- ═══════════════════════════════════════════════════════════════
-- 초대 결제 보안 2차 — 결제 한 줄은 한 초대에만 · 좌석 확정은 그 좌석의 구매 id 로 낸 결제만 · 살아 있는 초대 좌석의 결제는 어떤 구매 id 로도 환불 못 한다 (2026-10-22)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다. 마지막 표에 ❌ 가 없어야 정상.
-- 왜(1차 20261022_invite_payment_guard.sql 적대 리뷰 · 둘 다 재현):
--   ① _taam_invite_net_paid 가 invite_id 또는 'INV-<앞8>-' 구매 id 중 하나만 맞아도 셌다 → invite_id=X · purchase_id='INV-<Y앞8>-…' 인 결제 한 줄이
--      X 와 Y 두 초대에 동시에 잡혀 한 번 내고 두 좌석을 확정할 수 있었다.
--   ② 결제는 구매 id P1 로, 확정은 P2('INV-<앞8>-…' 면 확정 RPC 가 받는다)로 하면 좌석은 P2 로 살고, 가드 C 는 P1 의 살아 있는 티켓만 봐서
--      P1 로 낸 예치금 전액을 RPC 로 돌려받을 수 있었다(환불 한도도 P1 티켓이 없어 「옛 구매 — 낸 돈 전부」).
-- 무엇(덧대기 · 라이브 함수 본문은 그대로):
--   · _taam_invite_net_paid(초대, 회원, 구매 id 선택) — 결제 줄의 귀속: metadata.invite_id 가 있으면 **그 초대에만**, 없을 때만 INV-앞8 구매 id 로.
--     구매 id 를 주면 그 구매 id 로 낸 결제(+ 구매 id 없는 옛 줄)만 센다. 환불은 귀속된 결제의 구매 id · 같은 invite_id 로.
--   · 가드 B(좌석 확정)는 새 좌석의 purchase_id 로 센다 → 다른 구매 id 로 낸 돈으로 확정 불가. riPay 는 원장·확정이 같은 _riPurchaseId 라 그대로.
--   · 가드 C(회원 환불)에 한 겹: 환불하려는 구매 id 의 결제 줄이 어떤 초대에 귀속되고 그 초대의 좌석(extra_data.inviteId)이 살아 있으면 REFUND_TICKET_ACTIVE.
--     riPay 확정 실패 되돌림(좌석 없음)·취소 뒤 환불은 그대로.
-- 회귀: bash sql/_test/t_invite_guard.sh (1차 + 2차 사례)
-- ═══════════════════════════════════════════════════════════════

drop function if exists public._taam_invite_net_paid(uuid, uuid);
create or replace function public._taam_invite_net_paid(p_inv uuid, p_uid uuid, p_pid text default null)
returns bigint
language sql stable security definer set search_path = public
as $$
  with b as (
    select -d.amount::bigint as amt, nullif(d.metadata->>'purchase_id', '') as pid
      from public.deposit_transactions d
     where d.user_id = p_uid and d.change_type = 'ticket_purchase' and d.amount < 0
       and case when nullif(d.metadata->>'invite_id', '') is not null
                then d.metadata->>'invite_id' = p_inv::text                                         -- invite_id 가 있으면 그 초대에만
                else coalesce(d.metadata->>'purchase_id', '') like 'INV-' || left(p_inv::text, 8) || '-%' end
       and (p_pid is null or nullif(d.metadata->>'purchase_id', '') is null or d.metadata->>'purchase_id' = p_pid)
  ), r as (
    select d.amount::bigint as amt
      from public.deposit_transactions d
     where d.user_id = p_uid and d.change_type = 'ticket_refund' and d.amount > 0
       and (d.metadata->>'purchase_id' in (select pid from b where pid is not null)
            or (nullif(d.metadata->>'invite_id', '') is not null and d.metadata->>'invite_id' = p_inv::text
                and (p_pid is null or nullif(d.metadata->>'purchase_id', '') is null or d.metadata->>'purchase_id' = p_pid)))
  )
  select coalesce((select sum(amt) from b), 0) - coalesce((select sum(amt) from r), 0)
$$;
revoke all on function public._taam_invite_net_paid(uuid, uuid, text) from public, anon, authenticated;
comment on function public._taam_invite_net_paid(uuid, uuid, text) is
  '초대 순결제 — 결제 줄은 invite_id 가 있으면 그 초대에만(없을 때만 INV-앞8) · p_pid 를 주면 그 구매 id(와 id 없는 옛 줄)만 · 환불은 귀속 결제의 구매 id·같은 invite_id. 2026-10-22 2차';

-- 가드 B — 새 좌석의 purchase_id 로 낸 결제만
create or replace function public.taam_guard_invite_paid_seat()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_inv record; v_net bigint;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if lower(coalesce(new.status, '')) <> 'active' then return new; end if;
  if tg_op = 'UPDATE' and lower(coalesce(old.status, '')) = 'active' then return new; end if;
  if coalesce(new.extra_data->>'inviteId', '') = '' then return new; end if;
  begin
    select i.id, i.invitee_user_id, i.total_amount into v_inv
      from public.reservation_invites i where i.id::text = new.extra_data->>'inviteId';
  exception when others then return new; end;
  if v_inv.id is null then return new; end if;
  if v_uid is distinct from v_inv.invitee_user_id then return new; end if;
  v_net := public._taam_invite_net_paid(v_inv.id, v_inv.invitee_user_id, nullif(new.purchase_id, ''));   -- 2차: 이 좌석의 구매 id 로 낸 결제만
  if v_net < coalesce(v_inv.total_amount, 0) then
    raise exception 'INVITE_NOT_PAID: 초대 결제가 확인되지 않아 좌석을 확정하지 않습니다 (이 구매로 낸 결제 %원 · 초대 합계 %원)', v_net, coalesce(v_inv.total_amount, 0)
      using errcode = '42501';
  end if;
  return new;
end $$;

-- 가드 C — 살아 있는 초대 좌석의 결제는 어떤 구매 id 로도 회원이 스스로 환불 못 한다
create or replace function public.taam_guard_ledger_refund_active()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_pid text;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if coalesce(new.change_type, '') <> 'ticket_refund' or coalesce(new.amount, 0) <= 0 then return new; end if;
  v_pid := nullif(btrim(coalesce(new.metadata->>'purchase_id', '')), '');
  if v_pid is not null and exists (select 1 from public.tickets t
              where t.purchase_id = v_pid and t.user_id = new.user_id
                and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'hold', 'failed', 'refunded')) then
    raise exception 'REFUND_TICKET_ACTIVE: 티켓이 살아 있는 구매는 환불할 수 없습니다 — 먼저 취소해 주세요 (구매 %)', v_pid
      using errcode = '42501';
  end if;
  -- 2차: 이 환불(구매 id 또는 invite_id)이 가리키는 초대의 좌석이 살아 있으면 막는다 — 다른 구매 id 로 확정해 둔 좌석 포함
  if exists (
       select 1
         from public.deposit_transactions d
         join public.tickets t on t.extra_data->>'inviteId' = case when nullif(d.metadata->>'invite_id', '') is not null then d.metadata->>'invite_id' end
        where d.user_id = new.user_id and d.change_type = 'ticket_purchase' and d.amount < 0
          and ((v_pid is not null and d.metadata->>'purchase_id' = v_pid)
               or (nullif(new.metadata->>'invite_id', '') is not null and d.metadata->>'invite_id' = new.metadata->>'invite_id'))
          and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'hold', 'failed', 'refunded'))
     or (nullif(new.metadata->>'invite_id', '') is not null and exists (
          select 1 from public.tickets t where t.extra_data->>'inviteId' = new.metadata->>'invite_id'
             and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'expired', 'hold', 'failed', 'refunded'))) then
    raise exception 'REFUND_TICKET_ACTIVE: 초대 좌석이 살아 있어 이 결제는 환불할 수 없습니다 — 먼저 취소해 주세요'
      using errcode = '42501';
  end if;
  return new;
end $$;

-- ── 확인 — 한 표 ──
drop table if exists _tig2_chk; create temp table _tig2_chk(k text, v text);
insert into _tig2_chk
select '① 순결제 함수 3인자 판', case when to_regprocedure('public._taam_invite_net_paid(uuid,uuid,text)') is not null
                                       and to_regprocedure('public._taam_invite_net_paid(uuid,uuid)') is null then '✅' else '❌' end
union all select '② 가드 B 가 구매 id 로 센다', case when (select prosrc from pg_proc where oid = 'public.taam_guard_invite_paid_seat()'::regprocedure) like '%new.purchase_id%' then '✅' else '❌' end
union all select '③ 가드 C 가 초대 좌석을 본다', case when (select prosrc from pg_proc where oid = 'public.taam_guard_ledger_refund_active()'::regprocedure) like '%inviteId%' then '✅' else '❌' end
union all select '④ 트리거 셋 살아 있음', case when (select count(*) from pg_trigger where tgname in ('trg_taam_guard_invite_row','trg_taam_guard_invite_paid_seat','trg_taam_guard_ledger_refund_active') and not tgisinternal) = 3 then '✅' else '❌' end
union all select '⑤ paid 초대 중 순결제 < 합계 (정보 · 새 귀속 규칙)',
       (select count(*) from public.reservation_invites i where i.status = 'paid' and i.invitee_user_id is not null
           and public._taam_invite_net_paid(i.id, i.invitee_user_id) < coalesce(i.total_amount, 0))::text || '건'
union all select '⑥ 살아 있는 초대 좌석 중 그 좌석 구매 id 로 낸 결제 < 합계 (정보)',
       (select count(*) from public.tickets t join public.reservation_invites i on i.id::text = t.extra_data->>'inviteId'
         where lower(coalesce(t.status,'')) = 'active' and i.invitee_user_id is not null
           and public._taam_invite_net_paid(i.id, i.invitee_user_id, nullif(t.purchase_id, '')) < coalesce(i.total_amount, 0))::text || '건';
select k as 항목, v as 결과 from _tig2_chk order by 1;
