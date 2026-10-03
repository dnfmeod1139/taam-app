-- ============================================================================
-- 20261003_invite_confirm_owner.sql — 초대 결제 확정 시 좌석 소유자를 초대받은 회원으로 (2026-10-03)
-- ============================================================================
-- 경위: 캘린더에서 예약 초대를 보내면 좌석 홀드(INVH-)를 **보내는 어드민의 user_id** 로 넣는다(회원 세션이 아니라 좌석 트리거를
-- 태우기 위해). 회원이 결제하면 taam_invite_confirm_hold 가 그 홀드를 active 로 바꾸는데 user_id 를 그대로 둬서
-- 티켓이 슈퍼어드민 소유가 됐다. 예치금은 회원(유수봉)에게서 빠졌는데 티켓은 슈퍼어드민에게 붙어, 구매자 상세엔 Super Admin 이
-- 뜨고 회원 원장엔 「티켓 행 없음」이 떴다 (타카미츠 3인 · 2026-10-03). 확정할 때 소유자를 초대받은 회원으로 바꾼다.
-- 이미 어긋난 행은 아래 ③ 미리보기 → ④ 적용으로 되돌린다.
-- ============================================================================
create or replace function public.taam_invite_confirm_hold(p_invite_id text, p_purchase_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_super boolean := false;
  v_inv   public.reservation_invites%rowtype;
  v_tk    public.tickets%rowtype;
  v_pid   text;
  v_name  text;
  v_tp    public.ticket_products%rowtype;
begin
  if v_uid is null and coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','') <> 'service_role'
     and session_user <> 'postgres' then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  begin v_super := public._taam_uid_is_super(); exception when others then v_super := false; end;

  select * into v_inv from public.reservation_invites where id::text = p_invite_id;
  if not found then
    raise exception 'INVITE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_uid is not null and not v_super and v_inv.invitee_user_id is distinct from v_uid then
    raise exception '내 초대가 아닙니다' using errcode = '42501';
  end if;
  if coalesce(v_inv.status,'') <> 'paid' then
    raise exception 'INVITE_NOT_PAID: 결제가 끝난 초대만 확정합니다 (상태 %)', coalesce(v_inv.status,'없음') using errcode = 'P0002';
  end if;

  v_pid := coalesce(nullif(p_purchase_id,''), 'INV-' || left(v_inv.id::text,8) || '-' || (extract(epoch from now())*1000)::bigint);
  if v_pid not like 'INV-' || left(v_inv.id::text,8) || '-%' then
    raise exception 'PURCHASE_ID_MISMATCH: 이 초대의 구매 ID 가 아닙니다' using errcode = '22023';
  end if;

  -- 이미 확정돼 있으면 그대로 (extra_data.inviteId 가 정확한 열쇠 · 없는 옛 행만 구매ID 앞자리로)
  select * into v_tk from public.tickets
   where coalesce(status,'') <> 'cancelled'
     and purchase_id like 'INV-%'
     and (extra_data->>'inviteId' = v_inv.id::text
          or (extra_data->>'inviteId' is null and purchase_id like 'INV-' || left(v_inv.id::text,8) || '-%'))
   limit 1;
  if found then
    return json_build_object('ok', true, 'already', true, 'purchase_id', v_tk.purchase_id, 'ticket_product_id', v_tk.ticket_product_id);
  end if;

  select coalesce(p.display_name, '초대') into v_name from public.profiles p where p.id = v_inv.invitee_user_id;

  -- 홀드 행을 잠그고 그 자리에서 확정한다 (좌석이 비지 않는다)
  select * into v_tk from public.tickets
   where coalesce(status,'') = 'hold'
     and purchase_id like 'INVH-%'
     and (extra_data->>'inviteId' = v_inv.id::text
          or (extra_data->>'inviteId' is null and purchase_id like 'INVH-' || left(v_inv.id::text,8) || '-%'))
   order by created_at desc
   for update
   limit 1;
  if found then
    update public.tickets
       set status = 'active',
           purchase_id = v_pid,
           -- 🔧 2026-10-03 홀드 행은 초대를 **보낸 어드민**의 user_id 로 만들어진다(좌석 트리거를 태우려고). 확정할 때 소유자를
           --   결제한 초대받은 회원으로 바꾸지 않아, 티켓이 슈퍼어드민 것이 되고 회원 원장엔 「티켓 행 없음」이 떴다 (유수봉 · 타카미츠).
           user_id = coalesce(v_inv.invitee_user_id, user_id),
           price = coalesce(v_inv.total_amount, price),
           party_size = coalesce(v_inv.pax, party_size),
           buyer_name = coalesce(v_name, buyer_name),
           extra_data = coalesce(extra_data,'{}'::jsonb)
                        || jsonb_build_object('inviteHold', false, 'invitePaid', true, 'inviteId', v_inv.id::text,
                                              'confirmed_at', now(), 'confirmed_by', 'taam_invite_confirm_hold')
     where id = v_tk.id;
    return json_build_object('ok', true, 'converted', true, 'purchase_id', v_pid, 'ticket_product_id', v_tk.ticket_product_id);
  end if;

  -- 홀드가 없다 (해제된 뒤 결제된 옛 경로) → 연결 티켓이 있으면 확정 행을 새로 넣는다
  if v_inv.ticket_product_id is null or v_inv.ticket_product_id::text = '' then
    return json_build_object('ok', false, 'reason', 'no_hold_no_product');
  end if;
  select * into v_tp from public.ticket_products where id::text = v_inv.ticket_product_id::text;
  insert into public.tickets (
    user_id, restaurant_id, restaurant_name, ticket_product_id, ticket_type,
    reservation_date, visit_time, party_size, price, status, purchase_id,
    buyer_name, buyer_phone, extra_data, created_at
  ) values (
    v_inv.invitee_user_id, coalesce(v_tp.rest_id::text, v_inv.restaurant_id::text), v_inv.restaurant_name,
    v_inv.ticket_product_id::text, coalesce(v_tp.type_class, ''),
    v_inv.visit_date, v_inv.visit_time, v_inv.pax, coalesce(v_inv.total_amount,0), 'active', v_pid,
    coalesce(v_name,'초대'), '',
    jsonb_build_object('inviteHold', false, 'invitePaid', true, 'inviteId', v_inv.id::text,
                       'confirmed_at', now(), 'confirmed_by', 'taam_invite_confirm_hold', 'inserted', true),
    now()
  );
  return json_build_object('ok', true, 'inserted', true, 'purchase_id', v_pid, 'ticket_product_id', v_inv.ticket_product_id::text);
end;
$$;
revoke all on function public.taam_invite_confirm_hold(text, text) from public;
grant execute on function public.taam_invite_confirm_hold(text, text) to authenticated, service_role;

-- ── 확인 ──
select '① 확정 RPC 가 소유자를 초대받은 회원으로 바꾼다' as what,
       case when exists (select 1 from pg_proc where oid = to_regproc('public.taam_invite_confirm_hold') and prosrc like '%user_id = coalesce(v_inv.invitee_user_id, user_id)%') then '✅' else '❌ 옛 판' end as result
union all
select '② 소유자가 어긋난 확정 행 (아래 ③④ 로 수리)',
       (select count(*)::text || '건' from public.tickets t
          join public.reservation_invites i on i.id::text = t.extra_data->>'inviteId'
         where t.purchase_id like 'INV-%' and coalesce(t.status,'') <> 'cancelled'
           and i.invitee_user_id is not null and t.user_id is distinct from i.invitee_user_id);
