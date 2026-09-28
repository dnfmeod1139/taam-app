-- CASE 1: theft from mem whose amount equals the gen pocket's ledger balance (300,000)
-- ledger: mem +900,000 (09-01), gen +300,000 (09-02); bypass 09-10 mem -300,000 (no row); RPC 09-15 mem -100,000 bal_after=total
insert into auth.users(id) values ('a1000000-0000-0000-0000-000000000001');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a1000000-0000-0000-0000-000000000001','user','C1 타주머니액 도난', 500000, 300000, 800000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a1000000-0000-0000-0000-0000000000a1','a1000000-0000-0000-0000-000000000001','membership','membership_charge', 900000,  900000,'연회비 예치금','2026-09-01 10:00:00+09'),
('a1000000-0000-0000-0000-0000000000a2','a1000000-0000-0000-0000-000000000001','general',   'general_charge',    300000, 1200000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
-- bypass 2026-09-10: update profiles set membership_deposit_balance = membership_deposit_balance - 300000  (no ledger row)
('a1000000-0000-0000-0000-0000000000a3','a1000000-0000-0000-0000-000000000001','membership','ticket_purchase',  -100000,  800000,'티켓 구매','2026-09-15 10:00:00+09');
