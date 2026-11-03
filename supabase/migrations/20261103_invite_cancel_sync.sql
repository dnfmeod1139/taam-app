-- ═══════════════════════════════════════════════════════════════
-- TAAM — 초대 좌석(INV-)이 취소되면 초대장도 「취소」로 · 인원 줄일 때 남긴 대행비는 회원 취소로 돌려주지 않는다 (2026-11-03 · 타카미츠 12/18)
-- ═══════════════════════════════════════════════════════════════
--   A. 슈퍼어드민이 예치금 관리에서 타카미츠 12/18 초대 티켓(3인)을 위약 환불로 처리했다 — 티켓은 cancelled, 예치금은 환불,
--      좌석이 풀려 회원 전원에게 「취소표가 나왔습니다」까지 나갔는데 reservation_invites 는 'paid' 그대로였다.
--      캘린더는 초대 예약을 **초대장 표(paid)에서** 그리므로 「초대 유수봉 3명 · 잔여 0」이 남았다(서버는 3석이 비었다고 본다).
--      회원 본인 취소(cancelTicketPurchase → _invMarkCancelledByPurchase)만 초대장을 내리고, 슈퍼어드민 반환·환불(_dmPersistBuyerChanges)·
--      그 밖의 경로는 안 내렸다. → 어느 경로든 티켓 행이 취소되는 순간 서버가 맞춘다.
--
--      규칙: tickets 의 status 가 취소·환불로 바뀌고, purchase_id 가 'INV-'(결제된 초대 좌석 — 홀드 INVH- 는 결제 전이라 아님)이고,
--            **방문 후 반환이 아니고**(extra_data.deposit_return.type = 'returned' — 반환 화면은 방문한 예약도 status 를 cancelled 로 쓴다 ·
--            적대 리뷰: 그대로 두면 다녀온 초대가 전부 「취소」가 됐다), 같은 초대의 살아 있는 좌석 행이 더 없으면 → 그 초대장이 'paid' 일 때만 'cancelled'.
--      초대 찾기: extra_data.inviteId, 없으면(9/13 전 앱이 넣은 옛 좌석) purchase_id 의 'INV-' 뒤 8자 + 받는 회원 = 좌석 주인으로 정확히 한 장일 때만
--               (taam_invite_confirm_hold · 판매 현황 · 리마인드와 같은 짝짓기).
--      · 「결제했었다」는 사실은 원장(deposit_transactions)에 그대로 남는다(앱의 같은 동작 · 2026-08-28 주석).
--      · 초대장 가드(host · row)는 status → cancelled 를 모든 세션에 허용한다(되살리기만 막는다) — 이 트리거가 걸려 넘어지지 않는다.
--      · 예외는 삼킨다(warning) — 초대장 정리가 티켓 취소·환불을 막으면 안 된다.
--      · 이미 어긋난 줄은 아래에서 한 번 맞춘다(2026-11-03 라이브 진단: 타카미츠 1건 — 이미 손으로 맞췄다 · 건수만 찍는다 · 공개 로그).
--
--   B. 회원 예치금 환불 한도(trg_taam_guard_ledger_refund_paid · 20261022)에 「인원 줄일 때 남긴 대행비」를 더한다 — 적대 리뷰(재현).
--      서버 인원 변경(taam_change_party_size)은 구매 30분 뒤라면 줄인 사람의 대행비를 돌려주지 않고 price 에 남긴다(2인 ₩1,800,000 → 1인:
--      환불 ₩750,000 · price ₩1,050,000). 취소 규정(앱 · taam_refund_cap)은 「지금 인원 × 대행비」만 빼서 그 ₩150,000 이 다시 돌아갔다.
--      → 카드가 섞이지 않은 구매는 회원 환불 합이 「낸 돈 − 남긴 대행비 − 지금 인원 대행비」를 못 넘는다(남긴 대행비가 있을 때만 —
--        그런 변경이 있었으면 구매 30분은 이미 지났고 회원 환불 규정은 「대행비 제외」뿐이다 · 좌석 상실 되돌림 같은 전액 환원 경로는 인원 변경이 없다). 남긴 대행비 = 변경마다 min(줄인 인원 × 대행비,
--        줄인 인원 × 변경 전 1인 몫 − 그때 돌려준 돈) · 구매 30분 안의 변경은 0(그때는 대행비까지 돌려줬다). pax_changes 는 회원이 못 바꾸는 칸이다.
--        카드가 섞인 구매의 카드 몫은 사람이 처리한다(taam_card_refund_quote 가 인원 변경 구매를 거절 → 상점관리자) — 앱이 같은 식으로 미리 뺀다.
--      본문은 저장소 판(md5 ab336eb3…)과 같을 때만 바꾼다 · 이미 새 판이면 그대로 · 모르는 판이면 ❌ 로 알리고 건너뛴다.
--
--   회귀: bash sql/_test/t_invite_cancel_sync.sh
-- ═══════════════════════════════════════════════════════════════

