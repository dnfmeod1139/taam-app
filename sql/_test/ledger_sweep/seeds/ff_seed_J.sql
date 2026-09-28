-- Case J (expected ok) · pre-ledger baseline 50000 in mem, every ledger row TOTAL-semantic.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-000000000013');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-000000000013','user','OK-J baseline total', 40000, 20000, 60000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-0013-000000000001','aaaaaaaa-0000-0000-0000-000000000013','membership','ticket_purchase',-10000,40000,'mem -10000 (total, baseline 50000)','2026-09-20 10:00:00+00'),
('00000000-0000-0000-0013-000000000002','aaaaaaaa-0000-0000-0000-000000000013','general',   'charge',         20000,60000,'gen +20000 (total)',                '2026-09-20 10:00:10+00');
