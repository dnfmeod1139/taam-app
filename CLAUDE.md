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
- **다국어**: KO/EN/JA. → 아래 「다국어 — 어디가 새는가」를 반드시 읽을 것
- 환불 정책: `legal/refund.html` (대행비 환불불가, D-31 기준 등) — 결제/취소 코드 수정 시 반드시 참고

## 통화 — 언어와 분리한다. 환율로 청구하지 않는다

**2026-09-10에 실제로 난 사고.** 국내 회원이 1,785,278원으로 결제됐는데 티켓이
안 붙었다. 서버는 정가 1,700,000을 기대했고 `PRICE_CHANGED` 로 막혔다.
돈은 빠지고 좌석은 잡혔는데 티켓은 `cancelled` · 0원이 됐다.

### 두 가지를 함께 어겼다

**① 언어로 통화를 추론했다**
```js
// 옛 _taamUserCur() — 지정 통화가 없으면 앱 언어로 정했다
return l === 'ko' ? 'KRW' : 'USD';
```
폰 언어가 한국어가 아닌 **국내 회원**이 앱을 열면 USD 로 판정돼 해외 회원
취급을 받았다. 방아쇠는 그 전날 기본 언어를 `navigator.language` 로 읽게
바꾼 것이었다 — 번역 편의를 위한 변경이 결제 경로까지 닿았다.

→ **통화는 `profiles.currency` 에서만 온다. 지정이 없으면 원화다.**
   언어는 통화와 아무 상관이 없다 — 한국 회원이 앱을 영어로 볼 수 있다.

**② 실시간 환율로 청구액을 만들었다**
```js
// 옛 fxTicketCharge() — 외화 합계를 환율로 되돌려 원화를 만들었다
krw: Math.floor(u.sum * rate)
```
서버(`taam_ticket_price_krw`)는 `(식사비+대행비+주류미니멈)×인원` 만 센다.
환율은 순간마다 변하므로 두 값이 맞을 수가 없다. **환율을 청구 근거로 쓰면
서버가 검증할 방법이 원리적으로 없다.**

→ **역할을 나눈다.**

| | 무엇 | 어디서 |
|---|---|---|
| **외화 금액** | 회원에게 **보여줄** 값 | 어드민이 티켓 업로드에서 확정 정가(`ovs_prices`)로 직접 입력 |
| **원화 청구** | 실제로 **차감할** 값 | `(식사비+대행비+주류미니멈)×인원` — 서버와 같은 식 |

환율은 업로드 화면의 **환산 도우미**와 **표시**에만 쓴다.

### 새 코드를 넣을 때

- `_tkCurrentLang` 을 보고 통화·금액을 정하지 말 것. 언어는 문구에만 쓴다.
- 앱이 보내는 결제 금액은 **서버가 같은 식으로 다시 셀 수 있어야** 한다.
  서버가 못 세는 값(환율·시세·사용자 입력)을 청구 근거로 삼지 않는다.
- 외화로 팔 티켓은 업로드 때 **확정 정가를 반드시 넣는다.** 안 넣으면 화면에
  `≈` 가 붙은 추정치가 뜨고, 회원이 본 외화와 실제 청구가 대응하지 않는다.
- `_tossCurrencyForUserLegacy` 는 옛 방식(언어·국적 추론)이다. 되살리지 말 것.

## 티켓은 누구에게 언제 열리는가 — 축이 **둘**이다

가장 자주 헷갈리는 규정이다. **시간**과 **자격**은 별개 축이고, 둘 다 통과해야 산다.
(코드에도 "독립된 별개 축" 이라고 적혀 있다 — `index.html` `_tkTierAllowed` 주석, `sql/ticket_min_tier.sql`)

### 축 ① 시간차 — 「등급별 우선 공개」 (`grade_open`)

어드민이 **「우선 공개 설정」** 스위치를 켠 티켓에만 적용된다.

```
M 오픈 = m_open_date + m_open_time
T 오픈 = M 오픈 + t_open_delay × t_open_unit   (기본 24 · 'hour' | 'day')
```

| 구간 | 판정 함수 | 누가 보나 |
|---|---|---|
| `now < M오픈` | `tcIsLocked()` | 아무도 (슈퍼어드민만) |
| `M오픈 ≤ now < T오픈` | `tcIsMOnly()` | **M 등급만** |
| `now ≥ T오픈` | — | **전원** (T · 게스트 · 등급없음 동시) |