-- ── A. 초대장 동기화 ──
create or replace function public._taam_seat_invite_id(p_purchase_id text, p_extra jsonb, p_user uuid)
returns uuid
language plpgsql stable security definer set search_path = public
as $$
declare v text; v_ids uuid[];
begin
  v := nullif(btrim(coalesce(p_extra ->> 'inviteId', '')), '');
  if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return v::uuid; end if;
  if v is not null then return null; end if;                                 -- 적혀는 있는데 모양이 이상하면 짐작하지 않는다
  if coalesce(p_purchase_id, '') !~ '^INV-[0-9a-fA-F]{8}' or p_user is null then return null; end if;
  select array_agg(i.id) into v_ids from public.reservation_invites i
   where left(i.id::text, 8) = lower(substr(p_purchase_id, 5, 8)) and i.invitee_user_id = p_user;
  if coalesce(array_length(v_ids, 1), 0) = 1 then return v_ids[1]; end if;
  return null;
end $$;
comment on function public._taam_seat_invite_id(text, jsonb, uuid) is
  '좌석 행의 초대 id — extra_data.inviteId, 없으면 INV- 뒤 8자 + 받는 회원으로 정확히 한 장. 2026-11-03';
revoke all on function public._taam_seat_invite_id(text, jsonb, uuid) from public, anon, authenticated;

create or replace function public.taam_invite_sync_on_seat_cancel()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_inv uuid;
begin
  if new.status is not distinct from old.status then return new; end if;
  if lower(coalesce(new.status, '')) not in ('cancelled', 'canceled', 'refunded') then return new; end if;
  if coalesce(new.purchase_id, '') not like 'INV-%' then return new; end if;
  if coalesce(new.extra_data -> 'deposit_return' ->> 'type', '') = 'returned' then return new; end if;   -- 방문 후 반환 — 예약은 다녀왔다
  v_inv := public._taam_seat_invite_id(new.purchase_id, new.extra_data, new.user_id);
  if v_inv is null then return new; end if;
  if exists (select 1 from public.tickets t
              where t.purchase_id is distinct from new.purchase_id
                and public._taam_seat_invite_id(t.purchase_id, t.extra_data, t.user_id) = v_inv
                and lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'refunded', 'expired', 'failed')
                and (t.extra_data ->> 'inviteId' = v_inv::text or t.purchase_id like 'INV-' || left(v_inv::text, 8) || '%')) then
    return new;   -- 같은 초대의 다른 좌석이 아직 살아 있다
  end if;
  update public.reservation_invites
     set status = 'cancelled', cancelled_at = coalesce(cancelled_at, now())
   where id = v_inv and status = 'paid';
  return new;
exception when others then
  raise warning 'taam_invite_sync_on_seat_cancel: % — 초대장은 그대로', sqlerrm;
  return new;
end $$;
comment on function public.taam_invite_sync_on_seat_cancel() is
  '초대 좌석(INV-)이 취소·환불되고(방문 후 반환 제외) 같은 초대의 살아 있는 좌석이 없으면 reservation_invites 를 paid → cancelled. 예외는 삼킨다. 2026-11-03';
revoke all on function public.taam_invite_sync_on_seat_cancel() from public, anon, authenticated;

drop trigger if exists trg_taam_invite_sync_on_seat_cancel on public.tickets;
create trigger trg_taam_invite_sync_on_seat_cancel
  after update of status on public.tickets
  for each row execute function public.taam_invite_sync_on_seat_cancel();

