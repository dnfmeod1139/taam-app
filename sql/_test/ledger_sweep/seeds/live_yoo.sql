\i /tmp/claude-0/-home-user-taam-app/9fccb989-15eb-5a7c-bc50-7176c2fe905c/scratchpad/pre.sql
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('aaaaaaaa-0000-0000-0000-000000000001','user','유수봉',100631,4424369,4525000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('00000000-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','membership','admin_grant',1825000,1825000,'멤버십 예치금 부여','2026-08-01 10:00:00+09'),
('00000000-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','general','admin_grant',400631,2225631,'일반 예치금 부여','2026-08-01 10:00:01+09'),
('00000000-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','membership','ticket_purchase',-1724369,100631,'티켓 구매','2026-08-29 17:28:00+09'),
('00000000-0000-0000-0000-000000000004','aaaaaaaa-0000-0000-0000-000000000001','general','admin_grant',1623738,2024369,'주머니 보정 부여','2026-08-29 17:28:00+09'),
('00000000-0000-0000-0000-000000000005','aaaaaaaa-0000-0000-0000-000000000001','general','admin_grant',3750000,5774369,'사이토 부여','2026-09-12 23:27:00+09'),
('00000000-0000-0000-0000-000000000006','aaaaaaaa-0000-0000-0000-000000000001','general','admin_deduct',-3750000,2024369,'사이토 차감','2026-09-12 23:29:00+09'),
('00000000-0000-0000-0000-000000000007','aaaaaaaa-0000-0000-0000-000000000001','general','admin_grant',2400000,4525000,'부여','2026-09-27 16:34:00+09');