⚠ **게스트만을 위한 오픈 시각은 없다.** 단계는 3개가 아니라 **2개**다.
T 오픈 시점에 그 아래가 전부 같이 풀린다 — 그래서 화면이 이 시점을
**「GENERAL / 일반 구매」** 라고 부른다. 「T 오픈 = 일반 오픈」이 같은 시각이다.

⚠ **이 축은 서버가 지키지 않는다.** `grade_open` · `m_open_*` · `t_open_*` 는
`sql/` 전체에 실행 코드가 없다. 앱을 거치지 않고 `tickets` 에 직접 넣으면
M 오픈 전이라도 통과한다. (축 ②는 트리거가 지킨다 — 아래)

### 축 ② 자격 — 「티켓 이용 등급」 (`min_tier`)

시간이 풀려도 이쪽이 막으면 못 산다. 어드민 버튼 4개가 그대로 값이다.

| 버튼 | 값 | 게스트(A) 구매 |
|---|---|---|
| 회원 전용 | `''` | ❌ 유료 회원(T·M)만 |
| **일반공개** | `'A'` | ✅ **게스트 포함 누구나** |
| T 이상 | `'T'` | ❌ |
| M 전용 | `'M'` | ❌ |

⚠ **빈 값(`''`)은 일반공개가 아니다.** 옛 회차 대부분이 빈 값이라, 빈 값을 개방으로
읽으면 티켓이 통째로 열린다. `sql/general_open_to_guest.sql` 머리말 참조.

⚠ `'A'` 는 **하한이 아니라 개방**이다. 「A 이상」이 아니라 「전원 허용」으로 읽는다.

서버 강제: `trg_taam_guard_ticket_tier` (`sql/general_open_to_guest.sql`).
예외는 슈퍼어드민 · `MAN-`(수동입력) · `INV-`/`INVH-`(초대) · 취소행뿐.

### 게스트(A)가 티켓을 사는 길은 둘뿐이다

| | **일반공개 회차** | **게스트 초대석** |
|---|---|---|
| 켜는 법 | 티켓 업로드의 「일반공개」 버튼 | 티켓 리스트 → 「게스트석」 (RPC `taam_guest_seat_open`) |
| 가격 | **회원가 그대로** | **게스트가**(`guest_price`) — 회원가보다 높게 |
| 구매 후 | **즉시 확정** | `pending_confirm` — 어드민 확정 대기 |
| 조건 | 없음 | 여는 이유 필수 + 매장 허락(`guest_seat_allowed`, 기본 잠김) + 회차당 1~2석 |
| 지금 | 활성 | **입구 닫힘** (규칙은 살아 있음) |

게스트가가 비어 있으면 회원가로 폴백하지 않고 **0을 돌려 결제를 막는다** — 싸게 파는
쪽이라 조용히 넘어가면 안 된다.

### 등급 값 (표기만 바꾸고 값을 건드리지 말 것)

`M`(Regular) > `T`(Entry) > `A`(**게스트 회원**) > 등급없음.
DB 값은 `'A'` 그대로고 **이름만** 「게스트 회원」이다. 값을 바꾸면 등급 판정이
통째로 어긋난다. A 가 되는 순간 `guest_expires_at = now() + 90일`.

`membership_tier='M'` 인데 만료됐거나 만료일이 없으면 **`T` 로 내려앉힌다**(null 아님).

### 방문일의 연도는 두 군데가 읽는다 — 둘 다 세 토막을 받아야 한다 (2026-09-21)

티켓의 `date` 는 보통 `MM.DD` + `dateYear` 지만, `YYYY.MM.DD` 로 들어온 행도 있다.
`_tkDateKey`(정렬 키)와 `_isTicketExpired`(방문일이 지났나)가 **두 토막만** 읽어서,
세 토막짜리는 정렬에서 맨 뒤로 밀리고 **영원히 「안 지난」 회차**가 됐다. 둘 다 세 토막을 읽게 고쳤다.
→ 방문일을 새로 읽는 코드를 쓸 때는 두 형식을 모두 받는다. 화면 표기는 `_popStoryDate`(연·월·일·요일)를 쓴다.

