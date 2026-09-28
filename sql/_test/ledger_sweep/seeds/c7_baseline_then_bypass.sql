-- CASE 7: genuine pre-ledger baseline 200,000, then bypass +50,000 after the first ledger row
insert into auth.users(id) values ('a7000000-0000-0000-0000-000000000007');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a7000000-0000-0000-0000-000000000007','user','C7 기준선+우회', 0, 235000, 235000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a7000000-0000-0000-0000-0000000000a1','a7000000-0000-0000-0000-000000000007','general','ticket_purchase', -10000, 190000,'티켓 구매','2026-09-01 10:00:00+09'),
-- bypass 2026-09-05: general_deposit_balance += 50000 (no ledger row)
('a7000000-0000-0000-0000-0000000000a2','a7000000-0000-0000-0000-000000000007','general','ticket_purchase',  -5000, 235000,'티켓 구매','2026-09-06 10:00:00+09');
