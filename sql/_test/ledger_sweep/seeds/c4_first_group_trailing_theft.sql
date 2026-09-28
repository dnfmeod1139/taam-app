-- CASE 4: invite payment split written in one second (mem +900,000 / gen +100,000), then trailing theft gen -100,000 (== second row amount), no later rows
insert into auth.users(id) values ('a4000000-0000-0000-0000-000000000004');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('a4000000-0000-0000-0000-000000000004','user','C4 분할결제 후 도난', 900000, 0, 900000, '2026-09-03 08:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('a4000000-0000-0000-0000-0000000000a1','a4000000-0000-0000-0000-000000000004','membership','membership_charge', 900000,  900000,'초대 결제 mem','2026-09-03 09:00:00.100+09'),
('a4000000-0000-0000-0000-0000000000a2','a4000000-0000-0000-0000-000000000004','general',   'general_charge',    100000, 1000000,'초대 결제 gen','2026-09-03 09:00:00.200+09');
-- bypass 2026-09-12: update profiles set general_deposit_balance = general_deposit_balance - 100000 (no ledger row, nothing after)
