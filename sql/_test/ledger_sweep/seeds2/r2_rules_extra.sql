-- B1b realistic shape: mem baseline 1,700,000 (연회비 예치금 pre-ledger), only mem purchases; theft -500,000 then silent return +500,000
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-00000000001b');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-00000000001b','user','B1b mem기준선170만 도난50만후 반환', 1350000, 0, 1350000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000001b1','ad3b0000-0000-0000-0000-00000000001b','membership','ticket_purchase', -200000, 1500000,'티켓 구매 (총액, 기준선 1700000)','2026-09-01 10:00:00+09'),
-- bypass 09-04: membership_deposit_balance -= 500000 (no ledger row)
('ad3b0000-0000-0000-0000-0000000001b2','ad3b0000-0000-0000-0000-00000000001b','membership','ticket_purchase', -100000,  900000,'티켓 구매 (총액)','2026-09-05 10:00:00+09'),
-- bypass 09-07: membership_deposit_balance += 500000 (no ledger row)
('ad3b0000-0000-0000-0000-0000000001b3','ad3b0000-0000-0000-0000-00000000001b','membership','ticket_purchase',  -50000, 1350000,'티켓 구매 (총액)','2026-09-08 10:00:00+09');

-- B1c mirror of control C6 with baseline 0 but THEFT first then mint back (expect ❌❌ + 상쇄 — shows the asymmetry vs B1)
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-00000000001c');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-00000000001c','user','B1c 기준선0 도난후 반환', 0, 280000, 280000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000001c1','ad3b0000-0000-0000-0000-00000000001c','general','general_charge',  300000, 300000,'일반 예치금 충전','2026-09-01 10:00:00+09'),
-- bypass 09-05: general_deposit_balance -= 80000
('ad3b0000-0000-0000-0000-0000000001c2','ad3b0000-0000-0000-0000-00000000001c','general','ticket_purchase', -10000, 210000,'티켓 구매','2026-09-06 10:00:00+09'),
-- bypass 09-08: general_deposit_balance += 80000
('ad3b0000-0000-0000-0000-0000000001c3','ad3b0000-0000-0000-0000-00000000001c','general','ticket_purchase', -10000, 280000,'티켓 구매','2026-09-09 10:00:00+09');

-- X1 cross-pocket move under baseline: mem baseline 300000 (total-recorded), theft -100000 from mem (next mem row → pocketed, silent),
-- then mint +100000 into never-touched gen right before gen's first total row (cand returns to first_off → keep). tot diff = first_off.
insert into auth.users(id) values ('ad3b0000-0000-0000-0000-0000000000d1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad3b0000-0000-0000-0000-0000000000d1','user','X1 기준선하 mem→gen 원장밖이동', 170000, 90000, 260000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad3b0000-0000-0000-0000-0000000000d2','ad3b0000-0000-0000-0000-0000000000d1','membership','ticket_purchase', -20000, 280000,'티켓 구매 (총액, mem 기준선 300000)','2026-09-01 10:00:00+09'),
-- bypass 09-03: membership_deposit_balance -= 100000
('ad3b0000-0000-0000-0000-0000000000d3','ad3b0000-0000-0000-0000-0000000000d1','membership','ticket_purchase', -10000, 170000,'티켓 구매 (총액)','2026-09-04 10:00:00+09'),
-- bypass 09-06: general_deposit_balance += 100000 (gen never touched before)
('ad3b0000-0000-0000-0000-0000000000d4','ad3b0000-0000-0000-0000-0000000000d1','general',   'ticket_purchase', -10000, 260000,'티켓 구매 gen (총액, gen 첫 등장)','2026-09-07 10:00:00+09');
