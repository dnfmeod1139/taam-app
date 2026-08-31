# CLAUDE.md — TAAM 프로젝트 가이드

> 이 파일은 모든 Claude Code 세션 시작 시 자동 로드됩니다.
> TAAM 작업 시 아래 맥락·규칙을 기본 전제로 삼으세요.

## 프로젝트 개요
**TAAM(탐)** — 한국·일본 프리미엄 다이닝을 위한 **초대제 멤버십 컨시어지** 앱.
- 회원이 자연어로 묻고(AI 컨시어지 "탐"), 예약하기 어려운 레스토랑을 **예약 대행**으로 연결
- 셰프 계보도, 티켓(예약 대행 상품), 예치금(선결제) 모델
- 대상: 만 19세 이상, 초대 코드 보유 회원

## 기술 스택
| 영역 | 내용 |
|---|---|
| 프론트엔드 | **단일 `index.html`** PWA (약 4.7MB, 인라인 CSS/JS/데이터) + 서비스워커 `sw.js` |
| 네이티브 | Capacitor 8 (iOS/Android), `capacitor.config.json` |
| 백엔드 | **Supabase** (Postgres + Auth + Edge Functions) — 프로젝트 ref `edfsmzbcixfnqabrsvut` |
| 서버리스 | `supabase/functions/` = Edge Functions (Vercel `api/` 함수는 2026-08 미사용 확인 후 삭제) |
| 결제 | **PortOne(포트원) V2**, 원화(KRW), 카드·계좌이체 |
| AI | Anthropic Claude (컨시어지 챗 `taam-chat`, 번역 `taam-translate`) |
| 배포 | Vercel(웹, `taam-app.vercel.app`), Codemagic(iOS TestFlight) / 기본 브랜치 `main` |

## 디렉토리 구조
- `index.html` — **앱 본체**. 거의 모든 UI·로직·i18n이 여기 있음 (단일 파일)
- (삭제됨 2026-08) `api/` Vercel 함수 — 앱은 Supabase Edge Function 만 호출. 단 `taam-format` Edge Function 소스는 저장소에 없음(대시보드 배포) — 수정 시 대시보드에서 확인
- `supabase/functions/` — Edge Functions (taam-chat, send-push, consume-invite, verify-invite, lineage-summarize, taam-translate, taam-translate-venues-batch, _shared)
- `supabase/migrations/` — DB 마이그레이션 (0001~)
- `sql/` — **수동 실행용 SQL 스크립트** (스키마·정책·수정·진단). `SQL_RUN_GUIDE.md` 참고
- `venues/` — 큐레이션 지식베이스 (정적 JSON, venue당 1파일). `_index.json`/`_award_index.json` 인덱스
- `seed-data.json` — 초기 데이터 (약 21MB)
- `legal/`, `terms/` — 약관·정책 HTML
- `secrets/` (gitignore됨), 비밀키는 저장소에 두지 않음

## 핵심 도메인 개념
- **역할**: `superadmin`(전체) / `admin`(레스토랑 파트너, 자기 매장만) / `user`(회원)
- **멤버십**: M등급 / T등급. 연회비 = 이용료(10%) + 멤버십 예치금(90%)
- **티켓**: 본 가격 + 대행비. 예치금에서 차감, 부족 시 PG 결제로 보강
- **예치금**: 서비스 내 선결제 잔액. `membership_deposit_balance` / `general_deposit_balance`
- **다국어**: KO/EN/JA. `t(key)` / `applyI18n()` / `data-i18n*` 속성. `TRANSLATIONS` 전역
- 환불 정책: `legal/refund.html` (대행비 환불불가, D-31 기준 등) — 결제/취소 코드 수정 시 반드시 참고

## 단일 기기 로그인 규칙 — 깨뜨리지 말 것

**회원은 동시에 한 기기에서만 로그인이 유지된다. 가장 마지막 로그인이 이긴다.**

| 항목 | 내용 |
|---|---|
| 범위 | iOS·Android·웹 무관. 기기 종류·설치 방식과 상관없이 **1대만** |
| 승자 | **마지막으로 로그인한 기기**. 나머지는 즉시 강제 로그아웃 |
| 예외 | **슈퍼어드민만 면제** (운영상 다중 기기 필요) |

### 방어는 3겹이다 — 한 겹만 믿으면 뚫린다