### 아직 정리되지 않은 것

- ~~등급 판정 함수가 두 갈래다~~ → **2026-09-14 통일.** `getCurrentUserGrade()` 가 프로필 기반
  `window._currentUserGrade` 를 먼저 보고, `memberDB`(슈퍼어드민 화면용 로컬 목록)는 폴백이다.
  종전엔 일반 회원에게 `memberDB` 가 비어 있어 M 회원이 M 전용 구간의 상세 입구에서 막혔다(코드로 확인).
- 어드민의 T오픈 **미리보기**는 올해 기준으로 계산하는데, 실제 판정(`tcGetDatetime`)은
  **방문일 기준 역산**이다. 연말·연초 회차에서 미리보기만 어긋날 수 있다.

## 예약 작업(Cron) — 「Succeeded」를 믿지 말 것

**2026-09-07에 실제로 겪은 일:** `notify-guest-expiry-daily` 가 며칠간 매일
`Succeeded` 로 찍혀 있었는데, Edge Function 은 **한 번도 실행된 적이 없었다.**

pg_cron 의 `Succeeded` 는 「`net.http_post` 를 큐에 넣는 데 성공」이라는 뜻이다.
pg_net 은 비동기라 **HTTP 응답은 별도 표에 남는다.** 거기를 보면 매번 이랬다.

```
401  {"code":"UNAUTHORIZED_NO_AUTH_HEADER","message":"Missing authorization header"}
```

Edge Function 에 `Verify JWT` 가 켜져 있는데 cron 명령에 Authorization 헤더가
없었다. 게이트웨이가 함수를 부르기도 전에 막았으므로 함수 통계도 0 이었다.

### 그래서 예약을 걸었으면 반드시 이걸 본다

```sql
select status_code, created, left(coalesce(content,''),200)
  from net._http_response order by created desc limit 10;
```

`200` 과 함수의 응답 본문이 보여야 진짜로 도는 것이다.
`cron.job.last_run` 이 `Succeeded` 인 것은 근거가 못 된다.

### 새 예약을 걸 때 지킬 것

- 키는 **Vault 에 한 번만** 넣고(`vault.create_secret`), 명령에서는 이름으로 참조한다.
  cron 명령에 키를 직접 박으면 `cron.job` 테이블에 평문으로 남는다.
- ⚠ **legacy JWT 여야 한다.** `Verify JWT with legacy secret` 는 `eyJ…` 로 시작하는
  200자 이상 JWT 만 받는다. 새 형식 키(`sb_secret_…`, 41자)를 넣으면 401 이다.
  Settings → API Keys → **Legacy API keys** 탭에서 가져온다.
- 알림 잡은 **시간을 겹치지 않게** 둔다 (게스트 10시 · 방문 11시). 같이 돌면
  둘 다 `send-push` 를 때린다.

### 푸시 대상을 「최근 N분」으로 긁지 말 것

`taam_*_notify()` 계열은 방금 만든 알림을 Edge Function 에 넘겨 푸시를 쏜다.
이때 대상을 `created_at > now() - interval '2 minute'` 로 다시 조회하면
**이번 실행이 만든 것인지 구분하지 못한다.** 2분 안에 두 번 부르면(재시도·수동
호출) 앞 실행이 만든 알림을 다시 집어 **같은 사람에게 푸시가 두 번** 간다.
실제로 `made:0` 인데 `push_sent:1` 로 관측됐다.
→ `insert … returning` 으로 **이번에 넣은 행만** 돌려받는다. 시간 창을 쓰지 않는다.

## 다국어 — 어디가 새는가 (2026-09-07 전수 조사)

**사전은 멀쩡하다.** `TRANSLATIONS` 는 ko/en/ja 957키 완전 일치, 누락 0건.
「번역이 안 됐다」는 신고는 거의 항상 **사전이 닿지 못하는 자리**에서 나온다.

### 층이 셋이다 — 어느 층 문제인지 먼저 가린다

