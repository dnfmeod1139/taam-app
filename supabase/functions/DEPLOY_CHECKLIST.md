# 2026-09-14 밤 · low 마무리 — Edge 10개 재배포 (오류 원문 비노출 + CORS 오리진 제한)

SQL 과 순서 무관. 열 함수 모두 같은 두 가지가 바뀌었다.
- 바깥 catch 가 예외 원문(DB 컬럼·제약·함수 이름, 내부 URL) 대신 고정 문구를 돌려준다. 원문은 함수 로그에만.
- 응답의 `Access-Control-Allow-Origin` 이 `*` 대신 우리 오리진(`taam-app.vercel.app` · `playtaam.com` · `www.playtaam.com` · localhost)만.
  구조: 기존 본문을 `handle(req)` 로 감싸고 `serve()` 가 헤더를 덧씌운다 — 호출부는 그대로다.

| 함수 | 줄 수 | 비고 |
|---|---|---|
| consume-invite | 154 | |
| verify-invite | 244 | |
| lineage-summarize | 545 | |
| notify-reservation | 327 | |
| taam-translate-venues-batch | 349 | |
| send-push | 969 | 내부 호출(다른 Edge → send-push)은 Origin 없음 → 영향 없음 |
| toss-order | 393 | `detail` 제거 — 앱은 `error` 코드만 읽는다 |
| toss-confirm | 546 | 〃 |
| toss-billing-charge | 498 | 〃 |
| kashikiri-confirm | 221 | `message` 를 고정 문구로 (pay 페이지가 그대로 보여준다) |

아직 `*` 인 함수(재배포 안 함): notify-purchase · notify-guest-expiry · notify-visit-reminder · partner-account · taam-chat · taam-format · taam-translate · toss-billing-issue · taam-sms-hook · line-webhook. 다음 수정 때 같이.

---

# 2026-09-14 저녁 · low 묶음 — Edge 2개 재배포

`sql/low_batch_2026-09-14.sql` 과 순서 무관. 앱 빌드 `14-o` 와도 무관(각자 독립).

| 함수 | 바뀐 것 | 줄 수 |
|---|---|---|
| toss-billing-issue | 회원당 시간당 10회(`taam_rate_hit`, 없으면 통과) · DB/예외 원문을 응답에 안 실음 | 174 |
| taam-sms-hook | 회원 화면에는 고정 문구 + 코드(`SMS_4xx`)만. 설정 상태·Solapi 사유는 로그에만. 「국내 번호만」 안내는 유지 | 249 |

---

# 2026-09-14 미감사 영역 점검 — Edge Function 재배포 4개

`sql/audit5_hardening_2026-09-14.sql` 을 **먼저** 돌린 뒤(② `taam_kill_sessions` 가 있어야 partner-account 가 세션을 끊는다) 아래 넷을 재배포한다.

| 함수 | 바뀐 것 | 배포 전 확인 |
|---|---|---|
| taam-sms-hook | 목적지를 `sms_type` 으로 고정(phone_change 일 때만 새 번호) · **국내 휴대폰 번호만** 발송 · 로그 마스킹 강화 | 라이브에 `phone_change` 가 남은 회원이 있으면 정리: `select id from auth.users where coalesce(phone_change,'')<>''` |
| partner-account | reset·revoke 가 실제로 세션을 끊는다(`taam_kill_sessions`) · revoke 는 계정 잠금(ban) · restore 는 잠금 해제 · 단계별 오류 확인 · reset 이 해지를 되돌리지 않음 | SQL ② ✅ |
| notify-visit-reminder | **service_role 호출자만** 받는다 · DB 오류 원문을 응답에 안 싣는다 | ⚠ cron 이 보내는 Authorization 이 **service_role legacy JWT** 여야 한다. anon 키면 403 이 난다 — 다음 실행 뒤 `net._http_response` 에서 200 확인 |
| notify-guest-expiry | 〃 | 〃 |
| ⚠ verify-and-save-purchase | **삭제할 것.** 2026-04 대시보드 전용 함수(purchases 표 저장). 09-14 저녁 notify-purchase 코드를 이 함수에 잘못 붙여 배포하면서 옛 소스가 덮였다(복구 불가 · 저장소에 없었음). 앱은 빌드 14-k 부터 부르지 않는다 → 대시보드에서 함수 삭제 | — |
| taam-format | 소스를 저장소로 회수(`supabase/functions/taam-format/index.ts`). role `super_admin` 도 허용 · 회원당 30회/시간 · 예외 원문 비노출. 앱(14-l)은 응답 문자열을 전부 이스케이프해 그린다 | — |
| notify-purchase | **자기 구매만**(회원 JWT → uid 대조, service_role 은 통과) · 중복 방지를 「먼저 찍고 조건부」로(동시 호출 N 번 → 1 번) · 오류 원문 비노출. 2차 검증(critic)이 찾음 | — (SQL 없음) |