| 겹 | 무엇 | 막는 것 | 한계 |
|---|---|---|---|
| **1. Realtime 즉시 로그아웃** | 새 기기 UPSERT → 이전 기기가 `postgres_changes` 받고 `signOut()` | 정상 사용자, 즉각적 UX | 이전 기기가 **협조해야** 성립 |
| **2. 소유권 워치독** | 화면 복귀·온라인 복귀·창 포커스·60초 주기로 `active_sessions` 재조회 | Realtime 끊김·백그라운드 스로틀·오프라인 | 여전히 클라이언트 코드 |
| **3. 서버측 세션 폐기** ⭐ | 로그인 직후 `signOut({ scope: 'others' })` 로 **다른 기기 refresh token 을 서버에서 무효화** | DevTools 무력화·토큰 복사·구독 차단 | access token 잔여 수명(기본 1h) 동안은 유효 |

3겹이 핵심이다. 1·2겹은 이전 기기가 스스로 나가주기를 기대하는 구조라, 스크립트를
막으면 그만이다. 3겹은 **협조 없이도** 이전 기기가 토큰 갱신에 실패해 죽는다.

구현: `active_sessions` 테이블(`user_id` PK) + `device_id`(localStorage) + Realtime.
스키마·RLS·Realtime 발행은 `sql/active_sessions.sql`.

### 로그인 경로를 건드릴 때 반드시 지킬 것

1. **모든 '실제 로그인' 은 `_claimDeviceSession(user, role)` 하나만 부른다.**
   이 함수가 ①타 기기 서버 폐기 ②UPSERT ③Realtime 구독 ④워치독 시작을 한 번에 한다.
   개별 함수를 직접 부르지 말 것 — 그렇게 하다 `vpPasswordLogin` 이 등록을 통째로
   빠뜨려서, 비밀번호로 로그인하면 이전 기기가 안 풀리는 구멍이 생겼다.
   현재 경로: `vpVerify`(OTP) · 소셜 · 신규 가입 · `vpPasswordLogin`.

2. **앱 부팅·세션 복원에서는 `_resumeActiveSession()` 을 쓴다.** UPSERT 도, 타 기기
   폐기도 하지 않는다. 부팅은 로그인이 아니다.
   종전에 부팅마다 UPSERT 해서, 강제 로그아웃 시점에 꺼져 있던 기기가 앱을 여는
   순간 소유권을 되찾아 최신 기기를 쫓아냈다(핑퐁). 결과가 "마지막 로그인" 이 아니라
   **"마지막으로 앱을 연 기기"** 가 됐다. `_resumeActiveSession` 은 현재 소유자를
   먼저 읽고, 내 기기가 아니면 이 기기가 물러난다.
   반대로 부팅에서 `scope:'others'` 를 호출하면 **방금 로그인한 최신 기기를 죽인다.**

3. **활성 세션 조회가 실패하면 아무것도 하지 않는다.** 네트워크·RLS 오류로
   로그아웃시키면 멀쩡한 회원이 튕긴다. 조회 성공 + 소유자 불일치일 때만 로그아웃.

### 우회 시나리오 점검표

새 로그인/세션 코드를 넣을 때 이 표로 자문한다.

| # | 시나리오 | 상태 |
|---|---|---|
| 1 | 다른 기기에서 로그인 | ✅ 1겹 |
| 2 | 앱을 끈 채 다른 기기 로그인 → 나중에 복귀 | ✅ 2겹(`_resumeActiveSession`) |
| 3 | 비밀번호 로그인 경로 | ✅ 등록 추가됨 |
| 4 | Realtime 구독 실패·소켓 끊김 | ✅ 2겹(워치독 폴링) |
| 5 | 브라우저 백그라운드 스로틀 | ✅ 2겹(`visibilitychange`) |
| 6 | 오프라인으로 계속 사용 | ✅ 2겹(`online` 이벤트) |
| 7 | DevTools 로 로그아웃 코드·구독 무력화 | ✅ 3겹(서버 폐기) |
| 8 | access token 을 복사해 다른 브라우저에 주입 | ⚠️ 3겹 + **토큰 만료 시간에 비례한 잔여 창** |
| 9 | 앱 없이 anon key + JWT 로 REST 직접 호출 | ⚠️ 3겹만. 완전 차단은 RLS 강화 필요(아래) |
| 10 | 시크릿창·다른 브라우저·PWA 병행 | ✅ 서로 쫓아냄(규칙대로) |
| 11 | 같은 기기 여러 탭 | ✅ 같은 `device_id` → 허용 (의도된 동작) |
| 12 | `taam_device_id` 삭제 후 재로그인 | ✅ 새 기기 취급, 자기가 자기를 쫓아냄 (무해) |
| 13 | `active_sessions` row 를 직접 조작 | ✅ RLS 로 본인 row 만. 실익 없음 |
| 14 | 아이디·비밀번호를 남에게 공유 | ✅ 로그인마다 서로 쫓아냄 (번갈아 쓰는 것 자체는 정상 동작) |
| 15 | 슈퍼어드민 면제 악용 | ⚠️ 운영 계정 관리 문제 — 코드로 막지 않는다 |
| 16 | 탈퇴 후 같은 번호로 재가입 | ✅ 차단됨 — **의도된 정책**, 아래 참조 |

