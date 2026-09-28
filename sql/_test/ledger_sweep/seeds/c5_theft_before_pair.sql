-- CASE 5: theft mem -100,000 in the same second as (and right before) a 2-entry RPC purchase (mem -50,000 / gen -30,000)
insert into auth.users(id) values ('a5000000-0000-0000-0000-000000000005');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a5000000-0000-0000-0000-000000000005','user','C5 같은초 도난+분할차감', 350000, 150000, 500000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a5000000-0000-0000-0000-0000000000a1','a5000000-0000-0000-0000-000000000005','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('a5000000-0000-0000-0000-0000000000a2','a5000000-0000-0000-0000-000000000005','general',   'general_charge',    200000, 700000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
-- bypass 2026-09-10 10:00:00.050: update profiles set membership_deposit_balance = membership_deposit_balance - 100000 (no ledger row)
('a5000000-0000-0000-0000-0000000000a3','a5000000-0000-0000-0000-000000000005','membership','ticket_purchase',   -50000, 550000,'티켓 구매 mem','2026-09-10 10:00:00.100+09'),
('a5000000-0000-0000-0000-0000000000a4','a5000000-0000-0000-0000-000000000005','general',   'ticket_purchase',   -30000, 520000,'티켓 구매 gen','2026-09-10 10:00:00.200+09'),
('a5000000-0000-0000-0000-0000000000a5','a5000000-0000-0000-0000-000000000005','general',   'ticket_purchase',   -20000, 500000,'티켓 구매','2026-09-18 10:00:00+09');