---

# 2026-09-14 원장 서버화 4단계 — Edge Function 재배포 2개

`sql/ledger_close_member_insert.sql` 을 **먼저** SQL Editor 에서 돌린 뒤 아래 둘을 재배포한다.
SQL 없이 배포하면 RPC 가 「로그인이 필요합니다」로 거부해 **예치금을 섞은 카드 결제가
deposit_short 로 취소된다**(돈은 안 샌다 — 카드 승인이 취소되고 좌석은 홀드로 남는다).
그러니 순서를 지킨다. 반대로 SQL 만 돌리고 배포를 미루는 것은 안전하다.

| 함수 | 바뀐 것 | 배포 전 확인 |
|---|---|---|
| toss-confirm | `deductDeposit`/`refundDeposit` 가 profiles 직접 수정 대신 RPC `taam_apply_deposit_delta` 호출. 환원은 **뺀 주머니로**(종전 전부 일반) | SQL 확인 표 ⑤ `service_role 실행 권한` ✅ |
| toss-billing-charge | 〃 | 〃 |

**2차 (같은 날 오후, 선택)** — 카드 구매도 슈퍼어드민 **벨 이력**에 남긴다(`notifications` 행, 예치금 결제와 같은 모양).
종전엔 카드 구매는 푸시만 가고 벨을 열면 없었다. 두 함수 다시 복사해 Deploy. 줄 수 toss-confirm 528 · toss-billing-charge 480.

배포 뒤 확인: 예치금 일부 + 카드 부족분으로 티켓 1건 결제 → `deposit_transactions` 에
`metadata.server_caller = 'service_role'` 인 차감 행이 있고 `profiles.deposit_balance` 가 맞는지.

---

# 2026-09-13 감사 보강 — Edge Function 재배포 목록

`sql/audit_hardening_2026-09-13.sql` 을 **먼저** SQL Editor 에서 돌린 뒤, 아래 13개를
대시보드(Edge Functions → 함수 → 코드 붙여넣기 → Deploy)에서 다시 배포한다.
순서는 상관없다 — 어느 것도 SQL 이 없으면 통과(fail-open)하거나 종전대로 동작한다.

| 함수 | 바뀐 것 | 배포 전 확인 |
|---|---|---|
| toss-order | 홀드가 이 티켓의 홀드여야 함 | — |
| toss-confirm | 예치금 부족이면 확정 안 함(환원·카드 취소·`deposit_short`) | — |
| toss-billing-charge | 외화 주문 거부 · 예치금 부족 처리 | — |
| send-push | 회원 위로는 슈퍼어드민만 · 매장 어드민은 자기 손님만 · url 우리 경로만 | — |
| notify-reservation | 자기 예약만 · `notified_at` 1회 | SQL ⑩ (컬럼) |
| notify-purchase | 실제 발송 건수로 성공 판정 | — |
| lineage-summarize | 슈퍼어드민만 · 공개 http(s) 만 | — |
| verify-invite | IP 시간당 40회 | SQL 0 (`taam_rate_hit`) |
| consume-invite | 로그인 필수 · 초대받은 번호/이메일 대조 · 시간당 10회 | 〃 |
| taam-chat | 회원당 시간당 60회 | 〃 |
| taam-translate | 어드민·슈퍼어드민·서버만 | — |
| taam-translate-venues-batch | 슈퍼어드민·서버만 | — |
| line-webhook | `LINE_CHANNEL_SECRET` 없으면 거부 | ⚠ Secrets 에 `LINE_CHANNEL_SECRET` 이 있는지 먼저 본다 (LINE 콘솔 Basic settings → Channel secret). 없으면 LINE ID 회신이 멈춘다 |

배포 뒤 확인: 회원 계정으로 티켓 하나 결제(예치금) · 예약 요청 1건(알림톡이 **한 번**만) ·
컨시어지 챗 1회 · 파트너 계정으로 예약 수락 푸시가 회원에게 가는지.

---

# 계보 챗 두뇌 — 배포 체크리스트

이번 작업으로 만들어진 것 → 운영 적용까지 순서대로.

## ① DB 마이그레이션 (Supabase Studio)

