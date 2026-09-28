-- A1
insert into auth.users(id) values ('ad3a0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3a0000-0000-0000-0000-000000000001','user','A1 미접촉주머니 mint→첫총액행', 500000, 190000, 690000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3a0000-0000-0000-0000-0000000000a1','ad3a0000-0000-0000-0000-000000000001','membership','membership_charge', 500000, 500000,'연회비 예치금 (총액)','2026-09-01 10:00:00+09'),
('ad3a0000-0000-0000-0000-0000000000a2','ad3a0000-0000-0000-0000-000000000001','general','ticket_purchase', -10000, 690000,'티켓 구매 (총액, gen 첫 등장)','2026-09-11 10:00:00+09');
-- B1
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-000000000001','user','B1 기준선하 도난후 반환(pocketed→keep)', 0, 230000, 230000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000a1','ad3b0000-0000-0000-0000-000000000001','general','ticket_purchase', -10000, 240000,'티켓 구매 (총액, 기준선 250000)','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000a2','ad3b0000-0000-0000-0000-000000000001','general','ticket_purchase',  -5000, 185000,'티켓 구매 (총액)','2026-09-05 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000a3','ad3b0000-0000-0000-0000-000000000001','general','ticket_purchase',  -5000, 230000,'티켓 구매 (총액)','2026-09-08 10:00:00+09');
-- B1b
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-00000000001b');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-00000000001b','user','B1b mem기준선170만 도난50만후 반환', 1350000, 0, 1350000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000001b1','ad3b0000-0000-0000-0000-00000000001b','membership','ticket_purchase', -200000, 1500000,'티켓 구매 (총액, 기준선 1700000)','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000001b2','ad3b0000-0000-0000-0000-00000000001b','membership','ticket_purchase', -100000,  900000,'티켓 구매 (총액)','2026-09-05 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000001b3','ad3b0000-0000-0000-0000-00000000001b','membership','ticket_purchase',  -50000, 1350000,'티켓 구매 (총액)','2026-09-08 10:00:00+09');
-- B1c
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-00000000001c');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-00000000001c','user','B1c 기준선0 도난후 반환', 0, 280000, 280000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000001c1','ad3b0000-0000-0000-0000-00000000001c','general','general_charge',  300000, 300000,'일반 예치금 충전','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000001c2','ad3b0000-0000-0000-0000-00000000001c','general','ticket_purchase', -10000, 210000,'티켓 구매','2026-09-06 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000001c3','ad3b0000-0000-0000-0000-00000000001c','general','ticket_purchase', -10000, 280000,'티켓 구매','2026-09-09 10:00:00+09');
-- B2
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-000000000002');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-000000000002','user','B2 기준선하 영구도난(pocketed)', 0, 180000, 180000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000b1','ad3b0000-0000-0000-0000-000000000002','general','ticket_purchase', -10000, 240000,'티켓 구매 (총액, 기준선 250000)','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000b2','ad3b0000-0000-0000-0000-000000000002','general','ticket_purchase',  -5000, 185000,'티켓 구매 (총액)','2026-09-05 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000b3','ad3b0000-0000-0000-0000-000000000002','general','ticket_purchase',  -5000, 180000,'티켓 구매 (총액)','2026-09-08 10:00:00+09');
-- B3
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-000000000003');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-000000000003','user','B3 기준선+mint후 back', 0, 80000, 80000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000c1','ad3b0000-0000-0000-0000-000000000003','general','ticket_purchase', -10000,  90000,'티켓 구매 (총액, 기준선 100000)','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000c2','ad3b0000-0000-0000-0000-000000000003','general','ticket_purchase',  -5000, 165000,'티켓 구매 (총액)','2026-09-04 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000c3','ad3b0000-0000-0000-0000-000000000003','general','ticket_purchase',  -5000,  80000,'티켓 구매 (총액)','2026-09-07 10:00:00+09');
-- C1
insert into auth.users(id) values ('ad3c0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3c0000-0000-0000-0000-000000000001','user','C1 mem기준선+gen도난 합계0', 100000, 180000, 280000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3c0000-0000-0000-0000-0000000000a1','ad3c0000-0000-0000-0000-000000000001','general','general_charge',  300000, 400000,'일반 예치금 충전 (총액, mem 기준선 100000)','2026-09-01 10:00:00+09'),
('ad3c0000-0000-0000-0000-0000000000a2','ad3c0000-0000-0000-0000-000000000001','general','ticket_purchase', -20000, 280000,'티켓 구매 (총액)','2026-09-10 10:00:00+09');
-- D1
insert into auth.users(id) values ('ad3d0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3d0000-0000-0000-0000-000000000001','user','D1 RPC3 가운데 도난', 340000, 170000, 510000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3d0000-0000-0000-0000-0000000000a1','ad3d0000-0000-0000-0000-000000000001','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3d0000-0000-0000-0000-0000000000a2','ad3d0000-0000-0000-0000-000000000001','general',   'general_charge',    200000, 700000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('ad3d0000-0000-0000-0000-0000000000a3','ad3d0000-0000-0000-0000-000000000001','membership','ticket_purchase',   -50000, 650000,'티켓 구매 mem','2026-09-10 10:00:00.100+09'),
('ad3d0000-0000-0000-0000-0000000000a4','ad3d0000-0000-0000-0000-000000000001','general',   'ticket_purchase',   -30000, 520000,'티켓 구매 gen','2026-09-10 10:00:00.200+09'),
('ad3d0000-0000-0000-0000-0000000000a5','ad3d0000-0000-0000-0000-000000000001','membership','ticket_purchase',   -10000, 510000,'대행비 mem','2026-09-10 10:00:00.300+09');
-- D2
insert into auth.users(id) values ('ad3d0000-0000-0000-0000-000000000002');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3d0000-0000-0000-0000-000000000002','user','D2 RPC3 가운데 도난=타주머니', 440000, 0, 440000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3d0000-0000-0000-0000-0000000000b1','ad3d0000-0000-0000-0000-000000000002','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3d0000-0000-0000-0000-0000000000b2','ad3d0000-0000-0000-0000-000000000002','general',   'general_charge',    200000, 700000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('ad3d0000-0000-0000-0000-0000000000b3','ad3d0000-0000-0000-0000-000000000002','membership','ticket_purchase',   -50000, 650000,'티켓 구매 mem','2026-09-10 10:00:00.100+09'),
('ad3d0000-0000-0000-0000-0000000000b4','ad3d0000-0000-0000-0000-000000000002','general',   'ticket_purchase',   -30000, 450000,'티켓 구매 gen','2026-09-10 10:00:00.200+09'),
('ad3d0000-0000-0000-0000-0000000000b5','ad3d0000-0000-0000-0000-000000000002','membership','ticket_purchase',   -10000, 440000,'대행비 mem','2026-09-10 10:00:00.300+09');
-- E1
insert into auth.users(id) values ('ad3e0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3e0000-0000-0000-0000-000000000001','user','E1 진짜❌ 뒤 기록방식 위장 도난', 285000, 200000, 485000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3e0000-0000-0000-0000-0000000000a1','ad3e0000-0000-0000-0000-000000000001','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3e0000-0000-0000-0000-0000000000a2','ad3e0000-0000-0000-0000-000000000001','general',   'general_charge',    200000, 700000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('ad3e0000-0000-0000-0000-0000000000a3','ad3e0000-0000-0000-0000-000000000001','membership','ticket_purchase',   -10000, 790000,'티켓 구매 (총액)','2026-09-06 10:00:00+09'),
('ad3e0000-0000-0000-0000-0000000000a4','ad3e0000-0000-0000-0000-000000000001','membership','ticket_purchase',    -5000, 485000,'티켓 구매 (총액)','2026-09-09 10:00:00+09');
-- F1
insert into auth.users(id) values ('ad3f0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3f0000-0000-0000-0000-000000000001','user','F1 미접촉주머니 mint 이후행없음', 480000, 150000, 630000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3f0000-0000-0000-0000-0000000000a1','ad3f0000-0000-0000-0000-000000000001','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3f0000-0000-0000-0000-0000000000a2','ad3f0000-0000-0000-0000-000000000001','membership','ticket_purchase',   -20000, 480000,'티켓 구매','2026-09-03 10:00:00+09');
-- F2
insert into auth.users(id) values ('ad3f0000-0000-0000-0000-000000000002');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3f0000-0000-0000-0000-000000000002','user','F2 양주머니 기준선(gen 미접촉)', 580000, 150000, 730000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3f0000-0000-0000-0000-0000000000b1','ad3f0000-0000-0000-0000-000000000002','membership','membership_charge', 500000, 600000,'연회비 예치금 (mem 기준선 100000)','2026-09-01 10:00:00+09'),
('ad3f0000-0000-0000-0000-0000000000b2','ad3f0000-0000-0000-0000-000000000002','membership','ticket_purchase',   -20000, 580000,'티켓 구매','2026-09-03 10:00:00+09');
-- X1
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-0000000000d1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-0000000000d1','user','X1 기준선하 mem→gen 원장밖이동', 170000, 90000, 260000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000d2','ad3b0000-0000-0000-0000-0000000000d1','membership','ticket_purchase', -20000, 280000,'티켓 구매 (총액, mem 기준선 300000)','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000d3','ad3b0000-0000-0000-0000-0000000000d1','membership','ticket_purchase', -10000, 170000,'티켓 구매 (총액)','2026-09-04 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000d4','ad3b0000-0000-0000-0000-0000000000d1','general',   'ticket_purchase', -10000, 260000,'티켓 구매 gen (총액, gen 첫 등장)','2026-09-07 10:00:00+09');
-- BEN1
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-0000000000e1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-0000000000e1','user','BEN1 늦은주머니 기준선 주머니기록', 500000, 190000, 690000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000e2','ad3b0000-0000-0000-0000-0000000000e1','membership','membership_charge', 500000, 500000,'연회비 예치금 (주머니)','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000e3','ad3b0000-0000-0000-0000-0000000000e1','general',   'ticket_purchase',   -10000, 190000,'티켓 구매 (주머니, gen 기준선 200000)','2026-09-11 10:00:00+09');
-- BEN2
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-0000000000e4');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-0000000000e4','user','BEN2 늦은기준선 뒤 주머니기록행', 499000, 100000, 599000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000e5','ad3b0000-0000-0000-0000-0000000000e4','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000e6','ad3b0000-0000-0000-0000-0000000000e4','general',   'ticket_refund',       5000, 605000,'환불 (총액, gen 기준선 100000)','2026-09-05 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000e7','ad3b0000-0000-0000-0000-0000000000e4','general',   'ticket_purchase',    -5000, 600000,'티켓 구매 (총액)','2026-09-06 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000e8','ad3b0000-0000-0000-0000-0000000000e4','membership','ticket_purchase',    -1000, 499000,'대행비 (주머니 기록)','2026-09-08 10:00:00+09');
-- BEN4
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-0000000000e9');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-0000000000e9','user','BEN4 RPC묶음 안 늦은주머니 첫등장', 450000, 70000, 520000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000f1','ad3b0000-0000-0000-0000-0000000000e9','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000f2','ad3b0000-0000-0000-0000-0000000000e9','general',   'ticket_purchase',   -30000, 570000,'티켓 구매 gen (총액, gen 기준선 100000)','2026-09-10 10:00:00.100+09'),
('ad3b0000-0000-0000-0000-0000000000f3','ad3b0000-0000-0000-0000-0000000000e9','membership','ticket_purchase',   -50000, 520000,'대행비 mem (총액)','2026-09-10 10:00:00.200+09');
