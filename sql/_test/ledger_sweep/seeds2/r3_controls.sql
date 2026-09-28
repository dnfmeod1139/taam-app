-- BN1c: BN1 with ids IN write order (a3<a4<a5) — must have no ❌ (shows BN1's ❌묶음 is purely id-order)
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000c1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000c1','user','BN1c 같은 데이터 id 정순', 540000, 220000, 760000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000c1a1','ad400000-0000-0000-0000-0000000000c1','membership','membership_charge', 500000, 650000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('ad400000-0000-0000-0000-00000000c1a2','ad400000-0000-0000-0000-0000000000c1','general',   'general_charge',    200000, 850000,'충전 (총액)','2026-09-02 10:00:00+09'),
('ad400000-0000-0000-0000-00000000c1a3','ad400000-0000-0000-0000-0000000000c1','membership','ticket_purchase',   -50000, 800000,'RPC e1 mem (총액)','2026-09-10 10:00:00.100+09'),
('ad400000-0000-0000-0000-00000000c1a4','ad400000-0000-0000-0000-0000000000c1','general',   'ticket_purchase',   -30000, 220000,'RPC e2 gen (주머니)','2026-09-10 10:00:00.200+09'),
('ad400000-0000-0000-0000-00000000c1a5','ad400000-0000-0000-0000-0000000000c1','membership','ticket_purchase',   -10000, 760000,'RPC e3 mem (총액)','2026-09-10 10:00:00.300+09');
-- R1c: R1 but theft 500000 (≠ live mem balance 600000) — J3-P should now catch it
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000c2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000c2','user','R1c 도난 500000 (mem잔액과 다름)', 600000, 230000, 830000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000c2a1','ad400000-0000-0000-0000-0000000000c2','membership','membership_charge', 500000, 650000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('ad400000-0000-0000-0000-00000000c2a2','ad400000-0000-0000-0000-0000000000c2','general',   'general_charge',    200000, 850000,'충전 (총액)','2026-09-02 10:00:00+09'),
('ad400000-0000-0000-0000-00000000c2a3','ad400000-0000-0000-0000-0000000000c2','general',   'ticket_purchase',   -10000, 340000,'구매 (총액)','2026-09-05 10:00:00+09'),
('ad400000-0000-0000-0000-00000000c2a4','ad400000-0000-0000-0000-0000000000c2','general',   'ticket_purchase',   -10000, 830000,'구매 (총액)','2026-09-08 10:00:00+09');
-- R2c: R2 but Row3 total-recorded (ba 585000) — theft should now surface as ❌
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000c3');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000c3','user','R2c 셋째줄 총액 기록', 540000, 45000, 585000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000c3a1','ad400000-0000-0000-0000-0000000000c3','membership','membership_charge', 500000, 600000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('ad400000-0000-0000-0000-00000000c3a2','ad400000-0000-0000-0000-0000000000c3','general',   'ticket_purchase',   -10000, 650000,'구매 gen (총액, gen 첫 등장)','2026-09-04 10:00:00+09'),
('ad400000-0000-0000-0000-00000000c3a3','ad400000-0000-0000-0000-0000000000c3','general',   'ticket_purchase',    -5000, 585000,'구매 gen (총액)','2026-09-06 10:00:00+09');
-- R3c: R3 with NO baseline (mem 0) — D should catch via 「합계는 같은데 주머니가 다름」
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000c4');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000c4','user','R3c 기준선 없음', 340000, 270000, 610000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000c4a1','ad400000-0000-0000-0000-0000000000c4','membership','membership_charge', 500000, 500000,'연회비 (총액)','2026-09-01 10:00:00+09'),
('ad400000-0000-0000-0000-00000000c4a2','ad400000-0000-0000-0000-0000000000c4','general',   'general_charge',    200000, 700000,'충전 (총액)','2026-09-02 10:00:00+09'),
('ad400000-0000-0000-0000-00000000c4a3','ad400000-0000-0000-0000-0000000000c4','membership','ticket_purchase',   -50000, 650000,'RPC e1 mem (총액)','2026-09-10 10:00:00.100+09'),
('ad400000-0000-0000-0000-00000000c4a4','ad400000-0000-0000-0000-0000000000c4','general',   'ticket_purchase',   -30000, 620000,'RPC e2 gen (총액)','2026-09-10 10:00:00.200+09'),
('ad400000-0000-0000-0000-00000000c4a5','ad400000-0000-0000-0000-0000000000c4','membership','ticket_purchase',   -10000, 610000,'RPC e3 mem (총액)','2026-09-10 10:00:00.300+09');