| 층 | 무엇 | 고치는 곳 |
|---|---|---|
| **1. 정적 UI** | `t(key)` · `data-i18n*` · `TRANSLATIONS` | 키 추가 |
| **2. 런타임 스윕(TX)** | `TX_MAP` + `txSweep()` + MutationObserver. DOM 텍스트·placeholder·title·aria-label 을 사전에 있는 문구만 치환 | `TX_MAP` 에 문구 등록 |
| **3. DB 콘텐츠** | `pickI18nField(row,'name')` → `name_en`/`name_jp` · `pickI18nObj(obj,'title')` → jsonb 안의 `title_en`/`title_ja` | 번역 컬럼 + 배치 |

화면에 한글이 보이면 **그 문구가 DB에서 오는지 코드에서 오는지부터** 본다.
DB에서 오면 사전을 아무리 채워도 안 바뀐다.

### 새 기능을 만들 때 지킬 것

1. **정적 문구는 `t()` 나 `data-i18n`.** 급하면 최소한 `TX_MAP` 에 등록한다.
2. **DB 텍스트를 화면에 뿌릴 때는 반드시 `pickI18nField` / `pickI18nObj` 를 거친다.**
   원문 컬럼을 직접 박으면 EN·JA 에서 영구 한국어가 된다.
3. ~~번역이 필요한 새 테이블·필드를 만들면 `I18N_AUTO_JOBS` 에 한 줄 추가한다.~~ **자동 번역은 2026-09-20 부터 꺼져 있다** (`I18N_AUTO_LIVE=false`, 사용자 지시 — 기존 번역본을 그대로 쓴다). 로그인 스윕·매장 신규 등록·계보 노드 저장의 자동 번역이 전부 멈췄고, 어드민 메뉴의 「일괄 AI 번역」 수동 버튼만 남았다. 새 필드를 만들어도 자동으로 번역되지 않는다 — 켜려면 플래그 하나.
   그러면 자동 스윕이 알아서 번역한다. 이걸 빼먹으면 아무도 안 눌러서 영영 한국어로 남는다.
4. **의도적 한국어(슈퍼어드민 화면)는 `data-lang-lock="ko"` 를 단다.** 검사기가 이걸 보고 넘어간다.
5. 커밋 전 `node sql/_test/i18nshot.js` — EN·JA 화면의 한글이 **기준선보다 늘면 실패**한다.

### 이미 밟은 지뢰 (다시 밟지 말 것)

- **`i18n_jp_approved`** 는 `default false` 였고 이 값을 true 로 바꾸는 화면이 없었다.
  렌더가 false 면 일본어를 버리고 한글로 폴백해서, JA 가 **구조적으로 전부 막혀** 있었다.
  `sql/i18n_jp_open.sql` 로 열었다. 컬럼은 남아 있으니 특정 행만 되돌릴 수 있다.
- **쓰는 칸과 읽는 칸이 다른 경우가 있다.** 분류(genre)는 DB `description` 에 저장되고
  번역은 `description_en` 에 쓰이는데 화면은 `genre_en` 을 읽었다. 새 필드를 넣을 때
  **저장 경로와 렌더 경로가 같은 컬럼을 보는지** 확인한다.
- **원문을 고치면 `i18n_status_*` 를 `pending` 으로 되돌려야** 재번역된다.
  단, 무관한 저장(사진 교체·매진 토글)에까지 찍으면 번역비가 새고 손본 번역이 덮인다.
  → 원문 스냅샷과 비교해 **실제로 달라졌을 때만** 내린다.
- **`alert`/`confirm`/`prompt` 는 DOM 이 아니라 TX 가 못 닿는다.** 지금은 래퍼가 사전을
  태우지만, 사전에 없는 문구는 그대로 나간다. 회원 동선이면 `t()` 를 쓰는 게 낫다.
- **약관 4종(`legalTpl_*`)은 아직 한국어 단일이다.** EN/JA 번역본이 존재하지 않는다.
- **네이티브 앱은 기기 언어를 그대로 주지 않는다** (2026-09-16). iOS WKWebView 의 `navigator.language` 는
  앱 번들이 선언한 로컬라이즈(`CFBundleLocalizations`)와 기기 언어의 교집합이다. 선언이 없으면 한국 폰에서도 `en-US` 라
  앱이 영어로 떴다(슈퍼어드민이 한국어로 발행한 메인 팝업이 앱에서 영어로 보인 원인). codemagic.yaml 이 ko·ja·en 을 선언하고,
  앱은 자동 감지(`_tkLangGuessed`)였을 때만 프로필 `country=KR` 로 한국어로 보정한다(`_tkFixLangFromProfile`). 회원이 고른 `tkLang` 이 항상 우선.