### 면제 계정 — `profiles.single_device_exempt`

앱 심사·데모 계정만 다중 기기를 허용한다 (`sql/single_device_exempt.sql`).
Apple 은 iPad 와 iPhone **두 기기로 심사**하므로(리뷰 노트에 명시), 데모 계정이
단일 기기에 묶이면 리뷰어에게 "로그인이 자꾸 풀리는 앱" 으로 보여 2.1 리젝이 된다.

심사용 계정에 `super_admin` 을 주면 안 된다 — 면제만 필요한데 어드민 전체가 열린다.
그래서 역할과 분리된 플래그를 쓴다. 슈퍼어드민 → 회원 관리에서 토글한다.
**심사가 끝나면 반드시 되돌린다.** 켜둔 계정은 계정 공유가 가능해진다.

### 탈퇴 회원의 번호·이메일은 반환하지 않는다 — 의도된 정책

`taam_delete_my_account()` 는 `profiles` 만 마스킹하고 `auth.users.phone` /
`auth.users.email` 은 그대로 둔다. 그래서 **탈퇴한 회원은 같은 번호·이메일로
재가입할 수 없다.**

이건 버그가 아니다. 초대제 멤버십이라 "탈퇴 → 재가입" 을 자유롭게 열어두면
초대코드 재사용·중복가입 통제가 헐거워진다. 식별자를 묶어두는 쪽이 더 강한
통제가 된다고 판단해 그대로 둔다.

> ⚠️ **이걸 "탈퇴해도 번호가 안 풀리는 버그" 로 보고 고치지 말 것.**
> 정말 재가입이 필요한 사람이 생기면 **그 사람만** 슈퍼어드민이 개별 해제한다
> (해당 `auth.users` 행의 `phone` / `email` 정리). 정책 자체를 바꾸려면
> 사용자에게 먼저 확인한다.

**8·9 를 더 조이려면** (필요해지면 그때 한다):
- Supabase Auth → JWT expiry 를 3600 → 900초로 단축 (대시보드 설정, 코드 변경 없음)
- 민감 테이블(`profiles` · `tickets` · `deposit_transactions`) RLS 에
  "요청자가 `active_sessions` 의 현재 소유자일 때만" 조건 추가 → 앱을 거치지 않은
  직접 호출까지 차단된다. 단, 기기 식별자를 요청에 실어야 해서 설계가 커진다.

### 검증 방법 (기기 2대 또는 시크릿창 + 일반창)

- A 로그인 → B 로그인 → **A 가 로그아웃**되는지 (모든 로그인 경로별로)
- A 로그인 → **A 앱 완전 종료** → B 로그인 → A 를 다시 열면 **A 가 로그아웃**되는지
- A 에서 콘솔로 Realtime 채널을 제거한 뒤 B 로그인 → **A 가 60초 안에** 로그아웃되는지
- A 로그아웃 강제 후 A 의 콘솔에서 `sb.auth.refreshSession()` → **실패**해야 정상 (3겹)
- 슈퍼어드민은 두 기기 동시 로그인이 유지되는지

## 사진 캘린더 (새 첫 화면) — 플래그 뒤에 있다

첫 화면을 「사진 타일 캘린더」로 바꾸는 작업. **아직 전 회원에게 열려 있지 않다.**

| 항목 | 값 |
|---|---|
| 전역 플래그 | `NEW_HOME_LIVE = false` (index.html) |
| 기기별 스위치 | `localStorage.taamNewHome = '1'` + **슈퍼어드민만** |
| 판정 함수 | `newHomeEnabled()` |
| 켜고 끄기 | 슈퍼어드민 → 어드민 메뉴 → 「📅 사진 캘린더 (이 기기)」 |
| 편집 | 어드민 메뉴 → 「🖼 사진 캘린더 편집」 (`pcalAdminOpen()`) |
| 저장소 SQL | `sql/photo_calendar.sql` — **Supabase SQL Editor 에서 실행 필요** |

