-- ═══════════════════════════════════════════════════════════════════════════════
-- adv4 (2026-09-28 밤) — 병합본 v4_0.sql 의 이음새를 노린 3차 공격 시드
--   R1~R3 = 진짜 우회 (D ❌ 또는 ⚠ 판정 불가, 또는 E2 ❌쌍+상쇄 가 나와야 한다)
--   BN1~BN3 = 착시 (❌ 가 한 줄도 없어야 한다)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── R1 · J3-P 이음새: 두 주머니 기준선(mem 100000 · gen 50000) · 전부 총액 기록.
--    gen 에서 −600000 도난(= 그 순간 mem 잔액 600000) → 다음 gen 총액줄에서 balance_after − pocket_end(gen) = 50000
--    = 저장_gen − 원장_gen (뒤에 같은 주머니로 +600000 되돌려서 등식이 유지됨) → pocketed 통과 → 되돌림 줄은 keep.
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000e1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000e1','user','R1 J3-P상쇄 gen도난=mem잔액 후 반환', 600000, 230000, 830000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000e1a1','ad400000-0000-0000-0000-0000000000e1','membership','membership_charge', 500000, 650000,'연회비 (총액, 기준선 mem100000+gen50000)','2026-09-01 10:00:00+09'),
('ad400000-0000-0000-0000-00000000e1a2','ad400000-0000-0000-0000-0000000000e1','general',   'general_charge',    200000, 850000,'충전 (총액)','2026-09-02 10:00:00+09'),
-- bypass 09-04: general_deposit_balance -= 600000  (no ledger row; 600000 == live mem balance)
('ad400000-0000-0000-0000-00000000e1a3','ad400000-0000-0000-0000-0000000000e1','general',   'ticket_purchase',   -10000, 240000,'구매 (총액)','2026-09-05 10:00:00+09'),
-- bypass 09-07: general_deposit_balance += 600000  (money put back, no ledger row)
('ad400000-0000-0000-0000-00000000e1a4','ad400000-0000-0000-0000-0000000000e1','general',   'ticket_purchase',   -10000, 830000,'구매 (총액)','2026-09-08 10:00:00+09');

-- ── R2 · 「기준선?」 드러남 직후 도난: mem 기준선 100000. gen(미접촉)에 +60000 mint → gen 첫 총액줄이 latebase 「기준선?」 +60000.
--    그 직후 mem 에서 −60000 도난 → 다음 줄이 gen 주머니 기록(ba − pocket_end = 60000 = 저장_gen − 원장_gen) → pocketed 로 삼켜짐.
--    저장−원장 총차 = 100000 = first_off → D 세 번째 분기(정상) — 「기준선?」 +60000 이 총차에 반영되지 않았는데도 정상.
--    착시 쌍둥이 없음: 어떤 읽기로도 mem 기준선 40000 을 설명할 수 없다.
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000e2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000e2','user','R2 기준선?직후 mem도난 gen주머니줄 은폐', 540000, 45000, 585000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000e2a1','ad400000-0000-0000-0000-0000000000e2','membership','membership_charge', 500000, 600000,'연회비 (총액, mem 기준선 100000)','2026-09-01 10:00:00+09'),
-- bypass 09-03: general_deposit_balance += 60000  (gen never touched before)
('ad400000-0000-0000-0000-00000000e2a2','ad400000-0000-0000-0000-0000000000e2','general',   'ticket_purchase',   -10000, 650000,'구매 gen (총액, gen 첫 등장)','2026-09-04 10:00:00+09'),
-- bypass 09-05: membership_deposit_balance -= 60000  (theft right after the reveal)
('ad400000-0000-0000-0000-00000000e2a3','ad400000-0000-0000-0000-0000000000e2','general',   'ticket_purchase',    -5000,  45000,'구매 gen (주머니 기록)','2026-09-06 10:00:00+09');