- **메인 팝업을 고쳐 다시 발행하면 바뀐 칸의 `_en/_ja` 를 버린다** — 안 버리면 번역 잡이 「이미 됐다」고 넘어가 EN/JA 회원은 옛 문구를 본다.
- **매장 이름의 EN/JA 표기는 어드민이 직접 적을 수 있다** (레스토랑 등록·수정 폼의 「영문 표기」「일본어 표기」, 2026-09-15).
  적힌 값은 `_i18nBatch` 의 `keep` 필드라 AI 일괄 번역이 **덮어쓰지 않는다.** 다시 AI 로 받고 싶으면 그 칸을 비운다.
  한자·로마자 표기가 음차와 다른 매장(鮨 さいとう 등)은 이 칸으로 잡는다. 다른 필드(설명·주소)는 종전대로 AI.

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
| 티켓 필드 | `trg_taam_guard_ticket_row` | 회원은 **취소만**. `price`·`party_size`·`status(hold→active 포함)` 를 못 고침 (2026-09-13 강화) |
| 티켓 INSERT | `trg_taam_guard_ticket_insert` | 회원은 `status='hold'` 만, 매장 어드민은 `hold`·`manual`. **확정 행은 서버(RPC·toss-confirm)만** 만든다 (2026-09-13) |
| 푸시 구독 role | `save_push_subscription` | 클라이언트 `p_role` 무시 — `profiles.role` 로 정한다 (2026-09-13) |
| 초대코드 | `trg_taam_guard_invite_code_row` | 회원은 `used`·`used_by_*` 만. `invitee_tier` 등은 슈퍼어드민만 (2026-09-13) |
| `app_config` | RLS | 읽기 전원, 쓰기 슈퍼어드민만 — 환율(`fx_settings`) 오염 차단 (2026-09-13) |
| 공개 RPC 속도 | `taam_rate_hit(key, limit, window)` | `partner_agree`·`taam_mship_apply`·`taam_corp_inquire`·`taam_notify_admins`·verify/consume-invite·taam-chat. 새 공개 RPC 를 만들면 이걸 부른다 (2026-09-13) |
| 예치금 양수 델타 | `taam_apply_deposit_delta` | 회원은 `ticket_refund` + `purchase_id` 원장으로, **낸 돈 − 이미 환불** 한도 안에서만 (2026-09-13 핫픽스) |
| 원장 INSERT | RLS `deposit_tx_insert_server` | **회원은 `deposit_transactions` 를 직접 못 쓴다** — 슈퍼어드민만. 회원 원장은 RPC 가 쓴다. Edge(service_role)·SQL Editor 도 같은 RPC 를 부른다. 원장을 넘겼는데 잔액이 모자라면 `LEDGER_INSUFFICIENT` (2026-09-14, `sql/ledger_close_member_insert.sql`) |
| 푸시 발송 | `send-push` Edge Function | 회원은 자기에게만. 어드민 상향 통지만 예외 |
| 초대제 가입 | `trg_taam_guard_signup` (auth.users BEFORE INSERT) | **초대받은 사람만 계정이 생긴다** — 슈퍼어드민 화이트리스트 · `@partner.taam.kr` · 메타데이터 `invite_code`(미사용·미만료·초대장 번호/이메일 일치) · 초대장에 적힌 이메일/번호(소셜 첫 로그인). 그 밖은 `SIGNUP_NOT_INVITED` → GoTrue "Database error saving new user". 모드는 `app_config.signup_guard` (`enforce`, 2026-09-15 새벽 전환 · `log` 로 되돌림 가능). 판정 로그 `signup_guard_log`. 문지기 자체 오류는 `error` 로 적고 **막지 않는다** (`sql/signup_guard.sql`) |
| 환불 정책 | `taam_refund_cap` → `taam_apply_deposit_delta` ④ | 회원 환불은 **결제 30분 내 전액 · D-31 이상 총액−대행비 · 그 뒤 0** 을 서버가 센다. 앱 `calculateTicketRefund` 값은 참고일 뿐. 슈퍼어드민·옛 구매(tickets 없음)는 종전 (2026-09-14 밤, `sql/refund_policy_server.sql`) |