`CARD_PAY_LIVE` 와 완전히 같은 구조다. **심사 중에 이 플래그를 true 로 올리지 말 것** —
`server.url = taam-app.vercel.app` 이라 웹 배포가 곧 앱 반영이고, 켜는 순간 심사자에게도 보인다.
롤백은 플래그 하나 `false` 로 되돌리면 끝이고, 기존 홈/티켓 코드는 한 줄도 지우지 않았다.

플래그가 켜지면 같이 바뀌는 것:
- 일정(Ticket) 탭 상단 필터바·pill 바가 접히고 캘린더가 화면 맨 위부터 시작
- 홈 탭이 `homeView` 로 되돌아가 같은 캘린더를 그림 (지금은 일정 = 홈, 나중에 홈은 팝업·이벤트로 갈라짐)
- GNB 가 하단에 딱 붙음(`#mainGnb.gnb-flat`), `Quest` → `Cast`(준비 중), `Request` 도 준비 중

### 사진은 절대 index.html 에 넣지 않는다

| 사진 | 출처 |
|---|---|
| 월별 히어로 | `month_covers.photo_url` |
| 날짜 타일 | `ticket_products.tile_photo` — 없으면 `restaurants` 등록 사진 자동 폴백 |
| 고를 수 있는 원본 | `restaurants` 의 `photo_hero` / `photo_card` / `detail_photos` |
| 새로 올린 사진 | Supabase Storage `taam-photos` 버킷 |

코드에는 **URL 문자열만** 남는다. 예전에 base64 를 박아 `index.html` 이 25MB 까지 부푼 적이 있다.
타일은 **요리 단품 클로즈업** — 실내 전경·인물컷은 히어로에서만 (평균 휘도 108 · 채도 ×0.88 · 대비 ×1.06).

`ticket_products.tile_photo` 는 **저장 경로(`saveTicketProductToSupabase`)에 넣지 않았다.** 컬럼이
아직 없는 DB 에서 전체 티켓 저장이 통째로 실패하는 사고를 피하려는 것 — 타일은 편집 화면에서
`update({tile_photo}).eq('id',…)` 로만 따로 쓴다. `month_covers` 도 테이블이 없으면 조용히
폴백만 하고 앱은 그대로 돈다.

## 서버가 지키는 것 — 2026-08-31 이후 (깨뜨리지 말 것)

이 날 하루에 앱 전체를 훑어 **「앱이 막으니까 괜찮다」로 남아 있던 것들**을 서버로
옮겼다. 아래는 이제 DB 트리거·RPC 가 강제한다. 앱만 고치면 아무 일도 안 일어나고,
앱을 거치지 않은 요청은 그대로 통과한다 — 그게 이 목록이 생긴 이유다.

| 무엇 | 어디 | 규칙 |
|---|---|---|
| 예치금 잔액 | `trg_taam_guard_deposit_balance` | 회원이 직접 못 씀. **RPC(`taam_apply_deposit_delta`)와 슈퍼어드민만** |
| 예치금 결제 확정 | `taam_purchase_confirm_deposit` | 차감·거래기록·티켓확정이 **한 트랜잭션**. 금액도 서버가 재계산 |
| `profiles.role` | `trg_taam_guard_profile_role(_ins)` | 자기 승격 차단. 허용 이메일만 |
| `membership_tier` | `trg_taam_guard_membership_tier` | 비어 있을 때 **자기 초대코드 값으로만** 1회. M 만료일은 서버가 365일로 |
| 티켓 등급 제한 | `trg_taam_guard_ticket_tier` | `min_tier` 미달 구매 차단. 슈퍼어드민·초대·수동입력만 예외 |
| 재구매 제한 | `trg_taam_repurchase_guard` | 같은 매장 N일. **발매 7일 뒤 자동 해제**(`taam_repurchase_released`) |
| 티켓 필드 | `trg_taam_guard_ticket_row` | 회원이 `price`·`party_size`·`status` 를 못 고침 |
| 푸시 발송 | `send-push` Edge Function | 회원은 자기에게만. 어드민 상향 통지만 예외 |

### 금전 코드를 만질 때

1. **잔액은 절대 `profiles` 를 직접 update 하지 않는다.** `_depApplyDelta()` → RPC.
   델타를 넘긴다(새 값이 아니라). 읽고-쓰는 사이가 없어야 lost update 가 안 난다.
