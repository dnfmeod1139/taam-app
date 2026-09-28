-- ===== adv3: REAL bypass ledgers aimed at the NEW rules (latebase '기준선?', back, pocketed, per-pocket D) =====

-- A1 (a) mint 200000 into never-touched GEN right before gen's first TOTAL-recorded row, sized = stored_gen - ledger_gen
-- expect: E2 '기준선?' ⓘ 200000 ; D must be ⚠ (never 정상)
insert into auth.users(id) values ('ad3a0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3a0000-0000-0000-0000-000000000001','user','A1 미접촉주머니 mint→첫총액행', 500000, 190000, 690000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3a0000-0000-0000-0000-0000000000a1','ad3a0000-0000-0000-0000-000000000001','membership','membership_charge', 500000, 500000,'연회비 예치금 (총액)','2026-09-01 10:00:00+09'),
-- bypass 09-10: general_deposit_balance += 200000 (no ledger row; gen never touched before)
('ad3a0000-0000-0000-0000-0000000000a2','ad3a0000-0000-0000-0000-000000000001','general',   'ticket_purchase',   -10000, 690000,'티켓 구매 (총액, gen 첫 등장)','2026-09-11 10:00:00+09');

-- B1 (b) borrow-and-return under a genuine baseline 250000: theft -50000 then return +50000, both followed by total-recorded rows.
-- The theft lands 'pocketed' (ba - pocket_end = 200000 ∈ [0,250000]); the return lands 'keep'. Expect: is the pair reported (❌❌ + 상쇄) or lost?
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-000000000001','user','B1 기준선하 도난후 반환(pocketed→keep)', 0, 230000, 230000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000a1','ad3b0000-0000-0000-0000-000000000001','general','ticket_purchase', -10000, 240000,'티켓 구매 (총액, 기준선 250000)','2026-09-01 10:00:00+09'),
-- bypass 09-04: general_deposit_balance -= 50000 (no ledger row)
('ad3b0000-0000-0000-0000-0000000000a2','ad3b0000-0000-0000-0000-000000000001','general','ticket_purchase',  -5000, 185000,'티켓 구매 (총액)','2026-09-05 10:00:00+09'),
-- bypass 09-07: general_deposit_balance += 50000 (no ledger row) — money put back
('ad3b0000-0000-0000-0000-0000000000a3','ad3b0000-0000-0000-0000-000000000001','general','ticket_purchase',  -5000, 230000,'티켓 구매 (총액)','2026-09-08 10:00:00+09');

-- B2 same as B1 without the return (permanent theft -50000 under baseline 250000). Expect D ❌; does E2 show a ❌ or only ⓘ?
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-000000000002');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-000000000002','user','B2 기준선하 영구도난(pocketed)', 0, 180000, 180000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000b1','ad3b0000-0000-0000-0000-000000000002','general','ticket_purchase', -10000, 240000,'티켓 구매 (총액, 기준선 250000)','2026-09-01 10:00:00+09'),
-- bypass 09-04: general_deposit_balance -= 50000 (no ledger row)
('ad3b0000-0000-0000-0000-0000000000b2','ad3b0000-0000-0000-0000-000000000002','general','ticket_purchase',  -5000, 185000,'티켓 구매 (총액)','2026-09-05 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000b3','ad3b0000-0000-0000-0000-000000000002','general','ticket_purchase',  -5000, 180000,'티켓 구매 (총액)','2026-09-08 10:00:00+09');

-- B3 (b) 'back' rule proper: baseline 100000, mint +80000 (❌ nearest), then theft -80000 returning offset exactly to first baseline
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-000000000003');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-000000000003','user','B3 기준선+mint후 back', 0, 80000, 80000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000c1','ad3b0000-0000-0000-0000-000000000003','general','ticket_purchase', -10000,  90000,'티켓 구매 (총액, 기준선 100000)','2026-09-01 10:00:00+09'),
-- bypass 09-03: general_deposit_balance += 80000
('ad3b0000-0000-0000-0000-0000000000c2','ad3b0000-0000-0000-0000-000000000003','general','ticket_purchase',  -5000, 165000,'티켓 구매 (총액)','2026-09-04 10:00:00+09'),
-- bypass 09-06: general_deposit_balance -= 80000
('ad3b0000-0000-0000-0000-0000000000c3','ad3b0000-0000-0000-0000-000000000003','general','ticket_purchase',  -5000,  80000,'티켓 구매 (총액)','2026-09-07 10:00:00+09');

