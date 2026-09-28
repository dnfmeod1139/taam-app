-- Case A · alt_pocket — baseline 0, one row per second, every balance_after is the POCKET balance,
-- pockets alternate mem→gen→mem→gen while both pockets are non-zero. No money outside the ledger.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-00000000000a');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-00000000000a','user','FF-A altpocket', 80000, 25000, 105000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-000a-000000000001','aaaaaaaa-0000-0000-0000-00000000000a','membership','admin_grant',   100000,100000,'mem +100000 (pocket=total)','2026-09-20 01:00:00+00'),
('00000000-0000-0000-000a-000000000002','aaaaaaaa-0000-0000-0000-00000000000a','general',   'charge',        30000, 30000,'gen +30000 (pocket ba)',    '2026-09-20 01:00:10+00'),
('00000000-0000-0000-000a-000000000003','aaaaaaaa-0000-0000-0000-00000000000a','membership','ticket_purchase',-20000,80000,'mem -20000 (pocket ba)',   '2026-09-20 01:00:20+00'),
('00000000-0000-0000-000a-000000000004','aaaaaaaa-0000-0000-0000-00000000000a','general',   'ticket_purchase', -5000,25000,'gen -5000 (pocket ba)',    '2026-09-20 01:00:30+00');
