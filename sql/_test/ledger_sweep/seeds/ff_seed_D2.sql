-- Case D2 (control for D) · same second, but POCKET-semantic gen row written FIRST, TOTAL-semantic mem row written LAST.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-0000000000d2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-0000000000d2','user','OK-D2 samesec rev', 75000, 20000, 95000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-00d2-000000000001','aaaaaaaa-0000-0000-0000-0000000000d2','membership','admin_grant',    100000,100000,'mem +100000',                '2026-09-20 11:00:00+00'),
('00000000-0000-0000-00d2-000000000002','aaaaaaaa-0000-0000-0000-0000000000d2','general',   'charge',          30000, 30000,'gen +30000 (pocket ba)',     '2026-09-20 11:00:10+00'),
('00000000-0000-0000-00d2-000000000003','aaaaaaaa-0000-0000-0000-0000000000d2','general',   'ticket_purchase',-10000, 20000,'gen -10000 (pocket ba, 1st)','2026-09-20 11:00:20+00'),
('00000000-0000-0000-00d2-000000000004','aaaaaaaa-0000-0000-0000-0000000000d2','membership','ticket_purchase',-25000, 95000,'mem -25000 (total ba, 2nd)', '2026-09-20 11:00:20+00');
