-- Case H (expected ok) · two consecutive semantic switches pocket→total→pocket→total, one row per second,
-- the pocket-semantic rows switch pocket too (gen pocket → mem total → mem pocket → gen total).
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-000000000011');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-000000000011','user','OK-H switches', 85000, 29000, 114000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-0011-000000000001','aaaaaaaa-0000-0000-0000-000000000011','membership','admin_grant',    100000,100000,'mem +100000',           '2026-09-20 08:00:00+00'),
('00000000-0000-0000-0011-000000000002','aaaaaaaa-0000-0000-0000-000000000011','general',   'charge',          30000, 30000,'gen +30000 (pocket)',   '2026-09-20 08:00:10+00'),
('00000000-0000-0000-0011-000000000003','aaaaaaaa-0000-0000-0000-000000000011','membership','ticket_purchase',-20000,110000,'mem -20000 (total)',    '2026-09-20 08:00:20+00'),
('00000000-0000-0000-0011-000000000004','aaaaaaaa-0000-0000-0000-000000000011','membership','ticket_refund',    5000, 85000,'mem +5000 (pocket)',    '2026-09-20 08:00:30+00'),
('00000000-0000-0000-0011-000000000005','aaaaaaaa-0000-0000-0000-000000000011','general',   'ticket_purchase', -1000,114000,'gen -1000 (total)',     '2026-09-20 08:00:40+00');
