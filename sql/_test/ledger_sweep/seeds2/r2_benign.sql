-- ============================================================================
-- adv3_benign : BENIGN ledgers designed to trip the v3 sweep's NEW rules.
-- Every member: stored balance == ledger sum + constant pre-ledger baseline, per pocket.
-- "pocket" = balance_after is that pocket's balance; "total" = balance_after is mem+gen.
-- ============================================================================

-- (a) A1: pocket-recorded rows only in mem, total-recorded rows only in gen, interleaved. No baseline.
insert into auth.users(id) values ('a1000000-0000-0000-0000-0000000000a1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a1000000-0000-0000-0000-0000000000a1','user','A1 mem주머니/gen총액 교차', 600000, 220000, 820000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a1000000-0000-0000-0000-0000000000b1','a1000000-0000-0000-0000-0000000000a1','membership','membership_charge', 900000,  900000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('a1000000-0000-0000-0000-0000000000b2','a1000000-0000-0000-0000-0000000000a1','general',   'general_charge',    300000, 1200000,'충전 (gen 총액)','2026-09-02 10:00:00+09'),
('a1000000-0000-0000-0000-0000000000b3','a1000000-0000-0000-0000-0000000000a1','membership','ticket_purchase',  -100000,  800000,'구매 (mem 주머니)','2026-09-03 10:00:00+09'),
('a1000000-0000-0000-0000-0000000000b4','a1000000-0000-0000-0000-0000000000a1','general',   'ticket_purchase',   -50000, 1050000,'구매 (gen 총액)','2026-09-04 10:00:00+09'),
('a1000000-0000-0000-0000-0000000000b5','a1000000-0000-0000-0000-0000000000a1','membership','ticket_purchase',  -200000,  600000,'구매 (mem 주머니)','2026-09-05 10:00:00+09'),
('a1000000-0000-0000-0000-0000000000b6','a1000000-0000-0000-0000-0000000000a1','general',   'ticket_purchase',   -30000,  820000,'구매 (gen 총액)','2026-09-06 10:00:00+09');

-- (a2) A2: same shape + baseline mem 100000 (first row is mem pocket-recorded, so it reveals the baseline)
insert into auth.users(id) values ('a2000000-0000-0000-0000-0000000000a2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a2000000-0000-0000-0000-0000000000a2','user','A2 교차+mem기준선', 700000, 220000, 920000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a2000000-0000-0000-0000-0000000000b1','a2000000-0000-0000-0000-0000000000a2','membership','membership_charge', 900000, 1000000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('a2000000-0000-0000-0000-0000000000b2','a2000000-0000-0000-0000-0000000000a2','general',   'general_charge',    300000, 1300000,'충전 (gen 총액)','2026-09-02 10:00:00+09'),
('a2000000-0000-0000-0000-0000000000b3','a2000000-0000-0000-0000-0000000000a2','membership','ticket_purchase',  -100000,  900000,'구매 (mem 주머니)','2026-09-03 10:00:00+09'),
('a2000000-0000-0000-0000-0000000000b4','a2000000-0000-0000-0000-0000000000a2','general',   'ticket_purchase',   -50000, 1150000,'구매 (gen 총액)','2026-09-04 10:00:00+09'),
('a2000000-0000-0000-0000-0000000000b5','a2000000-0000-0000-0000-0000000000a2','membership','ticket_purchase',  -200000,  700000,'구매 (mem 주머니)','2026-09-05 10:00:00+09'),
('a2000000-0000-0000-0000-0000000000b6','a2000000-0000-0000-0000-0000000000a2','general',   'ticket_purchase',   -30000,  920000,'구매 (gen 총액)','2026-09-06 10:00:00+09');

-- (a3) A3: same shape + baseline gen 100000 (first row mem pocket-recorded hides it; first gen total row reveals it)
insert into auth.users(id) values ('a3000000-0000-0000-0000-0000000000a3');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a3000000-0000-0000-0000-0000000000a3','user','A3 교차+gen기준선', 600000, 320000, 920000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a3000000-0000-0000-0000-0000000000b1','a3000000-0000-0000-0000-0000000000a3','membership','membership_charge', 900000,  900000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('a3000000-0000-0000-0000-0000000000b2','a3000000-0000-0000-0000-0000000000a3','general',   'general_charge',    300000, 1300000,'충전 (gen 총액)','2026-09-02 10:00:00+09'),
('a3000000-0000-0000-0000-0000000000b3','a3000000-0000-0000-0000-0000000000a3','membership','ticket_purchase',  -100000,  800000,'구매 (mem 주머니)','2026-09-03 10:00:00+09'),
('a3000000-0000-0000-0000-0000000000b4','a3000000-0000-0000-0000-0000000000a3','general',   'ticket_purchase',   -50000, 1150000,'구매 (gen 총액)','2026-09-04 10:00:00+09'),
('a3000000-0000-0000-0000-0000000000b5','a3000000-0000-0000-0000-0000000000a3','membership','ticket_purchase',  -200000,  600000,'구매 (mem 주머니)','2026-09-05 10:00:00+09'),
('a3000000-0000-0000-0000-0000000000b6','a3000000-0000-0000-0000-0000000000a3','general',   'ticket_purchase',   -30000,  920000,'구매 (gen 총액)','2026-09-06 10:00:00+09');

-- (b) B1: baseline split mem 100000 / gen 50000; each pocket's FIRST row is pocket-recorded; all rows pocket-recorded.
insert into auth.users(id) values ('b1000000-0000-0000-0000-0000000000b1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b1000000-0000-0000-0000-0000000000b1','user','B1 양주머니기준선 mem큼', 900000, 120000, 1020000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b1000000-0000-0000-0000-0000000000c1','b1000000-0000-0000-0000-0000000000b1','membership','membership_charge', 900000, 1000000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('b1000000-0000-0000-0000-0000000000c2','b1000000-0000-0000-0000-0000000000b1','general',   'general_charge',    100000,  150000,'충전 (gen 주머니)','2026-09-02 10:00:00+09'),
('b1000000-0000-0000-0000-0000000000c3','b1000000-0000-0000-0000-0000000000b1','membership','ticket_purchase',  -100000,  900000,'구매 (mem 주머니)','2026-09-05 10:00:00+09'),
('b1000000-0000-0000-0000-0000000000c4','b1000000-0000-0000-0000-0000000000b1','general',   'ticket_purchase',   -30000,  120000,'구매 (gen 주머니)','2026-09-08 10:00:00+09');

-- (b') B2: same but baseline mem 50000 / gen 100000 (the pocket seen first has the SMALLER baseline)
insert into auth.users(id) values ('b2000000-0000-0000-0000-0000000000b2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('b2000000-0000-0000-0000-0000000000b2','user','B2 양주머니기준선 gen큼', 850000, 170000, 1020000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('b2000000-0000-0000-0000-0000000000c1','b2000000-0000-0000-0000-0000000000b2','membership','membership_charge', 900000,  950000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('b2000000-0000-0000-0000-0000000000c2','b2000000-0000-0000-0000-0000000000b2','general',   'general_charge',    100000,  200000,'충전 (gen 주머니)','2026-09-02 10:00:00+09'),
('b2000000-0000-0000-0000-0000000000c3','b2000000-0000-0000-0000-0000000000b2','membership','ticket_purchase',  -100000,  850000,'구매 (mem 주머니)','2026-09-05 10:00:00+09'),
('b2000000-0000-0000-0000-0000000000c4','b2000000-0000-0000-0000-0000000000b2','general',   'ticket_purchase',   -30000,  170000,'구매 (gen 주머니)','2026-09-08 10:00:00+09');

-- (c) C1: RPC 3-entry group (mem,gen,mem) total-recorded, ids REVERSED vs write order, baseline mem 100000
insert into auth.users(id) values ('c1000000-0000-0000-0000-0000000000c1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('c1000000-0000-0000-0000-0000000000c1','user','C1 RPC3 역순id+기준선', 540000, 170000, 710000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('c1000000-0000-0000-0000-0000000000d1','c1000000-0000-0000-0000-0000000000c1','membership','membership_charge', 500000, 600000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('c1000000-0000-0000-0000-0000000000d2','c1000000-0000-0000-0000-0000000000c1','general',   'general_charge',    200000, 800000,'충전 (총액)','2026-09-02 10:00:00+09'),
-- written .100 / .200 / .300 but ids d5 > d4 > d3
('c1000000-0000-0000-0000-0000000000d5','c1000000-0000-0000-0000-0000000000c1','membership','ticket_purchase',   -50000, 750000,'RPC e1 mem','2026-09-10 10:00:00.100+09'),
('c1000000-0000-0000-0000-0000000000d4','c1000000-0000-0000-0000-0000000000c1','general',   'ticket_purchase',   -30000, 720000,'RPC e2 gen','2026-09-10 10:00:00.200+09'),
('c1000000-0000-0000-0000-0000000000d3','c1000000-0000-0000-0000-0000000000c1','membership','ticket_purchase',   -10000, 710000,'RPC e3 mem 대행비','2026-09-10 10:00:00.300+09');

-- (c') C2: the reversed RPC 3-entry group IS the first (and only) group; baseline split mem 60000 / gen 40000; total-recorded
insert into auth.users(id) values ('c2000000-0000-0000-0000-0000000000c2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('c2000000-0000-0000-0000-0000000000c2','user','C2 첫묶음=RPC3 역순+기준선', 550000, 240000, 790000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('c2000000-0000-0000-0000-0000000000d5','c2000000-0000-0000-0000-0000000000c2','membership','membership_charge', 500000, 600000,'RPC e1 mem','2026-09-10 10:00:00.100+09'),
('c2000000-0000-0000-0000-0000000000d4','c2000000-0000-0000-0000-0000000000c2','general',   'general_charge',    200000, 800000,'RPC e2 gen','2026-09-10 10:00:00.200+09'),
('c2000000-0000-0000-0000-0000000000d3','c2000000-0000-0000-0000-0000000000c2','membership','ticket_purchase',   -10000, 790000,'RPC e3 mem','2026-09-10 10:00:00.300+09');

-- (d) D1: FIRST group is an RPC 2-entry split; e1 total-recorded, e2 pocket-recorded (mixed semantics in one txn); baseline gen 100000
insert into auth.users(id) values ('d1000000-0000-0000-0000-0000000000d1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('d1000000-0000-0000-0000-0000000000d1','user','D1 첫묶음 혼합기록+기준선', 900000, 150000, 1050000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('d1000000-0000-0000-0000-0000000000e1','d1000000-0000-0000-0000-0000000000d1','membership','membership_charge', 900000, 1000000,'초대 결제 mem (총액)','2026-09-03 09:00:00.100+09'),
('d1000000-0000-0000-0000-0000000000e2','d1000000-0000-0000-0000-0000000000d1','general',   'general_charge',    100000,  200000,'초대 결제 gen (주머니)','2026-09-03 09:00:00.200+09'),
('d1000000-0000-0000-0000-0000000000e3','d1000000-0000-0000-0000-0000000000d1','general',   'ticket_purchase',   -50000, 1050000,'구매 (총액)','2026-09-10 10:00:00+09');

-- (e) E1: semantic switch pocket -> total -> pocket in three consecutive seconds; both pockets non-zero; no baseline
insert into auth.users(id) values ('e1000000-0000-0000-0000-0000000000e1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('e1000000-0000-0000-0000-0000000000e1','user','E1 주머니→총액→주머니 3초', 430000, 170000, 600000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('e1000000-0000-0000-0000-0000000000f1','e1000000-0000-0000-0000-0000000000e1','membership','membership_charge', 500000, 500000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('e1000000-0000-0000-0000-0000000000f2','e1000000-0000-0000-0000-0000000000e1','general',   'general_charge',    200000, 700000,'충전 (총액)','2026-09-02 10:00:00+09'),
('e1000000-0000-0000-0000-0000000000f3','e1000000-0000-0000-0000-0000000000e1','membership','ticket_purchase',   -50000, 450000,'구매 (mem 주머니)','2026-09-10 10:00:01+09'),
('e1000000-0000-0000-0000-0000000000f4','e1000000-0000-0000-0000-0000000000e1','general',   'ticket_purchase',   -30000, 620000,'구매 (총액)','2026-09-10 10:00:02+09'),
('e1000000-0000-0000-0000-0000000000f5','e1000000-0000-0000-0000-0000000000e1','membership','ticket_purchase',   -20000, 430000,'구매 (mem 주머니)','2026-09-10 10:00:03+09');

-- (e') E2: same switch + baseline split mem 60000 / gen 40000, first row total-recorded
insert into auth.users(id) values ('e2000000-0000-0000-0000-0000000000e2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('e2000000-0000-0000-0000-0000000000e2','user','E2 스위치+양주머니기준선', 490000, 210000, 700000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('e2000000-0000-0000-0000-0000000000f1','e2000000-0000-0000-0000-0000000000e2','membership','membership_charge', 500000, 600000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('e2000000-0000-0000-0000-0000000000f2','e2000000-0000-0000-0000-0000000000e2','general',   'general_charge',    200000, 800000,'충전 (총액)','2026-09-02 10:00:00+09'),
('e2000000-0000-0000-0000-0000000000f3','e2000000-0000-0000-0000-0000000000e2','membership','ticket_purchase',   -50000, 510000,'구매 (mem 주머니)','2026-09-10 10:00:01+09'),
('e2000000-0000-0000-0000-0000000000f4','e2000000-0000-0000-0000-0000000000e2','general',   'ticket_purchase',   -30000, 720000,'구매 (총액)','2026-09-10 10:00:02+09'),
('e2000000-0000-0000-0000-0000000000f5','e2000000-0000-0000-0000-0000000000e2','membership','ticket_purchase',   -20000, 490000,'구매 (mem 주머니)','2026-09-10 10:00:03+09');

-- (e'') E3: switch pocket -> total -> pocket in 3 consecutive seconds where the FIRST row is pocket-recorded; baseline split mem 100000 / gen 50000
insert into auth.users(id) values ('e3000000-0000-0000-0000-0000000000e3');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('e3000000-0000-0000-0000-0000000000e3','user','E3 스위치 첫줄주머니+양기준선', 550000, 250000, 800000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('e3000000-0000-0000-0000-0000000000f1','e3000000-0000-0000-0000-0000000000e3','membership','membership_charge', 500000, 600000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('e3000000-0000-0000-0000-0000000000f2','e3000000-0000-0000-0000-0000000000e3','general',   'general_charge',    200000, 850000,'충전 (총액)','2026-09-01 10:00:01+09'),
('e3000000-0000-0000-0000-0000000000f3','e3000000-0000-0000-0000-0000000000e3','membership','ticket_purchase',   -50000, 550000,'구매 (mem 주머니)','2026-09-01 10:00:02+09');

-- (f) F1: baseline gen 50000; the ONLY rows are two same-second mem pocket-recorded rows
insert into auth.users(id) values ('f1000000-0000-0000-0000-0000000000f1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f1000000-0000-0000-0000-0000000000f1','user','F1 gen기준선+같은초 mem주머니쌍', 800000, 50000, 850000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-0000000000f1','membership','membership_charge', 900000, 900000,'연회비 (mem 주머니)','2026-09-05 10:00:00.100+09'),
('f1000000-0000-0000-0000-000000000002','f1000000-0000-0000-0000-0000000000f1','membership','ticket_purchase',  -100000, 800000,'구매 (mem 주머니)','2026-09-05 10:00:00.200+09');

-- (f') F2: baseline gen 50000; ONLY rows = one same-second pocket-recorded pair in DIFFERENT pockets (invite split, B6 shape)
insert into auth.users(id) values ('f2000000-0000-0000-0000-0000000000f2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f2000000-0000-0000-0000-0000000000f2','user','F2 gen기준선+같은초 교차주머니쌍', 900000, 150000, 1050000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f2000000-0000-0000-0000-000000000001','f2000000-0000-0000-0000-0000000000f2','membership','membership_charge', 900000, 900000,'초대 결제 mem (주머니)','2026-09-05 10:00:00.100+09'),
('f2000000-0000-0000-0000-000000000002','f2000000-0000-0000-0000-0000000000f2','general',   'general_charge',    100000, 150000,'초대 결제 gen (주머니)','2026-09-05 10:00:00.200+09');

-- (g) G1: baseline gen 50000; mem pocket-recorded first; gen +30000 / -30000 total-recorded (nets to 0); then mem pocket-recorded
insert into auth.users(id) values ('91000000-0000-0000-0000-000000000091');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('91000000-0000-0000-0000-000000000091','user','G1 gen기준선 늦게드러남+gen상쇄+mem주머니', 800000, 50000, 850000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('91000000-0000-0000-0000-000000000001','91000000-0000-0000-0000-000000000091','membership','membership_charge', 900000, 900000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('91000000-0000-0000-0000-000000000002','91000000-0000-0000-0000-000000000091','general',   'ticket_purchase',    30000, 980000,'환불 (총액)','2026-09-02 10:00:00+09'),
('91000000-0000-0000-0000-000000000003','91000000-0000-0000-0000-000000000091','general',   'ticket_purchase',   -30000, 950000,'구매 (총액)','2026-09-03 10:00:00+09'),
('91000000-0000-0000-0000-000000000004','91000000-0000-0000-0000-000000000091','membership','ticket_purchase',  -100000, 800000,'구매 (mem 주머니)','2026-09-05 10:00:00+09');

-- (h) H1: B6 shape (first group = same-second pocket-recorded pair in different pockets) + baseline gen 50000 + trailing total row
insert into auth.users(id) values ('81000000-0000-0000-0000-000000000081');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('81000000-0000-0000-0000-000000000081','user','H1 B6첫묶음주머니쌍+gen기준선', 900000, 100000, 1000000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('81000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-000000000081','membership','membership_charge', 900000, 900000,'초대 결제 mem (주머니)','2026-09-01 10:00:00.100+09'),
('81000000-0000-0000-0000-000000000002','81000000-0000-0000-0000-000000000081','general',   'general_charge',    100000, 150000,'초대 결제 gen (주머니)','2026-09-01 10:00:00.200+09'),
('81000000-0000-0000-0000-000000000003','81000000-0000-0000-0000-000000000081','general',   'ticket_purchase',   -50000,1000000,'구매 (총액)','2026-09-10 10:00:00+09');

-- (i) I1: RPC 3-entry group with mixed semantics (total, pocket, total); no baseline; stored == ledger
insert into auth.users(id) values ('71000000-0000-0000-0000-000000000071');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('71000000-0000-0000-0000-000000000071','user','I1 RPC3 혼합기록(총·주·총)', 440000, 170000, 610000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('71000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000071','membership','membership_charge', 500000, 500000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('71000000-0000-0000-0000-000000000002','71000000-0000-0000-0000-000000000071','general',   'general_charge',    200000, 700000,'충전 (총액)','2026-09-02 10:00:00+09'),
('71000000-0000-0000-0000-000000000003','71000000-0000-0000-0000-000000000071','membership','ticket_purchase',   -50000, 650000,'RPC e1 mem (총액)','2026-09-10 10:00:00.100+09'),
('71000000-0000-0000-0000-000000000004','71000000-0000-0000-0000-000000000071','general',   'ticket_purchase',   -30000, 170000,'RPC e2 gen (주머니)','2026-09-10 10:00:00.200+09'),
('71000000-0000-0000-0000-000000000005','71000000-0000-0000-0000-000000000071','membership','ticket_purchase',   -10000, 610000,'RPC e3 mem (총액)','2026-09-10 10:00:00.300+09');
