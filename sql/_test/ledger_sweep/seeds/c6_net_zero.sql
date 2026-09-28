-- CASE 6: mint gen +80,000 (09-05) then reverse gen -80,000 (09-08), each followed by a ledger row
insert into auth.users(id) values ('a6000000-0000-0000-0000-000000000006');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a6000000-0000-0000-0000-000000000006','user','C6 상쇄 우회쌍', 0, 280000, 280000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a6000000-0000-0000-0000-0000000000a1','a6000000-0000-0000-0000-000000000006','general','general_charge',  300000, 300000,'일반 예치금 충전','2026-09-01 10:00:00+09'),
-- bypass 2026-09-05: general_deposit_balance += 80000 (no ledger row)
('a6000000-0000-0000-0000-0000000000a2','a6000000-0000-0000-0000-000000000006','general','ticket_purchase', -10000, 370000,'티켓 구매','2026-09-06 10:00:00+09'),
-- bypass 2026-09-08: general_deposit_balance -= 80000 (no ledger row)
('a6000000-0000-0000-0000-0000000000a3','a6000000-0000-0000-0000-000000000006','general','ticket_purchase', -10000, 280000,'티켓 구매','2026-09-09 10:00:00+09');
