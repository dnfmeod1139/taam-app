-- Case D · same_second_total_then_pocket — baseline 0. Previous group is a gen pocket-semantic row (offset -mem).
-- Then, in ONE second: a TOTAL-semantic mem row written first (ba = total right after it = 105000),
-- followed by a POCKET-semantic gen row written second (ba = gen after = 20000). ids follow write order.
-- stored 75000+20000 = 95000 = ledger sum.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-00000000000d');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-00000000000d','user','FF-D samesec mix', 75000, 20000, 95000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-000d-000000000001','aaaaaaaa-0000-0000-0000-00000000000d','membership','admin_grant',    100000,100000,'mem +100000',                 '2026-09-20 04:00:00+00'),
('00000000-0000-0000-000d-000000000002','aaaaaaaa-0000-0000-0000-00000000000d','general',   'charge',          30000, 30000,'gen +30000 (pocket ba)',      '2026-09-20 04:00:10+00'),
('00000000-0000-0000-000d-000000000003','aaaaaaaa-0000-0000-0000-00000000000d','membership','ticket_purchase',-25000,105000,'mem -25000 (total ba, 1st)',  '2026-09-20 04:00:20+00'),
('00000000-0000-0000-000d-000000000004','aaaaaaaa-0000-0000-0000-00000000000d','general',   'ticket_purchase',-10000, 20000,'gen -10000 (pocket ba, 2nd)', '2026-09-20 04:00:20+00');
