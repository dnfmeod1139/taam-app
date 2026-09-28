-- Case E · three_rows_one_second_mixed_pockets — baseline 0. Previous group: gen pocket-semantic row (offset -100000).
-- Then 3 rows in ONE second, both pockets, all pocket-semantic: mem -40000 (ba 60000), gen -10000 (ba 20000), gen +3000 (ba 23000).
-- ids deliberately in the OPPOSITE order of writing. stored 60000+23000 = 83000 = ledger sum.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-00000000000e');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-00000000000e','user','FF-E 3rows mixed', 60000, 23000, 83000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-000e-000000000001','aaaaaaaa-0000-0000-0000-00000000000e','membership','admin_grant',    100000,100000,'mem +100000',              '2026-09-20 05:00:00+00'),
('00000000-0000-0000-000e-000000000002','aaaaaaaa-0000-0000-0000-00000000000e','general',   'charge',          30000, 30000,'gen +30000 (pocket ba)',   '2026-09-20 05:00:10+00'),
('00000000-0000-0000-000e-000000000005','aaaaaaaa-0000-0000-0000-00000000000e','membership','ticket_purchase',-40000, 60000,'mem -40000 (pocket, w1)',  '2026-09-20 05:00:20+00'),
('00000000-0000-0000-000e-000000000004','aaaaaaaa-0000-0000-0000-00000000000e','general',   'ticket_purchase',-10000, 20000,'gen -10000 (pocket, w2)',  '2026-09-20 05:00:20+00'),
('00000000-0000-0000-000e-000000000003','aaaaaaaa-0000-0000-0000-00000000000e','general',   'ticket_refund',    3000, 23000,'gen +3000 (pocket, w3)',   '2026-09-20 05:00:20+00');