2. **SQL 을 먼저 넣고 앱을 배포한다.** 반대로 하면 앱이 없는 함수를 부른다.
   2026-08-31 오전에 그렇게 해서 **돈은 빠지고 티켓은 안 붙는** 사고가 났다.
   그래서 앱에는 「함수가 없으면 예전 경로로 내려가는」 폴백이 들어 있다.
3. **가드를 걸기 전에 그 컬럼을 쓰는 코드를 전수 조사한다.** 예치금 가드를 걸기
   직전에 멤버십 결제가 아직 `profiles` 를 직접 쓰고 있는 걸 발견했다. 그대로
   걸었으면 **카드 승인 뒤에** 막혀서 돈만 나갔다.
4. **SQL 을 쓰기 전에 실제 컬럼 타입을 조회한다.** 로컬 픽스처를 짐작으로 만들어
   `sale_open_at`(text 인데 timestamptz 로 가정)·`invite_codes.member_id`(text 인데
   uuid 로 가정)에서 두 번 라이브를 깨뜨렸다.
5. **가드는 예외를 던질지 값을 되돌릴지 고른다.** 같은 UPDATE 문에 다른 컬럼이
   실려 있으면(가입은 등급·국가·만료일을 한 번에 쓴다) 예외는 그것들까지 날린다.

### 서버가 소유한 것 — 앱이 밀지 않는다

| 값 | 주인 |
|---|---|
| `ticket_products.status` (매진/판매중) | `trg_sync_ticket_soldout`. 앱은 **로컬만** 바꾼다 |
| `profiles.deposit_balance` (합계) | `trg_taam_sync_deposit_balance` (BEFORE 트리거 중 **마지막**에 돈다) |

앱이 이것들을 밀면 ① 낡은 로컬 값이 서버 최신을 덮어쓰고 ② 권한 없는 세션에서
403 이 쏟아지고 ③ 어드민이 손으로 잠근 매진까지 풀린다. 셋 다 실제로 일어났다.

### 사진은 DB 에 넣지 않는다 — base64 금지

`index.html` 뿐 아니라 **DB 도** 마찬가지다. 2026-08-31 에 `chefs` 173MB +
`restaurants` 1.3MB 를 Storage 로 옮겼다. 계보도 첫 화면이 매번 19MB 를 받아
Cloudflare 가 응답을 끊고 있었다(`net::ERR_FAILED 525`).

- 새 사진은 **반드시** `uploadImageToStorage()` → URL 만 저장
- 크롭·리사이즈 결과도 마찬가지. 크롭 원본(`origData`)까지 Storage 로 간다
- 남아 있는지 확인: `sql/photo_base64_targets.sql` — **컬럼을 짚지 않고 전부 훑는다**
  (컬럼 이름을 나열해서 찾다가 세 번 놓쳤다)

### 배포는 사용 중인 화면을 끊지 않는다

서비스워커가 새 버전에서 열린 창을 강제 리로드하던 것을 그만뒀다. 이제
`SW_ACTIVATED` 메시지만 보내고, 앱이 `_taamBusyNow()` 로 판단한다.
**새 결제·편집 화면을 만들면 그 목록에 같이 넣는다.** 안 넣으면 그 화면에서
배포 중에 리로드가 난다.

## 작업 규칙 (중요)
1. **index.html 수정 시**: 거대 단일 파일이므로 Grep으로 위치를 먼저 찾고, 주변 코드 스타일(바닐라 JS, 한국어 주석, `var`)에 맞춰 작성.
2. **SQL은 저장소에 두는 것 ≠ DB 적용**. `sql/`의 스크립트는 사용자가 **Supabase SQL Editor에서 직접 RUN** 해야 반영됨. 새 SQL을 만들면 사용자에게 "실행 필요"를 명시.
3. **비밀키 금지**: API 키·service_role·firebase 키 등은 절대 코드/커밋에 넣지 말 것. 모두 Vercel/Supabase 대시보드 또는 Edge Function 시크릿에 있음. `.gitignore`가 secrets/·*.keystore·*.p8·.env 차단.
4. **결제·환불·예치금 로직**은 금전 관련이라 신중히. 수정 시 거래기록(deposit_transactions) 정합성 확인.
5. 커밋/푸시는 사용자가 요청할 때. 기본 브랜치는 `main`.

## 다중 세션 협업 규칙 (index.html 충돌 방지) — 필수

