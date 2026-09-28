-- Case F · first_group_pocket_hides_baseline — pre-ledger baseline 50000 in MEMBERSHIP.
-- First ledger row is a gen pocket-semantic row (ba 20000 — says nothing about the baseline),
-- then a total-semantic mem row (ba 60000 = 50000-10000+20000). stored 60000 = ledger 10000 + baseline 50000.
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-00000000000f');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-00000000000f','user','FF-F first pocket', 40000, 20000, 60000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-000f-000000000001','aaaaaaaa-0000-0000-0000-00000000000f','general',   'charge',          20000,20000,'gen +20000 (pocket ba)',              '2026-09-20 06:00:00+00'),
('00000000-0000-0000-000f-000000000002','aaaaaaaa-0000-0000-0000-00000000000f','membership','ticket_purchase',-10000,60000,'mem -10000 (total ba, baseline 50000)','2026-09-20 06:00:10+00');