-- C1 (c) per-pocket: pre-ledger baseline 100000 in MEM + theft 100000 from GEN. total diff 0, pocket diffs +100000/-100000
insert into auth.users(id) values ('ad3c0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3c0000-0000-0000-0000-000000000001','user','C1 mem기준선+gen도난 합계0', 100000, 180000, 280000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3c0000-0000-0000-0000-0000000000a1','ad3c0000-0000-0000-0000-000000000001','general','general_charge',  300000, 400000,'일반 예치금 충전 (총액, mem 기준선 100000)','2026-09-01 10:00:00+09'),
-- bypass 09-05: general_deposit_balance -= 100000
('ad3c0000-0000-0000-0000-0000000000a2','ad3c0000-0000-0000-0000-000000000001','general','ticket_purchase', -20000, 280000,'티켓 구매 (총액)','2026-09-10 10:00:00+09');

-- D1 (d) theft -100000 from mem placed in the MIDDLE of a same-second 2-pocket RPC 3-entry group (between entry 1 and 2)
insert into auth.users(id) values ('ad3d0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3d0000-0000-0000-0000-000000000001','user','D1 RPC3 가운데 도난', 340000, 170000, 510000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3d0000-0000-0000-0000-0000000000a1','ad3d0000-0000-0000-0000-000000000001','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3d0000-0000-0000-0000-0000000000a2','ad3d0000-0000-0000-0000-000000000001','general',   'general_charge',    200000, 700000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('ad3d0000-0000-0000-0000-0000000000a3','ad3d0000-0000-0000-0000-000000000001','membership','ticket_purchase',   -50000, 650000,'티켓 구매 mem','2026-09-10 10:00:00.100+09'),
-- bypass 10:00:00.150: membership_deposit_balance -= 100000 (no ledger row)
('ad3d0000-0000-0000-0000-0000000000a4','ad3d0000-0000-0000-0000-000000000001','general',   'ticket_purchase',   -30000, 520000,'티켓 구매 gen','2026-09-10 10:00:00.200+09'),
('ad3d0000-0000-0000-0000-0000000000a5','ad3d0000-0000-0000-0000-000000000001','membership','ticket_purchase',   -10000, 510000,'대행비 mem','2026-09-10 10:00:00.300+09');

-- D2 (d-variant) middle theft sized so the group's last row equals the mem pocket ledger balance (gen wiped: -170000) → 'pocketed'?
insert into auth.users(id) values ('ad3d0000-0000-0000-0000-000000000002');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3d0000-0000-0000-0000-000000000002','user','D2 RPC3 가운데 도난=타주머니', 440000, 0, 440000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3d0000-0000-0000-0000-0000000000b1','ad3d0000-0000-0000-0000-000000000002','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3d0000-0000-0000-0000-0000000000b2','ad3d0000-0000-0000-0000-000000000002','general',   'general_charge',    200000, 700000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
('ad3d0000-0000-0000-0000-0000000000b3','ad3d0000-0000-0000-0000-000000000002','membership','ticket_purchase',   -50000, 650000,'티켓 구매 mem','2026-09-10 10:00:00.100+09'),
-- bypass 10:00:00.150: general_deposit_balance -= 170000 (no ledger row)
('ad3d0000-0000-0000-0000-0000000000b4','ad3d0000-0000-0000-0000-000000000002','general',   'ticket_purchase',   -30000, 450000,'티켓 구매 gen','2026-09-10 10:00:00.200+09'),
('ad3d0000-0000-0000-0000-0000000000b5','ad3d0000-0000-0000-0000-000000000002','membership','ticket_purchase',   -10000, 440000,'대행비 mem','2026-09-10 10:00:00.300+09');

-- E1 (e) two bypasses: genuine mint +100000 (❌), then theft -300000 sized so next row's balance_after == mem pocket ledger balance (disguised as 기록방식)
insert into auth.users(id) values ('ad3e0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3e0000-0000-0000-0000-000000000001','user','E1 진짜❌ 뒤 기록방식 위장 도난', 285000, 200000, 485000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3e0000-0000-0000-0000-0000000000a1','ad3e0000-0000-0000-0000-000000000001','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3e0000-0000-0000-0000-0000000000a2','ad3e0000-0000-0000-0000-000000000001','general',   'general_charge',    200000, 700000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
-- bypass 09-05: membership_deposit_balance += 100000
('ad3e0000-0000-0000-0000-0000000000a3','ad3e0000-0000-0000-0000-000000000001','membership','ticket_purchase',   -10000, 790000,'티켓 구매 (총액)','2026-09-06 10:00:00+09'),
-- bypass 09-08: membership_deposit_balance -= 300000 (= mint 100000 + gen 200000 → next ba equals mem pocket ledger balance)
('ad3e0000-0000-0000-0000-0000000000a4','ad3e0000-0000-0000-0000-000000000001','membership','ticket_purchase',    -5000, 485000,'티켓 구매 (총액)','2026-09-09 10:00:00+09');

-- F1 (f) mint 150000 into never-touched GEN, NO gen row ever. Expect D/G '판정 불가' wording, never 정상
insert into auth.users(id) values ('ad3f0000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3f0000-0000-0000-0000-000000000001','user','F1 미접촉주머니 mint 이후행없음', 480000, 150000, 630000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3f0000-0000-0000-0000-0000000000a1','ad3f0000-0000-0000-0000-000000000001','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3f0000-0000-0000-0000-0000000000a2','ad3f0000-0000-0000-0000-000000000001','membership','ticket_purchase',   -20000, 480000,'티켓 구매','2026-09-03 10:00:00+09');
-- bypass 09-05: general_deposit_balance += 150000 (no ledger row; gen never touched, no later row)

-- F2 (f-variant / benign twin) same as F1 but mem has a pre-ledger baseline 100000 (mem rows ba = 100000 + cum). Identical data to
-- BENIGN "two pre-ledger baselines (mem 100000, gen 150000), mem rows pocket-recorded, gen never touched". Correct verdict ⚠.
insert into auth.users(id) values ('ad3f0000-0000-0000-0000-000000000002');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3f0000-0000-0000-0000-000000000002','user','F2 양주머니 기준선(gen 미접촉)', 580000, 150000, 730000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3f0000-0000-0000-0000-0000000000b1','ad3f0000-0000-0000-0000-000000000002','membership','membership_charge', 500000, 600000,'연회비 예치금 (mem 기준선 100000)','2026-09-01 10:00:00+09'),
('ad3f0000-0000-0000-0000-0000000000b2','ad3f0000-0000-0000-0000-000000000002','membership','ticket_purchase',   -20000, 580000,'티켓 구매','2026-09-03 10:00:00+09');

-- BEN-1 (benign) gen pre-ledger baseline 200000, ALL rows pocket-recorded, gen touched only later. Identical data to
-- "mint 200000 into never-touched gen right before its first POCKET-recorded row" (A1 with a pocket-recorded reveal). Correct verdict ⚠.
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-0000000000e1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-0000000000e1','user','BEN1 늦은주머니 기준선 주머니기록', 500000, 190000, 690000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000e2','ad3b0000-0000-0000-0000-0000000000e1','membership','membership_charge', 500000, 500000,'연회비 예치금 (주머니)','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000e3','ad3b0000-0000-0000-0000-0000000000e1','general',   'ticket_purchase',   -10000, 190000,'티켓 구매 (주머니, gen 기준선 200000)','2026-09-11 10:00:00+09');

-- BEN-2 (benign) gen baseline 100000 revealed by gen's first total-recorded row (latebase ⓘ), then a mem POCKET-recorded row.
-- Does 'back' fire on the pocket row (cand 0 = first_off) and claim the 100000 was "returned" although stored gen is still 100000?
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-0000000000e4');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-0000000000e4','user','BEN2 늦은기준선 뒤 주머니기록행', 499000, 100000, 599000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000e5','ad3b0000-0000-0000-0000-0000000000e4','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000e6','ad3b0000-0000-0000-0000-0000000000e4','general',   'ticket_refund',       5000, 605000,'환불 (총액, gen 기준선 100000)','2026-09-05 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000e7','ad3b0000-0000-0000-0000-0000000000e4','general',   'ticket_purchase',    -5000, 600000,'티켓 구매 (총액)','2026-09-06 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000e8','ad3b0000-0000-0000-0000-0000000000e4','membership','ticket_purchase',    -1000, 499000,'대행비 (주머니 기록)','2026-09-08 10:00:00+09');

-- BEN-4 (benign) gen baseline 100000 first revealed INSIDE a same-second RPC 2-entry group where the gen row is written FIRST (non-final).
-- A1 with the two rows in one second and gen first. latebase only looks at the FINAL row's pocket (mem) → order-dependent.
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-0000000000e9');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-0000000000e9','user','BEN4 RPC묶음 안 늦은주머니 첫등장', 450000, 70000, 520000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000f1','ad3b0000-0000-0000-0000-0000000000e9','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('ad3b0000-0000-0000-0000-0000000000f2','ad3b0000-0000-0000-0000-0000000000e9','general',   'ticket_purchase',   -30000, 570000,'티켓 구매 gen (총액, gen 기준선 100000)','2026-09-10 10:00:00.100+09'),
('ad3b0000-0000-0000-0000-0000000000f3','ad3b0000-0000-0000-0000-0000000000e9','membership','ticket_purchase',   -50000, 520000,'대행비 mem (총액)','2026-09-10 10:00:00.200+09');
