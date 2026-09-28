-- C3x: in-group bypass in FIRST group but rows in DIFFERENT pockets (ambiguous with pocket-style pair) — expect D refuses 정상
insert into auth.users(id) values ('c3c00000-0000-0000-0000-0000000000c3');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('c3c00000-0000-0000-0000-0000000000c3','user','C3x 첫묶음 교차주머니 우회', 30000, 100000, 130000, '2026-09-04 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('c3c00000-0000-0000-0000-0000000000a1','c3c00000-0000-0000-0000-0000000000c3','general',   'general_charge',  100000, 100000,'일반 예치금 충전','2026-09-05 12:00:00.100+09'),
-- bypass +50000 mem at .500
('c3c00000-0000-0000-0000-0000000000a2','c3c00000-0000-0000-0000-0000000000c3','membership','ticket_purchase', -20000, 130000,'티켓 구매','2026-09-05 12:00:00.900+09');

-- T1: theft 50000 from gen BEFORE a gen pocket-style row (baseline 200000 gen) — expect D ❌ (E2 may be late)
insert into auth.users(id) values ('d1000000-0000-0000-0000-0000000000d1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('d1000000-0000-0000-0000-0000000000d1','user','T1 주머니기록 앞 도난', 800000, 140000, 940000, '2026-07-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('d1000000-0000-0000-0000-0000000000a1','d1000000-0000-0000-0000-0000000000d1','membership','membership_charge', 900000, 1100000,'연회비 예치금 (총액)','2026-09-01 10:00:00+09'),
('d1000000-0000-0000-0000-0000000000a2','d1000000-0000-0000-0000-0000000000d1','membership','ticket_purchase',  -100000,  800000,'티켓 구매 (주머니)','2026-09-05 10:00:00+09'),
-- bypass 09-07: gen -50000 (no ledger row) -> gen 150000
('d1000000-0000-0000-0000-0000000000a3','d1000000-0000-0000-0000-0000000000d1','general',   'ticket_purchase',   -10000,  140000,'티켓 구매 (주머니)','2026-09-08 10:00:00+09');

-- M1: mint 900000 (== prev row's other_pocket) at second group — expect D ❌ (first_off 0)
insert into auth.users(id) values ('d2000000-0000-0000-0000-0000000000d2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('d2000000-0000-0000-0000-0000000000d2','user','M1 c0 타주머니액 증발', 1700000, 250000, 1950000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('d2000000-0000-0000-0000-0000000000a1','d2000000-0000-0000-0000-0000000000d2','membership','membership_charge', 900000,  900000,'연회비 예치금','2026-09-01 10:00:00+09'),
('d2000000-0000-0000-0000-0000000000a2','d2000000-0000-0000-0000-0000000000d2','general',   'general_charge',    300000, 1200000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
-- bypass 09-10: mem +900000 (no ledger row)
('d2000000-0000-0000-0000-0000000000a3','d2000000-0000-0000-0000-0000000000d2','general',   'ticket_purchase',   -50000, 2050000,'티켓 구매','2026-09-12 10:00:00+09'),
('d2000000-0000-0000-0000-0000000000a4','d2000000-0000-0000-0000-0000000000d2','membership','ticket_purchase',  -100000, 1950000,'티켓 구매','2026-09-15 10:00:00+09');
