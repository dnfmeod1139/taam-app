-- CASE 2: cross-pocket bypass: mem -500,000 / gen +500,000 directly in profiles (total unchanged)
insert into auth.users(id) values ('a2000000-0000-0000-0000-000000000002');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a2000000-0000-0000-0000-000000000002','user','C2 주머니 간 이동', 400000, 550000, 950000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a2000000-0000-0000-0000-0000000000a1','a2000000-0000-0000-0000-000000000002','membership','membership_charge', 900000,  900000,'연회비 예치금','2026-09-01 10:00:00+09'),
('a2000000-0000-0000-0000-0000000000a2','a2000000-0000-0000-0000-000000000002','general',   'general_charge',    100000, 1000000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
-- bypass 2026-09-10: update profiles set membership_deposit_balance = mem-500000, general_deposit_balance = gen+500000 (no ledger row)
('a2000000-0000-0000-0000-0000000000a3','a2000000-0000-0000-0000-000000000002','general',   'ticket_purchase',   -50000,  950000,'티켓 구매','2026-09-15 10:00:00+09');
