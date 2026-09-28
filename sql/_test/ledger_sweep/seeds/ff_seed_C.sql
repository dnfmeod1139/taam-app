-- Case C · baseline_hidden_pocket_only — pre-ledger baseline 50000 in MEMBERSHIP, ledger rows only in GENERAL,
-- all pocket-semantic. No jumps at all can exist; stored 65000 = ledger 15000 + baseline 50000.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-00000000000c');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-00000000000c','user','FF-C baseline hidden', 50000, 15000, 65000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-000c-000000000001','aaaaaaaa-0000-0000-0000-00000000000c','general','charge',         20000,20000,'gen +20000 (pocket ba)','2026-09-20 03:00:00+00'),
('00000000-0000-0000-000c-000000000002','aaaaaaaa-0000-0000-0000-00000000000c','general','ticket_purchase', -5000,15000,'gen -5000 (pocket ba)', '2026-09-20 03:00:10+00');