이 표의 2026-09-13 항목은 `sql/audit_hardening_2026-09-13.sql` 한 파일이 만든다
(테스트 `sql/_test/t_audit_hardening.sh`). 같은 날 Edge Function 도 같이 조였다 —
send-push(회원의 위로는 슈퍼어드민만·매장 어드민은 자기 손님만·url 은 우리 경로만),
notify-reservation(자기 예약·1회), lineage-summarize(슈퍼어드민·공개 URL 만),
toss-order(홀드↔티켓 대조), toss-confirm/billing-charge(예치금 부족이면 확정 안 함, 외화 빌링 거부).
**앱은 tickets 에 확정 행을 넣지 않는다** (`savePurchase` 의 `TK_CLIENT_INSERT=false`) —
넣어 봐야 서버가 거부한다. 회원 세션에서 `tickets` 를 INSERT/UPDATE 하는 코드를 새로
쓰기 전에 이 표를 본다.

### 원장은 서버만 쓴다 — 2026-09-14 (4단계 완료)

`deposit_transactions` INSERT 정책이 「본인이면 허용」→ **슈퍼어드민만** 이 됐다.
회원 세션에서 `sb.from('deposit_transactions').insert(...)` 를 새로 쓰면 **RLS 에 막힌다.**
잔액과 원장은 언제나 `_depApplyDelta(userId, mem, gen, entries)` 한 번으로 — entries 를
꼭 넘긴다. **앱에는 이제 `deposit_transactions` INSERT 가 한 줄도 없다** — 「서버가 옛 3인자
함수일 때」의 폴백 8곳과 슈퍼어드민 환불 0원 기록까지 같은 날 걷어냈다(빌드 `14-j`). `_depApplyDelta` 는
서버가 `p_entries` 를 모르면 잔액을 움직이지 않고 오류로 멈춘다 — 잔액만 움직이고 원장이 안 남는 것이
가장 나쁜 모양이기 때문이다. **슈퍼어드민 부여(`adminGrantDeposit`)도 같은 날 RPC 로 옮겼다** —
이제 앱 어디에도 `profiles` 잔액을 직접 update 하는 줄이 없다. 「부여 누적」(`granted_*`)은
원장 INSERT 트리거 `trg_sync_split_balance` 가 더한다(`sql/admin_grant_via_rpc.sql`). 앱이 또 더하면 두 배가 된다.

Edge Function 도 같다. `toss-confirm` · `toss-billing-charge` 의 `deductDeposit` /
`refundDeposit` 은 profiles 를 직접 고치지 않고 `admin.rpc('taam_apply_deposit_delta', …)` 를
부른다. RPC 는 `auth.uid()` 가 없을 때 `request.jwt.claims.role = 'service_role'` 또는
`session_user = 'postgres'` 면 슈퍼어드민과 같게 본다 (그 밖엔 「로그인이 필요합니다」).
그래서 **Edge 를 재배포하기 전에 SQL 을 먼저** 돌린다 — 반대면 예치금 섞은 카드 결제가
`deposit_short` 로 취소된다(돈은 안 새지만 결제가 안 된다).

원장을 넘긴 호출에서 잔액이 모자라면 이제 0 에서 조용히 멈추지 않고 `LEDGER_INSUFFICIENT`
로 거부한다. 종전엔 원장에는 요청 금액이, 잔액에는 그보다 작은 움직임이 남아 둘이 어긋났다.
원장 없는 옛 3인자 호출만 종전대로 0 에서 멈춘다.

테스트: `bash sql/_test/t_ledger_close.sh`(40건) · `t_ledger_mint.sh` · `t_ledger.sh`.

### 예치금이 두 번 빠졌다 — 2026-09-14 (서버 확정과 앱 차감의 경주)

