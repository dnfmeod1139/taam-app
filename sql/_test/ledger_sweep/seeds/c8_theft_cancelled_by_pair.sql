-- CASE 8: theft gen -100,000, then in the same second a pocket-fix pair gen +100,000 / mem -100,000 (last ledger activity)
insert into auth.users(id) values ('a8000000-0000-0000-0000-000000000008');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a8000000-0000-0000-0000-000000000008','user','C8 도난 뒤 보정쌍', 400000, 100000, 500000, '2026-08-20 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a8000000-0000-0000-0000-0000000000a1','a8000000-0000-0000-0000-000000000008','membership','membership_charge', 500000, 500000,'연회비 예치금','2026-09-01 10:00:00+09'),
('a8000000-0000-0000-0000-0000000000a2','a8000000-0000-0000-0000-000000000008','general',   'general_charge',    100000, 600000,'일반 예치금 충전','2026-09-02 10:00:00+09'),
-- bypass 2026-09-10 09:00:00.100: general_deposit_balance -= 100000 (no ledger row) -> stored 500,000
('a8000000-0000-0000-0000-0000000000a3','a8000000-0000-0000-0000-000000000008','general',   'pocket_fix',        100000, 600000,'주머니 보정 gen','2026-09-10 09:00:00.500+09'),
('a8000000-0000-0000-0000-0000000000a4','a8000000-0000-0000-0000-000000000008','membership','pocket_fix',       -100000, 500000,'주머니 보정 mem','2026-09-10 09:00:00.600+09');
