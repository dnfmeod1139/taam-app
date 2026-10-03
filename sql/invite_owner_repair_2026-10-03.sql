-- 초대 결제 확정 행의 소유자 수리 — 2026-10-03 (20261003_invite_confirm_owner.sql 의 후속)
-- ③ 미리보기: 티켓 소유자(user_id)가 초대받은 회원과 다른 확정 행
select t.purchase_id, t.restaurant_name, t.reservation_date, t.party_size, t.price,
       t.user_id as now_owner, i.invitee_user_id as should_be, i.status as invite_status, t.created_at
  from public.tickets t
  join public.reservation_invites i on i.id::text = t.extra_data->>'inviteId'
 where t.purchase_id like 'INV-%' and coalesce(t.status,'') <> 'cancelled'
   and i.invitee_user_id is not null and t.user_id is distinct from i.invitee_user_id
 order by t.created_at desc;

-- ④ 적용 (③ 목록이 맞으면) — 소유자만 바꾼다. 금액·좌석·원장은 건드리지 않는다.
-- update public.tickets t
--    set user_id = i.invitee_user_id,
--        extra_data = coalesce(t.extra_data,'{}'::jsonb) || jsonb_build_object('owner_fixed_at', now(), 'owner_was', t.user_id::text)
--   from public.reservation_invites i
--  where i.id::text = t.extra_data->>'inviteId'
--    and t.purchase_id like 'INV-%' and coalesce(t.status,'') <> 'cancelled'
--    and i.invitee_user_id is not null and t.user_id is distinct from i.invitee_user_id;