-- 이미 어긋난 줄 — 결제 완료 초대장인데 그 초대의 좌석이 전부 취소(방문 후 반환 아님)
create temp table _taam_ics_bad as
select i.id
  from public.reservation_invites i
 where i.status = 'paid'
   and exists (select 1 from public.tickets t
                where t.purchase_id like 'INV-' || left(i.id::text, 8) || '%'
                  and public._taam_seat_invite_id(t.purchase_id, t.extra_data, t.user_id) = i.id
                  and lower(coalesce(t.status, '')) in ('cancelled', 'canceled', 'refunded')
                  and coalesce(t.extra_data -> 'deposit_return' ->> 'type', '') <> 'returned')
   and not exists (select 1 from public.tickets t
                    where (t.extra_data ->> 'inviteId' = i.id::text or t.purchase_id like 'INV-' || left(i.id::text, 8) || '%')
                      and public._taam_seat_invite_id(t.purchase_id, t.extra_data, t.user_id) = i.id
                      and (lower(coalesce(t.status, '')) not in ('cancelled', 'canceled', 'refunded', 'expired', 'failed')
                           or coalesce(t.extra_data -> 'deposit_return' ->> 'type', '') = 'returned'));
create temp table _taam_ics_fixed (n int);
with fx as (
  update public.reservation_invites i set status = 'cancelled', cancelled_at = coalesce(i.cancelled_at, now())
   where i.id in (select id from _taam_ics_bad) and i.status = 'paid'
  returning i.id
)
insert into _taam_ics_fixed select count(*)::int from fx;

-- ── B. 회원 예치금 환불 한도 + 인원 줄일 때 남긴 대행비 ──
create temp table _taam_ics_b (st text);
do $b$
declare v_src text; v_md5 text; v_new text;
begin
  select prosrc, md5(prosrc) into v_src, v_md5 from pg_proc
   where proname = 'taam_guard_ledger_refund_paid' and pronamespace = 'public'::regnamespace;
  if v_src is null then insert into _taam_ics_b values ('⚠ 함수 없음 — 20261022_card_refund_quote2.sql 먼저'); return; end if;
  if position('KEPT_AGENCY_20261103' in v_src) > 0 then insert into _taam_ics_b values ('✅ 이미 새 판'); return; end if;
  if v_md5 <> 'ab336eb3e74d8e5ce6f952cab67ea817' then insert into _taam_ics_b values ('❌ 모르는 판(md5 ' || v_md5 || ') — 건너뜀'); return; end if;
  v_new := $f$
-- KEPT_AGENCY_20261103 — 인원 줄일 때 남긴 대행비(카드가 섞이지 않은 구매)
declare v_uid uuid := auth.uid(); v_pid text; v_paid bigint; v_back bigint;
        v_kept bigint := 0; v_tk record; v_ag bigint := 0; pc jsonb; v_from int; v_to int; v_pb numeric; v_rf numeric; v_at timestamptz;
