-- Self-attack on the judge1 patch: bypass variants of every shape the patch relaxed. Each must stay ❌ (or ⚠, never 정상 / silent).
-- Z1: B1 shape (mem pocket first, gen pocket first appearance, both baselines) + LATER theft -20000 gen (no ledger row). stored gen 100000 (=50000+70000-20000)
insert into auth.users(id) values ('f1000000-0000-0000-0000-0000000000f1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f1000000-0000-0000-0000-0000000000f1','user','Z1 B1형+뒤 도난', 900000, 100000, 1000000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f1000000-0000-0000-0000-0000000000c1','f1000000-0000-0000-0000-0000000000f1','membership','membership_charge', 900000, 1000000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('f1000000-0000-0000-0000-0000000000c2','f1000000-0000-0000-0000-0000000000f1','general',   'general_charge',    100000,  150000,'충전 (gen 주머니)','2026-09-02 10:00:00+09'),
('f1000000-0000-0000-0000-0000000000c3','f1000000-0000-0000-0000-0000000000f1','membership','ticket_purchase',  -100000,  900000,'구매 (mem 주머니)','2026-09-05 10:00:00+09'),
('f1000000-0000-0000-0000-0000000000c4','f1000000-0000-0000-0000-0000000000f1','general',   'ticket_purchase',   -30000,  120000,'구매 (gen 주머니)','2026-09-08 10:00:00+09');
-- Z2: B2 shape (gen baseline larger) + later mint +40000 mem (no row). stored mem 890000
insert into auth.users(id) values ('f2000000-0000-0000-0000-0000000000f2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f2000000-0000-0000-0000-0000000000f2','user','Z2 B2형+뒤 증발', 890000, 170000, 1060000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f2000000-0000-0000-0000-0000000000c1','f2000000-0000-0000-0000-0000000000f2','membership','membership_charge', 900000,  950000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('f2000000-0000-0000-0000-0000000000c2','f2000000-0000-0000-0000-0000000000f2','general',   'general_charge',    100000,  200000,'충전 (gen 주머니)','2026-09-02 10:00:00+09'),
('f2000000-0000-0000-0000-0000000000c3','f2000000-0000-0000-0000-0000000000f2','membership','ticket_purchase',  -100000,  850000,'구매 (mem 주머니)','2026-09-05 10:00:00+09'),
('f2000000-0000-0000-0000-0000000000c4','f2000000-0000-0000-0000-0000000000f2','general',   'ticket_purchase',   -30000,  170000,'구매 (gen 주머니)','2026-09-08 10:00:00+09');
-- Z3: B6 first group (pocket pair, no baseline) + mint +70000 mem between groups, then total row reflects it. stored mem 970000
insert into auth.users(id) values ('f3000000-0000-0000-0000-0000000000f3');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f3000000-0000-0000-0000-0000000000f3','user','Z3 B6형+사이 증발', 970000, 50000, 1020000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f3000000-0000-0000-0000-0000000000c1','f3000000-0000-0000-0000-0000000000f3','membership','membership_charge', 900000,  900000,'초대 결제 mem (주머니)','2026-09-01 10:00:00.100+09'),
('f3000000-0000-0000-0000-0000000000c2','f3000000-0000-0000-0000-0000000000f3','general',   'general_charge',    100000,  100000,'초대 결제 gen (주머니)','2026-09-01 10:00:00.200+09'),
('f3000000-0000-0000-0000-0000000000c3','f3000000-0000-0000-0000-0000000000f3','general',   'ticket_purchase',   -50000, 1020000,'구매 (총액)','2026-09-10 10:00:00+09');
-- Z4: F2 shape (pocket pair only) but gen stored is 20000 LOWER than the pair says (theft -20000 after). stored gen 130000 vs row says 150000
insert into auth.users(id) values ('f4000000-0000-0000-0000-0000000000f4');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f4000000-0000-0000-0000-0000000000f4','user','Z4 F2형+뒤 도난', 900000, 130000, 1030000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f4000000-0000-0000-0000-000000000001','f4000000-0000-0000-0000-0000000000f4','membership','membership_charge', 900000, 900000,'초대 결제 mem (주머니)','2026-09-05 10:00:00.100+09'),
('f4000000-0000-0000-0000-000000000002','f4000000-0000-0000-0000-0000000000f4','general',   'general_charge',    100000, 150000,'초대 결제 gen (주머니)','2026-09-05 10:00:00.200+09');
-- Z5: I1 shape (RPC3 mixed semantics) but with a REAL in-group theft -30000 mem between e1 and e2 (id-order gap ≠ 0). stored mem 410000
insert into auth.users(id) values ('f5000000-0000-0000-0000-0000000000f5');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f5000000-0000-0000-0000-0000000000f5','user','Z5 I1형+묶음 안 도난', 410000, 170000, 580000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f5000000-0000-0000-0000-000000000001','f5000000-0000-0000-0000-0000000000f5','membership','membership_charge', 500000, 500000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('f5000000-0000-0000-0000-000000000002','f5000000-0000-0000-0000-0000000000f5','general',   'general_charge',    200000, 700000,'충전 (총액)','2026-09-02 10:00:00+09'),
('f5000000-0000-0000-0000-000000000003','f5000000-0000-0000-0000-0000000000f5','membership','ticket_purchase',   -50000, 650000,'RPC e1 mem (총액)','2026-09-10 10:00:00.100+09'),
('f5000000-0000-0000-0000-000000000004','f5000000-0000-0000-0000-0000000000f5','general',   'ticket_purchase',   -30000, 170000,'RPC e2 gen (주머니)','2026-09-10 10:00:00.200+09'),
('f5000000-0000-0000-0000-000000000005','f5000000-0000-0000-0000-0000000000f5','membership','ticket_purchase',   -10000, 580000,'RPC e3 mem (총액)','2026-09-10 10:00:00.300+09');
-- Z6: G1-like two-pocket member with a real C6 net-zero theft pair in gen: mem pocket first, then gen total rows; theft +60000 gen at 09-03, reversed -60000 at 09-06
insert into auth.users(id) values ('f6000000-0000-0000-0000-0000000000f6');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f6000000-0000-0000-0000-0000000000f6','user','Z6 두주머니 상쇄 우회쌍', 900000, 140000, 1040000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f6000000-0000-0000-0000-000000000001','f6000000-0000-0000-0000-0000000000f6','membership','membership_charge', 900000,  900000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('f6000000-0000-0000-0000-000000000002','f6000000-0000-0000-0000-0000000000f6','general',   'general_charge',    200000, 1100000,'충전 (총액)','2026-09-02 10:00:00+09'),
-- bypass 09-03 gen +60000
('f6000000-0000-0000-0000-000000000003','f6000000-0000-0000-0000-0000000000f6','general',   'ticket_purchase',   -30000, 1130000,'구매 (총액)','2026-09-04 10:00:00+09'),
-- bypass 09-06 gen -60000
('f6000000-0000-0000-0000-000000000004','f6000000-0000-0000-0000-0000000000f6','general',   'ticket_purchase',   -30000, 1040000,'구매 (총액)','2026-09-07 10:00:00+09');
-- Z7: D1 shape (mixed first split, gen baseline 100000) + theft -40000 mem after e3. stored mem 860000
insert into auth.users(id) values ('f7000000-0000-0000-0000-0000000000f7');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f7000000-0000-0000-0000-0000000000f7','user','Z7 D1형+뒤 도난', 860000, 150000, 1010000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f7000000-0000-0000-0000-0000000000e1','f7000000-0000-0000-0000-0000000000f7','membership','membership_charge', 900000, 1000000,'초대 결제 mem (총액)','2026-09-03 09:00:00.100+09'),
('f7000000-0000-0000-0000-0000000000e2','f7000000-0000-0000-0000-0000000000f7','general',   'general_charge',    100000,  200000,'초대 결제 gen (주머니)','2026-09-03 09:00:00.200+09'),
('f7000000-0000-0000-0000-0000000000e3','f7000000-0000-0000-0000-0000000000f7','general',   'ticket_purchase',   -50000, 1050000,'구매 (총액)','2026-09-10 10:00:00+09');
-- Z8: B1 shape but gen first-appearance pocket row is followed by a mem theft -50000 (other pocket). stored mem 850000, gen 120000
insert into auth.users(id) values ('f8000000-0000-0000-0000-0000000000f8');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f8000000-0000-0000-0000-0000000000f8','user','Z8 B1형+타주머니 도난', 850000, 120000, 970000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f8000000-0000-0000-0000-0000000000c1','f8000000-0000-0000-0000-0000000000f8','membership','membership_charge', 900000, 1000000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('f8000000-0000-0000-0000-0000000000c2','f8000000-0000-0000-0000-0000000000f8','general',   'general_charge',    100000,  150000,'충전 (gen 주머니)','2026-09-02 10:00:00+09'),
('f8000000-0000-0000-0000-0000000000c3','f8000000-0000-0000-0000-0000000000f8','general',   'ticket_purchase',   -30000,  120000,'구매 (gen 주머니)','2026-09-08 10:00:00+09');
-- Z9 (benign control for the patch): B1 shape + a later TOTAL-recorded gen row — must not ❌ (baseline 150000 confirmed by total row)
insert into auth.users(id) values ('f9000000-0000-0000-0000-0000000000f9');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('f9000000-0000-0000-0000-0000000000f9','user','Z9 B1형+총액 확인줄(정상)', 900000, 110000, 1010000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('f9000000-0000-0000-0000-0000000000c1','f9000000-0000-0000-0000-0000000000f9','membership','membership_charge', 900000, 1000000,'연회비 (mem 주머니)','2026-09-01 10:00:00+09'),
('f9000000-0000-0000-0000-0000000000c2','f9000000-0000-0000-0000-0000000000f9','general',   'general_charge',    100000,  150000,'충전 (gen 주머니)','2026-09-02 10:00:00+09'),
('f9000000-0000-0000-0000-0000000000c3','f9000000-0000-0000-0000-0000000000f9','membership','ticket_purchase',  -100000,  900000,'구매 (mem 주머니)','2026-09-05 10:00:00+09'),
('f9000000-0000-0000-0000-0000000000c4','f9000000-0000-0000-0000-0000000000f9','general',   'ticket_purchase',   -40000, 1010000,'구매 (총액)','2026-09-08 10:00:00+09');
