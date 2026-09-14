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
   - ✅ `sql/billing_keys_columns.sql` 적용(3줄 ✅) · ✅ Edge 10개 재배포됨(오류 원문 비노출 + CORS 오리진 제한) · 남은 것: CSP Report-Only, 나머지 10개 함수 CORS
10. 그 다음 후보 (아직 안 함)
   - 초대제 서버화(가입은 consume-invite 가 service_role 로 사용자 생성 · 대시보드 signup OFF)
   - ✅ taam-format 소스 회수 + 이스케이프(14-l) · 저장소 밖 함수 3개(portone-webhook·save-billing-key·verify-identity-and-auth) 삭제 · partner-account·lineage-summarize Verify JWT ON
   - vercel.json CSP(script-src) Report-Only 도입 + cdnjs SRI
   - 회원 세션 `deposit_transactions` SELECT 는 그대로 (자기 것만) — 건드릴 것 없음

## 2026-09-14 종료 시점 라이브 상태

- 앱 `2026.09.14-o` · SQL 6파일 적용(ledger_close · admin_grant_via_rpc · audit5_hardening · low_batch · billing_keys_columns 등) · Edge 재배포 총 17회
- 남은 high: **초대제 서버화 1건** (내일 별도 세션) — 설계: 가입은 verify-invite(welcome)가 service_role 로 createUser · 슈퍼어드민 화이트리스트도 서버 · 소셜 첫 로그인은 초대 대조 후 허용 · 대시보드 signup OFF 는 앱·Edge 배포 뒤 마지막에
- 내일 아침 확인: `net._http_response` 200 두 줄(10시·11시) · 「오늘 오류」 boot_slow 신규 0

## 밤에 더 한 것 (사용량 35% 남은 시점)

- ✅ 등급 판정 두 갈래 통일(빌드 `14-p`) — `getCurrentUserGrade` 가 프로필 기반 값을 먼저 본다. 회원에게 `memberDB` 가 비어 있어 M 회원이 M 우선 공개 구간 상세 입구에서 막히던 것(CLAUDE.md 「재현 미확인」 → 코드로 확인·수정)
- ⚠ `sql/_test/tiershot.js` 에 **내 변경 전부터** 실패 2건(팝업 문구 「33인 · 심사제」 · 「M 등급」 검사). 09-13 「단일 등급」 문구 변경 뒤 갱신이 안 된 옛 기대값으로 보임 — 다음에 테스트 기대값을 현재 문구에 맞출 것
- 안 한 것: 나머지 10개 함수 CORS · CSP Report-Only · 서버 생성 알림 EN/JA · 환율 재개 준비(확정 정가 강제, ≈ 제거)

## 넘어가지 말 것

- 잔액은 `profiles` 직접 update 금지. `_depApplyDelta` 에 **델타 + entries**.
- 회원 세션의 `deposit_transactions` INSERT 는 이제 RLS 에 막힌다 — 새로 쓰지 말 것.
- SQL 은 저장소에 두는 것 ≠ 적용. 채팅에 전문, 확인 쿼리는 하나.
- 검증은 시크릿 창 전부 닫고 새로 하나만.
