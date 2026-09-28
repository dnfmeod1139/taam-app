-- Case I (expected ok) · pocket-semantic rows where the other pocket is 0 (mem only, gen 0) — pocket == total.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-000000000012');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-000000000012','user','OK-I other zero', 85000, 0, 85000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-0012-000000000001','aaaaaaaa-0000-0000-0000-000000000012','membership','admin_grant',    100000,100000,'mem +100000','2026-09-20 09:00:00+00'),
('00000000-0000-0000-0012-000000000002','aaaaaaaa-0000-0000-0000-000000000012','membership','ticket_purchase',-20000, 80000,'mem -20000', '2026-09-20 09:00:10+00'),
('00000000-0000-0000-0012-000000000003','aaaaaaaa-0000-0000-0000-000000000012','membership','ticket_refund',    5000, 85000,'mem +5000',  '2026-09-20 09:00:20+00');