-- ── R3 · RPC 3-entry 묶음 안 교차 주머니 이동: mem 기준선 20000, 전부 총액 기록.
--    e1 과 e2 사이에서 mem −100000 / gen +100000 (총액 불변 → 사슬 그대로, keep).
--    저장_mem − 원장_mem = −80000 (음수 = 기준선으로 설명 불가) 인데 총차 20000 = first_off 라 D 는 정상.
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000e3');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000e3','user','R3 RPC3안 mem→gen 이동(mem 주머니 음수)', 360000, 270000, 630000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000e3a1','ad400000-0000-0000-0000-0000000000e3','membership','membership_charge', 500000, 520000,'연회비 (총액, mem 기준선 20000)','2026-09-01 10:00:00+09'),
('ad400000-0000-0000-0000-00000000e3a2','ad400000-0000-0000-0000-0000000000e3','general',   'general_charge',    200000, 720000,'충전 (총액)','2026-09-02 10:00:00+09'),
('ad400000-0000-0000-0000-00000000e3a3','ad400000-0000-0000-0000-0000000000e3','membership','ticket_purchase',   -50000, 670000,'RPC e1 mem (총액)','2026-09-10 10:00:00.100+09'),
-- bypass 10:00:00.150: membership_deposit_balance -= 100000 ; general_deposit_balance += 100000 (total unchanged)
('ad400000-0000-0000-0000-00000000e3a4','ad400000-0000-0000-0000-0000000000e3','general',   'ticket_purchase',   -30000, 640000,'RPC e2 gen (총액)','2026-09-10 10:00:00.200+09'),
('ad400000-0000-0000-0000-00000000e3a5','ad400000-0000-0000-0000-0000000000e3','membership','ticket_purchase',   -10000, 630000,'RPC e3 mem 대행비 (총액)','2026-09-10 10:00:00.300+09');

-- ── BN1 · 착시: I1 형 혼합 기록 RPC3(총·주·총) 인데 id 가 쓴 순서의 역순 + 두 주머니 기준선(mem 100000 · gen 50000).
--    J1-a 의 bad_gap 은 id 순으로 시작·끝 잔액을 읽는다 — uuid id 는 쓴 순서와 무관하므로 역순이면 bad_gap ≠ 0 → ❌묶음 오탐 예상.
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000b1');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000b1','user','BN1 I1형 혼합RPC3 역순id+양주머니기준선', 540000, 220000, 760000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000b1a1','ad400000-0000-0000-0000-0000000000b1','membership','membership_charge', 500000, 650000,'연회비 (총액, 기준선 150000)','2026-09-01 10:00:00+09'),
('ad400000-0000-0000-0000-00000000b1a2','ad400000-0000-0000-0000-0000000000b1','general',   'general_charge',    200000, 850000,'충전 (총액)','2026-09-02 10:00:00+09'),
-- written .100 / .200 / .300 but ids a5 > a4 > a3 (reversed)
('ad400000-0000-0000-0000-00000000b1a5','ad400000-0000-0000-0000-0000000000b1','membership','ticket_purchase',   -50000, 800000,'RPC e1 mem (총액)','2026-09-10 10:00:00.100+09'),
('ad400000-0000-0000-0000-00000000b1a4','ad400000-0000-0000-0000-0000000000b1','general',   'ticket_purchase',   -30000, 220000,'RPC e2 gen (주머니, gen 기준선 50000)','2026-09-10 10:00:00.200+09'),
('ad400000-0000-0000-0000-00000000b1a3','ad400000-0000-0000-0000-0000000000b1','membership','ticket_purchase',   -10000, 760000,'RPC e3 mem (총액)','2026-09-10 10:00:00.300+09');