`completePurchase` 의 홀드 전환(`taam_purchase_confirm_deposit` 이 차감·확정)과 예치금
블록(앱 차감)이 둘 다 **await 없는 async** 였다. 예치금 블록이 `_tkServerConfirmed` 를
읽는 순간 RPC 가 안 끝나 있으면 앱이 또 뺐다. 8/31 원장 서버화부터 살아 있었고,
1인 ₩1,000 티켓에 ₩2,000 · 한 회원은 ₩1,700,000 이 더 빠진 채 사흘을 갔다.
원장에 같은 `purchase_id` 로 `ticket_purchase` 가 두 줄(`server_confirmed` · `server_written`)
남는 것이 증상이다. 핫픽스: 전환 프로미스(`_tkHoldConvertPromise`)를 예치금 블록이 먼저
기다리고, 전환 실패(`_tkHoldConfirmFailed`)면 앱 차감도 하지 않는다.
→ **결제 경로에 「서버가 했으면 앱은 건너뛴다」 류의 플래그를 두면, 그 플래그를 세우는
쪽을 반드시 await 한다.** 병렬 async 두 개가 같은 돈을 만지게 두지 않는다.
정정 여부는 `metadata->>'fix' = 'double_deduct_2026-09-14'` 원장 줄로 남겼다.

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

## Supabase 도 main 이 곧 라이브다 — 2026-09-15 부터

`.github/workflows/supabase.yml` 이 `supabase/**` 가 바뀐 `main` 푸시마다 돈다.
- **SQL**: `supabase/migrations/2*.sql` 중 안 돌린 파일을 순서대로 실행하고 `public._taam_migrations` 에 기록한다.
  파일 안 확인 표에 ❌ 가 있으면 실패. 옛 `0001~0003` 은 건드리지 않는다.
  ⚠ **원장·잔액 수리처럼 미리보기가 필요한 SQL 은 여기 넣지 않는다** — `sql/` 에 두고 SQL Editor 로.
  트리거·정책·함수 같은 코드성 SQL 만 마이그레이션으로 간다. 파일 이름은 `20260915_무엇.sql`.
- **Edge**: 바뀐 함수만 CLI 로 배포한다 (`_shared/`·`config.toml` 이 바뀌면 전부).
  `verify_jwt` 는 **`supabase/config.toml` 이 정한다.** 대시보드에서 OFF 인 함수가 거기 없으면 다음 배포 때 ON 으로 돌아가 앱이 막힌다.
- 시크릿 `SUPABASE_ACCESS_TOKEN` · `SUPABASE_DB_URL`(Session pooler URI) 이 없으면 조용히 건너뛴다.
  손으로 돌리기: Actions → Supabase deploy → Run workflow (functions 칸 `all`).
- 순서는 SQL → Edge 다. 「SQL 을 먼저」 규칙을 워크플로가 지킨다.

## 배포 — Deploy Hook 의 201 은 「배포됐다」가 아니다

Vercel Hobby 는 **하루 100건**이다. 한도에 닿으면 이렇게 갈린다.

```
Deploy Hook 호출        → HTTP 201  {"state":"PENDING"}      ← 여기까진 성공
Vercel 이 빌드 시작     → Resource is limited - try again in 24 hours
                          (code: "api-deployments-free-per-day")
```

**훅은 「접수했다」만 말한다.** 실제 빌드는 그 뒤에 거부될 수 있고, 그러면
GitHub Actions 는 초록불인데 라이브는 안 바뀐다. 2026-08-31 에 이걸 두 번
틀렸다 — 오전에 한 번, 오후에 로그의 201 을 보고 「한도가 아니다」라고 또 한 번.

**라이브 반영 확인은 반드시 두 가지로 한다.**
1. Vercel Deployments 에서 그 커밋이 **Production · Ready** 인가
2. 앱에서 `BUILD` 번호가 실제로 올라갔는가

한도에 닿았으면 할 수 있는 건 기다리는 것뿐이다. 그래서 **index.html 변경은
모아서 한 번에** 내보낸다 (SQL·문서는 배포를 안 먹으므로 그때그때 해도 된다).

⚠ 그리고 앱 변경은 **「SQL 을 안 돌려도 안전한」 모양**으로 만든다.
   그러면 배포가 밀려도 반쪽 상태가 안 생긴다 — 원장 서버화 2단계가
   「앱이 안 넘기면 아무 일도 안 일어난다」로 설계된 이유다.

## 시크릿창 검증 — 창을 **전부** 닫아야 한다

시크릿 세션은 시크릿 창이 **하나라도 남아 있으면** 끝나지 않는다.
서비스워커·캐시가 그대로 살아 있어서, 새 창을 열어도 옛 빌드가 그대로 뜬다.
검증할 때는 시크릿 창을 전부 닫고 새로 하나만 연다.
