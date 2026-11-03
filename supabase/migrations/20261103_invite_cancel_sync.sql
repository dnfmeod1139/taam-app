-- ═══════════════════════════════════════════════════════════════
-- TAAM — 초대 좌석(INV-)이 취소되면 초대장도 「취소」로 (2026-11-03 · 타카미츠 12/18)
-- ═══════════════════════════════════════════════════════════════
--   슈퍼어드민이 예치금 관리에서 타카미츠 12/18 초대 티켓(3인)을 위약 환불로 처리했다 — 티켓은 cancelled, 예치금은 환불,
--   좌석이 풀려 회원 전원에게 「취소표가 나왔습니다」까지 나갔는데 reservation_invites 는 'paid' 그대로였다.
--   캘린더는 초대 예약을 **초대장 표(paid)에서** 그리므로 「초대 유수봉 3명 · 잔여 0」이 남았다(서버는 3석이 비었다고 본다).
--   회원 본인 취소(cancelTicketPurchase → _invMarkCancelledByPurchase)만 초대장을 내리고, 슈퍼어드민 반환·환불(_dmPersistBuyerChanges)·
--   그 밖의 경로는 안 내렸다. → 어느 경로든 티켓 행이 취소되는 순간 서버가 맞춘다.
--
--   규칙: tickets 의 status 가 취소·환불로 바뀌고, purchase_id 가 'INV-'(결제된 초대 좌석 — 홀드 INVH- 는 결제 전이라 아님)이고,
--         같은 초대(extra_data.inviteId)의 살아 있는 좌석 행이 더 없으면 → 그 초대장이 'paid' 일 때만 'cancelled' + cancelled_at.
--   · 「결제했었다」는 사실은 원장(deposit_transactions)에 그대로 남는다(앱의 같은 동작 · 2026-08-28 주석).
--   · 초대장 가드(host · row)는 status → cancelled 를 모든 세션에 허용한다(되살리기만 막는다) — 이 트리거가 걸려 넘어지지 않는다.
--   · 예외는 삼킨다(warning) — 초대장 정리가 티켓 취소·환불을 막으면 안 된다.
--   · 이미 어긋난 줄은 아래에서 한 번 맞춘다(2026-11-03 라이브 진단: 타카미츠 1건 — 이미 손으로 맞췄다 · 건수만 찍는다 · 공개 로그).
--
--   회귀: bash sql/_test/t_invite_cancel_sync.sh
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_invite_sync_on_seat_cancel()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_inv text;
begin
  if new.status is not distinct from old.status then return new; end if;
  if lower(coalesce(new.status, '')) not in ('cancelled', 'canceled', 'refunded') then return new; end if;
  if coalesce(new.purchase_id, '') not like 'INV-%' then return new; end if;
  v_inv := nullif(btrim(coalesce(new.extra_data ->> 'inviteId', '')), '');
  if v_inv is null or v_inv !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return new; end if;
  if exists (select 1 from public.tickets t
              where t.purchase_id is distinct from new.purchase_id
                and t.extra_data ->> 'inviteId' = v_inv
                and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'refunded', 'expired', 'failed')) then
    return new;   -- 같은 초대의 다른 좌석이 아직 살아 있다
  end if;
  update public.reservation_invites
     set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now())
   where id = v_inv::uuid and status = 'paid';
  return new;
exception when others then
  raise warning 'taam_invite_sync_on_seat_cancel: % — 초대장은 그대로', sqlerrm;
  return new;
end $$;
comment on function public.taam_invite_sync_on_seat_cancel() is
  '초대 좌석(INV-)이 취소·환불되고 같은 초대의 살아 있는 좌석이 없으면 reservation_invites 를 paid → cancelled. 예외는 삼킨다. 2026-11-03';
revoke all on function public.taam_invite_sync_on_seat_cancel() from public, anon, authenticated;

drop trigger if exists trg_taam_invite_sync_on_seat_cancel on public.tickets;
create trigger trg_taam_invite_sync_on_seat_cancel
  after update of status on public.tickets
  for each row execute function public.taam_invite_sync_on_seat_cancel();

-- ── 이미 어긋난 줄 한 번 맞추기 (여러 번 RUN 해도 같다) ──
create temp table _taam_ics_fixed (n int);
with fx as (
  update public.reservation_invites i
     set status = 'cancelled', cancelled_at = coalesce(i.cancelled_at, now())
   where i.status = 'paid'
     and exists (select 1 from public.tickets t
                  where t.extra_data ->> 'inviteId' = i.id::text and t.purchase_id like 'INV-%'
                    and lower(coalesce(t.status, '')) in ('cancelled', 'canceled', 'refunded'))
     and not exists (select 1 from public.tickets t
                      where t.extra_data ->> 'inviteId' = i.id::text
                        and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'refunded', 'expired', 'failed'))
  returning i.id
)
insert into _taam_ics_fixed select count(*)::int from fx;

-- ── 확인 — 한 표 (❌ 가 없어야 정상 · 건수 줄은 정보) ──
select '① 트리거 trg_taam_invite_sync_on_seat_cancel (after update of status on tickets)' as 항목,
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgname = 'trg_taam_invite_sync_on_seat_cancel' and c.relname = 'tickets' and not t.tgisinternal) then '✅' else '❌' end as 결과
union all select '② 함수 security definer · 회원 직접 실행 불가',
       case when exists (select 1 from pg_proc p where p.proname = 'taam_invite_sync_on_seat_cancel' and p.pronamespace = 'public'::regnamespace and p.prosecdef)
             and not has_function_privilege('authenticated', 'public.taam_invite_sync_on_seat_cancel()', 'execute') then '✅' else '❌' end
union all select '③ 정보 — 이번에 맞춘 초대장 수 (결제 완료로 남아 있었는데 초대 좌석은 취소된 것)',
       (select n::text from _taam_ics_fixed)
union all select '④ 남은 어긋남 — 결제 완료 초대장인데 그 초대의 INV- 좌석이 전부 취소 (0 이어야 정상)',
       case when (select count(*) from public.reservation_invites i
                   where i.status = 'paid'
                     and exists (select 1 from public.tickets t where t.extra_data ->> 'inviteId' = i.id::text and t.purchase_id like 'INV-%'
                                   and lower(coalesce(t.status, '')) in ('cancelled', 'canceled', 'refunded'))
                     and not exists (select 1 from public.tickets t where t.extra_data ->> 'inviteId' = i.id::text
                                       and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'refunded', 'expired', 'failed'))) = 0
            then '✅ 0' else '❌ 남음' end;
