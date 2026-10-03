-- ============================================================================
-- 20261004_invite_owner_guard.sql — 초대 티켓의 소유자는 언제나 초대받은 회원 (2026-10-04)
-- ============================================================================
-- 경위 (2026-10-03 타카미츠 3인): 캘린더 초대는 좌석 홀드(INVH-)를 **보낸 어드민**의 user_id 로 만든다. 9/28 의 확정 함수
-- (taam_invite_confirm_hold)가 그 홀드를 active 로 바꾸며 소유자를 안 바꿔, 예치금은 회원에게서 빠졌는데 티켓은 슈퍼어드민
-- 것이 됐다. 확정 함수는 10/03 에 고쳤다(20261003_invite_confirm_owner.sql). 이 파일은 **재발 방지 한 겹**이다 —
-- 어떤 경로(RPC·Edge·SQL Editor·앞으로 생길 코드)로 확정되든, 초대 id 가 적힌 확정 행의 소유자는 트리거가
-- reservation_invites.invitee_user_id 로 맞춘다. 홀드(hold) 상태는 그대로 둔다 — 홀드는 어드민 소유여야 좌석 트리거를 지난다.
-- ============================================================================
create or replace function public.taam_guard_invite_owner()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  if coalesce(new.status, '') <> 'active' then return new; end if;
  if coalesce(new.extra_data->>'inviteId', '') = '' and coalesce(new.purchase_id, '') not like 'INV-%' then return new; end if;
  if coalesce(new.extra_data->>'inviteId', '') = '' then return new; end if;   -- 초대 id 없는 옛 INV- 행은 건드리지 않는다
  select i.invitee_user_id into v_owner from public.reservation_invites i where i.id::text = new.extra_data->>'inviteId';
  if v_owner is null then return new; end if;
  if new.user_id is distinct from v_owner then
    new.extra_data := coalesce(new.extra_data, '{}'::jsonb)
                      || jsonb_build_object('owner_guarded_at', now(), 'owner_was', coalesce(new.user_id::text, ''));
    new.user_id := v_owner;
  end if;
  return new;
end $$;
drop trigger if exists trg_taam_guard_invite_owner on public.tickets;
create trigger trg_taam_guard_invite_owner
  before insert or update of status, user_id on public.tickets
  for each row execute function public.taam_guard_invite_owner();

-- ── 확인 (한 표) — ❌ 가 없어야 정상 ──
select '① 소유자 가드 트리거' as what,
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_invite_owner') then '✅' else '❌' end as result
union all
select '② 지금 어긋난 초대 확정 행',
       case when not exists (select 1 from public.tickets t join public.reservation_invites i on i.id::text = t.extra_data->>'inviteId'
                              where t.purchase_id like 'INV-%' and coalesce(t.status,'') <> 'cancelled'
                                and i.invitee_user_id is not null and t.user_id is distinct from i.invitee_user_id)
            then '✅ 0건' else '❌ 있음 — sql/invite_owner_repair_2026-10-03.sql' end;