이 저장소는 **`index.html` 단일 파일**이라 두 세션이 동시에 편집하면 머지 충돌이 난다.
사용자가 원격/다른 기기에서 별도 세션을 돌릴 수 있으므로 아래를 항상 지킨다.

### 1. 담당 영역을 넘지 않는다
세션마다 담당이 나뉜다. **내 담당이 아닌 영역은 건드리지 않는다** (읽는 건 자유).

| 영역 | 담당 |
|---|---|
| 결제·예치금·티켓·환불·좌석·토스(Toss) = **금전 로직** | 금전 세션 |
| 소셜로그인 · 스플래시 · 명함QR(`/card`) · i18n · `sw.js` | UI/인증 세션 |

담당 밖 파일이 고쳐져야 할 것 같으면 **직접 고치지 말고 사용자에게 보고**한다.

### 2. 편집 전 rebase, 끝나면 즉시 머지
- `index.html` 을 편집하기 **전에 항상 최신 `main` 으로 rebase** 한다
  (`git fetch origin main && git rebase origin/main`).
- 작업이 끝나면 **묵히지 말고 즉시 PR → 머지**한다. 브랜치를 오래 들고 있을수록 충돌이 커진다.

### 3. 검증은 반드시 시크릿창
- `main` 머지 후 검증은 **시크릿(프라이빗) 창**으로 한다.
- 일반 창은 서비스워커/브라우저 캐시 때문에 옛 화면을 보여줘 **믿을 수 없다**.
- 과거에 캐시 사고로 라이브를 롤백한 전례가 있다 — 배포 후 "잘 되는 것처럼 보이는" 착시를 경계한다.

### 4. 라이브 반영 순서
시크릿창 검증 → `main` 머지 → 배포 확인. 검증 없이 먼저 머지하지 않는다.

> **참고(2026-08-15 시점 상태, 시간이 지나면 무의미)**: 캐시 사고로 라이브가 #167(8/14)로
> 롤백된 적이 있음. 라이브가 `main` 과 다를 수 있으니 배포 상태를 별도로 확인할 것.
> 재구매 제한 면제(커밋 `2ed077a`)는 이미 적용됨 — 중복 작업 금지.

## 라이브러리/외부 API 문서
라이브러리·API(Supabase, PortOne, Capacitor, Vercel 등)의 최신 문서·설정·코드 생성이 필요하면 **항상 Context7를 자동으로 사용**한다 (설치돼 있는 경우).

## 사용자에게 코드·SQL 을 건네는 방법 (2026-08-31 개정)

**길이와 상관없이 채팅에 그대로 붙인다.** 복사·붙여넣기가 되는 형태로.

종전(2026-08-30)에는 「30줄 넘으면 raw 링크」였는데, 그 방식이 실제로 잘 안 됐다.
raw 링크는 CDN 캐시가 남아 **고친 파일 대신 옛 파일이 뜨는 일이 하루에 세 번** 있었고,
그때마다 「에디터를 전부 지우고 다시」를 반복해야 했다. 링크를 열고 → 전체 선택 →
돌아와서 붙여넣는 왕복도 채팅에서 바로 긁는 것보다 느리다.

1. **SQL·TS·코드는 채팅에 통째로** 붙인다. 파일이 길어도 나눠 자르지 않는다 —
   잘라 주면 어느 조각까지 실행했는지 사용자가 세어야 한다.
2. 저장소에도 **커밋은 그대로 한다.** 채팅은 실행용, 저장소는 기록용이다.
   나중에 「그때 뭘 돌렸더라」를 볼 곳이 있어야 한다.
3. 붙이기 전에 **무엇을 어디에 넣는지** 한 줄로 적는다
   (Supabase SQL Editor / Edge Function 대시보드 / 기타).
4. **결과를 어떻게 읽는지**도 같이 적는다 — 「❌ 가 한 줄도 없어야 정상」처럼.
5. ⚠ **확인 쿼리는 반드시 하나로 합친다.** Supabase SQL Editor 는 **마지막 결과만**
   보여준다. 여러 개를 따로 주면 앞의 것이 통째로 묻힌다. union all 로 묶는다.
   (2026-08-31 하루에만 이 실수를 네 번 했다)
6. sql/·docs/·supabase/·*.md 만 바뀌는 커밋은 배포를 걸지 않는다
   (deploy.yml 의 paths-ignore) — 기록용 커밋이 Vercel 하루 한도를 먹지 않는다.
