-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 회원 「시작일」: 첫 초대 또는 첫 티켓 구매 중 빠른 날 · 2026-10-13
--
-- 왜 — 초대제라 가입 뒤 한참 지나 첫 구매가 이뤄지기도 한다. 1년 유지 기간의 시작을
--   가입일이 아니라 「첫 초대 또는 첫 구매」로 보려고 두 날짜를 따로 보여 준다.
--   아직 둘 다 없으면 「시작 전」. 지금은 **표시만** 한다 — 멤버십 만료(membership_expires_at)
--   계산은 건드리지 않는다.
--
-- 무엇을 세나
--   · 첫 구매: tickets 에서 좌석을 실제로 가진 행(취소·홀드·만료 제외, PAYH-/INVH- 홀드 제외,
--     운영 행 KSK-/LINK-/MAN- 제외)의 가장 이른 created_at. 옛 구매(tickets 이전)는
--     deposit_transactions 의 ticket_purchase 원장 줄로 보완한다.
--   · 첫 초대: reservation_invites 에서 결제까지 간 초대(paid)의 created_at(초대한 날).
--   · 시작일 = 둘 중 빠른 날. 본인 또는 슈퍼어드민만 조회.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.taam_member_start(p_uid uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  u uuid := coalesce(p_uid, auth.uid());
  v_signup timestamptz; v_tk timestamptz; v_led timestamptz; v_inv timestamptz;
  v_buy timestamptz; v_start timestamptz; v_kind text;
begin
  if u is null then return null; end if;
  if u <> auth.uid() and not public._taam_uid_is_super() then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select p.created_at into v_signup from public.profiles p where p.id = u;
  if not found then return null; end if;

  select min(t.created_at) into v_tk
    from public.tickets t
   where t.user_id = u
     and coalesce(t.status, '') not in ('cancelled', 'hold', 'expired')
     and coalesce(t.purchase_id, '') not like 'PAYH-%'
     and coalesce(t.purchase_id, '') not like 'INVH-%'
     and coalesce(t.purchase_id, '') not like 'KSK-%'
     and coalesce(t.purchase_id, '') not like 'LINK-%'
     and coalesce(t.purchase_id, '') not like 'MAN-%';
  if to_regclass('public.deposit_transactions') is not null then
    select min(d.created_at) into v_led
      from public.deposit_transactions d
     where d.user_id = u and d.change_type = 'ticket_purchase';
  end if;
  if to_regclass('public.reservation_invites') is not null then
    select min(i.created_at) into v_inv
      from public.reservation_invites i
     where i.invitee_user_id = u and i.status = 'paid';
  end if;

  v_buy   := least(v_tk, v_led);           -- least 는 null 을 건너뛴다
  v_start := least(v_buy, v_inv);
  v_kind  := case when v_start is null then null
                  when v_inv is not null and v_inv <= coalesce(v_buy, v_inv) then 'invite'
                  else 'purchase' end;

  return jsonb_build_object(
    'uid',               u,
    'signup_at',         v_signup,
    'first_purchase_at', v_buy,
    'first_invite_at',   v_inv,
    'start_at',          v_start,
    'start_kind',        v_kind,
    'started',           (v_start is not null),
    'year_end_at',       case when v_start is null then null else v_start + interval '1 year' end
  );
end $$;

revoke all on function public.taam_member_start(uuid) from public;
grant execute on function public.taam_member_start(uuid) to authenticated;

-- ── 확인 (한 표) — ❌ 가 없어야 정상 ──
select '① 함수' as what,
       case when to_regproc('public.taam_member_start') is not null then '✅' else '❌' end as result
union all
select '② 시작일 있는 회원 / 전체 (참고)',
       '✅ ' || (select count(*) from public.profiles p
                  where exists (select 1 from public.tickets t where t.user_id = p.id
                                  and coalesce(t.status,'') not in ('cancelled','hold','expired')
                                  and coalesce(t.purchase_id,'') not like 'PAYH-%' and coalesce(t.purchase_id,'') not like 'INVH-%'
                                  and coalesce(t.purchase_id,'') not like 'KSK-%' and coalesce(t.purchase_id,'') not like 'LINK-%'
                                  and coalesce(t.purchase_id,'') not like 'MAN-%')
                     or exists (select 1 from public.reservation_invites i where i.invitee_user_id = p.id and i.status = 'paid'))::text
       || ' / ' || (select count(*) from public.profiles)::text;
