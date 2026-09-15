# 2026-09-14 밤 — 보안·기능·화면 전수 점검 (남은 사용량 활용)

세 갈래(보안 / 기능 / 화면 구조)로 훑었다. **이미 닫힌 것은 뺐고**, 점검기가 옛 파일을 보고 낸
오탐(멤버십 등급 가드의 phone 신뢰 → audit5 ⑦ 로 이미 닫힘 · `taam_ref_consume` anon → 09-13 ⑨ 로 회수됨)도 뺐다.

## 이번에 고친 것

| # | 무엇 | 어디 | 상태 |
|---|---|---|---|
| S-1 ⭐ | **환불액을 앱이 정했다.** 서버는 「낸 돈 − 이미 환불」만 봐서, 앱을 고친 회원이 D-5 티켓을 전액·대행비까지 환불받을 수 있었다 → `taam_refund_cap` (30분 전액 · D-31 이상 대행비 제외 · D-30 이하 0) 을 `taam_apply_deposit_delta` ④ 에 덧댐. 슈퍼어드민 예외는 그대로 | `sql/refund_policy_server.sql` (테스트 `t_refund_policy.sh` 24건 + ledger_close 52건 회귀) | **실행 필요** |
| S-2 | 회원이 쓴 예약 메모가 어드민 예약 목록 innerHTML 에 그대로 → 저장형 XSS (회원→어드민) | index.html `_raEsc(r.member_memo)` | 빌드 r |
| S-3 | 환불불가 사유 팝업 · 예치금 내역 환불 사유 · 회원관리 메모 textarea 이스케이프 누락 | index.html | 빌드 r |
| S-4 | 네이티브 푸시 탭 시 payload 의 url 을 그대로 `location.href` → 같은 출처 http(s) 경로만 | index.html `pushNotificationActionPerformed` | 빌드 r |
| F-1 | 홀드 전환이 `PRICE_CHANGED`/`INSUFFICIENT_DEPOSIT`/`HOLD_GONE` 으로 멈췄는데 「결제는 완료됐습니다」라고 말했다 → 「결제가 진행되지 않았습니다」+ 사유별 안내 | index.html `completePurchase` | 빌드 r |
| F-2 | D-31 경계: 앱은 「방문일 0시 − 지금」이라 D-31 당일 아침이 30.6일로 계산돼 환불이 막혔다 → 달력 날짜 차(서버와 동일) | `calculateTicketRefund` | 빌드 r |
| F-3 | `_tossConfirmPayment` 가 세션 없이 나가면 `_tossConfirmRunning` 이 영영 true → 뷰포트 가드 정지 | index.html | 빌드 r |
| F-4 | 옛 방문일 `'YYYY.MM.DD'` 를 `new Date()` 로 파싱 (iOS Invalid Date → 영원히 「방문예정」) → `_dParseDate` | index.html 구매내역 상태 | 빌드 r |
| F-5 | `sale_open_at` 에 공백 구분 값이 오면 Invalid Date → 티켓 영구 비공개·재구매 잠금 → `' '→'T'` | `_repSaleOpenedAt` · `_tkSaleHidden` | 빌드 r |
| U-1 | GNB 라벨 8.4px·투명도 .4 (대비 3.2:1) → 9.5px·.6 · 아이콘 .6 | CSS `.gnb-label` | 빌드 r |
| U-2 | 키보드 포커스 표시(`:focus-visible`) · `prefers-reduced-motion` 전역 | CSS | 빌드 r |

## 남은 것 — 우선순위 순 (다음 세션에서)

