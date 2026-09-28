-- B1 pattern(1): same-second pair, ids in OPPOSITE order of writing (pocket-fix pair + reversed invite split), no bypass
insert into auth.users(id) values ('b1000000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b1000000-0000-0000-0000-000000000001','user','B1 역순 쌍', 800000, 150000, 950000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
-- invite split: gen written FIRST (bal 100000) but got the HIGHER id; mem written second (bal 1000000) lower id
('b1000000-0000-0000-0000-0000000000a1','b1000000-0000-0000-0000-000000000001','membership','membership_charge', 900000, 1000000,'초대 결제 mem','2026-09-01 10:00:00.200+09'),
('b1000000-0000-0000-0000-0000000000a2','b1000000-0000-0000-0000-000000000001','general',   'general_charge',    100000,  100000,'초대 결제 gen','2026-09-01 10:00:00.100+09'),
-- pocket-fix pair: gen +100000 written first (bal 1100000) higher id; mem -100000 second (bal 1000000) lower id
('b1000000-0000-0000-0000-0000000000a3','b1000000-0000-0000-0000-000000000001','membership','pocket_fix',       -100000, 1000000,'주머니 보정 mem','2026-09-05 09:00:00.600+09'),
('b1000000-0000-0000-0000-0000000000a4','b1000000-0000-0000-0000-000000000001','general',   'pocket_fix',        100000, 1100000,'주머니 보정 gen','2026-09-05 09:00:00.500+09'),
('b1000000-0000-0000-0000-0000000000a5','b1000000-0000-0000-0000-000000000001','general',   'ticket_purchase',   -50000,  950000,'티켓 구매','2026-09-15 10:00:00+09');

-- B2 pattern(2): balance_after is pocket balance on some rows, total on others; no bypass
insert into auth.users(id) values ('b2000000-0000-0000-0000-000000000002');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b2000000-0000-0000-0000-000000000002','user','B2 주머니기록 혼재', 800000, 250000, 1050000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b2000000-0000-0000-0000-0000000000a1','b2000000-0000-0000-0000-000000000002','membership','membership_charge', 900000,  900000,'연회비 예치금','2026-09-01 10:00:00+09'),
('b2000000-0000-0000-0000-0000000000a2','b2000000-0000-0000-0000-000000000002','general',   'general_charge',    300000, 1200000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('b2000000-0000-0000-0000-0000000000a3','b2000000-0000-0000-0000-000000000002','membership','ticket_purchase',  -100000,  800000,'티켓 구매 (주머니 기록)','2026-09-05 10:00:00+09'),
('b2000000-0000-0000-0000-0000000000a4','b2000000-0000-0000-0000-000000000002','general',   'ticket_purchase',   -50000,  250000,'티켓 구매 (주머니 기록)','2026-09-08 10:00:00+09'),
('b2000000-0000-0000-0000-0000000000a5','b2000000-0000-0000-0000-000000000002','general',   'ticket_refund',      50000, 1100000,'환불 (총액 기록)','2026-09-12 10:00:00+09'),
('b2000000-0000-0000-0000-0000000000a6','b2000000-0000-0000-0000-000000000002','general',   'ticket_purchase',   -50000, 1050000,'티켓 구매 (총액 기록)','2026-09-15 10:00:00+09');

-- B3 pattern(3): pre-ledger baseline 250000, no bypass  (C7 minus the theft)
insert into auth.users(id) values ('b3000000-0000-0000-0000-000000000003');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b3000000-0000-0000-0000-000000000003','user','B3 원장전 기준선', 0, 235000, 235000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b3000000-0000-0000-0000-0000000000a1','b3000000-0000-0000-0000-000000000003','general','ticket_purchase', -10000, 240000,'티켓 구매','2026-09-01 10:00:00+09'),
('b3000000-0000-0000-0000-0000000000a2','b3000000-0000-0000-0000-000000000003','general','ticket_purchase',  -5000, 235000,'티켓 구매','2026-09-06 10:00:00+09');

-- B4 pattern(4): RPC multi-entry in one transaction (same second, id order, balance_after accumulating); no bypass (C5 minus the theft)
insert into auth.users(id) values ('b4000000-0000-0000-0000-000000000004');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b4000000-0000-0000-0000-000000000004','user','B4 RPC 분할차감', 450000, 150000, 600000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b4000000-0000-0000-0000-0000000000a1','b4000000-0000-0000-0000-000000000004','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('b4000000-0000-0000-0000-0000000000a2','b4000000-0000-0000-0000-000000000004','general',   'general_charge',    200000, 700000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('b4000000-0000-0000-0000-0000000000a3','b4000000-0000-0000-0000-000000000004','membership','ticket_purchase',   -50000, 650000,'티켓 구매 mem','2026-09-10 10:00:00.100+09'),
('b4000000-0000-0000-0000-0000000000a4','b4000000-0000-0000-0000-000000000004','general',   'ticket_purchase',   -30000, 620000,'티켓 구매 gen','2026-09-10 10:00:00.200+09'),
('b4000000-0000-0000-0000-0000000000a5','b4000000-0000-0000-0000-000000000004','general',   'ticket_purchase',   -20000, 600000,'티켓 구매','2026-09-18 10:00:00+09');