begin
  if v_uid is null or coalesce(public.is_super_admin(v_uid), false) then return new; end if;
  if coalesce(new.change_type, '') <> 'ticket_refund' or coalesce(new.amount, 0) <= 0 then return new; end if;
  v_pid := nullif(btrim(coalesce(new.metadata->>'purchase_id', '')), '');
  if v_pid is null then return new; end if;
  select coalesce(-sum(d.amount), 0) into v_paid from public.deposit_transactions d
   where d.user_id = new.user_id and d.change_type = 'ticket_purchase' and d.amount < 0 and d.metadata->>'purchase_id' = v_pid;
  select coalesce(sum(d.amount), 0) into v_back from public.deposit_transactions d
   where d.user_id = new.user_id and d.change_type in ('ticket_refund', 'ticket_pax_change') and d.amount > 0 and d.metadata->>'purchase_id' = v_pid;
  begin
    select tk.created_at, tk.extra_data, tk.ticket_product_id, tk.party_size into v_tk
      from public.tickets tk where tk.user_id = new.user_id and tk.purchase_id = v_pid limit 1;
    if found and jsonb_typeof(v_tk.extra_data -> 'pax_changes') = 'array'
       and not ((coalesce(v_tk.extra_data->>'cardPaid', '') ~ '^\d{1,12}$' and (v_tk.extra_data->>'cardPaid')::bigint > 0)
                or coalesce(v_tk.extra_data->>'paidBy', '') in ('card+deposit', 'card')) then
      select coalesce(tp.agency_fee, 0) into v_ag from public.ticket_products tp where tp.id::text = v_tk.ticket_product_id::text;
      v_ag := greatest(coalesce(v_ag, 0), case when coalesce(v_tk.extra_data->>'agencyFee', '') ~ '^\d{1,9}$' then (v_tk.extra_data->>'agencyFee')::bigint else 0 end);
      for pc in select value from jsonb_array_elements(v_tk.extra_data -> 'pax_changes') loop
        if coalesce(pc->>'from', '') !~ '^\d{1,4}$' or coalesce(pc->>'to', '') !~ '^\d{1,4}$' then continue; end if;
        v_from := (pc->>'from')::int; v_to := (pc->>'to')::int;
        if v_from <= v_to then continue; end if;
        v_at := null;
        begin v_at := (pc->>'at')::timestamptz; exception when others then v_at := null; end;
        if v_at is not null and v_tk.created_at is not null and v_at <= v_tk.created_at + interval '30 minutes' then continue; end if;
        v_pb := case when coalesce(pc->>'price_before', '') ~ '^\d{1,12}$' then (pc->>'price_before')::numeric else null end;
        v_rf := case when coalesce(pc->>'refund', '') ~ '^\d{1,12}$' then (pc->>'refund')::numeric else 0 end;
        v_kept := v_kept + case when v_pb is null then (v_from - v_to) * v_ag
                                else least((v_from - v_to) * v_ag, greatest(0, (v_from - v_to) * floor(v_pb / v_from) - v_rf))::bigint end;
      end loop;
      -- 줄일 때 남긴 대행비가 있으면 구매 30분은 이미 지났다 — 회원 환불은 「대행비 제외」 규정만 남는다(지금 인원 대행비도 못 돌려준다)
      if v_kept > 0 then v_kept := v_kept + v_ag * greatest(coalesce(v_tk.party_size, 1), 1); end if;
    end if;
  exception when others then v_kept := 0;
  end;
  if v_back + new.amount > v_paid - v_kept then
    raise exception 'LEDGER_REFUND_EXCEEDS_PAID: 구매 % 예치금 % · 이미 돌려줌(환불·인원 줄임) % · 남긴 대행비(+지금 인원 대행비) % · 이번 % — 넘습니다', v_pid, v_paid, v_back, v_kept, new.amount
      using errcode = '42501';
  end if;
  return new;
end $f$;
  execute format('create or replace function public.taam_guard_ledger_refund_paid() returns trigger language plpgsql security definer set search_path = public as %L', v_new);
  insert into _taam_ics_b values ('✅ 교체');
end $b$;

-- ── 확인 — 한 표 (❌ 가 없어야 정상 · 건수 줄은 정보) ──
select '① 트리거 trg_taam_invite_sync_on_seat_cancel (after update of status on tickets)' as 항목,
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                          where t.tgname = 'trg_taam_invite_sync_on_seat_cancel' and c.relname = 'tickets' and not t.tgisinternal) then '✅' else '❌' end as 결과
union all select '② 함수 security definer · 회원 직접 실행 불가',
       case when exists (select 1 from pg_proc p where p.proname = 'taam_invite_sync_on_seat_cancel' and p.pronamespace = 'public'::regnamespace and p.prosecdef)
             and not has_function_privilege('authenticated', 'public.taam_invite_sync_on_seat_cancel()', 'execute')
             and not has_function_privilege('authenticated', 'public._taam_seat_invite_id(text, jsonb, uuid)', 'execute') then '✅' else '❌' end
union all select '③ 정보 — 이번에 맞춘 초대장 수 (결제 완료로 남아 있었는데 초대 좌석은 취소된 것 · 방문 후 반환 제외)',
       (select n::text from _taam_ics_fixed)
union all select '④ 남은 어긋남 — 결제 완료 초대장인데 그 초대의 좌석이 전부 취소 (0 이어야 정상)',
       case when (select count(*) from public.reservation_invites i where i.id in (select id from _taam_ics_bad) and i.status = 'paid') = 0
            then '✅ 0' else '❌ 남음' end
union all select '⑤ 회원 환불 한도에 인원 줄일 때 남긴 대행비 (taam_guard_ledger_refund_paid)', (select st from _taam_ics_b limit 1);
