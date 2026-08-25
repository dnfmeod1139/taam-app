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