-- B5 combo (3)+(4)+(1): baseline 100000 in mem, then RPC 3-entry write, then reversed pair
insert into auth.users(id) values ('b5000000-0000-0000-0000-000000000005');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b5000000-0000-0000-0000-000000000005','user','B5 기준선+RPC3+역순', 540000, 170000, 710000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b5000000-0000-0000-0000-0000000000a1','b5000000-0000-0000-0000-000000000005','membership','membership_charge', 500000, 600000,'연회비 예치금','2026-09-01 10:00:00+09'),
('b5000000-0000-0000-0000-0000000000a2','b5000000-0000-0000-0000-000000000005','general',   'general_charge',    200000, 800000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('b5000000-0000-0000-0000-0000000000a3','b5000000-0000-0000-0000-000000000005','membership','ticket_purchase',   -50000, 750000,'티켓 구매 mem','2026-09-10 10:00:00.100+09'),
('b5000000-0000-0000-0000-0000000000a4','b5000000-0000-0000-0000-000000000005','general',   'ticket_purchase',   -30000, 720000,'티켓 구매 gen','2026-09-10 10:00:00.200+09'),
('b5000000-0000-0000-0000-0000000000a5','b5000000-0000-0000-0000-000000000005','membership','ticket_purchase',   -10000, 710000,'대행비 mem','2026-09-10 10:00:00.300+09'),
-- reversed pocket-fix pair (net 0): gen +100000 written first (810000) gets higher id
('b5000000-0000-0000-0000-0000000000a6','b5000000-0000-0000-0000-000000000005','membership','pocket_fix',      -100000, 710000,'주머니 보정 mem','2026-09-14 09:00:00.600+09'),
('b5000000-0000-0000-0000-0000000000a7','b5000000-0000-0000-0000-000000000005','general',   'pocket_fix',       100000, 810000,'주머니 보정 gen','2026-09-14 09:00:00.500+09');

-- B6 combo (2) in the FIRST group: cross-pocket pair both pocket-style, then total-style rows
insert into auth.users(id) values ('b6000000-0000-0000-0000-000000000006');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b6000000-0000-0000-0000-000000000006','user','B6 첫묶음 주머니기록쌍', 900000, 50000, 950000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b6000000-0000-0000-0000-0000000000a1','b6000000-0000-0000-0000-000000000006','membership','membership_charge', 900000,  900000,'초대 결제 mem (주머니)','2026-09-01 10:00:00.100+09'),
('b6000000-0000-0000-0000-0000000000a2','b6000000-0000-0000-0000-000000000006','general',   'general_charge',    100000,  100000,'초대 결제 gen (주머니)','2026-09-01 10:00:00.200+09'),
('b6000000-0000-0000-0000-0000000000a3','b6000000-0000-0000-0000-000000000006','general',   'ticket_purchase',   -50000,  950000,'티켓 구매 (총액)','2026-09-10 10:00:00+09');

-- B7 combo (2)+(3): baseline 200000 (gen) + last row pocket-style
insert into auth.users(id) values ('b7000000-0000-0000-0000-000000000007');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b7000000-0000-0000-0000-000000000007','user','B7 기준선+주머니기록', 800000, 190000, 990000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b7000000-0000-0000-0000-0000000000a1','b7000000-0000-0000-0000-000000000007','membership','membership_charge', 900000, 1100000,'연회비 예치금 (총액)','2026-09-01 10:00:00+09'),
('b7000000-0000-0000-0000-0000000000a2','b7000000-0000-0000-0000-000000000007','membership','ticket_purchase',  -100000,  800000,'티켓 구매 (주머니)','2026-09-05 10:00:00+09'),
('b7000000-0000-0000-0000-0000000000a3','b7000000-0000-0000-0000-000000000007','general',   'ticket_purchase',   -10000,  190000,'티켓 구매 (주머니)','2026-09-08 10:00:00+09');

-- C1b extra theft test: MINT of +300000 (== other pocket) instead of theft
insert into auth.users(id) values ('c1b00000-0000-0000-0000-00000000001b');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('c1b00000-0000-0000-0000-00000000001b','user','C1b 타주머니액 증발(mint)', 1100000, 300000, 1400000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('c1b00000-0000-0000-0000-0000000000a1','c1b00000-0000-0000-0000-00000000001b','membership','membership_charge', 900000,  900000,'연회비 예치금','2026-09-01 10:00:00+09'),
('c1b00000-0000-0000-0000-0000000000a2','c1b00000-0000-0000-0000-00000000001b','general',   'general_charge',    300000, 1200000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('c1b00000-0000-0000-0000-0000000000a3','c1b00000-0000-0000-0000-00000000001b','membership','ticket_purchase',  -100000, 1400000,'티켓 구매','2026-09-15 10:00:00+09');