-- ── BN2 · 착시: 전부 주머니 기록 + 두 주머니 기준선(mem 100000 · gen 50000) + 주머니 기록 RPC3(mem·gen·mem) 역순 id
--    + 역순 주머니 보정쌍(주머니 기록) + 뒤 gen 주머니 줄. 돈은 한 푼도 원장 밖으로 안 움직였다.
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000b2');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000b2','user','BN2 주머니기록RPC3 역순id+양기준선+역순보정쌍', 840000, 200000, 1040000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000b2a1','ad400000-0000-0000-0000-0000000000b2','membership','membership_charge', 900000, 1000000,'연회비 (mem 주머니, 기준선 100000)','2026-09-01 10:00:00+09'),
('ad400000-0000-0000-0000-00000000b2a2','ad400000-0000-0000-0000-0000000000b2','general',   'general_charge',    100000,  150000,'충전 (gen 주머니, 기준선 50000)','2026-09-02 10:00:00+09'),
-- RPC 3-entry, all pocket-recorded, written .100/.200/.300, ids a5 > a4 > a3 (reversed)
('ad400000-0000-0000-0000-00000000b2a5','ad400000-0000-0000-0000-0000000000b2','membership','ticket_purchase',   -50000,  950000,'RPC e1 mem (주머니)','2026-09-10 10:00:00.100+09'),
('ad400000-0000-0000-0000-00000000b2a4','ad400000-0000-0000-0000-0000000000b2','general',   'ticket_purchase',   -30000,  120000,'RPC e2 gen (주머니)','2026-09-10 10:00:00.200+09'),
('ad400000-0000-0000-0000-00000000b2a3','ad400000-0000-0000-0000-0000000000b2','membership','ticket_purchase',   -10000,  940000,'RPC e3 mem 대행비 (주머니)','2026-09-10 10:00:00.300+09'),
-- reversed pocket-fix pair (net 0), pocket-recorded: gen +100000 written first (.500) gets HIGHER id
('ad400000-0000-0000-0000-00000000b2a6','ad400000-0000-0000-0000-0000000000b2','membership','pocket_fix',      -100000,  840000,'주머니 보정 mem (주머니)','2026-09-14 09:00:00.600+09'),
('ad400000-0000-0000-0000-00000000b2a7','ad400000-0000-0000-0000-0000000000b2','general',   'pocket_fix',       100000,  220000,'주머니 보정 gen (주머니)','2026-09-14 09:00:00.500+09'),
('ad400000-0000-0000-0000-00000000b2a8','ad400000-0000-0000-0000-0000000000b2','general',   'ticket_purchase',   -20000,  200000,'구매 gen (주머니)','2026-09-18 10:00:00+09');

-- ── BN3 · 착시: mem 첫 줄 주머니 기록(mem 기준선 0 → 총액으로도 읽힘), 두 번째 mem 줄이 총액 기록이라 gen 기준선 100000 을
--    드러내는데 gen 은 아직 미접촉 → latebase 는 「같은 묶음 안의 첫 등장 주머니」만 보므로 못 잡고 ❌ 로 감 (예상).
--    A1(미접촉 주머니 mint→첫 총액행)과 데이터로 구분 불가 — A1 을 ⚠ 로 두는 규칙과 같은 판정이어야 한다.
insert into auth.users(id) values ('ad400000-0000-0000-0000-0000000000b3');
insert into public.profiles(id, role, display_name, membership_deposit_balance, general_deposit_balance, deposit_balance, created_at)
values ('ad400000-0000-0000-0000-0000000000b3','user','BN3 mem주머니첫줄+mem총액줄이 gen기준선 드러냄', 800000, 350000, 1150000, '2026-07-01 10:00:00+09');
insert into public.deposit_transactions(id,user_id,deposit_type,change_type,amount,balance_after,description,created_at) values
('ad400000-0000-0000-0000-00000000b3a1','ad400000-0000-0000-0000-0000000000b3','membership','membership_charge', 900000,  900000,'연회비 (mem 주머니, mem 기준선 0)','2026-09-01 10:00:00+09'),
('ad400000-0000-0000-0000-00000000b3a2','ad400000-0000-0000-0000-0000000000b3','membership','ticket_purchase',  -100000,  900000,'구매 mem (총액, gen 기준선 100000 포함)','2026-09-03 10:00:00+09'),
('ad400000-0000-0000-0000-00000000b3a3','ad400000-0000-0000-0000-0000000000b3','general',   'general_charge',    300000, 1200000,'충전 gen (총액, gen 첫 등장)','2026-09-05 10:00:00+09'),
('ad400000-0000-0000-0000-00000000b3a4','ad400000-0000-0000-0000-0000000000b3','general',   'ticket_purchase',   -50000, 1150000,'구매 gen (총액)','2026-09-08 10:00:00+09');
