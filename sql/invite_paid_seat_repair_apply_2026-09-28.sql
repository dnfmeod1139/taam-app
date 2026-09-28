-- ② 적용 — ① 목록을 확인한 뒤에만. 원장에 남은 구매 ID 가 있으면 그걸 쓰고, 없으면 새로 만든다.
do $$
declare r record; v_pid text; v_res json;
begin
  for r in
    select inv.id,
           (select d.metadata->>'purchase_id' from public.deposit_transactions d
             where d.metadata->>'invite_id' = inv.id::text and d.change_type = 'ticket_purchase' limit 1) as pid
      from public.reservation_invites inv
     where coalesce(inv.status,'') = 'paid' and inv.ticket_product_id is not null
       and not exists (select 1 from public.tickets t
                        where (t.purchase_id like 'INV-' || left(inv.id::text,8) || '-%'
                            or t.purchase_id like 'INVH-' || left(inv.id::text,8) || '-%')
                          and coalesce(t.status,'') <> 'cancelled')
  loop
    begin
      v_pid := case when r.pid like 'INV-' || left(r.id::text,8) || '-%' then r.pid else null end;
      v_res := public.taam_invite_confirm_hold(r.id::text, v_pid);
      raise notice '✅ 초대 % → %', r.id, v_res::text;
    exception when others then
      raise notice '❌ 초대 % 실패: %', r.id, sqlerrm;
    end;
  end loop;
end $$;

-- 확인 — 남은 대상이 0 이어야 한다
select count(*) as "아직 좌석 행 없는 결제 초대"
  from public.reservation_invites inv
 where coalesce(inv.status,'') = 'paid' and inv.ticket_product_id is not null
   and not exists (select 1 from public.tickets t
                    where (t.purchase_id like 'INV-' || left(inv.id::text,8) || '-%'
                        or t.purchase_id like 'INVH-' || left(inv.id::text,8) || '-%')
                      and coalesce(t.status,'') <> 'cancelled');
