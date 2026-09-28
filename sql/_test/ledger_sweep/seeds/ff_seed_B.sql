-- Case B · baseline_pocket_other — pre-ledger baseline 50000 sits in MEMBERSHIP (no ledger row for it).
-- Ledger: mem -10000 (total-semantic ba 40000), then gen +20000 (pocket-semantic ba 20000).
-- stored 40000+20000=60000 = ledger 10000 + baseline 50000.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-00000000000b');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-00000000000b','user','FF-B baseline+pocket', 40000, 20000, 60000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-000b-000000000001','aaaaaaaa-0000-0000-0000-00000000000b','membership','ticket_purchase',-10000,40000,'mem -10000 (total ba, baseline 50000)','2026-09-20 02:00:00+00'),
('00000000-0000-0000-000b-000000000002','aaaaaaaa-0000-0000-0000-00000000000b','general',   'charge',         20000,20000,'gen +20000 (pocket ba)',              '2026-09-20 02:00:10+00');
