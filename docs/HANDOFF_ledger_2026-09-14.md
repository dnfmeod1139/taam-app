# 인계 메모 — 원장 서버화 4단계 (2026-09-14)

사용량 한도로 세션이 끊길 수 있어 적는다. **코드는 전부 브랜치에 있다.**
없어지는 것은 대화 맥락뿐이라 그 맥락만 여기 둔다.

## 어디까지 왔나

| 곳 | 상태 |
|---|---|
| `main` | `8e4f324` — 빌드 `2026.09.14-g` (라이브 확인됨) |
| `claude/optimistic-bohr-gCBZ7` | main + 이번 4단계 (아래 4건) — **아직 main 에 안 올림** |
| 백업 | `backup/live-2026-09-14` = `1e91517` (오늘 아침 라이브 시점) |

## 이번에 만든 것 (전부 로컬 테스트 통과)

1. **SQL** `sql/ledger_close_member_insert.sql` — ✅ 라이브 적용됨 (7줄 ✅)
   - `taam_apply_deposit_delta` 에 service_role / postgres 호출 길 (슈퍼어드민과 같게)
   - 원장을 넘겼는데 잔액이 모자라면 `LEDGER_INSUFFICIENT` (조용한 clamp 폐지)
   - 반환값에 `prev_mem` / `prev_gen`
   - `deposit_transactions` INSERT 정책: 본인 → **슈퍼어드민만** (`deposit_tx_insert_server`)
   - 확인 표 7줄 전부 ✅ 여야 정상
2. **Edge** `toss-confirm` · `toss-billing-charge` — ✅ 재배포됨 (줄 수 510 · 462 일치)
   - `deductDeposit` / `refundDeposit` → RPC 호출. 환원은 뺀 주머니로(종전 전부 일반)
   - 순서: SQL 먼저. 반대면 예치금 섞은 카드 결제가 `deposit_short` 로 취소된다
3. **앱** `depositTransaction()` (멤버십 예치금 결제 이력) → RPC 원장으로. 빌드 `2026.09.14-h`
   - SQL 없이 배포해도 안전 (4인자 함수는 이미 라이브에 있다)
4. **테스트** `sql/_test/t_ledger_close.sh`(40건) · `fx_ledger_close.sql` · `t_ledger_mint.sh` 갱신

## 이어서 할 것 (순서대로)

1. 사용자에게 SQL 전문을 채팅에 붙이고 「실행 필요」 — 결과 표 ❌ 0 확인
2. Edge 2개 재배포 (저장소 파일 그대로 복사) — `DEPLOY_CHECKLIST.md` 맨 위 표
3. main 머지 → 빌드 `14-h` 시크릿창 확인
4. 검증: 예치금 일부 + 카드로 티켓 1건 → `deposit_transactions` 에
   `metadata.server_caller='service_role'` 차감 행 · `profiles.deposit_balance` 일치
5. ✅ 슈퍼어드민 `adminGrantDeposit` → RPC (빌드 `14-i`, `sql/admin_grant_via_rpc.sql` ✅ 적용 · 테스트1 부여 누적 3,510,000 으로 정정)
6. ✅ 앱의 옛 폴백 INSERT 8곳 제거 + 환불 0원 기록도 RPC (빌드 `14-j`) — 앱에 원장 INSERT 0줄
7. 알림 중복 조사 — **중복 없음**. 구매 1건 = 앱 `taam_notify_admins` 1회(예치금) 또는 Edge `notifyAdmins` 1회(카드).
   틈 하나: 카드 구매는 푸시만 가고 벨 이력이 없었다 → Edge 두 함수에 `notifications` INSERT 추가
   (⚠ 재배포 필요 · `DEPLOY_CHECKLIST.md` 2차)
8. 미감사 5개 영역 점검 (`docs/AUDIT_2026-09-14_unaudited5.md`) → `sql/audit5_hardening_2026-09-14.sql` ✅ 라이브 적용(9줄 ✅) · Edge 4개(sms-hook·partner-account·notify 2개) ✅ 재배포됨 · 2차 검증 후 notify-purchase 수정 — ⚠ 재배포 필요(⚠ 저녁에 verify-and-save-purchase 함수에 잘못 붙임 → 앱 호출 제거(14-k) · 그 함수는 대시보드에서 삭제)
9. low 묶음 — `sql/low_batch_2026-09-14.sql`(⚠ 실행 필요) · Edge 2개(toss-billing-issue·taam-sms-hook ⚠ 재배포) · 앱 14-o(카드등록 nonce · billing_key 원문 안 읽음 · 오류신고 sid)
   - 다음: billing_keys 컬럼 grant(앱 14-o 배포 확인 뒤 SQL) · 오류 원문 응답 10곳 · CORS 오리진 제한 · CSP Report-Only
10. 그 다음 후보 (아직 안 함)
   - 초대제 서버화(가입은 consume-invite 가 service_role 로 사용자 생성 · 대시보드 signup OFF)
   - ✅ taam-format 소스 회수 + 이스케이프(14-l) · 저장소 밖 함수 3개(portone-webhook·save-billing-key·verify-identity-and-auth) 삭제 · partner-account·lineage-summarize Verify JWT ON
   - vercel.json CSP(script-src) Report-Only 도입 + cdnjs SRI
   - 회원 세션 `deposit_transactions` SELECT 는 그대로 (자기 것만) — 건드릴 것 없음

## 넘어가지 말 것

- 잔액은 `profiles` 직접 update 금지. `_depApplyDelta` 에 **델타 + entries**.
- 회원 세션의 `deposit_transactions` INSERT 는 이제 RLS 에 막힌다 — 새로 쓰지 말 것.
- SQL 은 저장소에 두는 것 ≠ 적용. 채팅에 전문, 확인 쿼리는 하나.
- 검증은 시크릿 창 전부 닫고 새로 하나만.