### 보안 (앱·서버)
1. ~~슈퍼어드민 Supabase 비밀번호가 `localStorage.taamSaPw` 에 평문~~ → **빌드 `t` 에서 제거.** `superadminSupabaseLogin` 은 세션 유무만 보고, 세션이 없으면 OTP 로그인을 안내한다. 부팅 때 기기의 `taamSaPw` 를 지운다. `_getSaCred` 삭제.
2. ~~옛 카드 등록 화면이 카드번호·CVC 를 기기에 평문 저장~~ → **빌드 `s` 에서 제거.** 화면·모달·JS 를 지웠고 부팅 때 `excCards` 를 지운다. 결제 수단 진입은 전부 `openCardManagePage()`(토스 빌링키).
3. `profiles.select('*')` 6곳이 `billing_key` 까지 내린다 — **보류**: 자동갱신(`auto_renew`)이 아직 `profiles.billing_key` 를 쓴다. billing_keys 표로 옮긴 뒤에 컬럼 권한을 건다.
4. ~~매장·티켓 이름이 innerHTML 에 그대로~~ → **빌드 `u` 에서 12곳 `_raEsc()`** (구매 확인 팝업 · 회원 티켓 목록 · 파트너 티켓 목록·캘린더 · 승인 대기 · 연장 팝업 · 매장 검색/선택 카드 · 티켓 연결 안내 · 일정 매장 선택 · 미반환 예치금 점검 · 감사 화면). 계보도 핀의 이름 첫 글자(`charAt(0)`)만 남김 — 한 글자라 태그가 못 된다.
5. ~~주소 API 결과~~ → **빌드 `15-a`** 에서 이스케이프. 월 커버·캐러셀 자리는 확인 결과 앱 상수(비용 표)라 위험 없음.
6. ~~역할 판정을 앱이 PIN 으로 올린다~~ → **빌드 `15-a`**: PIN 통과 뒤 `_taam_uid_role()` 로 서버 역할을 확인, super_admin 이 아니면 열지 않는다.
7. `notifications` INSERT 본인 허용 — **보류**: 회원이 초대·시간변경 알림을 상대에게 직접 INSERT 하는 동선이 8곳. RPC 로 옮기는 작업이라 별도 세션에서.
8. `tcalCancelLinkedRow` 등 2곳 — **보류**: 어드민 캘린더 화면(회원 UI 아님)이고 행 트리거·RLS 가 이미 지킨다.
9. ~~Edge 8개 CORS `*` · POST 가드 · `req.json()` 미보호 · 로그 PII · 원문 오류~~ → **2026-09-15 코드 반영** (toss-billing-issue · partner-account · notify-purchase · notify-guest-expiry · notify-visit-reminder · taam-chat · taam-format · taam-translate 에 출처 허용목록 + 405 · json().catch 5곳 · Kakao/send-push 로그 수신자 마스킹 · consume-invite 고정 문구). 배포는 `supabase.yml` 이 시크릿 등록 뒤 자동. partner-account 의 원문 오류는 슈퍼어드민 전용 도구라 그대로.
10. `GOOGLE_GEOCODE_KEY` 공개 파일 포함 — GCP 콘솔에서 HTTP referrer 제한 확인.
11. `partner_logos` · `user_ticket_waitlist` · `partner_qr_codes` — 저장소에 정책 없음. 라이브 `pg_policies` 확인.

### 기능
12. **카드 승인 재시도 없음** — 사용자 지시로 나중에.
13. ~~전환 실패 시 잔액·완료 팝업 먼저~~ → **빌드 `15-a`**: 전환 프로미스를 먼저 기다리고, 실패면 로컬 잔액 복원 후 종료. 「결제 완료」 문구도 「확정되지 않았습니다·예치금은 빠지지 않았습니다」로.
14. ~~정원 확인 early return 4곳~~ → **빌드 `15-a`**: 각 return 앞에 `_tkReleaseSeatHold()`.
15. ~~결제 버튼 이중 탭~~ → **빌드 `15-a`**: `completePurchase` in-flight 가드(`_tdPayBusy`) · `#tdPayBtn` 홀드 확보 중 disabled.
16. 취소 `confirm()` 이 한국어 고정 → EN/JA 회원이 돈 결정을 한국어로. DOM 모달 + `t()`.
17. 서버 알림(`taam_visit_reminder_notify` · `taam_guest_expiry_notify` · `taam_notify_repurchase_released` · `taam_expire_invite_holds`) 한국어 단일 → `notifications` 에 `_en/_ja` 컬럼 + 렌더 `pickI18nObj`.
18. ~~원장 실패 console 만~~ → **빌드 `15-a`**: 회원 토스트 + `ledger_apply_failed` 어드민 통지.
19. ~~`_tkCapacityAutoRefund` 조회 실패~~ → **빌드 `15-a`**: 조회 실패면 환불 판단을 멈추고 `capacity_refund_unknown` 어드민 통지.
20. tiershot.js 2건은 로케일 문제(헤드리스 = en-US → TX 가 'M 등급'→'M Tier'). 테스트에서 `_tkCurrentLang='ko'` 고정.

### 화면
21. **viewport 에 `viewport-fit=cover` 없음** → `env(safe-area-inset-*)` 43곳이 전부 0. iOS PWA 에서 하단 바가 홈 인디케이터 밑. 추가하면 43곳이 한꺼번에 움직이므로 **실기기(노치·SE) 확인 후** 적용. `user-scalable=no` 도 제거.
22. 상단 여백이 화면마다 36/52/54/56px 하드코딩 → `--sat` 토큰 하나로.
23. `.ticket-modal` z-index 2147483000 !important → 토스트·오프라인 배지가 밑에 깔림. ~9750 으로.
24. 홈 첫 렌더: 커버 로딩 중엔 메뉴·언어·벨·FAB 까지 비어 검은 화면 → 사진만 기다리게.
25. 마이페이지 8px/7px 라벨(462 규칙 <12px) → 10px 바닥. 스테퍼·pax 버튼 28px 등 탭 영역 44px.
26. 1024px 에서 캘린더 max-width 없음 · 월 스트립 좌측 잘림 · 티켓 상세 사진 없을 때 검은 300px 블록 · 3번째 탭 말줄임.
27. 어드민 모달 10개 `data-lang-lock="ko"` 누락(혼합 번역) · aria-label 한국어 6곳 · 아이콘 버튼 27개 aria-label 없음 · 약관 중복 id.
28. `theme-color` 가 다크 고정인데 마이페이지·상세는 라이트 → 화면 열 때 갱신 · `color-scheme`.
29. 도달 불가 `#ticketView` 제거.
