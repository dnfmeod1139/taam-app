-- ═══════════════════════════════════════════════════════════════
-- TAAM — 캘린더·초대 좌석 홀드(A안) + 파트너 어드민 권한 (2026-08)
-- Supabase SQL Editor 에서 실행 (idempotent)
-- ① 초대 발송 시 좌석 홀드(INVH- 행) → 결제/취소 시 해제하는 RPC
-- ② 파트너 어드민이 "자기 매장" 한정으로 초대 발송·수동 예약 가능하도록 RLS 확장
-- ═══════════════════════════════════════════════════════════════

-- ── 1) 헬퍼: 이 사용자가 해당 매장의 파트너 어드민인가 (admin_grants 기반) ──
create or replace function public.taam_is_rest_admin(p_rest_id text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.admin_grants g
     where g.user_id = auth.uid()
       and coalesce(trim(p_rest_id),'') <> ''
       and ( coalesce(nullif(g.rest_id::text,''),'')  = trim(p_rest_id)
          or coalesce(nullif(g.venue_id::text,''),'') = trim(p_rest_id) )
  );
$$;
grant execute on function public.taam_is_rest_admin(text) to authenticated;

-- ── 2) 초대 홀드 해제 RPC ──
--   초대의 invitee(결제/취소), host(발송자), 슈퍼어드민, 해당 매장 어드민만 호출 가능.
--   INVH-<초대ID8>- 로 시작하는 tickets 행을 cancelled 처리 → 좌석 즉시 복구.
create or replace function public.taam_release_invite_hold(p_invite_id text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_inv record;
  v_cnt int := 0;
begin
  select * into v_inv from public.reservation_invites where id::text = p_invite_id;
  if not found then
    return json_build_object('ok', false, 'error', 'invite not found');
  end if;
  if not ( auth.uid() = v_inv.invitee_user_id
        or auth.uid() = v_inv.host_user_id
        or is_super_admin(auth.uid())
        or public.taam_is_rest_admin(v_inv.restaurant_id) ) then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  update public.tickets
     set status = 'cancelled'
   where purchase_id like 'INVH-' || substr(p_invite_id, 1, 8) || '-%'
     and coalesce(status,'') <> 'cancelled';
  get diagnostics v_cnt = row_count;
  return json_build_object('ok', true, 'released', v_cnt);
end;
$$;
revoke execute on function public.taam_release_invite_hold(text) from public;
grant  execute on function public.taam_release_invite_hold(text) to authenticated;

-- ── 3) reservation_invites — 파트너 어드민 확장 ──
--   INSERT: 슈퍼어드민 또는 "자기 매장" 어드민 (host 는 본인)
drop policy if exists "resinv_insert" on public.reservation_invites;
create policy "resinv_insert" on public.reservation_invites
  for insert with check (
    host_user_id = auth.uid()
    and ( is_super_admin(auth.uid()) or public.taam_is_rest_admin(restaurant_id) )
  );

--   UPDATE: invitee(결제·취소) / 슈퍼어드민 / host 본인
drop policy if exists "resinv_update" on public.reservation_invites;
create policy "resinv_update" on public.reservation_invites
  for update using (
    auth.uid() = invitee_user_id
    or auth.uid() = host_user_id
    or is_super_admin(auth.uid())
  );

--   DELETE: 슈퍼어드민 또는 host 본인 (발송 직후 좌석부족 롤백용)
drop policy if exists "resinv_delete" on public.reservation_invites;
create policy "resinv_delete" on public.reservation_invites
  for delete using (
    is_super_admin(auth.uid()) or auth.uid() = host_user_id
  );

-- ── 4) daegwan_manual — 파트너 어드민이 자기 매장 수동예약(비연결) 기록 가능 ──
drop policy if exists "daegwan_manual_rest_admin" on public.daegwan_manual;
create policy "daegwan_manual_rest_admin" on public.daegwan_manual
  for all using ( public.taam_is_rest_admin(venue_id) )
  with check ( public.taam_is_rest_admin(venue_id) );

do $$ begin raise notice '✅ 초대 좌석 홀드 RPC + 파트너 어드민 캘린더/초대 권한 설치 완료'; end $$;
