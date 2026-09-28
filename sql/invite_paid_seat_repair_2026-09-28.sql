-- ═════════════════════════════════════════════════
-- 결제됐는데 좌석 행이 없는 초대 복구 · 2026-09-28  (① 미리보기 → ② 적용, 따로 돌린다)
-- ═════════════════════════════════════════════════
-- 배경: supabase/migrations/20260928_invite_confirm_hold.sql 머리말. 9/13~9/28 사이에 결제된 초대는
--   홀드가 해제되고 확정 행이 안 생겨 티켓 좌석에서 빠져 있다. RPC 를 슈퍼어드민(SQL Editor = postgres)으로
--   불러 그 초대들을 확정한다 — 취소된 INVH 홀드가 남아 있어도 되살리지 않고 새 확정 행을 넣는다.
--   ⚠ 정원이 이미 찼으면 좌석 트리거가 막아 그 초대는 ❌ 로 남는다 — 그 회차는 사람이 본다.

-- ① 미리보기 — 대상 초대
select inv.id, inv.restaurant_name as "매장", inv.visit_date as "방문일", inv.pax as "인원",
       inv.total_amount as "금액", inv.ticket_product_id as "티켓",
       (select p.display_name from public.profiles p where p.id = inv.invitee_user_id) as "회원",
       (select d.metadata->>'purchase_id' from public.deposit_transactions d
         where d.metadata->>'invite_id' = inv.id::text and d.change_type = 'ticket_purchase' limit 1) as "원장 구매ID"
  from public.reservation_invites inv
 where coalesce(inv.status,'') = 'paid'
   and inv.ticket_product_id is not null
   and not exists (select 1 from public.tickets t
                    where (t.purchase_id like 'INV-' || left(inv.id::text,8) || '-%'
                        or t.purchase_id like 'INVH-' || left(inv.id::text,8) || '-%')
                      and coalesce(t.status,'') <> 'cancelled')
 order by inv.visit_date, inv.restaurant_name;
