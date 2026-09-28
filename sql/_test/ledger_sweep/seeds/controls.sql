-- CONTROL X1: same as C1 but theft 250,000 (not equal to gen pocket 300,000)
insert into auth.users(id) values ('b1000000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b1000000-0000-0000-0000-000000000001','user','X1 대조 C1 도난 250000', 550000, 300000, 850000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b1000000-0000-0000-0000-0000000000a1','b1000000-0000-0000-0000-000000000001','membership','membership_charge', 900000,  900000,'연회비 예치금','2026-09-01 10:00:00+09'),
('b1000000-0000-0000-0000-0000000000a2','b1000000-0000-0000-0000-000000000001','general',   'general_charge',    300000, 1200000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('b1000000-0000-0000-0000-0000000000a3','b1000000-0000-0000-0000-000000000001','membership','ticket_purchase',  -100000,  850000,'티켓 구매','2026-09-15 10:00:00+09');
-- CONTROL X4: same as C4 but theft 900,000 (mem row amount, not the gen split)
insert into auth.users(id) values ('b4000000-0000-0000-0000-000000000004');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b4000000-0000-0000-0000-000000000004','user','X4 대조 C4 도난 900000', 0, 100000, 100000, '2026-09-03 08:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b4000000-0000-0000-0000-0000000000a1','b4000000-0000-0000-0000-000000000004','membership','membership_charge', 900000,  900000,'초대 결제 mem','2026-09-03 09:00:00.100+09'),
('b4000000-0000-0000-0000-0000000000a2','b4000000-0000-0000-0000-000000000004','general',   'general_charge',    100000, 1000000,'초대 결제 gen','2026-09-03 09:00:00.200+09');
