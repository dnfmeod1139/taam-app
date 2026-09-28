-- (1) 유수봉
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-000000000001');
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
-- (2) Super Admin
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000002');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('bbbbbbbb-0000-0000-0000-000000000002','super_admin','Super Admin',0,11000,11000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,metadata,created_at) values
('b0000000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002','general','admin_grant',2000,2000,'테스트 일반 예치금 부여',null,'2026-08-10 10:00:00+09'),
('b0000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000002','general','ticket_purchase',-1000,0,'긴자 시노하라 카드결제 · 일반 예치금 차감','{"purchase_id":"P-20260815-SHINOHARA","source":"toss-confirm"}','2026-08-15 19:15:00+09'),
('b0000000-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000002','general','admin_grant',8000,8000,'테스트 일반 예치금 부여',null,'2026-08-18 10:00:00+09'),
('b0000000-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-000000000002','general','ticket_purchase',-1000,7000,'슈모쿠초 시미즈 티켓 1인 구매','{"purchase_id":"P-20260821-SHIMIZU"}','2026-08-21 11:58:00+09'),
('b0000000-0000-0000-0000-000000000005','bbbbbbbb-0000-0000-0000-000000000002','general','admin_grant',1000,8000,'테스트 일반 예치금 부여',null,'2026-08-21 13:00:00+09'),
('b0000000-0000-0000-0000-000000000006','bbbbbbbb-0000-0000-0000-000000000002','general','ticket_refund',1000,9000,'스시쇼 노무라 반환 완료(예치금) · 카드 ₩2,000','{"purchase_id":"P-20260819-NOMURA","card_refund":2000}','2026-08-21 15:11:00+09'),
('b0000000-0000-0000-0000-000000000007','bbbbbbbb-0000-0000-0000-000000000002','general','admin_grant',2000,11000,'테스트 일반 예치금 부여',null,'2026-08-25 10:00:00+09');
-- (2B) Super Admin B
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000003');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('bbbbbbbb-0000-0000-0000-000000000003','super_admin','Super Admin B (hint-literal)',0,11000,11000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,metadata,created_at) values
('b1000000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000003','general','admin_grant',10000,10000,'테스트 일반 예치금 부여',null,'2026-08-10 10:00:00+09'),
('b1000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000003','general','admin_grant',3000,13000,'테스트 일반 예치금 부여',null,'2026-08-12 10:00:00+09'),
('b1000000-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000003','general','ticket_purchase',-1000,0,'긴자 시노하라 카드결제 · 일반 예치금 차감','{"purchase_id":"P-20260815-SHINOHARA-B"}','2026-08-15 19:15:00+09'),
('b1000000-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-000000000003','general','ticket_purchase',-1000,7000,'슈모쿠초 시미즈 티켓 1인 구매','{"purchase_id":"P-20260821-SHIMIZU-B"}','2026-08-21 11:58:00+09'),
('b1000000-0000-0000-0000-000000000005','bbbbbbbb-0000-0000-0000-000000000003','general','ticket_refund',1000,9000,'스시쇼 노무라 반환 완료(예치금) · 카드 ₩2,000','{"purchase_id":"P-20260819-NOMURA-B"}','2026-08-21 15:11:00+09');
-- (2C) Super Admin C
insert into auth.users(id) values ('bbbbbbbb-0000-0000-0000-000000000004');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('bbbbbbbb-0000-0000-0000-000000000004','super_admin','Super Admin C (ba-consistent)',0,11000,11000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,metadata,created_at) values
('b2000000-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000004','general','admin_grant',10000,10000,'테스트 일반 예치금 부여',null,'2026-08-10 10:00:00+09'),
('b2000000-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000004','general','admin_grant',3000,13000,'테스트 일반 예치금 부여',null,'2026-08-12 10:00:00+09'),
('b2000000-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000004','general','ticket_purchase',-1000,12000,'긴자 시노하라 카드결제 · 일반 예치금 차감','{"purchase_id":"P-20260815-SHINOHARA-C"}','2026-08-15 19:15:00+09'),
('b2000000-0000-0000-0000-000000000004','bbbbbbbb-0000-0000-0000-000000000004','general','ticket_purchase',-1000,11000,'슈모쿠초 시미즈 티켓 1인 구매','{"purchase_id":"P-20260821-SHIMIZU-C"}','2026-08-21 11:58:00+09'),
('b2000000-0000-0000-0000-000000000005','bbbbbbbb-0000-0000-0000-000000000004','general','ticket_refund',1000,12000,'스시쇼 노무라 반환 완료(예치금) · 카드 ₩2,000','{"purchase_id":"P-20260819-NOMURA-C"}','2026-08-21 15:11:00+09');
-- (3) 김우종
insert into auth.users(id) values ('cccccccc-0000-0000-0000-000000000005');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('cccccccc-0000-0000-0000-000000000005','user','김우종',0,1001,1001);
-- (3B) 김우종 B
insert into auth.users(id) values ('cccccccc-0000-0000-0000-000000000015');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('cccccccc-0000-0000-0000-000000000015','user','김우종 B (양쪽 주머니)',1000,1001,2001);
-- (4a) 구자호
insert into auth.users(id) values ('dddddddd-0000-0000-0000-000000000006');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('dddddddd-0000-0000-0000-000000000006','user','구자호',0,1300000,1300000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('d0000000-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000006','membership','admin_grant',1000000,1000000,'멤버십 예치금 부여','2026-07-01 10:00:00+09'),
('d0000000-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-000000000006','general','admin_grant',500000,1500000,'일반 예치금 부여','2026-07-01 10:00:01+09'),
('d0000000-0000-0000-0000-000000000003','dddddddd-0000-0000-0000-000000000006','general','admin_grant',1000000,1500000,'예치금 주머니 보정 — 일반 → 멤버십','2026-08-28 09:06:00+09'),
('d0000000-0000-0000-0000-000000000004','dddddddd-0000-0000-0000-000000000006','membership','admin_deduct',-1000000,500000,'예치금 주머니 보정 — 일반 → 멤버십','2026-08-28 09:06:00+09'),
('d0000000-0000-0000-0000-000000000005','dddddddd-0000-0000-0000-000000000006','general','ticket_purchase',-200000,1300000,'티켓 구매','2026-09-01 12:00:00+09');
-- (4b) 김우
insert into auth.users(id) values ('dddddddd-0000-0000-0000-000000000007');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('dddddddd-0000-0000-0000-000000000007','user','김우',5000000,0,5000000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('d1000000-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000007','general','admin_grant',5866166,5866166,'일반 예치금 부여','2026-08-20 10:00:00+09'),
('d1000000-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-000000000007','membership','admin_grant',5866166,5866166,'예치금 주머니 보정 — 일반 → 멤버십','2026-08-28 09:06:00.700+09'),
('d1000000-0000-0000-0000-000000000003','dddddddd-0000-0000-0000-000000000007','general','admin_deduct',-5866166,5866166,'예치금 주머니 보정 — 일반 → 멤버십','2026-08-28 09:06:00.200+09'),
('d1000000-0000-0000-0000-000000000004','dddddddd-0000-0000-0000-000000000007','membership','ticket_purchase',-866166,5000000,'티켓 구매','2026-09-10 12:00:00+09');
-- (4c)+(5) 이형주
insert into auth.users(id) values ('dddddddd-0000-0000-0000-000000000008');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('dddddddd-0000-0000-0000-000000000008','user','이형주',9500008,1500000,11000008);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('d2000000-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000008','membership','admin_grant',5500004,5500004,'멤버십 예치금 부여','2026-05-20 10:00:00+09'),
('d2000000-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-000000000008','general','admin_grant',7300004,12800008,'일반 예치금 부여','2026-05-20 10:00:01+09'),
('d2000000-0000-0000-0000-000000000003','dddddddd-0000-0000-0000-000000000008','membership','ticket_purchase',-1800000,3700004,'티켓 구매 (주머니 기록)','2026-06-01 12:00:00+09'),
('d2000000-0000-0000-0000-000000000004','dddddddd-0000-0000-0000-000000000008','membership','ticket_refund',1800000,5500004,'티켓 환불 (주머니 기록)','2026-06-07 12:00:00+09'),
('d2000000-0000-0000-0000-000000000005','dddddddd-0000-0000-0000-000000000008','general','ticket_purchase',-300000,12500008,'티켓 구매 (총액 기록)','2026-07-10 12:00:00+09'),
('d2000000-0000-0000-0000-000000000006','dddddddd-0000-0000-0000-000000000008','membership','admin_grant',5500004,11000008,'예치금 주머니 보정 — 일반 → 멤버십','2026-08-28 09:06:00+09'),
('d2000000-0000-0000-0000-000000000007','dddddddd-0000-0000-0000-000000000008','general','admin_deduct',-5500004,1500000,'예치금 주머니 보정 — 일반 → 멤버십','2026-08-28 09:06:00+09'),
('d2000000-0000-0000-0000-000000000008','dddddddd-0000-0000-0000-000000000008','membership','ticket_purchase',-1500000,11000008,'티켓 구매 (총액 기록)','2026-09-05 12:00:00+09');
-- control 홍길동
insert into auth.users(id) values ('eeeeeeee-0000-0000-0000-000000000009');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance)
values ('eeeeeeee-0000-0000-0000-000000000009','user','홍길동',900000,100000,1000000);
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('e0000000-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-000000000009','membership','membership_charge',900000,900000,'연회비 예치금','2026-09-01 10:00:00+09'),
('e0000000-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-000000000009','general','general_charge',100000,1000000,'일반 예치금 충전','2026-09-01 10:00:00+09');
