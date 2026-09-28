-- ═════════════════════════════════════════════════
-- 초대 결제 확정 — 좌석 홀드(INVH-)를 확정 행(INV-)으로 바꾼다 · 2026-09-28
-- ═════════════════════════════════════════════════
-- 무슨 일이 있었나 (5/1 마츠카와 · 유수봉)
--   초대 결제(riPay)는 「홀드 해제 → 앱이 확정 행 INSERT」 순서였다. 9/13 에 앱의 tickets 확정 INSERT 를
--   막았으므로(TK_CLIENT_INSERT=false · 서버만 확정 행을 만든다) 홀드만 풀리고 확정 행은 영영 안 생겼다.
--   → 결제는 됐는데 티켓 상세는 「잔여 4석 이상」, 캘린더만 초대 2명. 수동 추가로 채워야 맞았다.
--
-- 고치는 법
--   확정 RPC 하나: 결제가 끝난 초대의 INVH- 행을 그 자리에서 status='active' · purchase_id='INV-…' 로 바꾼다.
--   좌석이 한 순간도 비지 않고(해제→재삽입이 아니다), 앱은 INSERT 를 하지 않는다.
--   SECURITY DEFINER 라 current_user 가 회원이 아니어서 trg_taam_guard_ticket_row 를 통과한다(확정 RPC 와 같은 길).
--
-- 권한: 초대받은 본인(invitee_user_id = auth.uid()) 또는 슈퍼어드민 · 초대 status 가 'paid' 여야 한다.
-- 멱등: 이미 INV- 확정 행이 있으면 그대로 돌려준다. 홀드가 없고 ticket_product_id 가 있으면 확정 행을 새로 넣는다.
-- ═════════════════════════════════════════════════

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
comment on function public.taam_invite_confirm_hold(text, text) is
  '초대 결제 확정 — INVH- 홀드 행을 INV- 확정 행으로 그 자리에서 바꾼다 (좌석 카운트 유지). 본인 또는 슈퍼어드민 · 초대 status=paid 만.';

-- 확인 (❌ 가 한 줄도 없어야 정상)
select case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='taam_invite_confirm_hold')
            then '✅ taam_invite_confirm_hold 있음' else '❌ 함수 없음' end as check;
