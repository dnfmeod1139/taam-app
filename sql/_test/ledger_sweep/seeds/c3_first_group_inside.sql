-- CASE 3: bypass +50,000 INSIDE the very first ledger group (same second, between two rows)
insert into auth.users(id) values ('a3000000-0000-0000-0000-000000000003');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a3000000-0000-0000-0000-000000000003','user','C3 첫묶음 안 우회', 0, 125000, 125000, '2026-09-04 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a3000000-0000-0000-0000-0000000000a1','a3000000-0000-0000-0000-000000000003','general','general_charge',  100000, 100000,'일반 예치금 충전','2026-09-05 12:00:00.100+09'),
-- bypass 2026-09-05 12:00:00.500: update profiles set general_deposit_balance = general_deposit_balance + 50000 (no ledger row)
('a3000000-0000-0000-0000-0000000000a2','a3000000-0000-0000-0000-000000000003','general','ticket_purchase', -20000, 130000,'티켓 구매','2026-09-05 12:00:00.900+09'),
('a3000000-0000-0000-0000-0000000000a3','a3000000-0000-0000-0000-000000000003','general','ticket_purchase',  -5000, 125000,'티켓 구매','2026-09-20 10:00:00+09');
