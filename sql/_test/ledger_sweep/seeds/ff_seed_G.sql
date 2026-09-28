-- Case G (expected ok) · rpc_split_reversed_ids — RPC writes mem -60000 then gen -10000 in one transaction,
-- balance_after accumulates from total-before (120000 → 60000 → 50000); ids are in the OPPOSITE order of writing.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-000000000010');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-000000000010','user','OK-G rpc split', 40000, 10000, 50000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-0010-000000000001','aaaaaaaa-0000-0000-0000-000000000010','membership','admin_grant',    100000,100000,'mem +100000',            '2026-09-20 07:00:00+00'),
('00000000-0000-0000-0010-000000000002','aaaaaaaa-0000-0000-0000-000000000010','general',   'charge',          20000,120000,'gen +20000 (total ba)',  '2026-09-20 07:00:10+00'),
('00000000-0000-0000-0010-000000000004','aaaaaaaa-0000-0000-0000-000000000010','membership','ticket_purchase',-60000, 60000,'rpc entry 1 (written first, higher id)','2026-09-20 07:00:20+00'),
('00000000-0000-0000-0010-000000000003','aaaaaaaa-0000-0000-0000-000000000010','general',   'ticket_purchase',-10000, 50000,'rpc entry 2 (written second, lower id)','2026-09-20 07:00:20+00');
