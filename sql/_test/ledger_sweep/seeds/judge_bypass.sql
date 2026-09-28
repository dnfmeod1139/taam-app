-- X1 total-only, bypass +50000 mem AFTER last row
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000001');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000001','user','BY-X1 total tail', 130000, 0, 130000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-00b1-000000000001','bbbbbbbb-0000-0000-0000-000000000001','membership','admin_grant',100000,100000,'2026-09-21 01:00:00+00'),
('00000000-0000-0000-00b1-000000000002','bbbbbbbb-0000-0000-0000-000000000001','membership','ticket_purchase',-20000,80000,'2026-09-21 01:00:10+00');
-- X2 total rows, bypass +50000 mem BETWEEN rows
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000002');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000002','user','BY-X2 total mid', 130000, 0, 130000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-00b2-000000000001','bbbbbbbb-0000-0000-0000-000000000002','membership','admin_grant',100000,100000,'2026-09-21 02:00:00+00'),
('00000000-0000-0000-00b2-000000000002','bbbbbbbb-0000-0000-0000-000000000002','membership','ticket_purchase',-20000,130000,'2026-09-21 02:00:10+00');
-- X3 pocket rows, bypass +50000 gen between R2 and R3 (same pocket as the pocket rows)
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000003');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000003','user','BY-X3 pocket same', 100000, 75000, 175000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-00b3-000000000001','bbbbbbbb-0000-0000-0000-000000000003','membership','admin_grant',100000,100000,'2026-09-21 03:00:00+00'),
('00000000-0000-0000-00b3-000000000002','bbbbbbbb-0000-0000-0000-000000000003','general','charge',30000,30000,'2026-09-21 03:00:10+00'),
('00000000-0000-0000-00b3-000000000003','bbbbbbbb-0000-0000-0000-000000000003','general','ticket_purchase',-5000,75000,'2026-09-21 03:00:20+00');
-- X4 pocket rows in gen, bypass +50000 mem between R2 and R3 (other pocket)
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000004');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000004','user','BY-X4 pocket other', 150000, 25000, 175000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-00b4-000000000001','bbbbbbbb-0000-0000-0000-000000000004','membership','admin_grant',100000,100000,'2026-09-21 04:00:00+00'),
('00000000-0000-0000-00b4-000000000002','bbbbbbbb-0000-0000-0000-000000000004','general','charge',30000,30000,'2026-09-21 04:00:10+00'),
('00000000-0000-0000-00b4-000000000003','bbbbbbbb-0000-0000-0000-000000000004','general','ticket_purchase',-5000,25000,'2026-09-21 04:00:20+00');
-- X5 A-shape + bypass +50000 mem after last row
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000005');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000005','user','BY-X5 A + tail', 130000, 25000, 155000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-00b5-000000000001','bbbbbbbb-0000-0000-0000-000000000005','membership','admin_grant',100000,100000,'2026-09-21 05:00:00+00'),
('00000000-0000-0000-00b5-000000000002','bbbbbbbb-0000-0000-0000-000000000005','general','charge',30000,30000,'2026-09-21 05:00:10+00'),
('00000000-0000-0000-00b5-000000000003','bbbbbbbb-0000-0000-0000-000000000005','membership','ticket_purchase',-20000,80000,'2026-09-21 05:00:20+00'),
('00000000-0000-0000-00b5-000000000004','bbbbbbbb-0000-0000-0000-000000000005','general','ticket_purchase',-5000,25000,'2026-09-21 05:00:30+00');
-- X6 baseline 50000 + bypass +30000 mem between total rows
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000006');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000006','user','BY-X6 base + mid', 70000, 20000, 90000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-00b6-000000000001','bbbbbbbb-0000-0000-0000-000000000006','membership','ticket_purchase',-10000,40000,'2026-09-21 06:00:00+00'),
('00000000-0000-0000-00b6-000000000002','bbbbbbbb-0000-0000-0000-000000000006','general','charge',20000,90000,'2026-09-21 06:00:10+00');
-- X7 A-shape, bypass +50000 gen between R3 and R4
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000007');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000007','user','BY-X7 A + mid gen', 80000, 75000, 155000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-00b7-000000000001','bbbbbbbb-0000-0000-0000-000000000007','membership','admin_grant',100000,100000,'2026-09-21 07:00:00+00'),
('00000000-0000-0000-00b7-000000000002','bbbbbbbb-0000-0000-0000-000000000007','general','charge',30000,30000,'2026-09-21 07:00:10+00'),
('00000000-0000-0000-00b7-000000000003','bbbbbbbb-0000-0000-0000-000000000007','membership','ticket_purchase',-20000,80000,'2026-09-21 07:00:20+00'),
('00000000-0000-0000-00b7-000000000004','bbbbbbbb-0000-0000-0000-000000000007','general','ticket_purchase',-5000,75000,'2026-09-21 07:00:30+00');
-- X8 F-shape + bypass +30000 mem AFTER R2
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000008');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000008','user','BY-X8 F + tail', 70000, 20000, 90000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-00b8-000000000001','bbbbbbbb-0000-0000-0000-000000000008','general','charge',20000,20000,'2026-09-21 08:00:00+00'),
('00000000-0000-0000-00b8-000000000002','bbbbbbbb-0000-0000-0000-000000000008','membership','ticket_purchase',-10000,60000,'2026-09-21 08:00:10+00');
-- X9 B-shape + bypass -5000 gen AFTER R2 (money removed)
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000009');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000009','user','BY-X9 B + tail', 40000, 15000, 55000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-00b9-000000000001','bbbbbbbb-0000-0000-0000-000000000009','membership','ticket_purchase',-10000,40000,'2026-09-21 09:00:00+00'),
('00000000-0000-0000-00b9-000000000002','bbbbbbbb-0000-0000-0000-000000000009','general','charge',20000,20000,'2026-09-21 09:00:10+00');
-- X10 D-shape + bypass -25000 mem after
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000010');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000010','user','BY-X10 D + tail', 50000, 20000, 70000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-0b10-000000000001','bbbbbbbb-0000-0000-0000-000000000010','membership','admin_grant',100000,100000,'2026-09-21 10:00:00+00'),
('00000000-0000-0000-0b10-000000000002','bbbbbbbb-0000-0000-0000-000000000010','general','charge',30000,30000,'2026-09-21 10:00:10+00'),
('00000000-0000-0000-0b10-000000000003','bbbbbbbb-0000-0000-0000-000000000010','membership','ticket_purchase',-25000,105000,'2026-09-21 10:00:20+00'),
('00000000-0000-0000-0b10-000000000004','bbbbbbbb-0000-0000-0000-000000000010','general','ticket_purchase',-10000,20000,'2026-09-21 10:00:20+00');
-- X11 E-shape + bypass +10000 gen after
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000011');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000011','user','BY-X11 E + tail', 60000, 33000, 93000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-0b11-000000000001','bbbbbbbb-0000-0000-0000-000000000011','membership','admin_grant',100000,100000,'2026-09-21 11:00:00+00'),
('00000000-0000-0000-0b11-000000000002','bbbbbbbb-0000-0000-0000-000000000011','general','charge',30000,30000,'2026-09-21 11:00:10+00'),
('00000000-0000-0000-0b11-000000000005','bbbbbbbb-0000-0000-0000-000000000011','membership','ticket_purchase',-40000,60000,'2026-09-21 11:00:20+00'),
('00000000-0000-0000-0b11-000000000004','bbbbbbbb-0000-0000-0000-000000000011','general','ticket_purchase',-10000,20000,'2026-09-21 11:00:20+00'),
('00000000-0000-0000-0b11-000000000003','bbbbbbbb-0000-0000-0000-000000000011','general','ticket_refund',3000,23000,'2026-09-21 11:00:20+00');
-- X13 bypass -40000 mem then a pocket-semantic mem row
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000013');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000013','user','BY-X13 shrink then pk', 50000, 0, 50000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-0b13-000000000001','bbbbbbbb-0000-0000-0000-000000000013','membership','admin_grant',100000,100000,'2026-09-21 13:00:00+00'),
('00000000-0000-0000-0b13-000000000002','bbbbbbbb-0000-0000-0000-000000000013','membership','ticket_purchase',-10000,50000,'2026-09-21 13:00:10+00');
-- X16 C-twin: mem-only total rows B=0, gen ledger EMPTY, bypass +50000 gen after (indistinguishable from C)
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000016');
insert into public.profiles(id,role,display_name,membership_deposit_balance,general_deposit_balance,deposit_balance) values ('bbbbbbbb-0000-0000-0000-000000000016','user','BY-X16 C-twin', 80000, 50000, 130000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,created_at) values
('00000000-0000-0000-0b16-000000000001','bbbbbbbb-0000-0000-0000-000000000016','membership','admin_grant',100000,100000,'2026-09-21 16:00:00+00'),
('00000000-0000-0000-0b16-000000000002','bbbbbbbb-0000-0000-0000-000000000016','membership','ticket_purchase',-20000,80000,'2026-09-21 16:00:10+00');
