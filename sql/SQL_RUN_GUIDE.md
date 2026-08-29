# TAAM — SQL 실행 가이드 (Supabase SQL Editor)

⚠️ **이미 실행한 SQL은 다시 돌리지 마세요.** 아래는 "안 돌린 것"을 골라 순서대로 실행하기 위한 분류입니다.
실행 위치: Supabase 대시보드 → SQL Editor → 붙여넣기 → Run.

## 1️⃣ 스키마 / 컬럼 (가장 먼저 — 테이블·컬럼이 있어야 정책·데이터가 동작)
- profiles_balance_columns.sql        (예치금 잔액 컬럼: membership/general)
- push_subscriptions_schema.sql       (웹푸시 구독 테이블)
- i18n_columns.sql / lineage_i18n_columns.sql / venues_i18n_columns.sql   (다국어 컬럼)
- user_cards_corporate.sql            (법인카드 관련)
- invite_codes_dedupe_constraint.sql  (초대코드 중복 방지 제약)

## 2️⃣ 정책 / 권한 / RPC
- admin_deposit_grant_policies.sql    (슈퍼어드민 예치금 부여 정책)
- set_super_admin_dnfmeod.sql         (본인 계정 슈퍼어드민 지정)
- tickets_admin_rls.sql               (★ 레스토랑 어드민이 자기 매장 구매 조회 — 캘린더용)
   └ 실행 후, restaurant_admins 에 매핑 INSERT 필요 (파일 하단 주석 참고)
- (기존) ticket_access_lists.sql / ticket_access_helpers.sql
- (기존) invite_codes_*_rpc.sql / notifications.sql / reservation_invites*.sql / active_sessions.sql

## 3️⃣ 데이터 보정 (필요할 때만 — 이미 돌렸을 가능성 높음)
- deposit_split_granted_charged.sql / deposit_transactions_check_fix.sql
- restore_missing_ticket_transactions.sql / sync_profiles_email_phone_from_auth.sql
- taam_verified_insert.sql / chefs_geometry_sync.sql
- fix_*.sql / restore_*.sql / delete_*.sql  (특정 매장·회원 핀포인트 수정 — 대상 확인 후)

## 4️⃣ 진단용 (읽기 전용 — 안 돌려도 됨, 상태 점검할 때만)
- diag_*.sql
- _health_check.sql        (전체 상태 한눈에 — 건수가 나오면 아래 두 개로 파고든다)
- _repair_preview.sql      (좌석 미연결 초대 · 예치금 주머니 — 고치기 전에 무엇을 손대는지)
- _invite_seat_audit.sql   (초대 ↔ 좌석 전수 점검 — 취소·회수·결제 후 좌석이 규칙대로인지)
- _push_reachability.sql   (푸시를 받을 수 있는 회원 / 못 받는 회원 + 그 이유)
- _tier_mismatch_repair.sql (초대 등급이 프로필에 반영 안 된 회원 — 찾기 + 고칠 문장 생성)

> ⚠️ `_` 로 시작하는 셋은 **아무것도 바꾸지 않는다.** 돈·좌석을 손대기 전에 항상 먼저 돌린다.
> 실제로 이 습관이 예치금 보정을 두 번 적용할 뻔한 사고를 막았다.

---
## DB 마이그레이션 (supabase/migrations/) — 참고
0001~0003 은 보통 Supabase CLI(`supabase db push`)로 적용합니다.
이미 적용돼 있으면 건너뛰세요. SQL Editor로 수동 실행도 가능하나 중복 적용 주의.

## 실행 원칙
1) 스키마(1️⃣) → 정책(2️⃣) → 데이터(3️⃣) 순서
2) 한 파일씩 실행하고 에러 메시지 확인
3) "already exists" 류 에러 = 이미 적용된 것 (대부분 무해)