`supabase/migrations/0003_chef_lineage_knowledge.sql` 전체를 SQL Editor 에 붙여넣고 RUN.

검증:
```sql
SELECT lineage_kind, count(*) FROM public.chef_lineage_knowledge GROUP BY lineage_kind;
-- 기대: sushi=12

SELECT column_name FROM information_schema.columns
WHERE table_name='restaurants' AND column_name LIKE 'chef_lineage%';
-- 기대: chef_lineage_text, chef_lineage_id, chef_lineage_synced_at
```

## ② Edge Function 배포

프로젝트 루트(`supabase` 폴더가 있는 곳)에서:

```bash
# Supabase CLI 로그인 + 링크 (한 번만)
supabase login
supabase link --project-ref edfsmzbcixfnqabrsvut

# 새 함수 배포
supabase functions deploy lineage-summarize --no-verify-jwt

# 환경 변수 설정 (Anthropic API 키)
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```

> `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` 는 자동 주입되므로 별도 설정 불필요.

## ③ taam-chat 패치 적용

`supabase/functions/TAAM_CHAT_LINEAGE_PATCH.md` 참고. 변경 3곳:

1. `import { buildLineageSystemSection, getRestaurantLineageLine } from "../_shared/lineage-context.ts";`
2. 사용자 쿼리 → 시스템 프롬프트 빌드 직전:
   ```ts
   const lineageSection = await buildLineageSystemSection(userQuery, sb);
   ```
   (시스템 프롬프트에 합치되 cache_control 영역 **밖**)
3. 매장 컨텍스트 직렬화 함수에:
   ```ts
   const lineageLine = getRestaurantLineageLine(rest);
   if (lineageLine) parts.push(`[쉐프 계보] ${lineageLine}`);
   ```
   `restaurants` 쿼리에 `chef_lineage_text, chef_lineage_id` 추가.

재배포:
```bash
supabase functions deploy taam-chat
```

## ④ 동작 테스트

### (a) 인앱 학습

1. 슈퍼어드민으로 로그인 → ☰ → AI 컨시어지 → 🧬 계보 챗 두뇌 동기화
2. "스시 쇼 계보" 클릭 → 자료 URL 1~2개 입력 + 큐레이터 노트 작성
3. **[🤖 AI 정리]** → 본문이 자동 채워짐 (10~30초)
4. 본문 검수 후 **[발행]**
5. 목록에서 ✅ 발행됨 뱃지 확인

### (b) 매장 롤업

상단 **[📡 매장 롤업 동기화]** → 발행된 계보의 chef → 매장 일괄 업데이트.

### (c) 챗 검증

탐 채팅에서 "스시 쇼 계보 알려줘" → 발행된 full_text 가 답변에 반영되는지 확인.

일반 질문 ("강남 한우 추천") → 응답 시간/품질 변동 없는지 확인.

## ⑤ 알려진 제한 / 향후 개선 후보

- **현재**: 라멘 계보는 시드/UI 미포함 (`스시부터` 정책). 추후 `0004` 마이그레이션 + UI 추가 예정.
- **현재**: chefs.parent_id (스승 ↔ 제자) 데이터는 SVG 좌표로만 존재. AI 정리 시 큐레이터 노트로 보완.
- **개선**: 매장별 한줄 (`chef_lineage_text`) 을 더 풍부하게 만들고 싶으면, `syncAllRestaurantLineages` 의 line 생성 로직을 chef 단위 LLM 호출로 교체 가능.

## 파일 트리 (이번 작업분)

```
supabase/
├── migrations/
│   └── 0003_chef_lineage_knowledge.sql        ← DB 스키마
├── functions/
│   ├── DEPLOY_CHECKLIST.md                    ← (이 파일)
│   ├── TAAM_CHAT_LINEAGE_PATCH.md             ← taam-chat 통합 가이드
│   ├── _shared/
│   │   ├── cors.ts                            ← 공통 CORS
│   │   └── lineage-context.ts                 ← 키워드 감지 + 프롬프트 빌더
│   └── lineage-summarize/
│       ├── index.ts                           ← 신규 Edge Function
│       └── README.md                          ← 개별 함수 가이드

index.html
├── (line 22~)        window.SUPABASE_URL/ANON_KEY 노출
├── (line 6492~)      어드민 메뉴 항목 추가
├── (line 7748~)      서브스크린 + 편집 모달 HTML
└── (line 41460~)     계보 동기화 JS (목록/편집/저장/AI/매장롤업)
```
