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
- (삭제됨 2026-08) `api/` Vercel 함수 — 앱은 Supabase Edge Function 만 호출. `taam-format` 은 2026-09-16(78761fd)부터 저장소에도 있지만 **그 판을 대시보드에 올린 기록이 없다**(2026-09-14 재배포 목록에서 빠짐) — 라이브 판이 더 새 것일 수 있으니 CLI 로 덮기 전에 대시보드 Code 와 대조한다
- `supabase/functions/` — Edge Functions (taam-chat, send-push, consume-invite, verify-invite, lineage-summarize, taam-translate, taam-translate-venues-batch, _shared)
- `supabase/migrations/` — DB 마이그레이션 (0001~)
- `sql/` — **수동 실행용 SQL 스크립트** (스키마·정책·수정·진단). `SQL_RUN_GUIDE.md` 참고
- `venues/` — 큐레이션 지식베이스 (정적 JSON, venue당 1파일). `_index.json`/`_award_index.json` 인덱스
- `seed-data.json` — 초기 데이터 (약 21MB)
- `legal/`, `terms/` — 약관·정책 HTML
- `secrets/` (gitignore됨), 비밀키는 저장소에 두지 않음

## 핵심 도메인 개념
- **역할**: `superadmin`(전체) / `admin`(레스토랑 파트너 = `profiles.role 'user'` + `admin_grants` 줄 · **승인(approved)된 매장만** · 아래 「파트너(매장 어드민)」) / `user`(회원)
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

### 해외 결제자의 예치금 — 환율은 **들어올 때 한 번**, 나갈 때는 원화 정가 (2026-10-13 정리)

「환율 적용이 이해가 안 된다」는 말이 나온 뒤 구조를 한 문장으로 못 박았다. **마진은 입금 때 확보하고, 소비는 국내 회원과 같다.**

| 단계 | 무엇 | 어디서 · 어떻게 |
|---|---|---|
| **적용환율** | 기준율(은행 「송금 받으실 때」) × (1 − 마진%) · USD/JPY 각각 | 어드민 메뉴 「💱 해외 통화 · 환율 설정」 → `app_config.fx_settings` (`FX`, `fxRate()`/`fxRateJpy()`) |
| **① 들어올 때** | 외화 × 적용환율 = 원화 예치금. 은행에는 외화 × 기준율이 들어오니 **그 차액이 마진** | 「예치금 부여」 $·¥ 모드(`_adgFxRate`) — 원장 metadata 에 `fx_currency/fx_amount/fx_rate/fx_base/fx_margin_pct`, 설명에 「송금 $x × 적용환율 r」. 정산 링크 외화 결제는 회차 환율(`kashikiri_events.fx_usd`, 기본값 = 적용환율)이고 **예치금을 건드리지 않는다** — 연회비를 링크로 받았으면 부여 화면에서 따로 넣는다 |
| **② 나갈 때** | 티켓 (식사비+대행비+주류)×인원 **원화 정가 그대로** 차감. 환율 무관 | `fxTicketCharge().krw` = 서버 `taam_ticket_price_krw` 와 같은 식. 환율을 다시 태우면 2026-09-10 사고가 재현된다(위 「통화」) |
| **③ 보일 때** | 해외 회원에게 같은 적용환율로 ≈외화 — **표시일 뿐 청구 근거가 아님** | `fxMoney` · 확정 정가 `ovs_prices` 는 ≈ 없이. **지금은 `FX_CURRENCY_LIVE=false` 로 전원 원화 표시**(`sql/currency_krw_only.sql`) — ①의 환산에는 그대로 쓰인다 |

왜 소비 때 환율을 안 태우나: 환율은 순간마다 바뀌어 서버가 검증할 수 없고, 입금 때 이미 마진을 챘으니 두 번 챌 이유도 없다.
보이는 곳: 환율 설정 팝업 미리보기(`_fxStructureHtml` — 입력 중인 기준율·마진으로 ①②③ 예시 금액을 다시 센다) · 예치금 부여 미리보기·확인창(은행 입금 ≈ · 마진) ·
회원 원장 예치금 탭 머리의 「해외 입금」 카드(`_mlFxSummary` — 통화별 송금 합계 → 예치금 · 적용환율 · 마진, 기준율 기록이 없는 옛 줄은 지금 마진율로 ≈ 어림)와 줄 태그 「송금 $x × r」(`_fxOfTx`).
회원 화면에는 환율을 적지 않는다 — 해외 회원에게 원화를 숨기는 2026-08-22 정책과 충돌한다. 회귀: 스크래치 `fxstruct.js`(12건).

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

### 회원 「시작일」 = 첫 초대 또는 첫 구매 중 빠른 날 — 가입일과 따로 (2026-10-13)

초대제라 가입 뒤 한참 지나 첫 구매가 이뤄지기도 한다. 1년 유지의 기산일을 가입일이 아니라 **첫 초대 또는 첫 구매**로 보려고
두 날짜를 따로 보여 준다. 서버 RPC `taam_member_start(p_uid)`(`20261013_member_start.sql`, 본인 또는 슈퍼어드민)가 센다 —
첫 구매 = `tickets` 에서 좌석을 실제로 가진 행(취소·홀드·만료 제외, PAYH-/INVH- 홀드와 운영 행 KSK-/LINK-/MAN- 제외)의 가장 이른
`created_at`, 옛 구매는 `deposit_transactions.ticket_purchase` 로 보완 · 첫 초대 = `reservation_invites` 중 `paid` 의 `created_at`(초대한 날) ·
둘 다 없으면 「시작 전」. `year_end_at` 도 돌려주지만 **멤버십 만료 계산은 아직 건드리지 않았다** — 표시만이다.
표시: 마이페이지 회원 자격 칸(가입일 · 시작일 · 종료일, TX 사전 「시작일/시작 전/첫 초대/첫 구매」) · 회원 원장 헤더 · 구매자 팝업.
앱은 절대 스스로 세지 않는다(세 표를 같이 봐야 한다). 회귀: `bash sql/_test/t_member_start.sh`(8건) · 스크래치 `mstart.js`(7건).

### 회원 가입일은 셋이다 — 앱 가입일 · 실제 멤버십 가입일 · 멤버십 시작일 (2026-10-15)

멤버십은 앱이 생기기 전(2024-12)부터 받았다. 앱은 초대코드로 가입한 날(`profiles.created_at`)을 가입일로 보여 주니 옛 회원에겐 1년 넘게 늦게 보였다. 운영 결정:

| | 무엇 | 어디 | 누가 보나 |
|---|---|---|---|
| ① 앱 가입일 | 초대코드로 가입한 날 = `profiles.created_at` | 종전 그대로 | 슈퍼어드민(원장 · 구매자 팝업에서 ②와 다를 때) |
| ② 실제 멤버십 가입일 | 앱 이전 가입자의 진짜 가입일 = `profiles.membership_joined_at`(date) | `20261015_membership_joined.sql` · 슈퍼어드민이 **회원 원장 헤더**에서 입력·수정·지움(`mlJoinedSave/Clear`, 직접 UPDATE) | 슈퍼어드민 |
| ③ 멤버십 시작일 | 첫 초대 또는 첫 구매 (`taam_member_start`, 2026-10-13) | 종전 그대로 | 회원·슈퍼어드민 |

- **회원에게는 둘만**: 「가입일」 = ② 가 있으면 ②, 없으면 ① (서버 `taam_member_start().joined_at` 이 고른다 · `joined_kind` manual/app) · 「멤버십 시작일」 = ③. 셋을 가르는 건 원장뿐.
  마이페이지 `_mpPaintMemberStart` 가 `joined_at` 으로 가입일 칸을 덮는다(함수가 옛 판이면 created_at 그대로). 「종료일」(member_until)은 손대지 않았다.
- 서버 가드 `trg_taam_guard_membership_joined`(BEFORE INSERT/UPDATE on profiles): 회원 세션은 이 칸을 못 바꾼다 — **되돌림**(예외 아님 · role 가드와 같은 방식, 같은 UPDATE 의 다른 칸을 날리지 않게).
  `membership_joined_set_by/at` 는 트리거만 적는다(앱이 보내도 무시). 날짜는 2015-01-01 ~ 오늘(KST), 아니면 `BAD_JOINED_DATE`. 지운 것도 set_by 에 남는다.
- ⚠ **2026-10-23 수리(빌드 `2026.10.23-c`) — 원장 헤더의 실제 가입일 「저장」·「지우기」가 10-15 부터 한 번도 안 됐다.** 버튼을 `_btn("mlJoinedSave(\'' + _uidQ + '\')", …)` 처럼 **큰따옴표 JS 문자열** 안에 썼는데, 그 안의 `\'' + _uidQ + '\'` 는
  이어붙이기가 아니라 글자 그대로라 onclick 이 `mlJoinedSave('' + _uidQ + '')` 가 됐고 누르면 `ReferenceError: _uidQ`(그동안 실제 가입일은 SQL 시드로만 들어갔다). → `"mlJoinedSave('" + _uidQ + "')"`.
  같은 모양(큰따옴표 리터럴 안의 `\'' + 변수 + '\'`)은 index.html 전체에서 이 둘뿐이었다(스캔). 스크래치 `mjoined.js` 가 이제 **화면의 버튼을 실제로 누른다**(종전엔 함수만 직접 불러 못 잡았다 · 옛 코드에선 ❌).
- 날짜 키(`joined_at`·`app_signup_date`·`membership_joined_at`)는 `'YYYY-MM-DD'` 문자열 — 앱은 `_memberDateFmt` 로 시간대 변환 없이 찍는다(해외 회원 기기에서 `new Date('2024-12-05')` 가 하루 밀리는 것).
- 앱 이전 가입자 22명 목록은 `sql/membership_joined_seed_2026-10-15.sql`(SQL Editor · `display_name` 공백 제거로 맞춘다 · 정확히 한 명일 때만 적고 ⚠/❌ 는 원장에서 손으로).
  「6/5 남기욱」은 목록 순서상 5/5 오타일 수 있어 적힌 대로 넣고 머리말에 적어 뒀다.
- **멤버십 연회비 탭**(원장 네 번째 탭 `mship`): 연회비는 어디에도 「연회비」로 적히지 않았다(앱 카드 흐름 `payments.type='membership'`·원장 `membership_payment` 는 포트원 시절 것 · 실제 회원은 송금·정산 링크 → 「예치금 부여」 줄로만 남음).
  그래서 `membership_fees` 표(`20261015_membership_fees.sql` · 납부일·원화·외화·수단·기간·등급·메모 · RLS 슈퍼어드민만 · created_by/updated_at 트리거)를 두고 탭에서 적는다(`mlFeeSave/Edit/Del`).
  **잔액·원장은 건드리지 않는다** — 예치금으로 쓸 몫은 종전대로 부여 화면. 옛 `membership_payment` 원장 줄은 탭에 「앱 결제 · 예치금」으로 같이 보이고 예치금 탭 라벨도 「멤버십 연회비」. CSV 에 연회비 줄 포함.
  표가 없으면(SQL 미실행) 원장은 그대로 열리고 저장만 「서버 준비 필요」.
- **2차(2026-10-16, 적대 리뷰 36 에이전트 → 확정 7건, 전부 경미).** ① 마이페이지가 created_at 을 먼저 칠하고 RPC 뒤에 덮어써 옛 날짜가 번쩍이고 RPC 실패 날엔 그대로 남았다 → 프로필을 `*` 로 읽어
  `membership_joined_at` 이 있으면 첫 칠부터 그 날(`_applyMembershipPeriodToUI` 3번째 인자 · 컬럼이 없는 서버에서도 안 깨진다). ② 연회비 머리줄이 자동 줄을 안 세어 「납부 0회」 밑에 앱 결제 줄이 보였다 →
  「기록 N회 · ₩ · 앱 결제 M건 ₩」로 따로. ③ 자동 줄 날짜를 UTC 로 잘라 새벽 결제가 하루 앞으로 → KST(`_kstYmd`). ④ membership_fees 를 **못 읽은 것**(5xx·프록시)이 「기록 없음」으로 보여 중복 기록을 유도 → 표 없음(42P01/PGRST205)과
  갈라 경고 줄 + 저장 차단(`_mlFeeLoadErr`). ⑤⑦ 삭제에 바쁨 가드 없음 · 0행을 「권한 오류」로 읽음 → 가드 + 「기록을 찾지 못했어요」(RLS 거절은 error 로 따로 온다). ⑥ 구매자 팝업 「앱 가입일」을 둘이 같아도 보여줌 → 다를 때만.
  리뷰가 기각한 것 중 하나는 고쳤다: **`taam_member_start` 가 비로그인(auth.uid() null)에게 열려 있었다** — `u <> null` 이 NULL 이라 검사가 비켜 갔다(2026-10-13 부터). 같은 파일에서 null 거절 + anon 권한 제거.
  같은 이유로 재구매 해제 푸시가 쓰는 `taam_repurchase_release_targets` 도 슈퍼어드민·SQL Editor·service_role 만 부르게 조였다(`20261016_rpc_caller_guard.sql` · 몸체 그대로 · `t_rpc_caller_guard.sh` 7건).
- **연회비 규정(2026-10-17 운영 확인).** 「예치금 부여 금액 = 총액 − 연회비」라 **첫해 연회비는 부여 줄에 숨어 있다**(설명에 안 적힌 것이 많다). 국내 M 11,250,000(연회비 1,125,000 → 예치금 10,125,000) ·
  국내 T 3,150,000(630,000 → 2,520,000) · 해외 M $9,900($990 → $8,910) · 해외 T $3,000($300 → $2,700). 2년차부터는 예치금 「관리 차감」으로 뺀다(2026-08-31 일괄이 그 모양).
  연회비 탭 기록으로 옮긴 것: 8/31 차감 8명 9건(2026-10-16 · 채팅 SQL) + 부여 15명 첫해(2026-10-17 · 채팅 SQL) + `sql/membership_fees_seed_2026-10-17.sql`(A T·해외 첫해 · 구자호·유수봉 2026년 — **가입 기념일에 구두 안내 뒤 이체**로 받은 것이라
  예치금과 무관(처음 메모가 「차감 · 추정」이어서 C 로 정정) · B 앱 이전 가입자 9명 첫해 기록용). **`membership_fees` 는 잔액·원장을 절대 움직이지 않는다** — 트리거는 stamp 하나뿐(「다시 입금되는 거냐」 질문에 확인 · D 블록이 확인 쿼리).
- **연회비 탭 머리 「다음 납부 기준일 · 부족 N건」(2026-10-17 · `_mlFeeDue`/`_mlFeeDueHtml`).** 가입일은 서버 `joined_at` 규칙(실제 가입일 우선, 없으면 앱 가입일 · 서버 함수가 없으면 `profiles.membership_joined_at` → `created_at` KST)으로 고르고,
  오늘(KST)까지 지난 기념일 수 = 시작된 연차 수, 납부 건수 = 기록 + 앱 결제 줄. **기준일 = 가입일 + 납부 건수 년** — 오늘 이전이면 「N일 지남 · 부족 N건」(빨강), 아니면 「D-N」, 건수가 연차보다 많으면 「선납 N건」.
  연차 통에 넣어 세지 않는 이유: 기념일보다 먼저 낸 선납이 「앞 통 2건·뒤 통 0건」의 거짓 부족을 만든다 — 대신 분납(한 해를 두 번에)은 두 건으로 세이니 메모로 가린다. M·T 가 아니면 「산정 대상 아님」, 못 읽은 상태(`mfLoadErr`)면 건수가 거짓이라 세지 않는다.
  2/29 가입은 평년 2/28. 날짜는 'YYYY-MM-DD' 문자열만(시간대 변환 없음). **앱 결제 줄(membership_payment)은 결제 단위로 센다** — 한 결제가 멤버십+일반 두 주머니를 쓰면 원장 줄이 둘이라 같은 `payment_id`(없으면 같은 KST 날짜)를 한 건으로(적대 리뷰 · 원장 select 에 `payment_id` 추가 · 머리줄 「앱 결제 1건(원장 2줄)」). 회귀: 스크래치 `mfdue.js`(47건 · 제외 스위치 포함).
- **연회비 납부 시기 — 서버 보고 RPC + 매일 슈퍼어드민 알림 + 어드민 화면 (2026-10-17, `20261017_membership_fee_due.sql` · 실행 필요).** 탭의 규칙을 서버에 그대로 둔다 —
  `taam_membership_fee_due(p_uid, p_today)`(security definer · 슈퍼어드민/SQL Editor/크론/service_role 만 · 회원·anon FORBIDDEN · `_taam_fee_caller_ok`)가 M·T 회원(탈퇴·운영 계정 제외) 전원의
  가입일(실제 우선 · 없으면 created_at KST) · 연차 수(`_taam_fee_years`: 오늘까지 지난 기념일 수 · 2/29 는 date+interval 이 2/28 로 자른다 = 앱) · 납부 건수(membership_fees + 원장 membership_payment 결제 수) ·
  기준일(가입일 + 납부 건수 년) · days_left · short · ahead · fee_hint(KRW M ₩1,125,000 / T ₩630,000 · USD $990 / $300 · 그 외 「규정 없음」)를 기준일 순으로 돌려준다.
  **fee_hint 의 통화는 `profiles.currency` 가 아니다** — 라이브는 2026-09-14 부터 전원 'KRW' 로 잠겨 있어(`sql/currency_krw_only.sql`) 그것만 보면 해외 회원이 원화로 나온다(적대 리뷰). 그 회원의 연회비 기록 외화(`membership_fees.fx_currency` 최근) → 잠금 전 통화(`currency_prev` · `to_jsonb(p)->>` 로 컬럼이 없어도 안전) → currency → KRW.
  `taam_membership_fee_notify(p_today)`: days_left ≤ 30 인 회원마다 단계 30 · 7 · 0 · −7 · −30 중 **도달한 가장 급한 하나**를 `membership_fee_notices`(회원·기준일·단계 PK · RLS 슈퍼어드민 읽기)에 적고
  (그 위 단계도 같이 적어 첫 실행에 다섯 번 쌓이지 않게 · `insert … on conflict do nothing` 의 row_count 로 「새로 적힌 것만」) 새로 적힌 회원을 모아 **슈퍼어드민마다 인앱 알림 1줄**(type `membership_fee_due` · 벨 라벨 FEE DUE ·
  본문 「이름 · 등급 · 기준일 D-N/오늘/N일 지남 · N년차 · 예상액」을 **1000자 안에서 줄 단위로** · 넘치면 「외 N명 — 전원은 화면에서」(줄 중간 절단 금지 · 적대 리뷰 — 전원은 payload.members 와 /?feedue=1 화면) · url `/?feedue=1`) + `taam_admin_push` 1번(8줄 + 「외 N명」 · tag `mfee-YYYYMMDD`). 푸시 실패는 삼킨다(알림은 간다).
  납부가 기록되면 기준일이 1년 밀려 새 키가 되므로 자연히 다음 해에 다시 알린다. 크론 `taam-membership-fee-due` 매일 00:00 UTC(09:00 KST · 게스트 10시·방문 11시와 안 겹침) — 함수가 DB 안에서 돌아 Edge·JWT 가 없다.
  **예치금·원장·membership_fees 에는 쓰지 않는다** — 알리기만. 앱: 어드민 메뉴 「💰 연회비 납부 시기」(`feeDueOpen` · 필터 전체/부족/30일 내/정상 · 줄 → `openMemberLedger()+mlOpen(uid)` · 「지금 점검 · 알림」= notify RPC ·
  함수 없으면 「서버 준비 필요」) · 벨 `/?feedue=1` → 이 화면 · 부팅 `?feedue=1` 은 **스플래시가 닫히고**(`_splashIsShowing` · 안 보면 z 9000 스플래시 위에 팝업이 뜬다 — 적대 리뷰) 슈퍼어드민으로 확인될 때까지 기다렸다 연다(20초). ⚠ 테스트에서 알림 호출과 조회를 한 문장에 넣으면 조회가 호출 전 스냅샷을 본다 — 따로 부른다.
  **대상 제외 스위치 `profiles.fee_exempt`**(`20261017_membership_fee_exempt.sql` · 2026-10-17 운영 결정으로 김우·손진범·민경만·도성국·테스트1 제외 — `sql/fee_exempt_seed_2026-10-17.sql` · **둘 다 2026-10-17 라이브 설치 ✅** · 대상 36 → 31명): 보고 함수에 `p_include_exempt`(기본 false)와 출력 `fee_exempt/_note` 가 더해져
  기본 조회·매일 알림에서 빠지고 화면 「제외」 필터(앱은 `p_include_exempt:true` 로 부르고 옛 서버면 인자 없이)에서만 보인다. 켜고 끄기는 원장 연회비 탭의 「연회비 대상에서 제외 / 대상에 포함」(`mlFeeExemptSet` · 직접 UPDATE).
  서버 가드 `trg_taam_guard_fee_exempt`(BEFORE INSERT/UPDATE **전 칸** · membership_joined 가드와 같은 되돌림 방식 · `fee_exempt_set_by/at` 는 트리거만 적는다 — `UPDATE OF` 두 칸으로 걸었다가 set_by/at 만 보낸 UPDATE 가 안 걸리는 것을 3차 리뷰가 잡았다) — 회원이 자기를 제외해 연회비 알림을 피하는 길을 막는다.
  ⚠ `fee_exempt_note` 는 profiles 칸이라 **회원 본인도 읽는다**(자기 행 select) — 보여도 되는 말만(prompt 에도 적혀 있다). 설치 파일은 알림을 보내지 않는다(⑤ 존재 검사만 — 시드 전에 제외 예정 회원이 실려 나가지 않게). 3차 적대 리뷰(15 에이전트 → 확정 3 · 전부 반영): 감사 칸 위조 · 「제외」 필터 잔존 · 설치 중 알림 발송.
  ⚠ 리뷰 에이전트가 스크래치에 같은 이름(`feedue.js`)으로 파일을 쓸 수 있다 — 화면 회귀는 `fdscreen.js`. 회귀: `bash sql/_test/t_fee_due.sh`(47건 · 제외 스위치·가드 포함) · 스크래치 `fdscreen.js`(40건). 2차 적대 리뷰(19 에이전트 → 확정 3 · 전부 반영): 인앱 본문 절단 · fee_hint 통화 · 스플래시 위 팝업.
- **예치금 「관리 차감」을 연회비 납부로 함께 기록 — 한 트랜잭션 (2026-10-18, `20261018_fee_deduct_record.sql` · **2차 판으로 2026-10-18 라이브 설치 ✅** · 확인 표 전부 ✅ · ⑤ 0).** 연회비 갱신은 대부분 예치금에서 뺀다(운영 확인 · 회원에게 알림·고지는 없다 — 연회비 알림은 슈퍼어드민에게만).
  그런데 「납부 시기」가 납부로 세는 것은 `membership_fees` 기록 + 앱 카드 결제 줄뿐이라 **관리 차감은 납부가 아니었다** — 차감 뒤 연회비 탭에 한 줄을 더 적어야 기준일이 밀렸고, 안 적으면 「부족」으로 남아 7일·30일 뒤 알림이 다시 왔다.
  → 부여·차감 모달의 차감(－)일 때만 보이는 **「연회비 납부로 기록」 체크 + 납부일**(`adgFeeWrap` · `_adgFeeChecked` · 기본 오늘 KST). 켜면 `window._adgFeeMeta = {membership_fee:{amount_krw, paid_at, note}}` 가 원장 entries 의 metadata 에 실리고,
  서버 **AFTER INSERT 트리거 `trg_taam_fee_from_deduct`**(deposit_transactions · security definer)가 **같은 트랜잭션**으로 `membership_fees` 에 한 줄(method `deposit` · source `deposit_deduct` · source_ref = 원장 줄 id · 등급은 프로필 M/T · 메모 = 차감 설명)을 적는다.
  **기록을 못 적으면 차감도 롤백**(`FEE_RECORD_FAILED` · 앱 안내 「연회비 기록에 실패해 차감도 취소됐습니다」) — 「돈은 빠졌는데 기록은 없다」가 이 기능이 없애려는 모양이라 조용히 넘기지 않는다. 플래그가 부여(+)·다른 change_type 에 실려 오면 같은 이유로 거절. 플래그 없는 줄(종전 전부·Edge·회원 환불)은 트리거가 보지 않는다. 같은 원장 줄로 두 번 적히지 않는다(source_ref).
  입구: 「💰 연회비 납부 시기」 줄의 **「예치금에서 차감」**(`feeDueDeduct` → `_adgOpenForFee` — 회원·멤버십 주머니·－·금액(fee_hint 의 ₩숫자, 외화·규정 없음이면 비움 + 토스트)·사유 「연회비 N년차 (기준일)」·체크를 채워 열고 확정은 사람이 누른다) · 원장 연회비 탭의 같은 버튼(`feeDueDeductFromLedger` · 금액은 사람이).
  차감을 되돌리는 부여(+)는 기록을 자동으로 지우지 않는다 — 연회비 탭에서 지운다. 연회비 탭 source 라벨 `_MF_SOURCE`(`deposit_deduct` 「예치금 차감과 함께 기록」 · `pay_link` 「결제 링크 자동 기록」) · 부여/차감 로그 두 목록(회원 거래 목록 · 전체 로그) 모두 「· 연회비 기록」 태그.
  **2차(적대 리뷰 3 렌즈 → 확정 6 · 전부 반영).** ① **회원이 납부 기록을 위조할 수 있었다** — `taam_apply_deposit_delta` 는 회원 호출에서 **음수 항목의 change_type 을 보지 않아** 회원이 `admin_deduct` 모양의 −₩1 줄에 `membership_fee` 플래그와 `by`(슈퍼어드민 uuid)를 실어 보내면
  security definer 트리거가 호출자를 안 보고 슈퍼어드민 전용 표에 「M 1,125,000 · 기록자 슈퍼어드민」을 적었다(기준일 1년 밀림 · 알림 소거). → 트리거가 **호출자를 본다**: `auth.uid()` 가 있으면 슈퍼어드민이어야 하고(아니면 FEE_RECORD_FAILED 로 차감까지 롤백), `by` 는 서버 호출(uid null)만 받고 로그인 호출은 `auth.uid()` 로 고정.
  옛 구멍도 같은 날 닫았다: 회원이 RPC 로 **자기 원장에 admin_deduct 모양의 음수 줄**을 쓸 수 있던 것(2026-09-14 부터 · 손실은 없지만 라벨이 거짓) → `20261018_ledger_admin_type_guard.sql`(아래 「서버가 지키는 것」 표 · 실행 필요). RPC 본문은 건드리지 않고 BEFORE INSERT 트리거로 덧댔다.
  ② 외화($·¥) 차감의 기록에 `fx_currency/fx_amount` 가 비었다(연회비 탭·fee_hint 통화 판정이 본다) → 앱 `_feeMeta` 와 트리거가 원장 metadata 의 외화 값을 함께 적는다(양수). ③④ 원장 연회비 탭 입구로 차감하면 **밑의 원장이 낡은 채**(「부족 1건 · 받았다면 기록하세요」) 남아 같은 연회비를 또 적게 됐다 → `_adgOpenForFee` 의 `after` 훅(`window._adgAfterGrant` · 1회성 · 열기·닫기에서 비움)이 성공 뒤 `mlOpen(uid)+mlTab('mship')`.
  ⑤ 프리필 「N년차」가 `years`(시작된 연차 수)여서 2건 이상 밀린 회원에선 틀렸다 → 납부 건수+1. ⑥ 「전체 로그」에 태그가 없었다 → 추가.
  회귀: `bash sql/_test/t_fee_deduct.sh`(16건 — 플래그 true/false/null/객체 · 부여에 플래그 거절 · **회원 세션 거절·서버 호출 통과·by 위조 무시** · 외화 기록 · 날짜 오류·표 없음 롤백 · 등급 A → null) · 스크래치 `adgfee.js`(40건 · 모달·확인창·실패 안내·두 입구·외화·원장 재그리기).
- **연회비 기준일 — 회원은 두 부류다 (2026-10-19 운영 결정 · `20261019_fee_due_anchor.sql` · 실행 필요).** 「회원 멤버십 만료일 관리」가 전원 가입일 2026.10.12 · 종료일 2027.12.31 ★프로모션으로 보이는 것을 보고 못 박았다.
  | 부류 | 누구 | 연회비 기준(anchor) | 첫해 | 보이는 날짜 |
  |---|---|---|---|---|
  | ① 앱 이전 계약 회원 | 슈퍼어드민이 적은 **실제 가입일**(`membership_joined_at`)이 있는 회원 — **반드시 앱 출시(2026-08-25) 전 날짜**(가드 `JOINED_AFTER_LAUNCH` · `_taam_app_launch_date()` · 앱 `TAAM_APP_LAUNCH_DATE`) | 실제 가입일 + 납부 건수 년 | 기록대로 | 실제 가입일(앱 가입일은 괄호) · **프로모션 무관** |
  | ② 앱 이후 가입자 | 실제 가입일이 없는 회원 | **첫 구매 또는 초대 결제일**(`_taam_member_start_at` — 예치금·카드·링크 무관 · 회원 소유 LINK- 포함 · 홀드·비회원 LINK- 제외 · **결제한 날**: INV- 는 `extra_data.confirmed_at` · LINK- 는 `extra_data.paidAt` · 초대는 `paid_at` · 없으면 created_at) + 납부 건수 년 | 가입 때 예치금 부여에서 연회비를 제외하고 받으므로 **첫 기념일(시작일+1년) 전에 낸 납부가 없으면 1건을 더한다**(`implicit_first` · 날짜로 가른다 — 기록 수로 가르면(greatest(기록,1)) 2년차 갱신 기록이 첫해 자리를 먹어 기준일이 안 밀리고 「부족」이 남았다 · 적대 리뷰) | 앱 가입일 **과** 시작일 둘 다 |
  | ②-시작 전 | 첫 구매·초대가 아직 없음 | 없음(`anchor_kind` none · 기준일 null · 알림 없음) | — | 앱 가입일 · 「시작 전」 |
  서버 `taam_membership_fee_due` 를 **같은 이름·인자**로 다시 만들었다(반환 칸이 늘어 drop → create · md5 가드) — 새 칸 `anchor_kind`(joined|start|none) · `anchor_date` · `app_signup_date` · `membership_joined_at` · `start_at` · `implicit_first` · `paid_recorded`(기록 건수 · `paid` 는 암묵 포함 실효 건수).
  종전 칸은 그대로라 매일 알림(`taam_membership_fee_notify`)은 손대지 않았다 — ②부류의 기준일이 바뀌면 알림 열쇠(회원·기준일·단계)가 새것이 되어 **한 번 다시 알린다**(예상된 일).
  앱: 원장 연회비 탭 머리(`_mlFeeDueHtml` opts.kind — 「실제 가입일 … 기준 (앱 가입 …)」/「첫 구매·초대 결제일 … 기준 (앱 가입 …) · 납부 N건(첫해 가입 때 제외 1 + 기록·앱 결제 M)」/「시작 전」 · 암묵 판정은 서버와 같은 날짜 규칙(`_mlAddYears(시작일,1)` 전의 `membership_fees.paid_at` · 원장 앱 결제 KST 날짜) · 시작일은 `taam_member_start` 의 `start_at` — 함수가 없으면 「시작일을 못 읽었습니다」) ·
  「💰 연회비 납부 시기」 줄(두 날짜 · 「프로모션 무관」 · 상태 「시작 전」 · 머리글도 두 부류 문구) · **「📅 회원 멤버십 만료일 관리」**(`_muFeeLine` — ① 실제 가입일+앱 가입일 ② 앱 가입일+시작일 · 아래에 「연회비 기준일 … · 기준 종류」 · ①부류인데 종료일이 프로모션이면 ⚠ 「프로모션 대상이 아닙니다 — 종료일은 아래에서 바꿔 주세요」 ·
  앱 가입일은 KST(`app_signup_date` 우선) · 옛 서버(`anchor_kind` 없음)면 시작일 셀 「—」와 「가입일 기준 · 서버 준비 필요」 — 첫 구매 기준이라고 거짓으로 적지 않는다 · 연회비 표를 **먼저 읽고 한 번만 그린다** — 두 번 그리면 그 사이 입력한 종료일이 지워졌다(적대 리뷰)).
  **2026-10-19 사고 — 10-16 실제 가입일 시드가 10월 가입자 7명을 ①부류로 만들었다.** `sql/membership_joined_seed_2026-10-15.sql` 은 운영자가 보낸 목록을 그대로 적었는데 거기에 앱 출시 뒤 가입자(최정우·강지헌·권한진·장동진·김세민·안가람·김민혁 — 가입일과 같은 날)가 섞여 있었다 → 전원 「앱 이전 계약 회원」으로 보이고 연회비 기준도 그 날로. `20261019_member_until_sync.sql` 이 **출시일(2026-08-25) 이후로 적힌 실제 가입일을 지우고**(②부류 복귀) 가드에 `JOINED_AFTER_LAUNCH` 를 더했다(원장 헤더 `mlJoinedSave` 도 같은 규칙으로 먼저 막는다). ①부류 판정은 날짜 하나로 끝난다: **실제 가입일 < 2026-08-25**.
  **종료일(`member_until`) = 연회비 갱신일 (2026-10-19 운영 결정 · 같은 파일).** 종전 「자동으로 바꾸지 않는다」를 뒤집었다 — 단, **`membership_expires_at`(M 등급 유효 판정)은 여전히 건드리지 않는다**(`member_until` 은 만료일 관리·마이페이지 종료일에 보이는 운영 날짜). 규칙: ① → 실제 가입일 기준 기준일(due_date) · ② 첫 구매·초대 있음 → **첫 구매·초대 결제일 + 1년**(= 기준일 · 첫해 암묵 1건) · ② 시작 전 → **프로모션 2027-12-31 유지(갱신일 미정)** · is_test·fee_exempt 는 건너뜀.
  서버 `taam_member_until_sync(p_uid, p_apply)`(슈퍼어드민·서버 · 기본 미리보기 · 바꾼 것은 `member_until_sync_log` 에 옛값과 함께) · `trg_taam_member_until_after_fee`(membership_fees INSERT/UPDATE/DELETE → 그 회원만 자동 적용 · 실패는 warning) · 앱 「📅 회원 멤버십 만료일 관리」의 **「🔄 연회비 기준일로 종료일 맞추기」**(`muSyncUntil` — 미리보기 → confirm(과거로 잡히는 인원 경고) → 적용 → 다시 그림) · 원장 헤더에서 실제 가입일을 저장·지우면 그 회원은 바로 맞춘다. 마이그레이션 자체는 종료일을 바꾸지 않고 ④에 「바뀔 회원 수」만 보여 준다 — 적용은 버튼 또는 `select * from taam_member_until_sync(null, true)`.
  ⚠ ①부류 중 연회비가 밀린 회원은 종료일이 **과거**로 잡힌다(마이페이지에도 보인다) — 그게 「갱신할 때」라는 신호다(운영 확인). 「변경」으로 손본 종료일은 그 회원의 다음 납부 기록 때 다시 맞춰진다.
  **2026-10-18 라이브 적용 ✅** — 자동 배포 #41 이 파일을 적용(7명 실제 가입일 지움)하고, 운영자가 SQL Editor 에서 `taam_member_until_sync(null,true)` 로 **28명** 종료일을 맞췄다(①부류 17 · ②부류 11 · 과거 날짜 없음 · 가장 가까운 갱신일 이항빈 2026-10-21). 시작 전 3명(장동진·Michael Minku Lee·박효민)은 프로모션 그대로. 회귀: `bash sql/_test/t_member_until_sync.sh`(19건) · 스크래치 `musync.js`(20건).
  확인 표 ⑥ 은 `taam_member_start` 가 memberUid 판인지 본다(아니면 ⚠ 「20261019_member_link_rows.sql 먼저」 — 원장 탭 시작일과 이 보고의 시작일이 어긋난다).
  회귀: `bash sql/_test/t_fee_due_anchor.sh`(14건 — 두 부류 · 암묵 1건 · 기념일 뒤 갱신 1건 → paid 2 · 결제일(초대 paid_at · INV- confirmed_at) · 시작 전 · 회원 LINK- 첫 구매 · 기록 2건 · 알림 · md5 재실행) · 스크래치 `mfdue.js`(62건 · ⑪~⑰ 두 부류·기념일 규칙·`_mlAddYears`) · `fdscreen.js`(42건 · anchorRows) · `muscreen.js`(12건 · 만료일 관리 한 번 그리기·KST·옛 서버).
- 회귀: `bash sql/_test/t_member_start.sh`(25건 — 가드·시드·anon 포함) · `bash sql/_test/t_membership_fees.sh`(12건) · `bash sql/_test/t_rpc_caller_guard.sh`(7건) · 스크래치 `mjoined.js`(23건).

### 테스트 계정은 회원 목록에서 숨긴다 — `profiles.is_test` (2026-10-19 운영 결정)

운영자 본인 계정·테스트 계정(**김우 · 테스트1 · 김우종** — 처음 시드는 「김우종은」으로 찾아 ⚠ 없음, 2026-10-19 운영자 정정 → `20261019_test_accounts_kimwoojong.sql` 로 다시 시드 · **2026-10-18 자동 배포 #44 라이브 ✅** — 숨긴 계정 김우 · 김우종 · 테스트1)이 진짜 회원과 섞여 보였다. 탈퇴 처리는 로그인을 막으니 못 쓰고, 「숨김」 스위치를 따로 뒀다(`20261019_test_accounts.sql` · 실행 필요).
- 서버: `profiles.is_test`(기본 false) + `is_test_set_by/at`(트리거만 적는다) · 가드 `trg_taam_guard_is_test`(BEFORE INSERT/UPDATE 전 칸 · 회원 세션은 **되돌림** · fee_exempt 가드와 같은 모양). 시드는 세 이름이 공백 제거 `display_name` 으로 **정확히 한 명**일 때만(탈퇴 안 한 회원 우선 · 0명·2명 이상은 ⚠ 로 두고 손으로 — 「김우」는 「김우종은」의 앞글자라 `=` 비교).
  켜면 `fee_exempt=true`(메모 「테스트 계정」 · 이미 있으면 그대로)도 같이 — 연회비 납부 시기·매일 알림에서 빠진다. 끌 때 fee_exempt 는 건드리지 않는다. 여러 번 RUN 해도 안전(「이미 숨김」).
- 앱: `is_test=true` 인 uid 집합을 **한 번 읽어**(`_taamTestIds` · 실패·컬럼 없음은 캐시하지 않고 빈 집합 → 화면은 그대로) 화면마다 `_taamHideTest(rows, q)` 로 거른다 — 회원 관리 목록(`renderMemberList` · 머리에 「테스트 계정 N개 숨김 · 보기」 띠 · 드러나면 「테스트」 배지) · 명부(`_mbPass` · 「테스트」 칩에서만) · 만료일 관리 · 원장 검색(`mlSearch`) ·
  회원 고르기(예치금 부여 `adgSearchUsers` · 초대 `riSearchMembers` · 결제 링크 `payLinkMemberSearch`) · 연회비 납부 시기(`feeDueRender` — 제외처럼 「제외」 필터에서만) · 「회원」 메뉴 배지(`_mbBadge` — `not.is.true` · 컬럼 없으면 종전 질의).
  **보이는 때**: 「테스트 계정 보기」(`window._taamShowTest` · 이 세션만 · `taamToggleShowTest`)를 켰거나, 검색어가 이름·이메일·번호(숫자만 · `+82 10` → `010`)와 **정확히** 같을 때 — 테스트 계정에 예치금을 부여하거나 초대할 때 이름을 그대로 친다. 부분 일치로는 안 나온다(「테스」·「김우」로 김우종은만).
  토글은 회원 관리 모달(`memOpenProfileQuick` → `select('*')` · `mmmSaveTest`) — 「일반 회원 / 테스트 계정 (숨김)」. 푸시·알림 대상·구매 내역·캘린더는 건드리지 않는다(테스트 계정이 받는 푸시는 테스트에 쓸모가 있다).
- 회귀: `bash sql/_test/t_test_accounts.sh`(13건 — 시드 정확히 한 명·공백·탈퇴 동명·⚠ · 회원 되돌림(다른 칸 유지·끄기·감사 칸·INSERT) · 슈퍼어드민 켜기/끄기 · 재실행 · 제외 풀림 복구) · 스크래치 `testhide.js`(47건 · 옛 서버 · 집합 · 정확 일치 규칙 · 여덟 화면 · 모달 토글).

### 한 회원 = 한 회차 1건 · 같은 날 같은 시간대 1건 (2026-10-13 카타오리 5/21 사고)

카타오리 5/21 회차가 같은 회원에게 두 번 팔렸다. **서버 어디에도 「같은 회원이 같은 회차를 두 번」을 막는 코드가 없었다** —
재구매 가드(`trg_taam_repurchase_guard`)는 날짜 간격만 보고 **같은 날은 인원추가·동반이라며 일부러 통과**시키고(`abs(...) > 0`),
좌석 엔진의 `SOLO_LIMIT` 은 「1인 팀 수」지 회원별 한도가 아니다. 앱의 `checkRepurchaseLimit` 은 `handleTicketAction` 에서만 불리는데
**회원의 실제 구매 경로(사진 캘린더 `pcalPay → openTdPayPopup`)는 그 함수를 지나지 않는다.** 운영 결정으로 규칙을 둘 세웠다
(`supabase/migrations/20261014_purchase_uniqueness.sql`, 트리거 **`trg_taam_guard_ticket_unique`** BEFORE INSERT OR UPDATE OF user_id,status,ticket_product_id,reservation_date,visit_time):

| 코드 | 규칙 | 예외 |
|---|---|---|
| `DUPLICATE_PURCHASE` | 같은 `user_id` 가 같은 `ticket_product_id` 의 살아 있는 행(취소·expired 아님, **hold 포함**)을 이미 가지면 거부 | 운영 행 KSK-/MAN-/INVH-(및 extra_data manualEntry·inviteHold·kashikiri) — user_id 가 어드민이라 서로 부딪힌다. **LINK- 는 `extra_data.memberUid` 가 없을 때만**(결제 전 홀드·비회원) 예외 — 결제 링크로 회원 소유가 되면 그 회원의 예약으로 **센다**(2026-10-18 · `_taam_ticket_is_ops` 20261018 판). **회원 행(PAYH-/PAYC-)은 플래그가 있어도 회원 행**(3차). **INV-(확정 초대)는 회원 것이라 센다.** 슈퍼어드민·service_role 도 예외 아님 |
| `TIME_CONFLICT` | 같은 날(`_taam_pu_visit_date`) 같은 시간대(`taam_time_slot`: **16:00 전 점심 / 16:00 부터 저녁**)의 살아 있는 행이 있으면 거부 — 다른 매장이든 같은 매장 다른 회차든 | 시각을 모르는 쪽이 있으면 **겹치는 것으로**(막는 쪽이 기본). 날짜·시각이 빈 행(toss-confirm 폴백 INSERT)은 `ticket_products.date/time` 으로 보충 |

- **회원 세션이 남의 user_id 로 넣는 행은 이 가드가 보지 않는다**(`auth.uid()` 와 다르면 return) — 바로 뒤 소유권 가드가 42501 로 끊는다. 먼저 보면 거절 문구에
  그 회원의 예약(매장·날짜·시각·구매 id)이 실려 샌다(적대 리뷰). 같은 이유로 이름이 `…guard_ticket_unique` 다 — BEFORE 트리거는 이름 순이라 insert/row/tier 가드 **뒤**에 돈다.
  ⚠ security definer 안에서 `current_user` 는 함수 소유자다 — 호출자 판별은 `auth.uid()` 로만.
- 회원 단위 `pg_advisory_xact_lock('tkuniq_'||uid)` 로 직렬화한다(다른 회차·같은 시간대 동시 INSERT 경주). 정원 트리거의 회차 잠금이 언제나 먼저라 순서는 회차→회원.
- UPDATE 는 **이 갱신이 새로 만드는 위반**만 본다: 소유자·회차가 그대로면 ① 을 묻지 않고, 날짜·시간대가 그대로면 ② 도 묻지 않는다 — 옛 중복·옛 겹침 회원의 출석 처리·금액 보정·
  어드민 시간 변경이 막히면 안 된다. 취소는 언제나 통과. 초대 확정(`taam_invite_confirm_hold`, INVH-→INV- 로 소유자 이전)은 걸린다.
- ⚠ **초대 결제(`riPay`)의 예치금 차감은 확정 RPC 와 같은 트랜잭션이 아니다**(앱이 `_depApplyDelta` 로 먼저 뺀다). 그래서 ① 차감 전에 `_tkServerPurchaseConflict` 로 서버의 내 티켓을
  새로 읽어 거르고(읽기 실패면 **진행하지 않는다** — `{error:true}`), ② 그래도 확정 RPC 가 DUPLICATE_PURCHASE/TIME_CONFLICT 로 거절되면 **그 자리에서 ticket_refund 원장으로 되돌리고**
  초대 상태를 복구한 뒤 차단 팝업을 띄운다(원장 `reason: duplicate_purchase|time_conflict`). 「예약 완료」로 내려가지 않는다.
- `taam_visit_date` 는 리마인드·재입고가 쓰는 라이브 함수라 **건드리지 않는다** — 이 가드는 `_taam_pu_visit_date`(2020~2100 가드) 를 따로 둔다.
- 앱: `checkPurchaseConflicts(t)` 를 `handleTicketAction` 과 **`openTdPayPopup` 입구** 둘 다에서(역할·티켓 종류 무관). `_tkFindPurchaseConflict(rows,…, strict)` — 구매 시트 경로는 내 옛 PAYH- 홀드를
  중복으로 안 세고(재사용), 서버 읽기 경로(strict)는 서버와 똑같이 센다. 로컬 행의 빈 시각은 `ticketDB` 에서 보충(`_tkHistFill`), 연도 없는 'MM.DD' 는 서버처럼 건너뛴다.
  홀드 INSERT 거절은 `_tkAcquireSeatHold` 가 `dup`/`clash` 로 매핑해 같은 팝업(`showPurchaseBlockPopup`). 인원 변경 시 옛 홀드 반납이 실패하면 새 홀드를 넣지 않는다.
- ⚠ `_tkAcquireSeatHold(t, r, pax)` · `openTdPayPopup` 안의 `t` 는 **티켓**이다. 사전은 `_shT()`/`window.t` 로 — 종전 `t('seathold.tier')` 줄이 TypeError 를 내고 있었다(같은 날 수리).
- 배포 순서: **앱(index.html) 먼저, 마이그레이션은 그 뒤 커밋으로** — 옛 빌드가 캐시에 남은 채 서버 거절을 받으면 메시지 없이 끝난다(지금 빌드는 예외도 토스트로 보인다).
- 회귀: `bash sql/_test/t_purchase_unique.sh`(42건 — 같은 purchase_id·삭제된 회차·옛 중복 행 시간 변경·남의 user_id 침묵 포함) · 스크래치 `dupguard.js`. 진단: 스크래치 `dup_kataori.sql`.
- **🔓 구매 규정 예외(협의 구매) — 슈퍼어드민만 (2026-10-22 · `20261022_purchase_rule_exception.sql` · 빌드 `2026.10.22-d`).** 「슈퍼어드민과 협의 후 같은 회차를 한 번 더(일행 추가) · 같은 저녁에 두 매장」이 위 규칙에 막혔다(스시 사이토 2027.06.01 20:30 「중복 구매 불가」). 규칙은 그대로 두고 **그 회원 · 그 회차에만** 푼다.
  표 `purchase_rule_exceptions`(회원 · 회차 · `allow_dup`(같은 회차 추가 · `extra` 1~5건) · `allow_time`(같은 날 같은 시간대) · `expires_at`(기본 방문일 끝 KST) · `note` 필수 · 만든 사람 · 해제) + 사용 기록 `purchase_rule_exception_uses`(예외로 통과한 구매 id·종류) · 티켓 행 `extra_data.ruleException`(표시용).
  쓰기는 RPC 만(`taam_purchase_exception_grant/_revoke` · 슈퍼어드민·SQL Editor·서버 = `_taam_fee_caller_ok`) · 같은 회원·회차의 살아 있는 예외는 하나(새로 허용하면 옛 줄 「새 예외로 대체」) · 해제·기한이 지나면 다시 막힌다(**이미 산 티켓은 그대로** — 취소는 따로).
  읽기: 슈퍼어드민 RLS · `taam_purchase_exception_list/_preview` · 회원은 `taam_my_purchase_exceptions()` 로 **자기 것의 열쇠만**(사유·만든 사람 없음).
  가드 `taam_guard_purchase_unique` 교체(md5 가드 — 저장소 20261014 판 `7e6c53a6…` 또는 **라이브 주석 축약 판 `efee83c2…`**(로직 같음 · 2026-10-22 진단 `20261022_diag_guard_src.sql` 로 확인) · 이미 새 판이면 ✅ · 모르는 판 ❌ 건너뜀): ① 같은 회차가 있으면 **살아 있는 같은 회차 행 수 ≤ extra** 일 때만 통과(그때 ② 에서 같은 회차 행은 안 센다) ·
  ② 같은 날 같은 시간대가 있으면 사려는 회차가 time 예외일 때만 통과 · **time 예외는 양쪽으로** — 예외를 받은 회차는 이 회원의 겹침 판정에서 빠진다(사이토 20:30 이 있는 회원에게 다른 매장 19:00 을 허락했으면 그 뒤 사이토를 한 번 더 살 때도 19:00 은 겹침으로 안 센다).
  그 밖의 줄(남의 user_id 침묵 · UPDATE 열쇠 그대로 통과 · 회원 잠금 · 문구)은 종전 그대로. 초대 확정·결제 링크 결제 뒤 소유자 이전·toss-confirm 폴백 INSERT 는 가드를 지나므로 같은 규칙. 결제 링크 만들기의 회원 선검사 두 줄도 치환(md5 `350c0c48…` · `pg_get_functiondef` + 정확히 한 곳 · `_taam_pu_clash_other`).
  재구매 제한(같은 매장 N일)과는 **별개**다 — 같은 날은 원래 예외, 다른 날은 회차별 「재구매 해제」.
  앱: 사전 차단(`_tkFindPurchaseConflict`)이 예외 캐시(`_tkPurchaseExc` · `_tkExcFor`)를 서버와 같은 규칙으로 보고, **막히면 서버에서 다시 읽고 한 번 더**(`checkPurchaseConflictsAsync` — 결제 팝업 입구 · `handleTicketAction` 은 한 번만 다시 연다 · riPay 의 `_tkServerPurchaseConflict` 도) · `taamSyncNow` 가 미리 읽는다 · 옛 재구매 검사는 예외 회차의 같은 날 행을 안 센다.
  막힘 팝업에 「일행 추가처럼 꼭 필요한 경우 TAAM 에 문의」(`ticket.block_contact` 세 벌). 슈퍼어드민 화면 `pxOpen`(어드민 메뉴 「🔓 구매 규정 예외 (협의 구매)」 · 회원 원장 「🔓 구매 규정 예외」 · 캘린더 구매자 상세 「🔓 이 회원에게 추가 구매 허용」 — 회원 행만) — 회원 · 회차(새로 살 것) · 미리보기(지금 걸리는 것 · 필요한 항목 자동 체크) · 항목 · 기한 · 사유 · 「회원에게 알림」(알림함 「예약하실 수 있습니다」 + 푸시 세 벌 · `/?ticket=` · category `purchase_exception`) · 목록(상태 · 사용 기록 · 해제). `_taamBusyNow` 에 `pxPopup`.
  **적대 리뷰(9 에이전트 → 확정 3 · 반영).** 옛 구멍 둘(가드가 원래부터 믿던 칸) — 회원이 자기 INV-/LINK- 행의 운영 행 표시(`inviteHold`·`manualEntry`·`kashikiri`·`linkInvite`·`memberUid`)를 켜거나 지워서,
  또는 자기 행의 `ticket_product_id`·`visit_time` 을 옮겨서 중복·시간대 가드가 그 행을 안 세게 만들 수 있었다(예외 없이도 같은 회차 두 장) → 결제 사실 칸 가드(`20261022_card_refund_quote2.sql` A)가 **회원 소유자 세션**의 그 칸들을 되돌린다
  (매장 어드민의 인원 변경 · 보낸 어드민의 초대 시간 변경(INVH-) · 소유자가 바뀌는 초대 확정은 그대로 · `t_card_refund_quote.sh` C18·C19). 앱: 초대 결제 선검사는 **언제나** 예외를 새로 읽고(해제된 낡은 캐시로 통과 → 예치금 먼저 빠짐 방지) · 실패하면 빈 목록 · 계정 전환 때 캐시 비움.
  회귀: `bash sql/_test/t_purchase_exception.sh`(49건 — A 실제 가드 위: 예외 없음 종전 · 허용 규칙·권한 · 같은 회차 추가 N건 · 취소 뒤 · PAYC 폴백 · 시간대 · 양쪽 규칙 · 초대 확정 모양 · 기한·해제·대체 · 회원이 보는 것·못 하는 것 · 목록·미리보기 · 운영 행 · 재실행 / B 결제 링크 픽스처 위(`PL_DB/PL_KEEP` 로 `t_pay_link.sh` 를 남김): 선검사 치환 · 결제 뒤 소유자 이전 / C 모르는 판 ❌) · `t_purchase_unique.sh` 를 새 가드 위에서(스크래치 `tpu_exc.sh`) · 스크래치 `pxc/px.js`(29건).

### 📦 티켓 연계(패키지) — 묶인 회차는 패키지로만 판다 (2026-10-29 · `20261029_ticket_package.sql` · `20261029_ticket_package_reports.sql` · Edge `toss-package-pay` · 빌드 `2026.10.29-b`)

운영 요청: 「티켓 연대 상품 — 연계하면 단일 상품 사는 건 해제해야 살 수 있게 · 연계하면 패키지로 살 수 있게」. 운영 결정(2026-10-29): **가격 = 회차 정가 합계**(할인 없음) ·
**결제 = 예치금 먼저 + 모자라면 카드** · **취소 = 패키지 통째로만** · **같은 시기 여러 매장을 연속으로 묶는다**(슈퍼어드민이 만든다 · 파트너는 못 묶는다).

| | 무엇 | 어디 |
|---|---|---|
| 묶음 | `ticket_packages`(이름 세 벌 · 설명 세 벌 · active/unlinked · 회차 스냅샷) · `ticket_package_rounds`(지금 연계된 회차 · 회차 하나는 한 패키지에만 · 풀면 줄을 지운다) | 읽기 공개(연계 중인 것만) · 쓰기는 RPC `taam_package_save`(만들기 · 이름·설명 고치기 — 회차는 바꾸지 않는다: 풀고 새로) · `taam_package_unlink` · `taam_package_list` · `taam_package_orders_admin` — 슈퍼어드민·서버만 |
| 만들 때 서버가 거절 | 회차 2~8 · 없는 회차 · 승인 대기·삭제 신청·숨김 · 연도 없는 날짜 · 지난 회차 · 이미 다른 패키지 · **같은 날 같은 시간대(점심/저녁 · 시각 모름 = 겹침)** · **같은 매장 재구매 제한 기간 안 두 회차**(재구매 해제 회차는 통과) | `_taam_pkg_conflicts` — 목록에도 지금 충돌을 ⚠ 로(만든 뒤 회차 날짜를 바꾼 경우) |
| 단일 구매 막음 | `trg_taam_guard_ticket_package`(tickets · BEFORE INSERT · UPDATE OF status, party_size, ticket_product_id) — **연계 회차의 회원 구매 행(PAY*)은 패키지 홀드(`extra_data.pkg` = 그 패키지)로만 INSERT** · 그 밖(단일 홀드 · 카드 확정 폴백 PAYC-)은 `PACKAGE_ONLY`. **연계 회차·패키지 홀드·패키지 구매에 든 행이 active 로 바뀌는 것은 패키지 확정 함수 안에서만**(GUC `taam.pkg_confirm` = 묶음 id) — 단일 예치금 확정(`taam_purchase_confirm_deposit`)·옛 카드 확정(toss-confirm·toss-billing-charge)이 그 홀드를 집으면 거절 → 롤백·카드 자동 취소 | 운영 채널(수동 MAN- · 초대 INVH-/INV- · 결제 링크 LINK- · 정산 KSK-)은 **막지 않는다**(어드민 판단) |
| 결제된 패키지 | 회원·파트너가 한 줄만 취소하면 `PACKAGE_CANCEL_WHOLE`(슈퍼어드민은 된다 — 운영 판단) · 인원 변경은 누구든 `PACKAGE_PAX_LOCKED`(서버 함수 밖) · 연계된 회차는 못 지운다 `PACKAGE_ROUND_LOCKED` | 같은 트리거 · `trg_taam_guard_tp_package_delete` |
| 구매 | 앱이 **회원 세션으로 회차마다 PAYH- 홀드**(정원·등급·같은 회차·같은 시간대·재구매 가드를 그대로 지난다 · 실패하면 잡은 홀드를 반납) → `taam_package_start(패키지, 인원, 홀드들, 화면 합계)`(본인·hold·패키지 표시·인원·회차 집합·5분 · 합계를 서버가 다시 센다 `PRICE_CHANGED` · 같은 홀드의 옛 시도는 superseded) → 묶음 `ticket_package_orders`(hold) | 인원 = 모든 회차에서 되는 인원의 교집합 · 남은 좌석 최소 이하 |
| 예치금 | `taam_package_confirm_deposit(묶음, 합계)` — **한 트랜잭션**: 홀드 잠금 · 금액 다시 · 잔액 잠금 · 멤버십 먼저 · **줄마다 · 주머니마다 원장**(구매 id = 그 줄 · metadata package_order) · 줄 확정(정가 · `extra_data.pkg/pkg_info`) · 묶음 paid(items 에 줄마다 dep/mem/gen/card) | 회원 세션이라 결제 사실 칸(paidBy·depositUsed)은 payfacts 가드가 되돌린다 — 진실은 묶음 표 |
| 카드 몫 | Edge `toss-package-pay`: `order`(→ `taam_package_order_prepare` · 예치금 먼저 · 카드 몫만 `payment_orders` purpose **package_topup** · 주문 번호 `taampkg_…` · 같은 묶음의 결제 안 된 옛 주문 superseded · 홀드 시각 다시 5분) → 결제창(successUrl `?toss_pay=success` · 앱 `_tossConfirmPayment` 가 `taampkg_` 면 이 함수로) → `confirm`(토스 승인 TOSS_SECRET_KEY · 주문 paid + **`metadata.pkg_claim`** → `taam_package_confirm_card` 한 트랜잭션 — 줄마다 예치금을 앞에서부터 채우고 남는 것이 카드 · `cardPaid/depositUsed/order_id` 줄마다) · `billing`(등록 카드 · TOSS_BILLING_SECRET_KEY) · 주문을 paid 로 잡는 것은 서버 함수 `taam_package_order_claim`(한 문장 · pending 일 때만 · metadata **합침**) · 확정이 **분명히** 거절되면(4xx + 우리 코드 — 좌석 만료 · 예치금 변동 · 패키지 해제 · 늦게 온 옛 주문) **전액 취소**(키 `taam-cancel-<paymentKey>`) + 묶음 failed(홀드 반납) · 취소 직전 묶음을 다시 읽어 **이 주문으로 이미 확정(또는 그 뒤 취소)된 묶음이면 취소하지 않는다** · 애매하면(네트워크 · 5xx · 토스 처리 중 · ALREADY_PROCESSED) 취소·실패로 굳히지 않고 결제를 조회해 DONE 이면 잇고 아니면 `{retry:true}`(주문 paid 면 `confirm_pending` + 슈퍼어드민 「확정 보류」 알림) · `resume`(회원 · 묶음의 마지막 카드 주문 — paid 면 확정부터 · pending 이면 토스에 주문 번호로 조회 · 새로 긁지 않는다) · 잡기가 애매하고 주문이 pending 이면 **먼저 주문을 닫고(failed) 그다음 승인 취소** · 자동 취소마저 실패하면 슈퍼어드민 알림(모든 갈래) | ⚠ `trg_taam_guard_pkg_order_claim`: **패키지 주문은 pkg_claim 없이 paid 가 못 된다** — 옛 toss-confirm/toss-billing-charge 가 패키지 주문 번호로 불리면 좌석 없이 승인만 하고 paid 로 끝내는 길(앱이 잘못 보내도) |
| 취소 | `taam_package_cancel_quote` · `taam_package_cancel(묶음, 화면 환불액)` — 회원 본인(또는 슈퍼어드민 · `p_full` 전액) · **줄마다 지금 규정**(결제 30분 안 전액 · 방문 D-31 이상 정가 − 대행비×인원 · 그 뒤 0) 의 합 · 환불액이 바뀌면 `REFUND_CHANGED` · **어느 줄이든 방문일이 오늘 이전이거나 active 가 아니면 회원은 `PACKAGE_CANCEL_CLOSED`(TAAM 문의)** · **줄마다 그 줄의 돈만**(적대 리뷰 — 패키지 단위 「예치금 먼저」는 환불을 다른 회차로 옮겨 매장별 판매·대행비가 틀렸다): 그 줄 환불액 ≤ 그 줄에 남은 돈(예치금 − 이미 돌려준 것 + 카드 몫) · 그 줄 안에서 예치금 먼저, 남으면 그 줄의 카드 몫 · 운영이 따로 취소한 줄(active 아님)은 0 · 방문일은 **지금 회차 날짜** · 방문·노쇼 처리된 줄이 있으면 `ROUND_DONE`(회원 막힘) · 원장 ticket_refund 줄마다(환불 한도 가드를 지난다) · 카드 몫도 줄마다(`pkg_card_refund` · 묶음 `cancel.alloc` — 판매 현황이 매장별로 센다) · **카드 환불 대기는 카드 몫이 있는 첫 줄 하나에**(`card_refund_pending.pkg_group` — 기존 「카드환불」 탭에 한 건) + 묶음 `card_refund` | 앱 「패키지 전체 취소」(구매 내역 · 패키지 줄) · 패키지 환불 요약은 그 한 줄에 |
| 카드 환불 | 「카드환불」 탭의 패키지 줄 → **묶음은 서버 기록으로 찾는다**(`_pkGroupForPending` — 묶음의 `card_refund.first_purchase_id` = 이 줄 · 대기 칸의 `pkg_group` 은 회원이 취소 순간 쓸 수 있어 믿지 않는다 · 없으면 단일 견적) → `_pkAdminCardRefund` → `toss-package-pay` `refund`(미리보기 → 실행 · 서버 견적 `taam_package_card_refund_quote` · 토스에 앱 밖 취소가 있으면 `outside_cancel` → 「완료 표시」 · 키 `taam-pkgrf-<묶음>`) → `taam_package_card_refund_mark`(묶음 · 그 줄 대기 done · 주문 `app_cancels` — toss-card-refund 와 같은 모양 `purchase_id`·`tx`·`by` · 금액은 묶음 대기 금액까지만) → 회원 알림(`tkMarkCardRefundDone` notifyOnly) · 「완료 표시」(상점관리자 처리)도 묶음 기록 | 패키지 관리 「구매자」에서도 같은 버튼 |
| 판매 현황 | `20261029_ticket_package_reports.sql` 이 라이브 `taam_ticket_sales_report` 본문 세 곳을 덧댄다(정확히 한 곳씩 · 모양이 다르면 ⚠) — 패키지 주문은 「한 주문 = 한 판매」에서 빼고 줄마다 카드 몫(`items[].card`)·카드 환불 몫(`cancel.alloc`)을 묶음 표에서(줄이 따로 자기 카드 환불 대기를 가졌으면 그것) | 결제 내역(pmx)은 손대지 않았다 — 주문에 잇는 티켓이 카드 몫 첫 줄(대기가 있는 줄)과 같다 |

- 앱: 회차 상세(`_pcalDetailHtml`)가 연계 회차면 결제 패널 대신 패키지 안내 카드 + 「패키지로 예약」(`pkOpen`) · 하단 바 = 패키지 1인 합계 · 결제 팝업 입구(`openTdPayPopup`)·홀드 거절(`PACKAGE_ONLY`)도 패키지 시트로 ·
  날짜 목록 `PACKAGE` 표시 · 티켓 리스트(슈퍼어드민) 「📦 패키지」 배지 · 구매 내역 「📦 패키지 i/n」 · 부팅 홀드 복구(`_tkRestoreSeatHold`)는 패키지 홀드를 단일 홀드로 붙잡지 않는다 ·
  결제창에서 결제 없이 돌아오면(`?toss_pay=fail` · 빈 복귀 `_tossRecoverTrip`) 그 시도의 패키지 좌석 반납(`_pkTripRelease` · sessionStorage `taam_pkg_trip`) — 단 그 주문이 이미 paid 면 반납하지 않고 `resume` · 복귀 승인이 도는 중(`_tossConfirmRunning`)이면 손대지 않는다 ·
  **결과가 애매하면 좌석을 반납하지 않는다**(`_pkAmbiguous` — 네트워크 · `retry` · `confirm_pending` · `charge_unknown` → `_pkSettle`: 묶음 상태 → Edge 다시 · 끝내 모르면 「결제 확인이 늦어지고 있습니다」 · 서버가 5분 뒤 풀고 늦은 승인은 취소한다) · 좌석 잡기·결제 대기 중엔 시트가 안 닫힌다 ·
  시트를 열면 앞 시도의 내 홀드부터 반납하고 서버 좌석 수(`taam_ticket_sold_slots` → `_pk.sold`)로 인원 선택지(자유 구성 = 좌석 엔진 `_tseAvailableSizes` · 고정 = 인원석 남은 수 · 낡은 로컬 「매진」 무시) · 카드 ₩100 최소 금액 표시 · 연계 회차 삭제 거절(`PACKAGE_ROUND_LOCKED`)은 화면에서도 되살린다 ·
  슈퍼어드민 「📦 티켓 패키지 (연계)」(`pkgAdminOpen` · 한국어 고정) — 만들기(회차 고르기 · 방문일 순 정렬 · 1인 합계 · 가능한 인원) · 이름·설명 · 연계 풀기 · 구매자(취소·카드 환불·원장) ·
  `_taamBusyNow` 에 `pkSheet`·`pkPayPopup`·`pkCancelPopup`·`pkgAdminPopup` · 회원 문구는 `pkg.*` 세 벌(TRANSLATIONS).
- ⚠ 서버가 지키지 않는 것: 등급별 우선 공개(grade_open) · 판매 공개(sale_state) · 마감 — 단일과 같이 앱만(`_pkBlockReason`). 게스트석으로만 열린 회차는 패키지로 못 산다(확정 대기 흐름과 맞지 않는다).
- 서버 덧: 카드 주문 만들기는 묶음 20분까지(`HOLD_GONE` — 주문마다 홀드 시각을 다시 재므로 끝없이 붙들지 않게) · 회원마다 시간당 30번(`taam_rate_hit`) · 결제된 패키지 줄의 방문 표시(used·noshow)를 되돌리는 것은 막지 않는다(홀드 확정·취소 되살리기만) · 연계 회차의 취소표 알림 줄은 넣지 않는다(`trg_taam_restock_skip_package` — 단일로 못 산다).
- 적대 리뷰(배포 전 · 37 에이전트 → 확정 30 · 전부 반영): 위 줄마다 환불 · Edge 실패 처리(애매하면 취소 안 함 · 확정된 묶음 취소 안 함 · 잡기 RPC · 등록 카드 재시도) · 앱 흐름(반납 시점 · 닫기 · 두 번 누름 · 인원 선택지) · 연동(pkg_group 위조 · app_cancels · 재입고 · 삭제 · 판매 현황).
- 배포 순서: SQL 두 파일 → Edge `toss-package-pay`(새 함수 · `[functions.toss-package-pay] verify_jwt = true`) → 앱. 앱이 먼저 가면 패키지가 0개라 아무 화면도 바뀌지 않는다(목록 읽기 실패 = 빈 목록).
- 회귀: `bash sql/_test/t_ticket_package.sh`(123건 — 리뷰 반영: 줄마다 환불(A 예치금 800,000 · B 예치금 500,000+카드 200,000 · C 카드 400,000) · 지금 회차 날짜 · ROUND_DONE · 따로 취소된 줄 0 · 오늘 방문 30분 안 · 잡기 RPC(합침·두 번) · 취소된 묶음 재확정 already · 20분 · 취소표 알림 · 완료 표시 상한 · app_cancels 모양 / 만들기 거절 규칙 · 단일 홀드·PAYC 폴백 막음 · 운영 행 통과 · 패키지 홀드 · 등록 검사 · 단일 예치금 확정·서버 단일 확정 막음 · 카드 주문·superseded·옛 함수 claim 막음 · 카드 확정 줄마다 몫 · 한 줄 취소·인원 막음 · 취소 30분/D-31/D-30 · 예치금 주머니 · 줄마다 예치금·카드 환불 몫 · 카드 환불 견적·완료 · 방문 시작 뒤 회원 취소 막음·슈퍼어드민 전액 · 이미 산 회차 DUPLICATE · 홀드 만료 · 반납 · 실패 · 풀기 · 회차 삭제 · 읽기 권한 · 재실행) ·
  `t_ticket_sales.sh` P0~P7 · 스크래치 `tpp/harness.mjs`(61건 · Edge — 애매한 확정·승인·잡기·등록 카드·resume) · `pkapp/pk.js`(37건 · 앱 — 리뷰 반영 10건 · 그중 8건은 고치기 전 판에서 ❌).

### 캘린더 「수동 추가」 내역 수정 — 좌석 연동 행은 서버 RPC, 기록은 직접 UPDATE (2026-10-14)

캘린더 상세 줄의 「수정」(슈퍼어드민·매장 어드민). 수동 추가는 저장 때 둘로 갈린다 — 본 티켓에 연결된 **MAN- 좌석 행**(`tickets`, status `manual`,
소유자 = 입력한 어드민)과 연결 없는 **기록**(`daegwan_manual`). 수정도 같은 두 갈래다(`tcalManualEditOpen(kind,…)` 가 추가 모달을 수정 모드로 열고
`tcalManualEditSave` 가 저장 · 종전엔 ×(취소) 뒤 재추가뿐이어서 그 사이 좌석이 풀려 남이 채갈 수 있었다).
- **MAN- 행 → RPC `taam_manual_entry_update`**(`20261014_manual_entry_edit.sql` · 실행 필요). 직접 UPDATE 가 안 되는 이유 둘: ① 매장 어드민 세션은
  `trg_taam_guard_ticket_row` 가 party_size·price 를 막는다(의도된 잠금, 풀지 않는다) ② `trg_enforce_ticket_capacity` 는 **BEFORE INSERT 에만** 걸려
  UPDATE 로 인원을 늘리면 정원 검사가 없다(`ticket_pax_change.sql` 이 증가를 막아 둔 이유). RPC 는 슈퍼어드민 또는 그 매장 어드민
  (`is_restaurant_admin_of` / `taam_is_rest_admin` 둘 중 하나)만, 이름·국내 번호(앱 `_krMobile` 과 같은 규칙, 아니면 `BAD_PHONE`)·인원·받은금액(price)·
  유형·메모를 고친다. **인원을 늘릴 때만** 정원 트리거와 같은 잠금(`tkcap_<회차>`)을 잡고 **총 정원**을 본다(이 행의 옛 인원은 빼고 센다 · 1인 한도·허용
  인원·슬롯 규칙은 KSK- 처럼 안 건다 · 정원 없는 회차는 제한 없음). `extra_data.edits` 에 {at,by,role,from,to} 최근 30건, 바뀐 게 없으면 쓰지 않는다.
  연결 티켓·날짜·시간·매장은 **바꾸지 않는다** — 좌석을 다른 회차로 옮기는 일이라 ×(취소) 뒤 재추가다.
- **기록 → `daegwan_manual` 직접 UPDATE**(RLS 가 슈퍼어드민·매장 어드민에게 `for all`). 번호 칸이 없어 숨긴다. `tcalLoadManual` 이 `ttype` 도 읽는다(프리필).
- 함수가 아직 없으면(SQL 미실행 · `_tcalRpcMissing`) 앱은 **인원 증가만 거절**하고 나머지는 tickets 직접 UPDATE 로 내려간다 — 슈퍼어드민은 행 가드를 지나고
  매장 어드민은 인원·금액에서 42501 을 그대로 본다. 늘릴 때는 저장 전에 `taam_ticket_sold_slots` 로 한 번 먼저 세어 모자라면 바로 말한다(최종 판정은 서버).
- 인원이 바뀌면 `trg_sync_ticket_soldout` 이 회차 매진·판매중을 되돌린다(앱은 `_tkSyncFromServer` 만 부른다). 손님 번호가 있고 알림톡이 나간 행이면
  「재발송」을 권한다 — 자동으로 다시 보내지 않는다.
- **2차(같은 날, 적대 리뷰 45 에이전트 → 확정 9건, `20261014_manual_entry_edit2.sql` · 실행 필요 · 7인자 판을 지우고 8인자로).** ① **낡은 화면이 남의 수정을 되돌렸다** — `for update` 는 쓰기만
  직렬화하고 캘린더는 열 때만 읽는다. A 가 인원 2→3 으로 고친 뒤 B 가 옛 화면에서 이름만 고치면 앱이 여섯 칸을 전부 보내 인원이 2 로 돌아가고(매진→판매중 → 취소표 푸시 전원 발송),
  기록은 B 가 줄인 것으로 남았다. → 앱이 「내가 본 값」 `p_expect` 를 보내고 서버는 한 칸이라도 다르면 `STALE_EDIT`(텍스트 비교 · 보낸 키만) → 앱은 다시 읽어 보여 준다. NULL 은 전 칸 「그대로」.
  ② **번호를 바꾸면 「✓ 카톡」이 거짓** — kakao_* 가 남아 새 번호 옆에 보냈다고 떴다. → 서버가 kakao_* 네 키를 지우고 `phone_changed` 를 돌려주며, 앱은 「새 번호로 지금 보낼까요?」를 `confirm` 으로 묻는다
  (자동 발송 없음 · 수정 모드의 번호 안내 문구도 그렇게 바꿈 — 추가 모드 문구는 「저장 직후 보낸다」였다). ③ 함수 없음 폴백이 **열 때의 스냅샷으로 extra_data 를 통째로 덮어** 그 사이 Edge 가 쓴 kakao_sent_at·
  운영 메모가 지워졌다 → 지금 행을 다시 읽어(`maybeSingle`) 취소·낡음을 거르고 그 위에 얹는다. ④ 선검사 RPC 를 기다리는 동안 저장 버튼이 살아 있어 이중 저장 → `_tcalEditBusy` 가드. ⑤ 선검사 정원이
  `assignedPax` 를 먼저 봐 고정 슬롯(배정 합계 < 총 좌석) 회차에서 서버가 허락할 증가를 앱이 막았다 → 서버와 같은 `totalPax`. ⑥ Edge `notify-guest-booking` 이 발송 1~3초 뒤 처음 스냅샷으로 PATCH 해
  그 사이의 수정(ttype·memo·edits)을 지울 수 있다 → PATCH 직전에 다시 읽어 kakao_* 만 얹는다(대시보드 배포 필요 · 급하지 않음). 프리필·비교는 `buyerNameRaw`(원문)로 — `buyerName` 은 빈 값일 때 어드민 이름으로 폴백한다.
- 회귀: `bash sql/_test/t_manual_edit.sh`(38건 — 1차→2차 순서로 올림 · STALE_EDIT · NULL 유지 · 번호 변경 kakao 초기화 · 매장 어드민 직접 UPDATE 가 가드에 막히는 것 포함) · 스크래치 `manedit.js`(21건).

### 초대 티켓의 소유자는 초대받은 회원이다 — 홀드는 어드민 소유다 (2026-10-03 사고)

캘린더 예약 초대는 좌석 홀드(`INVH-`)를 **보낸 어드민의 user_id** 로 넣는다(어드민 세션이라 그래야 INSERT 가드·좌석 트리거를
지난다). 9/28 의 `taam_invite_confirm_hold` 가 그 홀드를 그 자리에서 active 로 바꾸며 소유자를 안 바꿔, 유수봉의 예치금은 빠졌는데
타카미츠 3인 티켓은 슈퍼어드민 것이 됐다(구매자 상세에 Super Admin · 회원 원장엔 「티켓 행 없음」). 확정 함수가 소유자를
`invitee_user_id` 로 바꾸고(`20261003_invite_confirm_owner.sql`), **어떤 경로로 확정되든** `trg_taam_guard_invite_owner`
(BEFORE INSERT/UPDATE of status·user_id)가 초대 id 가 적힌 active 행의 소유자를 초대받은 회원으로 맞춘다
(`20261004_invite_owner_guard.sql`). 홀드 상태는 건드리지 않는다. 수리: `sql/invite_owner_repair_2026-10-03.sql`.
→ 「홀드를 그대로 확정으로 바꾸는」 코드를 쓸 때는 **소유자·금액·인원·이름을 전부 다시 쓴다** — 홀드의 값은 보낸 사람 기준이다.

### 💸 결제 링크 — 용도 셋을 한 화면·한 RPC 로 (2026-10-18 재구성)

링크 하나 보내는 데 대관 회차(매장·날짜 필수) → 상세 → 환율 폼 → 보내기 시트 → 복사의 화면 4개를 지났고, 연회비는 매장 이름을 임의로 적어 우회한 뒤
예치금 부여·연회비 기록을 세 화면에서 따로 손으로 적었다(2026-10-17 조사 · 리더 5명). 뼈대(`kashikiri_charges` 한 줄 = 링크 = 토스 주문 · `/pay` · `kashikiri-confirm` ·
`mark_paid_v2` · paid 트리거들)는 그대로 두고 **입구만 하나**로 모았다 — 어드민 메뉴 「💸 결제 링크」(`payLinkOpen`) · 캘린더 상세의 「💸 결제 링크」 · 회원 원장 연회비 탭의 「💸 연회비 결제 링크」.
옛 「정산 링크 보내기」(대관 회차·조·게스트 시트 · `kskOpen`)는 지우지 않고 새 화면 안의 「대관 정산 · 시트 ›」로 들어간다(운영 결정).

| 용도 | 입력 | 금액 | 결제되면 |
|---|---|---|---|
| 🎫 티켓 좌석 | 회차 · 이름 · 인원 · 통화 · (회원 선택) | 서버 (식사+대행+주류)×인원 — `taam_link_invite_create` 에 위임(좌석 홀드 · 매장 어드민 허용) | 홀드 → active. **회원을 골랐으면 그 회원의 티켓**(`taam_link_invite_on_charge` 가 user_id·buyer_name 이전 + `extra_data.memberUid` · 그 뒤로는 중복 가드가 **그 회원의 예약으로 센다** · 회원 구매내역에도 보인다 — 취소 버튼 대신 「TAAM 에 문의」(카드 환불은 결제 링크 목록의 「환불」)) |
| 💳 멤버십 | 회원(필수) · M/T · 가입/갱신 · 통화 · 환율 | `taam_membership_price` = `membership_settings`(국내 M deposit_amount+annual_fee_cash 11,250,000 / T t_total_krw 3,150,000 · 해외 M $9,900 / T $3,000 · 갱신은 연회비만). 바꾸면 **사유 메모 필수**(`OVERRIDE_NOTE_REQUIRED`) · JPY 는 규정이 없어 직접 입력 | `membership_fees` **자동 기록**(link · 외화·환율 · source `pay_link` · source_ref 청구 id) — **예치금 부여는 사람이**(2026-10-17 결정) · 알림 「💳 멤버십 결제 완료 … → 예치금 부여 ₩… 필요」 · 목록의 「예치금 부여」가 부여 화면을 채운다(`payLinkGrant`) · 환불되면 자동 기록 삭제 |
| 💸 자유 금액 | 이름 · 통화 · 금액 · 제목(메모) · (회원) | 어드민 입력 | 알림 「💳 결제 완료」 |

- 서버: `supabase/migrations/20261018_pay_link.sql`(**2026-10-18 라이브 설치 ✅** — 확인 표 ①~⑧-b 전부 ✅ · ⑨ 기존 청구 0 티켓 · 5 정산 · 3차 판으로 설치). `kashikiri_charges` 에 `purpose`(ticket|membership|custom) · `title` · `subtitle` · `payload` · `applied_at/_note` · `created_by`,
  **`event_id` 가 비어도 된다**(회차 없는 결제). 옛 행은 `link_invite` 면 ticket, 아니면 custom. RPC `taam_pay_link_create(p_purpose, p jsonb)`(슈퍼어드민 · 티켓만 매장 어드민도) ·
  `taam_pay_link_list(limit, uid, purpose)` · `taam_membership_price(tier, kind, currency)`. 공개 RPC 둘(`charge_public` · `order_start`)은 회차를 left join 해 제목·부제·purpose 를 함께 주고
  주문명도 용도별(「[TAAM] 멤버십 M 가입」). 좌석 트리거는 `event_id null` 이면 건너뛴다. 결제 완료 알림은 용도별 문구(record 변수 대신 스칼라 — 회차 없는 행에서 「not assigned」로 터졌다).
  환불 견적: 멤버십·자유 금액은 `admin_full`(전액 · 슈퍼어드민 판단), 티켓은 종전 규정. 외화는 외화로 적고 원화 = round(외화×환율) · 환율은 링크에 못 박힌다.
- `/pay`: purpose 가 membership/custom(회차 없음)이면 제목·부제로 그리고, **멤버십은 적용환율·원화 기준 줄을 숨긴다**(회원 화면에 원화·환율을 적지 않는 2026-08-22 정책) · 완료 뒤 「멤버십 알아보기」 퍼널은 티켓(비회원)에만 ·
  실패로 돌아오면(`pay_fail=1`) 토스가 붙인 `message/code` 를 한 줄 보여 준다(종전엔 조용히 결제 전 화면).
- 앱: 팝업 `payLinkOpen(opts)`(용도 세그 · 폼 · 결과(QR `_qrSvg` · 복사 · **공유 = `navigator.share`**, 없으면 복사) · 최근 링크 목록(복사·공유·끊기·환불·예치금 부여·원장)). 용도를 바꾸면 통화·회원은 초기화.
  매장 어드민은 티켓 용도만(자기 매장 회차만 · 대관 버튼 없음). `_taamBusyNow` 목록에 `payLinkPopup`. 결제 링크 URL 은 서버가 돌려주는 값(`taam-app.vercel.app/pay/?t=`).
- **2차(2026-10-18 적대 리뷰 62 에이전트 → 확정 15 · 전부 반영).** ① 매장 어드민이 임의 회원 uid 를 티켓 링크에 붙여 결제 뒤 그 회원 티켓을 만들 수 있었다 → 회원 지정은 슈퍼어드민만(존재 검사는 권한 뒤). ② 회원 소유가 된 LINK- 행이 중복 가드의 운영 행 예외에 들어 같은 회차를 또 살 수 있었다 → `_taam_ticket_is_ops` 가 memberUid 있는 LINK- 를 회원 행으로 세고, 만들 때 같은 회차/같은 시간대를 먼저 보며(DUPLICATE_PURCHASE/TIME_CONFLICT), 결제 뒤 소유자 이전이 가드에 막히면 **결제·좌석은 확정하고 소유자만 보류**(`memberUidPending` · ⚠ 알림). ③ 어드민 메모·실패 원문·만든 어드민이 회원이 읽는 청구 행(kc_mine)에 있었다 → `kashikiri_charge_admin` 표(슈퍼어드민 RLS)로. ④ 이름 없는 회원 label NOT NULL. ⑤⑥ 부여 화면 채우기 — 외화 센트(100배 위험)·기준율 없음(₩ 칸에 외화 숫자)이면 금액을 비우고 안내. ⑦ /pay 가 옛 정산 청구(purpose custom 백필·회차 있음)를 회차 없는 결제로 그렸다 → `event_date` 로만 판정. ⑧ 실패 사유 줄 재번역. ⑨ 통화·회원 바꿀 때 입력값이 지워지고 티켓 환율이 기본값으로 돌아갔다 → 값 거두기(`_plCollect`)·통화별 환율 기억. ⑩ 금액 수정 뒤 통화 바꾸면 입력칸 숨은 채 막힘 → override 해제. ⑪ 원장 버튼에 이름을 onclick 문자열로 넣어 아포스트로피에 깨짐 → uid 만 넘기고 화면이 읽는다. ⑫ 금액 조회 경주 → 순번. ⑬ 링크 초대 직접 경로의 purpose → BEFORE INSERT 트리거. ⑭ 기록 실패 때 완료 알림 문구. ⑮ 픽스처 FK.
  기각 4(부분 환불 때 기록 삭제 · 회원 티켓 링크의 /pay 환율 줄(pre) · mark_paid_v2 pending 미검사(pre) · 확정 뒤 재조회 실패 폴백).
- **3차(2026-10-18 · 2차 수정만 30 에이전트 → 확정 7 · 전부 반영).** ① **앱의 운영 행 판정 `_tkIsOpsRow` 가 서버 새 규칙과 어긋났다** — 서버만 memberUid LINK- 를 회원 행으로 세게 바꿔, 그 회원이 같은 회차 초대를 `riPay` 로 결제하면
  앱 선검사(`_tkServerPurchaseConflict`)는 통과시키고 서버가 거절해 **예치금이 먼저 빠졌다 되돌아오는** 모양이 됐다(20261014 머리말이 경고한 바로 그 경로) → 앱도 같은 규칙(memberUid LINK- 는 회원 행 · PAY* 는 언제나 회원 행) + 회원 구매내역에 그 티켓이 보이게(종전엔 LINK- 를 통째로 뺐다 · 취소 버튼은 「TAAM 에 문의」로 — 카드 환불이라 앱의 예치금 환불 경로를 타면 안 된다).
  ② 선검사가 가드보다 엄격(기존 행 visit_time 이 비면 무조건 겹침 → 점심+저녁 링크 거절) → 가드와 같은 식(`_taam_pu_visit_date`·`taam_time_slot`·회차 보충 · ⑧ 존재 검사에 둘 추가). ③ 이전 실패 폴백이 가드 거절 문구(다른 매장·날짜·구매 id)를 `tickets.extra_data` 에 적어 **매장 어드민에게 샜다** → 코드만(`ownerTransferError`='DUPLICATE_PURCHASE'), 원문은 `kashikiri_charge_admin.fail_note`.
  ④⑤ ⑨가 덜 닫혔다 — 회원 선택·「바꾸기」때 환율이 설정 기본값으로(통화 전환만 닫혔었다) → `_plCollect` 가 통화별 환율을 기억 · 앞 회원 이름으로 자동 채워진 「받는 사람 이름」이 다른 회원 링크에 실렸다 → `_plMemberSet` 이 자동 채움을 가려낸다. ⑥ 문서 세 줄(「LINK- 는 중복 가드 예외」)을 코드와 맞춤.
  기각 2 중 하나는 고쳤다: **회원이 자기 PAYH- 홀드의 extra_data 에 `kashikiri:true` 를 넣으면 중복·시간대 가드를 통째로 비켜 갔다**(20261014 부터 · pre) → `_taam_ticket_is_ops` 가 PAY 접두어는 언제나 회원 행(회원 INSERT 는 PAYH- 로만 허용되므로 이 한 줄로 닫힌다). 목록 줄에 어드민 메모·실패 원문도 보인다.
  ~~남은 것: 방문 리마인드·멤버십 시작일이 LINK- 를 통째로 빼서 회원 소유 LINK- 티켓은 리마인드가 안 가고 첫 구매로 안 셌다~~ → **2026-10-19 `20261019_member_link_rows.sql`** 로 둘 다 「memberUid 가 없을 때만 제외」로 좁혔고 시작일은 **결제한 날**(INV- confirmed_at · LINK- paidAt · 초대 paid_at)로 센다(라이브 함수 둘 · md5 가드 — 원본과 같으면 교체 · 이미 새 판(memberUid)이면 ✅ 그대로 · 모르는 판만 ❌ 건너뜀 · 회귀 `t_member_link_rows.sh` 10건). 아래 「비회원 손님 — 알림톡 리마인드 · 게스트 회원 초대」도 같은 날.
- **🎫 티켓 좌석 금액 수동 설정 · 미결제 링크 금액 변경 (2026-10-19 운영 요청 · `20261019_pay_link_ticket_override.sql`).** 종전엔 티켓 링크 금액이 서버 정가뿐이라 할인·특약은 자유 금액 링크로 우회해야 했고 그러면 좌석 홀드·회원 연결이 빠졌다.
  ① 만들 때: 티켓 폼의 「금액 수정」(슈퍼어드민만 · `payLinkTicketOverride` · 정가 미리 채움 · 「정가로 되돌리기」) → `p.total`(링크 통화) · `p.note`. 서버 `taam_pay_link_create('ticket')`(md5 가드 교체 · 3차 판 → 4차): 슈퍼어드민이 아니면 `PRICE_OVERRIDE_FORBIDDEN` · 정가와 다르면 사유 필수(`OVERRIDE_NOTE_REQUIRED` · 멤버십 수정과 같은 규칙 · 예외면 **홀드까지 롤백**) · 정가와 같은 total 은 수정으로 안 친다.
     바뀌는 것은 청구(`amount_krw`·`pay_amount` · 외화는 round(외화×환율))뿐 — 좌석 홀드·정산 회차·회원 연결·환불 규정·완료 알림·/pay·토스 주문은 모두 청구 금액을 읽으니 따로 손댈 곳이 없다. payload 엔 `price_override=true` 만, 「정가 → 수정액 · 사유」는 `kashikiri_charge_admin.note`(회원이 못 읽는 표). LINK- 홀드 행(tickets)에는 협의 금액을 **적지 않는다** — `extra_data.payAmount` 를 지우고 `priceOverride=true` 만, **`price` 는 정가×인원 그대로**(매장 어드민이 자기 매장 행을 읽는다 · KSK- 와 같은 원칙).
  ② 보낸 뒤: 최근 링크 목록의 미결제 티켓·자유 금액 줄에 「금액 변경」(`payLinkSetAmount` · prompt 금액 → 사유) → `taam_pay_link_set_amount(charge_id, total, note)`(슈퍼어드민 · `pending`·만료 전만 · `NOT_PENDING`/`LINK_EXPIRED` · 멤버십은 `BAD_PURPOSE` — 총액·연회비·예치금 몫이 같이 움직여야 해서 끊고 다시 만든다 · 같은 금액이면 `changed=false`). 어드민 메모에 「[금액 변경 MM-DD HH:MI] 전 → 후 · 사유」를 줄로 이어 붙인다. 토스 주문은 결제 순간 청구 금액으로 만들어지므로 미결제 변경은 안전하다.
  회귀: `t_pay_link.sh` +12건(수정·사유 없음 롤백·매장 어드민 거부·정가 동일·외화·0원·결제 뒤 환불 견적 수정액·변경·같은 금액·NOT_PENDING·BAD_PURPOSE·회원 거부·외화 변경·재실행) · `paylink.js` +18건.
  **2차(2026-10-19 적대 리뷰 2 렌즈 → 확정 11 · 전부 반영).** ① **협의 금액이 좌석 행에 실렸다**(`extra_data.payAmount` · 매장 어드민이 RLS 로 읽고 캘린더가 $ 로 보여 줬다 — 「정산 금액은 tickets 로 새지 않게」 원칙 위반) → 수정 때 지운다 · 캘린더는 **슈퍼어드민만** LINK- 행도 `kashikiri_charges` 에서 실제액(`linkPay` · `kskPayMap` 재사용 · 「(금액 수정 · 정가 ₩…)」) · 매장 어드민은 정가.
  ② 회원 구매내역이 `tickets.price`(정가)를 보여 줬다 → LINK- 행은 내 청구(kc_mine · 소유자 이전 때 `user_id` 가 회원)를 읽어 `amt`=amount_krw · 외화는 낸 외화 그대로(`h.payFx`). ③ md5 가드가 건너뛰면 앱만 금액 수정 UI 를 들고 옛 함수가 정가 링크를 만들었다 → 만든 뒤 **서버 금액 ≠ 화면 예상**이면 confirm 으로 끊기(`_pl.expect` · 확정 정가 미설치도 같은 길). ④ 대관 정산 조 몫(회차 있음 · link_invite 아님 · purpose 백필 custom)이 `set_amount` 로 바뀌어 시트와 어긋남 → `SETTLEMENT_CHARGE` + 목록 버튼 숨김.
  ⑤ 외화인데 `pay_fx` 없으면 1 로 지어냈다 → `FX_MISSING`. ⑥ 정가와 같은 total 이면 메모를 버리고 매장 어드민은 거절 → 같음 판정을 권한 검사 **앞에**(매장 어드민 통과) · 메모는 언제나 어드민 표에. ⑦ 통화 전환이 `plTotal` 을 남겨 ₩ 숫자가 $ 칸에 미리 채워졌다 → 지움. ⑧ 회원 선택·해제·비동기 프로필 읽기가 블록을 숨긴 채 `override=true` 로 두어 「금액을 적어라」만 떴다 → 다시 그릴 때 블록 복원 · `_plCollect` 먼저. ⑨ 인원·회차·환율을 바꾸면 미리 채운 정가가 낡아 「수정」으로 실렸다 → `_plOverrideRefresh`(손대지 않은 값만 따라감 · 라벨 갱신). ⑩ 클라이언트 비교가 외화에서 언제나 사유를 요구·센트 반올림 차이 → 서버와 같은 반올림(`_plRound2`)으로 같으면 사유 생략. ⑪ 목록에 `order_id`·`price_override`(목록 RPC 에 두 키 추가) · 결제 시작한 링크엔 버튼 없음 · 바쁨 가드 · `_pl.last` 갱신 · /pay 는 `order_start` 금액이 화면과 다르면 다시 그리고 묻는다(`amt_changed` KO/EN/JA).
- **💱 외화 링크 금액 = 티켓 업로드의 확정 해외 정가(`ovs_prices`) 우선 (2026-10-19 운영 요청 · `20261019_link_invite_ovs_prices.sql`).** 업로드 폼의 「$·¥ 자동 채우기」를 손으로 다듬어 저장해도 $·¥ 링크는 **원화 정가 ÷ 환율**로 금액을 지었다(「업로드 때 수정한 게 링크에 반영이 안 된다」).
  서버 `taam_ticket_price_fx(ticket, pax, currency, fx)`: 항목(식사·대행·주류)마다 **확정 해외 정가가 있으면 그 값 × 인원**, 없는 항목만 원화 × 인원 ÷ 환율(USD 센트 · JPY 정수) · USD 대행비는 옛 `overseas_agency_usd` 폴백 · 0원 항목은 건너뜀(대행비만 확정값이 있으면 센다 — 앱 `_fxUnitSum` 과 같은 규칙) · 확정 항목이 0 이면 **종전 식과 같은 값**(옛 링크 금액 불변) · `krw` 는 확정 항목이 있으면 round(외화×환율)(정산 링크 외화 규칙 · 환불 견적도 이 값) 아니면 원화 정가. `to_jsonb(row)` 로 읽어 컬럼 없는 DB 에서도 돈다.
  `taam_link_invite_create` 를 md5 가드로 교체(저장소 원본 `c53eceb383f113e7f7ef8b665ebe34aa` 와 같을 때만 · 이미 새 판(`taam_ticket_price_fx`)이면 ✅ · 모르는 판 ❌ 건너뜀) — 청구 `amount_krw`=krw · 좌석 행 `price` 는 종전대로 원화 정가 × 인원 · `extra_data.ovsFixed`(확정 항목 수) · `payAmount` 는 외화 정가(공개 가격이라 실어도 된다 — 수정 때만 지운다). 원화 링크는 아무것도 안 바뀐다. 금액 수동 설정(`p.total`)은 이 값 위에서 이긴다 — 「정가」 비교 기준이 확정 정가 기준이 되는 것뿐.
  앱: 티켓 폼 미리보기(`_plTicketPreview`)가 외화일 때 「$ 금액: 식사 **$550** + 대행 ≈$109 + … → N인 **$…** · 확정 해외 정가 N항목(티켓 업로드) / 없음 — 환율 환산」을 보여 주고(`_plTicketFxQuote` = 서버와 같은 식 · 환율 칸 `oninput` 도 갱신), 금액 수정 블록의 미리 채움·라벨(`_plOverrideLabHtml`)도 이 값. 확정 정가가 없으면 「티켓 업로드의 $·¥ 칸을 채우면 그 값으로」 안내.
  회귀: `bash sql/_test/t_link_invite.sh`(24건 — 전항목 확정 · JPY 섞임 · 원화 불변 · md5 재실행 · 3차 환불 견적) · `t_pay_link.sh`(계산 함수 · 전항목 · JPY 섞임 · 옛 대행비 폴백 · 확정 없음 = 종전 · 수정 비교 기준) · 스크래치 `paylink.js`(⑮ 미리보기 네 모양 · 미리 채움 · 같음 통과 · 수정).
  **2026-10-18 라이브 적용 ✅** — 자동 배포 #42 가 `20261019_link_invite_ovs_prices.sql`(① ✅ 교체 · ②③④ ✅)과 `20261019_pay_link_ticket_override.sql`(① ✅ 교체 · ②~⑤ ✅)을 순서대로 적용(`새로 적용 2 · state=ok` · ❌ 0). 앱 빌드 `2026.10.18-i` 는 Vercel 배포로.
  **3차(2026-10-19 적대 리뷰 3 렌즈 + 반박 2명 → 확정 3 · 전부 반영 · `20261019_link_invite_refund_agency.sql`).** ① **환불 견적이 어긋났다(실제 돈)** — 외화 링크의 `amount_krw` 는 round(외화×환율)인데 좌석 행 `agencyFee` 는 원화 정가 대행비 그대로여서,
  D-31 견적(`amount_krw − agencyFee×인원` 을 원화로 뺀 뒤 ÷환율)이 확정 $120 대행비 링크($1,860 · 2인)에서 ₩300,000 을 빼 **$1,642.61**(규정 $1,620.00 · $22.61 과환불)을 토스 부분취소로 보냈고, 원화 대행비 0 + `overseas_agency_usd` 100 회차는 환불 불가 대행비 $100 이 통째로 돌아갔다(반대 방향이면 소환불).
  → `taam_link_invite_create`(확정 정가 판 → 스냅샷 판 · md5 가드 `46f7b200874294c8758a4f1b405208d5`)가 좌석 행에 **`agencyPay`(1인 · 결제 통화 — 확정 외화 또는 원화÷환율)** 와 `agencyFee`(1인 · 원화 — 확정이면 round(확정값×환율)) 를 적고,
  `taam_link_invite_refund_quote`(20261018 판 → 결제 통화 판 · md5 가드 `ace3bccb056481ee7125193bc4c9ee73`)는 **외화 링크를 결제 통화로 센다**: D-31 `refund_amount = pay_amount − agencyPay×인원`(USD 센트 · JPY 정수) · `refund_krw = round(×환율)` · 30분 안·admin_full 은 `refund_amount = pay_amount` 그대로(종전 round(amount_krw÷환율)이 센트 어긋나 전액인데 부분취소가 되던 것도 닫힘) ·
  스냅샷 없는 행(확정 정가 판이 라이브였던 10-18 10:13 ~ 이 파일 전)은 지금 회차 요금(`taam_ticket_price_fx`)으로 어림. 원화 링크는 종전 식 그대로(tp1 USD 미확정 링크의 D-31 은 $1,594.19 · ₩2,199,982 — 종전 ₩2,200,000·$1,594.20 과 1센트 차 · 결제 통화 기준이 맞다).
  ② 금액 불일치 「끊기」가 슈퍼어드민 전용 RPC(`taam_kashikiri_charge_cancel`)를 매장 어드민에게도 물었고 실패하면 결과 칸 없이 끝나 **만든 링크가 보이지 않았다** → 매장 어드민은 묻지 않고 토스트 + 결과 표시 · 끊기 실패도 결과 표시 · 끊은 뒤 `_tkSyncFromServer`·`tcalLoadPurchases`.
  ③ 옛 「🔗 링크 초대」 화면(`riLinkPreview`)이 ₩÷환율을 미리 보여 주는데 서버는 확정 정가를 청구했다 → 같은 식(`_plTicketFxQuote` · 확정/환산 표시) + 만든 뒤 서버 금액이 다르면 토스트(끊기는 결제 링크 목록에서). 기각 3·보류 4 중 반영: /pay 금액 변경 때 원화 기준 줄도 갱신 · 회원 카드 USD 센트 두 자리. 자유 금액 칸의 통화 전환 유지는 2차 ⑨ 결정 그대로(바꾸지 않음).
  회귀: `t_link_invite.sh`(24건 — 확정 대행비 D-31 $1,620 · 30분 안 = pay_amount · 스냅샷 없는 행 어림 · JPY 미확정 대행비 · 옛 대행비 예외 $100 환불 불가 · md5 재실행) · `t_pay_link.sh`(77건) · 스크래치 `paylink.js`(126건 · ⑯ 끊기 실패·매장 어드민·옛 링크 초대 미리보기).
  **2026-10-18 라이브 적용 ✅** — 자동 배포 #43 이 `20261019_link_invite_refund_agency.sql` 을 적용(① 교체 2 · ③④ ✅ · ⑤ 스냅샷 없는 외화 LINK- 행 **0건** — 어림 경로를 탈 행이 없다 · `새로 적용 1 · state=ok`). 앱 빌드 `2026.10.18-j` 는 Vercel 배포로.
- **🧾 금액 수정 = 항목별(식사비 · 대행비 · 주류 미니멈 · 1인) × 인원 (2026-10-19 운영 요청 · `20261019_pay_link_override_parts.sql` · 빌드 `2026.10.19-a`).** 「금액 수정」이 받을 금액 한 칸뿐이라 무엇을 깎았는지 남지 않았고, 환불 D-31 은 언제나 **정가 대행비**를 뺐다.
  앱: 세 칸(`plPartMeal/plPartAgency/plPartWine` · 아래에 「정가 …」) + 합계 줄 `#plPartsSum`(「1인 X × N인 = 받을 금액 Y · 정가 Z ±차이」 · `_plPartsSumRefresh`). 미리 채움은 정가 항목 `_plListParts`(원화 = 회차 요금 · 외화 = 확정 해외 정가 또는 원화÷환율 — `_plTicketFxQuote` 의 parts · 서버와 같은 식).
  손대지 않은 칸만 인원·회차·환율을 따라간다(칸마다 「손댄 적 있음」 `_pl.partsTouched` — `_plPartInput` 이 적는다 · 지운 칸(빈 값 = 0)도 손댄 칸이라 회원 고르기·인원 변경에 정가로 돌아오지 않는다 · 블록을 새로 열거나 「정가로 되돌리기」·통화·용도 전환 때 비운다 · `_plOverrideRefresh`) · 통화 전환은 세 칸을 비운다 · 빈 칸 = 0 · 음수·문자는 막는다. **정가 항목과 셋 다 같으면 아무것도 안 보낸다**(정가 그대로 — 외화 환산 항목 × 인원이 정가와 센트 차이 나는 것을 「수정」으로 만들지 않게).
  다르면 `p.parts` + `p.total`(= 합 × 인원) + 사유(필수). 서버 `taam_pay_link_create` 가 **합 × 인원을 다시 센다**(`PARTS_TOTAL_MISMATCH` · `BAD_PARTS`) · 정가 항목 비교도 서버가 다시 하고 · 다르면 종전 금액 수정 규칙 + `payload.override_parts = {meal, agency, wine, pax, currency}` · 어드민 메모 「(1인 식사 … + 대행 … + 주류 … × N인)」 · 총액이 같아도 대행비가 다르면 수정으로 친다(환불 기준이 바뀐다 · price_override 는 false).
  **환불 견적 `taam_link_invite_refund_quote` 는 `override_parts.agency` × 그 인원을 대행비로 뺀다** — 단 **항목 합 × 인원이 지금 청구액과 같고 통화가 같을 때만**(원화·외화 · 아니면 종전 좌석 행 스냅샷 · 낡은 항목이 환불 기준이 되지 않게). 저장 위치가 청구 행인 이유: `kashikiri_charges` 는 슈퍼어드민(kc_super)·결제 회원 본인(kc_mine)만 읽는다 — 좌석 행(tickets)은 매장 어드민이 읽으므로 협의 항목을 적지 않는다.
  미결제 링크 「금액 변경」(`taam_pay_link_set_amount` · 같은 파일이 다시 만든다)은 총액을 바꾸면 **`override_parts` 를 지운다**(메모 「항목 내역 해제 — 환불은 정가 대행비 기준」 · 응답 `parts_cleared` · 토스트) — 1차 판은 남겨서, 대행비를 면제한 링크의 총액을 바꾸면 그 면제가 환불 때 「대행비 0」으로 남아 D-31 에 전액이 돌아갔다(적대 리뷰). 항목을 다시 정하려면 끊고 새 링크. 옛 앱 판(p.total 만)도 그대로 돈다. 두 함수 md5 가드(create `75a262d65111c7b646584f4ee02eb6aa` · quote `fa4c2c741daaf83d97ad05edf99bae2b`).
  회귀: `t_pay_link.sh`(97건 — 항목별 KRW/USD · 정가 그대로 · 합계 불일치 · 음수·문자·0 · 사유 · 매장 어드민 · 총액 같은 항목 조정 · 확정 없는 3인 환산 센트 · 환불 D-31 원화/외화 · 금액 변경이 항목 해제 → 정가 대행비 환불 · 청구액·통화 불일치 폴백 · 재실행) · 스크래치 `paylink.js`(145건 · 지운 칸 유지 · 0 으로 전송).
  적대 리뷰(2 렌즈 → 확정 2 · 전부 반영): 금액 변경 뒤 낡은 항목이 환불 기준 · 지운 칸이 정가로 다시 채워짐.
  **2026-10-19 라이브 적용 ✅** — 자동 배포 #52 가 `20261019_pay_link_override_parts.sql` 을 적용(① 교체 2 · ③④⑤ ✅ · `새로 적용 1 · state=ok`). 앱 빌드 `2026.10.19-a` 는 Vercel 배포로.
- **🔗 결제 → 회원 예약 연결 · 결제되면 회원 알림 (2026-10-23 · `20261023_pay_link_member_visible.sql` · 빌드 `2026.10.23-a`).** 에릭(회원)에게 보낸 스시 사이토 2027.03.15 2인 $1,800 링크가 **자유 금액**(티켓 링크 금액 수정 · 10-19 전)이라 좌석 행이 없었고
  좌석은 캘린더 「수동 추가」(MAN- · 슈퍼어드민 소유)로 따로 잡혀 회원 「예약 내역」에 안 보였다 · 결제 완료 알림도 슈퍼어드민에게만 갔다(진단 `20261023_diag_link_member*.sql` — 결제된 청구 3건: 정산 1 · 자유 금액 2 · 결제된 티켓 링크 0).
  서버 `taam_pay_link_attach_ticket(청구, 회차, 인원, 회원?, 대체할 MAN-?, 메모, 알림)`(슈퍼어드민·서버 · `_taam_fee_caller_ok`): ⓐ 좌석 행이 없는 결제(자유 금액·티켓) → **그 회원 소유 LINK- 좌석 행**(price 정가×인원 · 협의 금액은 좌석 행에 안 적고 `priceOverride` 표시만 · 대행비 스냅샷 `agencyFee/agencyPay` — 환불 견적 D-31 이 뺀다 · `convertedFrom`)을 만들고
  고른 수동 좌석(MAN- · 같은 회차 · manual/active)은 **같은 트랜잭션에서 취소**(자리를 넘긴다 · 정원 두 번 안 먹게 · 없으면 빈 자리에 — 꽉 찼으면 TICKET_SOLD_OUT) ⓑ 좌석은 있는데 회원 것이 아닌 결제(비회원 티켓 링크 · 소유자 이전 보류 `memberUidPending`) → 그 행을 회원에게(user_id · memberUid).
  청구는 **티켓 링크로**(purpose ticket · link_invite · user_id · 제목·부제 = 회차 · payload 에 원래 제목 `orig_title`·`attached_from`) — 환불은 티켓 규정(링크 초대 견적) · 환불되면 좌석도 풀린다(링크 초대 트리거) · 판매 현황은 결제 링크 채널로 센다. 어드민 메모 한 줄. 중복 가드는 그대로 — 막히면 앱이 「🔓 구매 규정 예외」를 권한다.
  회원에게 알림함 「예약이 등록되었습니다」 + 푸시 세 벌(`_taam_member_push` — `app_config.restock_push` 의 Vault 이름·URL 재사용 · send-push `uid:` · 서버 호출은 어느 대상이든 된다). 목록 `taam_pay_link_unattached`(reason no_seat · not_member · transfer_pending).
  **결제되면 회원에게 알린다** — `trg_taam_pay_link_member_notify`(AFTER UPDATE OF status · 청구에 회원 user_id 가 있을 때): 티켓(좌석이 회원 것으로 붙었을 때만) 「예약 결제가 완료되었습니다 · … N인 — 예약 내역에서 확인하실 수 있습니다」(url 구매내역) ·
  멤버십 「멤버십 결제가 완료되었습니다 · 금액 — 감사합니다」 · 그 밖(자유 금액 · 이전 보류) 「결제가 완료되었습니다 · 제목 · 금액」. 금액은 **결제 통화 그대로**(원화·환율은 회원에게 안 적는다) · 결제 확정을 막지 않는다(warning).
  앱: 연결 화면 `plAttachOpen`(결제 · 회원(결제에 적힌 회원 / 검색) · 회차 · 인원 · 「대신할 수동 좌석」(그 회차 MAN- 목록) · 메모 · 알림) — 입구: 결제 링크 목록의 「⚠ 회원 예약 내역에 안 보이는 결제 N건」 띠·줄의 「🎫 예약으로 연결」 · **캘린더 날짜 상세의 수동 좌석 줄 「💳 결제 링크와 연결」**.
  캘린더 회원 구매 줄에 「🔓 추가 구매 허용」(협의 구매 `pxOpen`) — ⚠ 10-22 에 넣은 구매자 상세 시트(`tcalShowBuyer`)는 **어디서도 열리지 않는 옛 코드**였다(버튼이 안 보였다) · 이제 실제 날짜 상세 줄에.
  예방: 자유 금액 폼에 「좌석 예약 결제는 🎫 티켓 좌석으로」 안내 · 회원을 고른 자유 금액 링크는 만들기 전에 묻는다. 알림함 EN/JA(`_NOTIF_TITLES` · `_notifL10nBody`). `_taamBusyNow` 에 `plAttachPopup`. 결제 링크 목록은 순번으로 늦게 온 옛 응답을 버린다.
  **적대 리뷰(배포 전 · 3 렌즈 → 확정 반영).** ① **결제 링크 좌석(LINK-)의 「인원」 변경이 카드 돈을 예치금으로 돌려줬다** — `taam_change_party_size` 는 카드 표시(cardPaid·paidBy)가 없는 좌석을 예치금 결제로 보고 줄인 몫을 예치금에 넣는다 · 그 뒤 링크 환불 견적은 줄어든 인원으로 대행비를 덜 뺀다(돈 두 번 · 10-18 회원 티켓 링크부터 · 에릭 연결로 첫 실제 행) →
  캘린더 LINK- 줄에 「인원」 없음 + 서버 `trg_taam_guard_link_pax`(LINK- party_size 고정 · `LINK_PAX_CHANGE` · SQL Editor 는 `set local taam.link_pax_ok='1'`) + `trg_taam_guard_ledger_card_pax`(원장 ticket_pax_change 가 LINK-/KSK- 면 거절). 인원을 바꾸려면 링크를 환불하고 새로 만든다.
  ② **링크 환불 견적 `taam_link_invite_refund_quote` 가 누구에게나 열려 있었다**(20260929 부터 · authenticated · 호출자 검사 없음) — 매장 어드민이 자기 매장 LINK- 행의 chargeId 로 협의 금액·payment_key 를 읽었다(캘린더 × 의 확인창) → 본문 첫 `begin` 뒤에 슈퍼어드민·서버만 검사 한 줄을 덧댄다(`PLMV_QUOTE_GUARD` · 이미 있으면 그대로) · 캘린더 LINK- × 는 슈퍼어드민만(끊기·환불 RPC 도 슈퍼어드민 전용이라 매장 어드민에겐 원래 안 됐다).
  ③ 회원 결제 알림이 **대관 정산 청구**에도 갔다 — 「구매자 불러오기」가 운영 행(KSK-·비회원 LINK-)의 어드민 uid 를 실어 매장 어드민 폰에 정산 금액이 갔다 → 회차 있는 비링크 청구 제외 · role user 에게만. ④ `taam_admin_push` 가 anon·회원 실행 가능(20261013 부터 public 만 막힘 — 아무나 슈퍼어드민 폰에 글을 보냈다) → anon·authenticated 회수(부르는 곳은 전부 security definer).
  ⑤ 예치금 반환 관리(`getDmItems`)가 카드 결제 LINK-/KSK- 좌석을 예치금 티켓처럼 「반환」 대상으로 보여 줬다(비회원 LINK- 는 만든 어드민의 예치금으로) → KSK-·비회원 LINK- 는 목록에서 빼고, **회원 소유 LINK- 는 남긴다**(「⏰ 시간 변경」이 그 목록에만 있다 · 2차 리뷰) — 반환·환불 처리 버튼 대신 「💳 결제 링크(카드) 결제 — 환불은 결제 링크 목록」 안내(`_dmIsCardLink` · `openDmPopup` 도 막음 · 반환 예정 금액에서 제외). ⑥ `/?open_ticket_hist=1` 을 아무도 안 읽었다 → 알림 클릭·부팅 둘 다 티켓 구매 내역(`_taamOpenTicketHistFresh` — 열고 `loadPurchase` 로 다시 읽어 그린다 · 켜져 있던 앱은 연결 전 목록이라 방금 붙은 예약이 안 보였다) · 부팅은 스플래시와 **openMain 뒤**(`window._taamMainOpenedAt` — openMain 이 시작할 때 이 페이지를 숨겨, 스플래시를 건너뛰는 웹·PWA 열린 탭에선 먼저 열었다 바로 닫혔다 · 2차 리뷰).
  ⑦ 「알림 전체 끔」 무시 → `_taam_member_push` 가 notif_prefs.all=false 면 건너뜀. ⑧ EN/JA 문구의 한국어(멤버십 제목 · 매장 이름) → 서버 i18n · 알림함 정규식 + `_tbRestName`. ⑨ 회원 「구매 일시」 = 연결한 날 → 결제한 날(created_at = approved_at). ⑩ 판매 현황 「⚠ 판매액과 다름」 → 연결 때 payload.price_override(외화는 **결제 통화로** `taam_ticket_price_fx` 정가와 비교 — 원화 정가와 비교하면 정가로 낸 외화 결제도 「수정」이 됐다 · 2차 리뷰).
  ⑪ 「예약 아님」 — 와인 추가분·보증금 같은 자유 금액 결제가 목록·띠에 영원히 남았다 → `taam_pay_link_unattached_dismiss(청구, on, 메모)`(payload.attach_dismissed · 되돌리기 p_on=false · 연결하면 지움) + 연결 화면 버튼. ⑫ 연결 화면: 회원 고르기·「바꾸기」가 인원·메모·알림 끔을 지웠다 → `_plaCollect` · 수동 좌석 목록이 오기 전 「연결」을 누르면 빈 자리에 새로 잡혔다 → 잠금(`_plaGoState`) · 못 읽었으면 캘린더에서 고른 좌석 그대로 ·
  수동 좌석을 고르면 인원을 그 좌석에 맞추고 줄이면 「N석이 다시 판매」 경고 · 연결 뒤 캘린더 다시 그림. 기각: 수동 좌석 인원 비교(설계대로 · 화면에 인원이 보인다) · 예치금 반환 이중 지급의 원인 자체(pre — ⑤ 로 목록에서 뺐다). 남긴 것(low): 비회원이 낸 좌석을 다른 회원에게 넘기면 그 회원이 kc_mine 으로 결제자 번호·게스트 초대 코드를 읽는다(슈퍼어드민이 고른 경우뿐).
  **2026-10-23 라이브 적용 ✅** — 자동 배포 #76 이 `20261023_pay_link_member_visible.sql` 을 적용(①~④ ⑥ ⑧ ⑨ ✅ · ⑦ 링크 환불 견적에 「검사 덧댐」 · ⑤ 회원 예약 내역에 안 보이는 결제 **1건** = 에릭 · `state=ok`). 앱 빌드 `2026.10.23-a` 는 Vercel 배포로(#280 훅 접수).
  회귀: `bash sql/_test/t_pay_link_attach.sh`(39건 — 리뷰 반영(외화 정가 연결 = 수정 아님) ·(정산 무알림 · 알림 끔 · 인원 가드 · 견적 가드 · admin_push 회수 · 예약 아님 · 구매 일시) · 결제 알림 셋(자유 금액·멤버십·티켓) · 회원 없는 결제 무알림 · 목록 · 권한 · 정원 꽉 참 · 없는 MAN- · 날짜 없는 회차 · 회원 불일치 · 회원 없음 · 멤버십 · 미결제 · 에릭 연결(MAN- 대체 · 좌석 행 모양 · 대행비 $74.50 · 청구 전환 · 메모 · 알림 · 정원 4/4 · 재연결 거절 · 환불 견적 $1,651.00 · 환불 → 좌석 취소) · 중복 가드 → 규정 예외 뒤 통과 · 비회원 좌석 → 회원 이전 · 다른 회차 거절 · 이전 보류 알림 문구 · 재실행) · 스크래치 `plattach/pla.js`(22건) · `rv9ui/oth_boot.js skip|fresh`(부팅 딥링크) · `rv9ui/oth_stale.js`(알림 클릭 다시 읽기).
- 회귀: `bash sql/_test/t_pay_link.sh`(77건 — 금액 규칙 · 세 용도 · 위임 · 권한(매장 어드민 회원 지정 거부) · 공개 RPC · 결제→기록·알림 · 환불→기록 삭제 · 회원 소유 이전 · 중복 선검사(가드와 같은 식 · 실제 가드 설치) · 이전 실패 보류(실제 가드 · 코드만) · PAYH- 플래그 구멍 · 기록 실패 경로 · 어드민 메모 표 · 금액 수정·변경) · 스크래치 `paylink.js`(126건 · 화면 · 3차 환율·이름·메모 · 금액 수정 · 확정 해외 정가 · 2차·3차 리뷰) · `dupguard.js`(21건 · 운영 행 판정·구매내역 카드) · `paypage.js`(35건 · /pay 네 용도 + 옛 정산 청구 + 실패 사유 재번역).

### 비회원 손님 — 알림톡 리마인드 · 게스트 회원 초대 (2026-10-19)

결제 링크로 카드 결제한 비회원(LINK- · memberUid 없음)과 캘린더 「수동 추가」 손님(MAN-)은 앱 계정이 없어 방문 리마인드(푸시)를 못 받았다. 운영 결정(2026-10-19): **알림톡으로 보내고, 결제 완료 화면에서 게스트 회원 가입을 권한다.**
- **알림톡 리마인드** — `20261019_guest_reminder.sql`(실행 필요): 표 `guest_remind_log`(티켓·남은 일수 열쇠) · `taam_guest_reminder_targets()`(status active|manual · 손님 번호 9자리↑ · 비회원 LINK- 또는 MAN- · 방문 **3일 전·1일 전** · 아직 안 보낸 것 · 서버·슈퍼어드민만) ·
  `taam_guest_reminder_mark()`. Edge `notify-visit-reminder` 가 회원 푸시 뒤 ③ 손님 알림톡을 솔라피로 보낸다(`notify-guest-booking` 과 같은 호출 · **대시보드 배포 필요**) — 시크릿 `KAKAO_TEMPLATE_GUEST_REMIND`(카카오 비즈니스 채널 템플릿 id · 변수 `#{name} #{shop} #{date} #{party} #{dday}`) ·
  국내 번호(010 등)만, 해외 번호는 `skip(해외번호)` 로 기록 · 템플릿이 없으면 기록하지 않고 건너뛴다(설정되면 그때 나간다). 응답에 `guest:{sent,failed,skipped,reason}`. 회원 소유 LINK-(memberUid)는 회원 푸시가 맡아 두 번 안 간다. 회귀 `t_guest_reminder.sh`(9건).
- **게스트 회원 초대** — `20261019_guest_invite.sql`(실행 필요): 티켓 링크 결제가 paid 가 되면(`trg_taam_guest_invite_on_paid` · 비회원 · 결제자 번호 있음) `invite_codes` 에 **A 등급 초대장**(코드 `G`+7자 · 번호에 묶임 · `invited_by` 'pay_link' · 30일 · 같은 번호의 살아 있는 초대장은 재사용)을 만들고
  `payload.guest_invite_code` 에 적는다. `taam_kashikiri_charge_public`(md5 가드 교체)이 paid·비회원 청구에 `guest_invite{code,expires_at}` 를 주고 `/pay` 완료 화면이 「게스트 회원으로 가입하기」(초대 코드 + 앱 링크 `/?invite=코드`)를 그린다(퍼널 대신). 앱의 `?invite=` 는 **종전 `_autoFillInviteFromUrl`**(코드 화면 열기 · 입력칸 채움 · verify-invite welcome)이 그대로 처리한다 — 따로 부팅 블록을 두지 않는다(먼저 `replaceState` 로 지우면 그 경로가 코드를 못 읽는다 · 적대 리뷰). 재사용한 초대장의 만료는 그 초대장의 실제 `expires_at`.
  **가입하면 티켓이 붙는다** — `taam_guest_attach_tickets(uid, code, phone)`: 그 청구의 LINK- 좌석 행 `user_id` 를 새 회원으로, `extra_data.memberUid` 를 적는다(그 뒤로 회원 행 — 리마인드·중복 가드·구매내역·첫 구매). 부르는 곳: `invite_codes.used` 가 true 로 바뀔 때(consume-invite · 회원은 **번호 → 이메일(`used_by_email`/`invitee_email` ↔ `profiles.email` · 이메일 OTP 로 가입한 해외 손님) → `member_id`** 순으로 찾는다) · `profiles` INSERT(가입 번호 = 결제자 번호 · 게스트 초대가 있는 청구만). 둘 다 실패를 삼킨다(가입을 막지 않는다).
  등급은 A(게스트 · 90일 · `trg_taam_guard_membership_tier` 가 초대코드 값으로만) · 가입 문지기(`trg_taam_guard_signup`)는 초대장 번호와 OTP 번호를 대조한다. 회귀 `t_guest_invite.sh`(18건 · 이메일·member_id 붙이기 · 재사용 만료 · 이미 새 판·모르는 판) · 스크래치 `paypage.js`(38건 · 게스트 블록) · `invboot.js`(1건 · 종전 경로).

### 링크 초대 — 비회원·해외 손님을 티켓 회차에 태우는 길 (2026-09-29)

초대 화면의 「🔗 링크 초대」. 이름·번호·통화(₩/¥/$)·환율만 적으면 `taam_link_invite_create` 가
① `tickets` 에 `LINK-` 홀드(좌석 즉시 차감) ② 대관 정산 테이블에 회차·팀·청구(`link_invite=true`) ③ `/pay/?t=` 링크를 만든다.
금액은 **서버가** `taam_ticket_price_krw`(식사비+대행비+주류)×인원 으로 센다 — 앱이 보낸 금액을 믿지 않는다.
결제 승인(kashikiri-confirm → `paid`)이 되면 `trg_link_invite_on_charge` 가 홀드를 `active` 로 바꾸고, 링크가 끊기거나
만료·환불되면 좌석을 푼다. 예치금·원장은 전혀 건드리지 않는다 — 카드 돈은 토스로 간다.
취소 규정은 회원과 같다: `taam_link_invite_refund_quote`(30분 전액 · D-31 대행비 제외 · 그 뒤 0) → Edge `kashikiri-refund` 가
통화별 MID 시크릿으로 토스 (부분)취소 → `taam_link_invite_mark_refunded`. 캘린더의 × 가 이 순서를 탄다.
회귀: `bash sql/_test/t_link_invite.sh`. 옛 회원 초대(예치금)는 `riPay` 그대로다 — 갈래를 섞지 말 것.

**정산 링크의 외화는 외화로 적는다 (2026-09-29 밤, `20260929_kashikiri_send_fx_input.sql`).** 종전엔 금액 칸이 언제나 원화였고
서버가 ÷환율로 달러를 만들어 「$1,680 을 보내려다 $1,679.85 가 나갔다」. 이제 보내기 화면에서 $·¥ 를 고르면 그 통화로 적고
(달러 센트·엔 정수), 아래에 ≈ 원화(×회차 환율)가 뜬다. 서버는 `pay_amount` 를 승인액으로 그대로 쓰고 `amount_krw = round(외화×환율)`
로 만든다 — 브라우저가 준 원화는 믿지 않는다. 원화 줄은 종전 나눗셈 경로. 정산 좌석(KSK-) 행의 `price` 는 0 — 정산·링크 결제액은
티켓 금액과 별개이고 캘린더는 슈퍼어드민일 때 `kashikiri_charges` 에서 실제 결제액을 따로 읽어 「정산 결제」로 보여 준다.
회귀: `bash sql/_test/t_ksk_send_fx.sh`(7건).

### 정산·링크 결제가 끝나면 슈퍼어드민에게 알린다 (2026-10-13)

`kashikiri_charges.status` 가 paid 로 바뀌는 순간(`trg_taam_kashikiri_paid_notify`, AFTER UPDATE OF status, `20261013_kashikiri_paid_notify.sql`)
슈퍼어드민마다 `notifications`(type `kashikiri_paid`, 앱 라벨 PAID) 한 줄 + `taam_admin_push` 가 pg_net 으로 send-push 에 `role:superadmin` 한 번.
푸시 설정은 `app_config.restock_push` 의 Vault 시크릿 이름·URL 을 **재사용**한다(URL 의 함수 이름만 send-push 로 바꿔 쓴다). 설정·pg_net 이 없으면
인앱 알림만 가고 푸시는 조용히 건너뛴다. 본문은 「매장 날짜 시간 · 결제자 · 승인 통화 금액 (₩원화)」, 링크 초대면 제목이 「🔗 링크 초대 결제 완료」.
⚠ 알림이 결제 확정을 막으면 안 된다 — 예외는 전부 warning. 회귀: `bash sql/_test/t_ksk_paid_notify.sh`(8건). 연회비를 정산 링크로 받는 경우도 같은 표라 같이 잡힌다.
⚠ **2026-10-17 확인: 이 파일은 라이브에 올라간 적이 없었다.** 연회비 알림(`20261017_membership_fee_due.sql`) 설치 결과의 `push.reason` 이 「function public.taam_admin_push … does not exist」였다 — 즉 10-13 부터 정산·링크 결제 완료 알림도 실제로는 안 가고 있었다. **2026-10-17 SQL Editor 로 설치 완료**(①②③ ✅ · 슈퍼어드민 1명) — 이날부터 정산·링크 결제 완료 푸시와 연회비 알림 푸시가 간다.
→ **`supabase/migrations/` 에 파일이 있다고 라이브에 있는 게 아니다**(워크플로는 시크릿이 없어 돌지 않는다). 새 SQL 이 옛 함수에 의존하면 확인 표에 `to_regproc` 존재 검사를 한 줄 넣는다 — 연회비 알림 파일의 ⑧ 이 그 예.
⚠ **2026-10-19 확인: 설치 뒤에도 푸시는 한 번도 안 갔다 — 인앱 알림만 갔다.** `taam_admin_push` 는 Vault 의 legacy service_role JWT 를 Bearer 로 send-push 를 부르는데, send-push 의 서버 호출 판정이 **환경변수 `SUPABASE_SERVICE_ROLE_KEY` 와 글자 그대로 같을 때만**(`t === SERVICE_KEY`)이었다.
두 문자열이 달라(새 형식 키 · 복사 때 붙은 공백 등) `callerUserId` 도 없는 요청이 되어 `401 {"error":"로그인이 필요합니다"}` 로 끊겼다 — 10-18 에릭 결제 링크 때 `net._http_response` 에 그대로 찍혔다. Edge→Edge(notify-restock 등)는 같은 환경변수를 쓰니 멀쩡했고 **DB→send-push 만** 죽어 있었다.
→ send-push 가 토큰의 `role` 클레임이 `service_role` 이면 서버 호출로 본다(크론 함수 셋의 `isServiceCaller` 와 같은 방식 · 서명은 게이트웨이가 확인 · `config.toml` 에 `[functions.send-push] verify_jwt = true` 를 명시 — **끄면 위조 가능**). 점검은 SQL Editor 에서 `select public.taam_admin_push('테스트','DB→푸시 점검','/','test-'||extract(epoch from now())::bigint,'admin');` 뒤 `net._http_response` 최신 줄이 `200` 이고 슈퍼어드민 폰에 푸시가 오는지로 — `request_id` 만 보고 믿지 않는다.

### 🔔 슈퍼어드민 알림 → 그 내역 화면 (2026-10-25 · 빌드 `2026.10.25-a` · `20261025_notif_payload_cap.sql`)

「알림 목록에서 항목을 누르면 그 내역에 맞는 화면으로 — 슈퍼어드민만」. 실제로 쓰는 알림 목록은 표지 종의 검은 시트(`tkOpenNotice` · `_notifRenderMerged` → `_notifRenderItems`)뿐인데,
줄에 클릭이 아예 없었고 서버 알림의 type·url·payload 를 버리고 글자만 그렸다(흰 `notificationsListPage` 는 2026.07 부터 여는 곳이 없다). 슈퍼어드민 알림은 거의 전부 url 이 `/` 라(taamNotifyAdmins 기본값 · 서버 트리거)
**url 로는 못 가르고 type + payload 로** 정한다 — `_anRoute(n)` → `{label, go}` · 줄 아래 「… 보기 ›」 · 회원·매장 어드민은 종전 그대로(누를 곳 없음 · payload 도 안 읽음).

| 알림 (type) | 가는 곳 |
|---|---|
| ticket_purchased · ticket_cancelled · pax_change · time_change_ack | 「예약」 탭(`rvScreen`) 구매번호 검색 · 그 줄 펼침. **예약 탭에 없으면**(취소된 회원 구매 PAYH- · 방문일 빈 카드 결제 행 — `_tbLoad` 가 뺀다) 그 행 소유자의 회원 원장 티켓 탭 + 안내 |
| ticket_cancelled_card_refund | 예치금 관리 「카드환불」 탭의 그 카드(`data-pid` · 한 번만 쓰는 `window._dmOpenTab`) |
| deposit_granted_admin · deposit_charged · seat_hold_convert_failed · ledger_apply_failed · capacity_refund_unknown · invite_confirm_blocked · member_joined · member_left | 회원 원장(예치금 탭) · sync_from_storage 는 티켓 탭 |
| invite_paid · invite_cancelled · invite_recalled · invite_sent | 티켓 캘린더의 방문일(payload.visit_date · 없으면 회차 날짜 · 그래도 없으면 초대 행을 읽는다 — 시트를 열어 둔 채, 닫거나 다른 줄을 누르면 버림) · `window._tcalFocusNext` 를 `tcalInit` 이 한 번 쓴다 |
| ticket_restock · ticket_open | 티켓 캘린더의 그 회차 날짜(`_tkYMD`) |
| ticket_upload_request | 승인 대기의 그 카드(`data-tid`) |
| kashikiri_paid | 정산(회차 있고 링크 아님) → 대관 정산 그 회차 · 소유자 이전 실패 → 아직 연결 대기면 「예약으로 연결」, 처리됐으면 결제 링크 목록 + 「이미 처리된 결제」(대기 목록을 **못 읽었으면** 그렇게 말하지 않고 연결 화면) · 그 밖 → 결제 링크 목록의 그 줄(`data-pl-charge` · 최근 40건) |
| membership_fee_due | 연회비 납부 시기 · 「연회비 자동 기록 실패」(charge_id) → 결제 링크 목록 그 줄 |
| guest_expiry_admin | 멤버십 · 게스트 「게스트」 탭(+90일) |
| fx_alert | 환율 설정 |
| 회원 몫 url(?ticket= · ?ri_pay= · open_ticket_hist · open_deposit_hist · ?tchg= · ?feedue) | 종전 `handleNotifClick(url)` — 「열기 ›」 |

- 화면 전환: `_anBase()` = 시트 닫기 → `openAdmin()` 바탕(GNB 숨김) → `_acLastTab='today'`(뒤로가기 = 대시보드) → `_acCloseOthers(null)` · `_acNavHold(700)` 을 250ms 뒤 푼다(오래 붙잡으면 도착 직후 ← 가 빈 「전체 메뉴」에 멈췄다 — 리뷰).
  팝업(결제 링크 · 연결 · 납부 시기 · 환율)은 회원 앱 위에 바로 — 닫으면 표지로. 비동기 이동은 `window._anNavSeq`(줄 누름·시트 다시 열기에서 올림)로 늦게 온 결과를 버린다.
  ⚠ 콘솔 안의 이동(← · 탭 · ✕)은 순번을 안 올린다 — 그래서 `_anGoRv` 는 「예약 탭이 그 판(`_rvState`)으로 아직 떠 있나」도 본다(로딩 중 ← 로 나갔는데 늦은 조회가 원장으로 끌고 가던 것 · 2차 리뷰).
- ⚠ **새 슈퍼어드민 알림 종류를 만들면 `_anRoute` 에 한 줄**, 읽는 payload 키는 `_AN_PKEYS` 에도 — 시트는 슈퍼어드민에게 payload 통째가 아니라 그 키만 PostgREST JSON 경로(`pk_키:payload->>키`)로 읽는다(`_anPackPayload` 가 되묶는다 · 그 select 가 실패하면 종전 칸만).
  통째로 안 읽는 이유: `taam_notify_admins` 는 로그인한 회원 누구나 부를 수 있고(시간당 30건) payload 는 자르지 않았다 → 회원이 수 MB 를 슈퍼어드민 알림함마다 꽂을 수 있었다(종 열 때마다 내려받음 · 리뷰).
  서버도 막는다: `trg_taam_notif_payload_cap`(notifications BEFORE INSERT/UPDATE OF payload · **회원 세션만** — 서버·슈퍼어드민은 그대로): 문자열 값 500자 · 전체 16KB 넘으면 짧은 스칼라만 + `payload_truncated`. 알림은 막지 않는다.
- **2026-10-25 라이브 적용 ✅** — 자동 배포 #78 이 `20261025_notif_payload_cap.sql` 을 적용(①②③ ✅ · ④ 지금 16KB 넘는 알림 0건 · `state=ok`). 앱 빌드 `2026.10.25-a` 는 Vercel 배포로(#283 훅 접수).
- 덤으로 고친 것: 시트가 열린 채 로컬 기록이 늘면 로컬만 다시 그려 서버 알림 줄이 사라졌다 → 서버 캐시와 같이.
- 안 한 것(필요하면): 토스트 탭 이동(지금은 읽음 처리만 — 일하는 중 실수로 끌려가지 않게) · 슈퍼어드민 푸시 탭(url 이 `/` 라 앱만 열린다 — 알림을 만들 때 url 을 실어야 한다).
- 회귀: 스크래치 `annav/an.js`(36건 — 종류별 도착 화면·포커스 · 3초 뒤에도 맨 위 · ← 대시보드 · 회원 무변화 · 취소 구매 원장 폴백 · 처리된 연결 · 게스트 · 늦은 초대 조회 취소 · select 칸 · pk_ 복원) · `bash sql/_test/t_notif_payload_cap.sh`(15건).
  적대 리뷰(4 렌즈 · 12 에이전트 → 확정 8 · 전부 반영) · 수정분 2차 리뷰(7 에이전트 → 확정 2 · 반영: 콘솔 안 이동 뒤 늦은 원장 이동 · 조회 실패를 「처리됨」으로 말함 — 새 검사 4개는 고치기 전 판에서 ❌).

### 정산 결제도 좌석을 잡는다 — 「티켓 연결」은 라벨이 아니다 (2026-09-29)

정산 회차(대관 정산)에 「티켓 연결」을 눌러도 회차 행에 `ticket_product_id` 만 적히고 좌석은 안 잡혔다. Takiya 3/20 에
Trina Chin 이 $1,679.85 를 결제했는데 캘린더에 없고 잔여 4 그대로였다. 이제 `_taam_ksk_seat_sync(event_id)` 가
**paid 인 정산 청구마다 `tickets` 에 `KSK-` 행 하나**(인원 = 조 `pax`, 조 없으면 1)를 만들고, 청구가
취소·환불·만료되면 그 행을 `cancelled` 로, 연결을 끊거나 바꾸면 옛 행을 접고 새 티켓에 다시 만든다. 부르는 곳은
RPC `taam_kashikiri_link_ticket`(앱 버튼) · 청구 status 트리거 · 조 pax 트리거 · 회차 `ticket_product_id` 트리거.
정원이 모자라면 예외로 깨지 않고 `short` 에 적어 돌려준다 — 돈은 이미 받았으니 어드민이 정원을 늘리고 다시 누른다.
`KSK-` 행의 `user_id` 는 회차 작성자다(사람이 아니다) — 캘린더는 uid 로 묶지 않고, × 대신 ⓘ 만 둔다. 좌석의 주인은
청구 상태다. 링크 초대(`LINK-`)는 자기 트리거가 있으므로 여기서 건드리지 않는다. 회귀: `bash sql/_test/t_ksk_seat.sh`(17건).

**2차(같은 날 밤, `20260929_kashikiri_seat_sync2.sql`) — 라이브에서 바로 밟은 것 셋.** ① 1차는 매진·슬롯·인원만 `short` 로 삼키고
나머지는 예외로 올려서 Takiya 가 `SOLO_LIMIT`(1인 구매 한도) 에서 통째로 실패했다. ② 그 예외가 **청구 status 갱신 트리거 안**에서
나면 `mark_paid` 가 실패한다 — 토스는 승인됐는데 우리 기록은 pending 인 최악의 모양. ③ 티어 가드는 `auth.uid()` 만 보므로
Edge(service_role) 경로의 KSK- 행은 M·T 전용 티켓에서 `TIER_BLOCKED`. → 동기화는 insert 실패를 **무엇이든** `short`(kind
capacity|error) 로 적고, 트리거 3종은 예외를 `raise warning` 으로 삼킨다(결제 확정을 좌석이 막지 않는다). 티어 가드에 `KSK-`·`LINK-`
면제를 넣고, 정원 트리거는 `taam.seat_engine_bypass=1` + `KSK-` 면 **총 정원(①)만** 본다 — 1인 한도·허용 인원·조각 차단은 회원 자가
구매를 다듬는 규칙이라 어드민이 매장과 잡은 자리에는 안 건다. 라이브 함수 둘을 바꾸므로 **본문 md5 가 저장소 원본과 같을 때만**
교체하고 다르면 건너뛰고 ❌ 로 알린다 (`prosrc` 는 닫는 `$$` 앞 줄바꿈까지 포함한다 — md5 셀 때 빠뜨려 한 번 틀렸다).
회귀: `bash sql/_test/t_ksk_seat2.sh`(실제 정원 트리거 v3 와 티어 가드 원본을 픽스처에 올린다).

**4차·5차(같은 날 밤, 적대 리뷰 33개 에이전트 검증 결과)**: 회차 잠금을 읽기 **전에** 잡고, 조 인원을 늘릴 땐 총 정원을 세서
넘치면 `short`(RESIZE_OVER_CAPACITY), 트리거는 short 를 warning 으로 남기고, 티어 가드의 KSK-/LINK- 면제는 **증명**(동기화
플래그 또는 실제 정산 청구)이 있을 때만, INSERT 가드는 회원 홀드를 PAYH- 로만(옛 MAN- 흉내 구멍도 닫힘), 연결 RPC 는 슈퍼어드민이
아니면 **회차 매장·티켓 매장 둘 다** 권한, KSK- 행 `price` 는 정산 청구액이 아니라 **정가×인원**(정산 금액은 매장 어드민이
읽는 tickets 로 새면 안 된다), 회차 날짜·시간 변경과 청구·회차 삭제도 좌석이 따라간다. 인원은 `taam_ksk_seat_set_pax`(캘린더
「인원」 버튼)로 — 조가 없으면 한 명짜리 조를 만들어 붙인다. 방문 리마인드는 KSK-/LINK-/MAN- 행을 뺀다.
`t_ksk_seat2.sh` 49건.

### 티켓 오픈 알림 문구 — 일정과 이름만, 전부 나열 (2026-10-14 운영 결정)

슈퍼어드민 「📢 티켓 오픈 알림 발송」(`tbBuildMessage`)의 문구는 **금액·잔여석·이모티콘 없이 일정과 매장 이름만** 적는다.
줄마다 「연도 월 일(요일) 시간 · 매장」 — **연도는 언제나**. 단일도 같은 방식: 제목 「새 티켓 오픈」 + 한 줄, 복수는 「새 티켓 N건 오픈」 + 한 줄에 한 회차
(날짜순). 예: 「2027년 5월 21일(금) 19:00 · 카타오리」 · EN 「Fri, May 21, 2027 19:00 · Kataori」 · JA 「2027年5月21日(金) 19:00 · カタオリ」.
푸시 본문은 8줄까지 + 「외 N건」, 인앱 알림함(`preview`)은 전부.
EN/JA 는 같은 규칙으로 `i18n` 세 벌(send-push 가 기기 언어로 고른다 · 매장 이름은 `name_en`/`name_jp`). 저장된 인앱 알림은 한국어 한 벌이라
표시 때 `_notifL10nTitle/_notifL10nBody` 가 같은 규칙으로 다시 그린다(날짜 줄 정규식 · 「외 N건」). 요일·연도 도우미 `_tbDateStr`·`_tbKstYear`·`_tbRestName`.
회귀: 스크래치 `tkopen.js`(8건). 금액·잔여석을 다시 넣자는 요청이 오면 2026-10-14 결정을 먼저 말한다.

### 취소표(재입고) 알림 — 매진이던 회차에 자리가 나면 전원 푸시 (2026-09-29 밤)

`supabase/migrations/20260929_ticket_restock.sql` + Edge `notify-restock`. 좌석이 풀리는 길은 전부 `tickets` 를 지나
`trg_sync_ticket_soldout` 이 `ticket_products.status` 를 soldout→active 로 되돌리고, 어드민 토글·연장·재편집은 status 를
직접 쓴다 — 그래서 **status 의 soldout→active 전이**가 유일한 길목이고 거기에 `trg_ticket_restock` 을 걸었다.
**지연 제약 트리거(DEFERRABLE INITIALLY DEFERRED)** 다: 한 트랜잭션 안의 soldout→active→soldout 왕복(링크 초대의 만료 홀드
정리 + 새 홀드, 재연결)을 즉시 트리거는 「자리가 났다」고 잘못 본다. 커밋 직전에 `taam_ticket_restock_check` 가 다시 읽는다 —
active · 판매 공개 · 방문일 안 지남 · 잔여 > 0 · flex 면 채울 수 있음(`taam_seat_fillable`) · 60분 쿨다운. 통과하면
`ticket_restock_events` 에 pending 한 줄 → `taam_restock_kick()` 이 Edge 를 부른다(`app_config.restock_push` 에 Vault 시크릿
**이름**과 URL — 값은 Vault 에만) → Edge 가 `taam_ticket_restock_process()` 로 수신자를 정하고(탈퇴 아님 · `notif_prefs.restock`
·`all` 안 끔 · `min_tier` 통과 · `taam_ticket_visible` · 그 회차 미보유) 인앱 알림을 넣고, 회원 uid 마다 + 슈퍼어드민 `role:` 로
한 번 send-push(category `ticket_restock` → 설정 키 `restock`). 1분 크론이 같은 kick 을 불러 놓친 것을 줍는다.
못 잡는 것(의도): 등급별 우선 공개 시각(서버가 모른다) · 고정 슬롯(1·2·4인석)이 종류별로 매진된 것 · `daegwan_manual`.
알림 url `/?ticket=<id>` 는 이날부터 앱이 읽는다(`_taamOpenTicketById` · 부팅 시 `_taamPendingTicket` → `pcalRenderAll` 뒤 열기).
회귀: `bash sql/_test/t_restock.sh`(20건).

### 방문 리마인드 — 실제로 어떻게 나가나 (2026-09-29 점검)

`sql/visit_reminder.sql` `taam_visit_reminder_notify()` 가 방문 **7·3·1일 전** 알림 행을 만들고(회원 설정 `remind7/3/1`, 기본
3·1만), Edge `notify-visit-reminder` 가 uid 마다 send-push — 대시보드 크론이 매일 11:00 KST 에 Edge 를 부른다(저장소엔 없다).
~~문구: 「내일 방문 예정입니다 / 3일 뒤 방문 예정입니다 / 방문 7일 전입니다」 + 「{매장} · {시간} 예약이 내일입니다.」 EN/JA 는 Edge 가 만든다.~~ → **2026-10-27 부터 아래 「예약 안내」**.
**문구 = 「예약 안내」 (2026-10-27 운영 요청 · `20261027_visit_reminder_format.sql` · 빌드 `2026.10.27-a`).** 제목 「예약 안내」 · 본문 `[레스토랑] : 미토우` / `[날짜] : 2026년 9월 10일(목)` / `[시간] : 오후 6:30` / `[인원] : 5`
(며칠 전이든 같은 모양 · 시각을 못 읽으면 적힌 그대로 · 비면 그 줄 없음) + 매장이 적었으면 빈 줄 뒤 `[유의사항]` · `[안내말씀]`(없으면 그 칸이 아예 안 나간다 — 지금은 넷만). EN `Reservation Reminder` · [Restaurant]/[Date] Thu, Sep 10, 2026/[Time] 6:30 PM/[Guests]/[Notes]/[Message] ·
JA `ご予約のご案内` · [レストラン]/[日付] 2026年9月10日(木)/[時間] 午後6:30/[人数]/[ご注意事項]/[ご案内]. 매장 이름 EN/JA 는 `restaurants.name_en/name_jp`(없으면 한국어) · 매장 문구 EN/JA 칸이 비면 한국어 문구.
- **문구는 서버 한 곳에서** — `_taam_visit_remind_msg(rest{ko,en,ja}, 방문일, 시각, 인원, 문구)` → `{ko,en,ja}{title,body}`. `taam_visit_reminder_notify` 교체(md5 가드 `3b8771fc…` · 표시 `VR_FMT_20261027` · 대상·설정·중복 규칙은 20261019 판 그대로)가 알림함 줄(제목·본문 = 한국어)과 payload `i18n` · `date` · `pax` · `rest_id` · `fmt:'v2'` 을 적고
  돌려주는 줄에 `i18n` 을 싣는다 → Edge `notify-visit-reminder` 가 있으면 그대로 푸시(없으면 옛 `build()` 문구 — 옛 SQL 판 대비). 매장 id = `tickets.restaurant_id`, 비면 회차 `ticket_products.rest_id`.
- **매장 문구 표 `restaurant_visit_notes`**(매장 id PK · notice/message + `_en`/`_ja` · 칸마다 300자 · 전부 비우면 줄 삭제 · 직접 접근 없음) — RPC `taam_visit_notes_get(매장 | null=전부·슈퍼어드민)` · `_set(매장, jsonb)` · `_preview(매장, jsonb)`(그 매장의 가장 가까운 회차 날짜·시각 · 2인으로 같은 함수가 그린다).
  권한 `_taam_rest_note_ok` = 슈퍼어드민·서버(`_taam_fee_caller_ok`) 또는 그 매장 어드민(`taam_is_rest_admin` · `is_restaurant_admin_of`). 회원·다른 매장 어드민 FORBIDDEN.
- 앱: 「📩 방문 안내 문구 (예약 리마인드)」 — 슈퍼어드민 어드민 메뉴(매장 고르기 · 문구 있는 매장 ●) · 매장 어드민 메뉴 「레스토랑」 아래(자기 매장 고정 · `data-i18n partner.visit_notes`) · `vnOpen` · 미리보기 KO/EN/JA 탭(서버 미리보기 · 함수가 없으면 앱 사본 `_vrMsg` + 「서버 준비 필요」 · 저장 막음) · 다른 매장으로 갈 때 저장 안 한 문구를 묻는다 · `_taamBusyNow` 에 `vnPopup`.
  알림함: 영어·일본어 화면이면 시트가 리마인드 줄의 `payload->i18n->en|ja->>title|body` 넷만 함께 읽어 그 언어로(읽기 실패면 종전 칸 → 앱 규칙 `_vrL10nBody` 로 항목 이름·날짜·시각·매장 이름만 바꾼다) · 시트·토스트가 **줄바꿈을 더는 뭉개지 않는다**(`\s{2,}`→공백이 빈 줄을 지웠다) · 영어·일본어 화면은 다른 서버 알림도 `_notifL10nTitle/Body` 를 탄다(한국어 화면은 종전 그대로).
  슈퍼어드민 알림 설정의 「7일 전 리마인드 / 3일 전 / 하루 전」 미리보기도 새 문구(예시 미토우 2026-09-10 18:30 5인 · `_vrMsg`). ⚠ `_vrMsg` 는 서버 함수의 사본이다 — 규칙을 바꾸면 둘 다.
- **적대 리뷰(배포 전 · 4 렌즈 32 에이전트 → 확정 13 · 전부 반영 · `5e0e9a9`).** ① **회원 한 명이 그날 리마인드 전체를 멈출 수 있었다**(20261019 판부터) — 회원은 자기 알림 줄을 쓰고 고칠 수 있어(notif_insert · notif_update_own) `payload.days` 에 'x' 를 넣으면
  중복 검사 `(payload->>'days')::int` 가 터져 그날 회원 리마인드 전체 + 비회원 알림톡(Edge 가 rpc 실패에서 끝났다)이 빠졌다 → **글자 비교** `payload->>'days' = d::text` · Edge 는 rpc 가 실패해도 알림톡은 보낸다(응답 `ver:'vr-2026-10-27'`).
  ② **send-push 가 고른 언어 뒤에도 i18n 을 실어 보내** 웹 푸시 본문에 문구가 네 벌 — 매장 문구가 길면 aes128gcm 4096B 를 넘어 413 → `payloadFor` 가 고른 뒤 `i18n` 을 뺀다(모든 호출부 공통). ③ 공개 저장소라 **Actions 로그도 공개** — 테스트 발송 파일이 가장 가까운 실제 예약(매장·날짜·인원)을 찍었다 → 고정 예시만 · 점검은 날짜별 건수만.
  ④ 매장 문구 화면: 불러오는 중·불러오기 실패에 「저장」을 누르면 빈 칸 여섯 개가 가 **저장된 문구가 지워졌다** → 다 불러온 뒤에만 저장(`_vn.loaded` · `_vnSaveEnable`) · 실패 문구 「불러오지 못했습니다」 · 바깥에서 끌어 놓아도 안 닫힘(pointerdown 이 바깥일 때만) · 저장 안 한 문구가 있으면 닫기 전에 묻는다 · 글자 수는 코드 포인트(`_vnLen` = 서버 char_length) · 번역 스윕 제외(`data-no-tx`).
  ⑤ 알림함·토스트: 리마인드 줄은 `_vrPick` — 기호(①·→·★·☎) 그대로 · 영어·일본어면 서버 문구(payload.i18n / vr_* 칸) · **슈퍼어드민은 payload 의 다른 언어 문구를 믿지 않는다**(회원이 `taam_notify_admins` 로 같은 type 을 꽂을 수 있다) · 토스트 중복 열쇠에 티켓·일수(D-3·D-1 문구가 같아 D-1 이 버려졌다).
  ⑥ 매장 이름: 티켓에 적힌 이름 → 매장 등록 이름 → 언어별 「예약하신 매장 / Your reservation / ご予約」 · 일본어 이름은 `i18n_jp_approved=false` 면 안 쓴다(앱 `_tbRestName` 과 같다). ⑦ 테스트 발송은 Edge 를 지나지 않는다 — Edge 판은 Actions 의 `Deployed Functions` 와 응답 `ver` 로 본다.
- **2차(수정분만 · 3 렌즈 27 에이전트 → 확정 6 · 전부 반영).** ① **같은 `::int` 구멍이 게스트 만료 알림(매일 10:00)에도** — `taam_guest_expiry_notify` 의 중복 검사 두 곳 · 회원 누구나 `taam_notify_admins('guest_expiry_admin', …, {days:'x'})` 로
  슈퍼어드민 알림함에 꽂으면 그날 슈퍼어드민 알림 + 게스트 본인 알림(한 트랜잭션)이 전부 멈췄다 → `20261027_guest_expiry_days_text.sql`(라이브 본문 `pg_get_functiondef` 에서 그 비교만 글자 비교로 · 어느 판이든 · 모양을 못 찾으면 ❌ 건너뜀 · 권한 anon/회원 회수 · 회귀 `t_guest_expiry_days_text.sh` 12건).
  ⚠ **새 알림 함수를 쓸 때: 회원이 쓸 수 있는 칸(`notifications.payload` — notif_insert · notif_update_own · `taam_notify_admins`)을 `::int`·`::uuid` 로 바꾸지 말 것** — 글자로 비교한다. 서버만 쓰는 표(`kashikiri_charges.payload`)는 괜찮다.
  ② 토스트: `showToast(…, {raw:true})` — 서버가 그 언어로 만든 글은 `_toastSafeMsg`(영어 문구의 'does not exist' 를 기계 오류로 봐 「잠시 후 다시」로 바꿨다)·`_toastAutoMap`(TX)을 지나지 않고 `data-no-tx` · 같은 묶음 안 같은 티켓 리마인드는 가장 새것 하나(안 누른 D-3 + D-1 이 같은 문구로 두 번).
  ③ 입력 화면 순번을 창을 닫았다 열어도 이어 간다(앞 창의 늦은 응답이 새 창을 다른 매장 문구로 채웠다) · `_vrClean` 은 코드 포인트로 2000 자. ④ 테스트 파일 요약 줄도 리마인드와 같은 거름.
- **2026-10-27 라이브 적용 ✅** — 자동 배포 #81: `20261027_guest_expiry_days_text.sql`(① ✅ 교체 2곳 · ②③ ✅) · `20261027_visit_reminder_format.sql`(①~⑤ ✅ · ④ 교체 · md5 `ae6336f8…`) · 테스트 파일(슈퍼어드민 1명 · request 120 → **HTTP 200 · 성공 1**) · Edge `notify-visit-reminder`·`send-push` 배포.
  진단 3·4(`20261027_diag_visit_reminder3/4.sql`): 새 send-push 로 두 번째 테스트(유의사항·안내말씀 예시 · request 121 → **200 · 성공 1**) · **Edge 실제 경로**(크론과 같은 호출 · request 122 → `ver vr-2026-10-27` · ok · made 0 — 오늘 보낼 것 없음) · 회원 37명 중 7일 전 켬 2 · 나머지 기본.
  다가오는 발송(그날 11:00 KST): 11-05 7일 전 2건(켠 회원 없음 → 0) · 11-09/10 3일 전 2·2 · 11-11/12 하루 전 2·2 · 11-13 7일 전 1 · 12-16 3일 전 3 · 12-18 하루 전 3 …(살아 있는 회원 예약 90건 · 가장 가까운 방문 11-12). 앱 빌드 `2026.10.27-a` 는 Vercel 배포로(훅 접수 · 이 환경에서는 vercel.app 접속이 막혀 빌드 번호는 시크릿창으로 확인).
- **제목 = 매장·일수 (2026-10-27 운영 결정 · `20261027_visit_reminder_title.sql` · 빌드 `2026.10.27-b`).** 「예약 안내」 테스트를 받아 본 뒤 「예약 안내라고 하지 말고 (레스토랑 이름) 방문 (날짜) 전입니다 — 그래야 리마인드가 된다」 →
  추천안 셋 중 운영자가 고른 것: 7일·3일 전 **「미토우 방문 3일 전입니다」** · 하루 전 **「내일은 미토우 방문일입니다」**(「1일 전」 대신) · EN `Your visit to Mitou is in 3 days` / `… is tomorrow` · JA `味豆へのご来店まであと3日です` / `明日は味豆へのご来店日です` · 매장 이름을 모르면 이름 없이 · 일수 없음(미리보기 밖)은 「예약 안내」. 본문은 그대로.
  `_taam_visit_remind_msg` 에 `p_days`(6 인자 · 5 인자 판은 지웠다 — 둘 다 두면 5 인자 호출이 「not unique」) · `taam_visit_reminder_notify` 는 라이브 본문(md5 `ae6336f8…`)의 문구 호출에 `w.d` 만 더했다(표시 `VR_TITLE_20261027`) · 문구 화면 미리보기 = 하루 전 알림(내일 날짜) · 앱 사본 `_vrTitle` · 알림함 제목 번역(`_notifL10nTitleNum`).
  검토(2 렌즈 12 에이전트): 확정 = 문구 화면·메뉴 설명이 아직 「예약 안내」 → 고침 · 영어/일본어 제목의 일수가 끝이라 잠금화면에서 잘릴 수 있다 → 한국어 모양(운영 선택)과 맞춰 그대로.
- **슈퍼어드민은 캘린더 전 일정을 받는다 (2026-10-27 운영 요청 · `20261027_visit_reminder_admin.sql` · 빌드 `2026.10.27-c`).** 「티켓 캘린더에 우댕으로 수동 추가하는 건 내가 가는 일정 — 슈퍼어드민 계정으로 나도 알림 받게 · 슈퍼어드민은 전 일정 리마인드」.
  `_taam_visit_reminder_admin()`: 슈퍼어드민마다 · 일정마다 회원과 같은 문구 + **`[예약자] : 이름`**(넷째 줄 뒤 · 매장 문구 앞 · `_taam_vr_add_who` · EN `[Name]` · JA `[ご予約者]`). 일정 = tickets 확정(active)·수동(manual) 행 전부(회원 구매 · 초대 INV- · 결제 링크 · 정산 KSK- · **수동 예약 MAN-**)
  + **결제된 초대 중 좌석 행이 한 번도 없었던 것**(`i:` — 매진 회차·회차 없는 날로 보낸 초대 · 좌석이 반환·취소된 초대는 빼다 — 초대는 paid 로 남는다) + **수동 기록 `daegwan_manual`**(날짜만 · [시간] 줄 없음). 홀드·취소·만료·확정 대기 제외 · 테스트 계정이 회원으로 산 것 제외(운영 행은 그대로).
  며칠 전 = **슈퍼어드민 본인 알림 설정**(remind7/3/1 · 기본 3·1) · 중복 = 같은 일정(rkey `t:/i:/m:`)·일수 한 번 · 슈퍼어드민이 회원으로 산 티켓은 회원 리마인드 줄로 한 번만 · 글자 비교 · `via=taam_notify_admins` 로 꽂은 줄은 안 센다(회원이 슈퍼어드민 리마인드를 막을 수 있었다) ·
  **한 번에 슈퍼어드민마다 50건 상한**(넘친 수 `admin_skipped` + 알림함 「방문 리마인드 N건 상한 초과」 하루 한 줄 — 대량 수동 기록이 같은 실행의 손님 알림톡을 밀지 않게).
  `taam_visit_reminder_notify` 는 라이브 본문(md5 `3e902422…`) 끝에서 그것을 부르고 줄을 덧붙인다(표시 `VR_ADMIN_20261027` · **예외 블록 — 슈퍼어드민 몫이 실패해도 회원 리마인드는 그대로** · 응답 `admin_made`·`admin_skipped`) → Edge 가 그대로 푸시(응답에 두 건수 · `ver vr-2026-10-27b`).
  앱: 슈퍼어드민 알림함의 리마인드 줄 → 티켓 캘린더 그 날짜(`_anRoute` · payload.date) · 영어·일본어 알림함 `[예약자]` 번역(`_VR_LB.who`) · 토스트 묶음 열쇠 rkey.
  ⚠ 회원 쪽은 그대로다 — **좌석 행 없이 결제된 초대는 회원 본인에게 리마인드가 안 간다**(전부터 · 슈퍼어드민만 받는다). 테스트 파일은 공개 로그라 며칠 전별 합계만(수동 예약 날짜 = 운영자 개인 일정) · Edge 전체 실행 대신 슈퍼어드민 몫만 만들고 푸시.
  검토: 1차(3 렌즈 31 에이전트 → 확정 10) · 수정분(2 렌즈 10 에이전트 → 확정 2: 반환된 초대 · 상한 신호) 전부 반영. 회귀 `bash sql/_test/t_visit_reminder_admin.sh`(23건) · `vrfmt/vr.js`(45건).
- ⚠ 비회원 알림톡 리마인드(`KAKAO_TEMPLATE_GUEST_REMIND`)는 **카카오가 승인한 템플릿 문구**라 이 변경과 무관하다 — 바꾸려면 카카오 비즈니스 채널에서 템플릿을 새로 승인받는다.
- 회귀: `bash sql/_test/t_visit_reminder_format.sh`(30건 — 라이브 판 md5 · 요청 예시 KO/EN/JA · 시각 변환 · 이름·문구 폴백(이름 없음 · 매장 등록 이름 · 일본어 미승인) · 실행 문구·payload·i18n · 중복 · **위조 days 줄에도 실행 성공** · 권한(회원·다른 매장·그 매장·슈퍼어드민) · 300자 · 직접 읽기 막힘 · 칸별 출력 · 비우면 삭제 · 재실행 · 모르는 판 · 테스트 발송 파일(고정 예시 · 며칠 전 점검)) · 스크래치 `vrfmt/vr.js`(40건 — 사본=서버 · 알림함 번역 · 시트 세 언어 · 기호 보존 · 슈퍼어드민 영어 · 토스트 D-3/D-1 · 입력 화면(불러오는 중·실패 저장 막힘 · 이모지 글자 수 · 바깥 끌기 · 닫기 확인 · TX 제외) · 미리보기 발송 · 메뉴·사전 · 2차: 토스트 raw·같은 티켓 한 번·창 다시 열기·이모지 2000 — 40건 · 리뷰 반영 13건은 고치기 전 판에서 ❌).
확인은 반드시 `net._http_response`(200 + `{"ok":true,"made":N,"push_sent":…}`)로 — `cron.job.last_run` 은 근거가 못 된다.
미리보기: 슈퍼어드민 알림 설정의 「7일 전 리마인드 / 3일 전 / 하루 전」 버튼(본인 기기, 서버 문구 그대로, 본인 설정 적용).
⚠ 같은 날 잡은 회귀: 알림 설정 「전체」가 「모든 항목이 켜져야 켜짐」이라 7일 전 기본 꺼짐(09-28) 뒤 항목 하나만 건드려도
`all=false` 가 저장됐고 send-push 는 그걸 「아무 푸시도 보내지 말라」로 읽었다 → 「하나라도 켜져 있으면 켜짐」으로 고치고
`sql/notif_prefs_all_repair_2026-09-29.sql` 로 되돌린다. 리마인드는 KSK-·LINK-·MAN- 행(user_id 가 어드민)을 뺀다.
**2026-10-27 점검(진단 `20261027_diag_visit_reminder.sql` · `_2.sql` · 읽기 + 슈퍼어드민 테스트 1건).** 대시보드 크론 #40 `notify-visit-reminder-daily`(`0 2 * * *` UTC = 11:00 KST · 키는 Vault)가 매일 성공 ·
Edge 는 비회원 알림톡까지 든 새 판(응답에 `guest`) · 리마인드 함수는 회원 소유 LINK- 포함 판. 알림이 10-07 뒤로 없는 것은 **그 뒤 회원 방문이 없어서**다(지난 45일 방문 0 · 살아 있는 회원 예약 90건은 전부 11-12 이후 · 방문일 못 읽는 행 0).
테스트(category remind1 · 실제와 같은 문구 · `_taam_member_push`)는 send-push 200 · 시도 1 · 성공 1. 다음 실제 발송은 11-12 방문분(7일 전 11-05 — 7일 전을 켠 회원만 · 3일 전 11-09 · 하루 전 11-11).

### 여러 회차 동시 업로드 — 「추가 일정」 (2026-10-05)

연간 예약권처럼 한 매장의 회차가 여러 개일 때 티켓 업로드에서 **「추가 일정」** 줄을 더해 한 번에 올린다.
위의 날짜·시간이 1회차, 추가 줄이 2회차부터. 확정 시 `_pendingTicket` 을 JSON 복제해 **id·date·dateYear·time 만** 바꾼
`_pendingTicketExtras` 를 함께 `ticketDB` 에 넣고 `saveTickets()` 로 저장한다 — 회차마다 `ticket_products` 행이 따로 생기므로
구매·결제·좌석·재입고·리마인드는 단일 업로드와 완전히 같다. id 는 `Date.now()+1+i` 로 띄운다(같은 밀리초 충돌).
피커는 공용 캘린더·휠을 `_tkCalMode='uploadExtra'` · `_tkWheelCallerMode='uploadExtra'` 로 열어 `_tuExtraIdx` 번째 줄에만 쓴다
(초대 화면처럼 `setInterval` 로 1회차 값을 훔쳐 오지 않는다). 수정 모드는 한 장만 다루므로 섹션을 숨긴다.
막는 것: 날짜·시간 빠진 줄 · 같은 날짜·시간 중복. 묻는 것: 그 매장에 같은 날짜·시간 티켓이 이미 있을 때(confirm).
마감·우선 공개·판매 오픈 **시각은 절대값**이라 모든 회차에 같은 값이 들어간다 — 회차마다 달라야 하면 따로 올린다(폼에 안내).
회원 쪽 주의: 매장에 `repurchase_day` 가 켜져 있으면 같은 회원이 N일 안의 두 회차를 사는 것은 종전대로 막힌다(기본 0=없음).
회귀: 스크래치 `multisched.js`(17건) — 저장소엔 없다.

### 재편집이 매진을 풀었다 — status 는 저장할 때도 좌석으로 다시 센다 (2026-10-05)

시마즈 3/19 를 비공개로 올려 초대로 8/8 을 채운 뒤(soldout) 「즉시 공개」로 재편집해 저장하자 **캘린더엔 판매중(색), 상세엔 매진**이 됐다.
`uploadTicket` 이 status 를 언제나 `getUploadStatus()`='active' 로 보냈고, 매진 동기화 `trg_sync_ticket_soldout` 은 **tickets 가 바뀔 때만**
돌아서 아무도 되돌리지 않았다(상세는 `taam_ticket_sold_slots` 로 좌석을 직접 센다 · 캘린더·목록은 `status` 만 본다).
→ ① 앱: 재편집은 원래 soldout 이면 soldout 을 그대로 보낸다. ② 서버: `trg_taam_tp_status_recalc`(BEFORE INSERT/UPDATE OF status,total_pax
on ticket_products, `20261005_ticket_products_status_recalc.sql`) — 점유 ≥ 정원인데 active 로 쓰면 soldout(auto) 으로, 자동 매진인데 **정원을
늘려** 자리가 생기면 active 로. 되돌림은 정원 늘림 때만이다 — 저장마다 풀면 어드민 수동 잠금(앱은 status 먼저, `auto_soldout=false` 뒤)을 매번 푼다.
취소표 알림 트리거는 `UPDATE OF status, total_pax` 로 넓혔다(SET 에 없는 열은 BEFORE 가 바꿔도 UPDATE OF 가 안 본다). 회귀: `bash sql/_test/t_tp_status_recalc.sh`(18건).
따라온 것(2026-10-08): 꽉 찬 회차의 「판매 재개」는 이 트리거가 조용히 되돌린다(시마즈 1/30 8/8 — 어드민은 「재개가 안 된다」로 봤다).
`tuToggleSoldout` 은 재개 전에 `taam_ticket_sold_slots` 로 좌석을 세서 꽉 찼으면 이유를 말하고, 비공개(`saleState` draft/scheduled)면
「공개로 전환」(`_tuPublishSoldout`: saleState=open · 매진 그대로 · 캘린더에 SOLD OUT)을 준다 — 어드민이 원한 건 재판매가 아니라 노출이었다.

### 방문일의 연도는 두 군데가 읽는다 — 둘 다 세 토막을 받아야 한다 (2026-09-21)

티켓의 `date` 는 보통 `MM.DD` + `dateYear` 지만, `YYYY.MM.DD` 로 들어온 행도 있다.
`_tkDateKey`(정렬 키)와 `_isTicketExpired`(방문일이 지났나)가 **두 토막만** 읽어서,
세 토막짜리는 정렬에서 맨 뒤로 밀리고 **영원히 「안 지난」 회차**가 됐다. 둘 다 세 토막을 읽게 고쳤다.
→ 방문일을 새로 읽는 코드를 쓸 때는 두 형식을 모두 받는다. 화면 표기는 `_popStoryDate`(연·월·일·요일)를 쓴다.

### 연도 없는 방문일은 「오늘」이 아니라 「올린 날」로 읽는다 — 서버가 연도를 채우고 지킨다 (2026-10-19 · 빌드 `2026.10.19-c`)

「티켓 캘린더 2027년 6월에 2026년 6월 티켓(시마즈 6/17 · 스시 이코우 6/16 · 히가시아자부 아마모토 6/15)이 또 보인다 — 올린 적 없다」.
2026.07(연도 저장 도입) 전에 올린 회차 **11개**가 `ticket_products.date` = `'MM.DD'` 로만 남아 있었고(전부 5/11~6/8 작성 · 매진 · 진단 `20261019_diag_yearless_dates.sql` 의 Actions 로그),
앱은 연도 없는 날짜를 **오늘 기준**으로 짐작했다 — `_tkFullDate`·`_dParseDate` 「120일 넘게 지났으면 내년」, `_tkDateKey`·`_isTicketExpired` 「180일」. 그래서
6/15~17 은 10/13~15 부터 관리자 캘린더 2027년 6월에(예약 0 — 구매 행은 연도가 있어 2026 에 남았다), 5/15 스시 사이토는 9/12 부터 2027년 5월에 떠 있었고,
7월 회차는 10월 말, 9·10월 회차는 1~2월에 넘어갈 차례였다. 회원 화면(180일)은 12월 중순부터 **지난 회차가 2027년 회차로 되살아나** 자리가 풀리면 살 수 있게 될 모양이었다.
2027년 6/1·6/3·6/4 의 점·인원 배지(스시 사이토·메이노·히키타)는 10/13 에 연도와 함께 올린 **진짜** 2027 회차다.
- 규칙(앱 `_tkInferYear` = 서버 `_taam_mmdd_year` · 140점 일치 · KST 로 센다): **기준일 30일 전 이후의 첫 그 날.** 기준일 = 올린 날 — 회차는 방문 전에 올린다.
  앱 기준일 `_tkAnchorOf`: `createdAt`(로더가 `created_at` 을 싣는다) → `regDate` → 회차 id(업로드 때 `Date.now()` · 1780800733940 = 2026-06-07) → 오늘(마지막 폴백 · 실제 행엔 없다).
  `_tkFullDate`·`_tkYMD`·`_tkDateKey`·`_isTicketExpired` 가 이 한 규칙을 쓴다(캘린더·정렬·만료가 다시는 갈라지지 않게). 2/29 는 다음 윤년. 서버 함수는 기준일이 없으면 null(지어내지 않는다).
- 서버 `20261019_ticket_date_year.sql`: ① 11건 채우기(올린 날 기준 · 확정 구매 행(홀드·취소 제외)의 연도와 다르면 멈추고 ⚠ · 옛값 `ticket_date_year_log` batch `20261019_backfill` · 되돌리기 쿼리는 파일 머리말)
  ② 가드 `trg_taam_tp_date_year`(BEFORE INSERT/UPDATE OF date · security definer): 연도 없는 date 가 오면 **같은 id 의 저장된 연도를 지킨다**. ⚠ 앱 저장은 PostgREST **upsert** = `INSERT … ON CONFLICT DO UPDATE` 라
  BEFORE INSERT 트리거를 먼저 탄다 — INSERT 가지에서 「지금」으로 연도를 지으면 옛 앱의 다시 저장('06.17')이 2027.06.17 로 굳는다(첫 판의 결함 · 조사가 잡았다). 그래서 INSERT 가지도 저장된 행을 읽는다.
  아직 연도 없는 행은 그 행의 created_at, 월·일이 바뀐 옛 앱 수정은 지금(KST), 새 행은 created_at 기준. 고친 것은 기록(source `guard:keep|created|moved|new`) — 옛 빌드가 도는지 보인다.
  ③ 확인 표 ⑤ 에 연도 의심(읽기만): 회차와 날짜가 다른 연결 구매(KSK- 제외) · 보낸 날보다 앞선 날짜로 저장된 초대.
- **초대 날짜 고르기가 연도를 버렸다**(같은 날 같이 고침): `riOpenCal` 이 `_tuSelectedDate`(MM.DD)만 복사하고 `riSubmit` 이 `_dParseDate` 로 다시 짐작 → 8~12개월 뒤 날짜가 **한 해 일찍** 저장되고
  「판매 티켓 연결」 가드가 그 회차를 못 찾았다. 이제 고른 연도를 함께 가져오고(업로드 폼 값은 원상복구) 연도 없는 날짜는 「날짜를 다시 선택」으로 막는다.
- 그 밖에: 파트너 캘린더 날짜 고르기가 연도를 안 봤다(`partnerCalSelect` → `_tkSameDay`) · 결제 팝업 입구(`openTdPayPopup`)가 지난 회차를 연다면 막는다(「기한 만료 · 지난 일정입니다」 TX).
- 적대 리뷰(4 렌즈 · 22 에이전트 → 9건 중 7건 기각 · 반영 3): 초대 날짜 폴러의 60초 「되살리기」가 closeTU 가 비운 업로드 폼에 지난 날짜를 숨겨 넣었다 → 되살리기 없음 · 폴러 하나(`window._riCalPoll`) ·
  티켓 목록 글자가 `{date,dateYear}` 만 넘겨 올린 날을 잃었다 → `_popStoryDate(t)` · 편집이 `regDate` 를 오늘로 다시 적는다 → 기준일은 id 를 regDate 보다 먼저.
- **2026-10-19 라이브 적용 ✅** — 자동 배포 #54 가 `20261019_ticket_date_year.sql` 을 적용: 11건 전부 2026 으로(① ✅ · ② 남음 0 · 아사누마 9/7·타카미츠 10/3 은 구매 연도 2026 일치 · ④ ✅ · ⑤ 의심 행 없음 · `state=ok`). 앱 빌드 `2026.10.19-c` 는 Vercel 배포로.
- ⚠ 새 코드에서 방문일을 쓸 때: **연도를 짐작하는 식을 새로 쓰지 말 것** — `_tkYMD`/`_tkFullDate`/`_tkDateLabel` 을 쓴다. 저장은 언제나 `'YYYY.MM.DD'`(가드가 받쳐 준다).
- 회귀: `bash sql/_test/t_ticket_date_year.sh`(24건 — 11건 모양 · 연말 경계 · 늦게 올림 · 구매 연도 일치/충돌 · 홀드 무시 · **upsert 가 2026 을 지킨다** · 회원 세션 · 2/29 · null · 재실행) ·
  스크래치 `yearless/yl_app.js`(가짜 오늘 10/19 · 12/20 · 3/1 — 관리자 캘린더 2027년 6월엔 진짜 2027 회차만) · `yearless/yl_app2.js`(앱=서버 140점 · 서울/LA 시간대 · 초대 연도 · 파트너 캘린더 · 결제 팝업).

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
  지금 Vault 에 있는 이름은 **`service_role_key`** (2026-09-07, legacy service_role JWT). 새 잡·`app_config.restock_push` 는 이 이름을 쓴다.
  취소표 알림의 즉시 호출·1분 크론(`taam-restock-kick`, jobid 43)이 이걸로 Edge `notify-restock` 을 부른다 (2026-09-29).
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
- **계보(is2) 는 사전이 닿지 않는 층이 셋 더 있다** (2026-09-28 전수 조사·59건 수정):
  ① 트리 노드 이름·부제는 `chefs.name_en/name_jp · sub_en/sub_jp` 가 유일한 출처 — `applyLineageNameOverrides` 가 덮어쓴다.
     종전엔 없는 컬럼(`sub`, `i18n_jp_approved`)을 select 해 **조용히 실패**했고 EN/JA 트리가 통째로 한글이었다. 실패는 이제 콘솔에 남는다.
  ② 세대 축(2代)·배지(1935 · 1代)·관계 라벨(첫제자)·메타 줄(2006 오픈 · 긴자)은 SVG 리터럴이라 t()·TX 가 못 닿는다 →
     `LIN_SVG_DICT` 토큰 사전 + `_lnLocalizeSvgTexts` (EN/JA/KO 세 값 — KO 도 한자 라벨은 「2대」로). 새 계보 SVG 를 그리면 사전에 토큰을 더한다.
  ③ 노드 팝업 본문은 DB(`sec1_data.desc*`) — `**굵게**` 는 `_ndmInline` 이 `<strong>` 으로만 바꾼다. 커스텀 노드는 `_nameKo/_s1TitleKo…` 원문을
     같이 싣고 **저장은 원문으로만**(`saveCustomNodes`·팝업 편집) — EN/JA 화면에서 좌표만 옮겨도 번역문이 한국어 컬럼에 들어가던 사고를 막는다.
  회귀: `node sql/_test/lineageshot.js`. 이름 번역이 빈 노드 목록: `sql/diag_chef_names_i18n_2026-09-28.sql`.
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
| 전역 플래그 | `NEW_HOME_LIVE = true` (index.html) — **2026-08-25 iOS 출시에 맞춰 전 회원 전환됨.** 아래 「아직 열려 있지 않다」는 그 전의 서술이다. 회원의 실제 구매 경로는 `pcalOpenTicket → pcalPay → openTdPayPopup` 이며 `handleTicketAction` 을 지나지 않는다 — 구매 전 검사는 `openTdPayPopup` 입구에 둔다 (2026-10-13) |
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

### 캘린더 시트 — 날짜 목록의 뒤로가기는 언제나 한 단계 (2026-10-19 · 빌드 `2026.10.19-b`)

「표지 → 📅 → 날짜 → 티켓 목록에서 ‹ 를 누르면 **가끔** 표지로 간다」. 앱에는 history/popstate·하드웨어 뒤로 리스너가 없다 — 「뒤로」는 시트 머리말의 ‹ 하나다. 셋이 겹쳐 있었다(측정 · 5 렌즈 조사):
① ‹ 가 26×22 판이고 그 둘레가 전부 「닫기」였다 — 머리말 onclick·손잡이 탭은 `magSheetCycle()` 이고 목록은 늘 전체(2)라 2 → 0. 44×44 손끝 영역의 40~68% 가 닫힘(378점 격자에서 313점).
② 뒤에서 도는 다시 그리기(`taamSyncNow → _tkRepaintAll → pcalRenderAll → magRender` — 티켓 Realtime·포커스·당겨서 새로고침·홀드 반납)가 끝에서 `magShowCalendar()` 를 불러 **목록을 말없이 달력으로** 바꿨다 → ‹ 가 숨고 제목이 그 자리로 와서 다음 탭이 제목(=닫기)에. ③ 뒤로 직후 반사적 두 번째 탭도 같은 제목에.
→ 지금 규칙(`magHeadTap` · `magDimTap` · `magBindDrag` 의 `tap()`):

| | 날짜 목록 | 달력 |
|---|---|---|
| ‹ · 머리말 아무 곳(× 빼고) | 달력으로 | 중간 → 전체 · 전체에선 아무것도 안 함(**닫지 않는다**) |
| 손잡이 탭 | 달력으로 | 중간 → 전체 → 닫힘(한 번만 — 터치 뒤 호환 마우스로 두 번 돌던 것 막음 · 탭/끌기 경계 10px) |
| 어두운 띠 | 달력으로 | 닫힘 |
| × · 끝까지 끌어내리기 | 닫힘 | 닫힘 |

- 날짜 열기·뒤로·상세 닫기(`pcalCloseTicket`) 직후 400ms 의 손잡이·어두운 띠 탭은 흘린다(`_magNavMark/_magNavFresh`). ‹ 판은 44×35(머리말 높이 전체 · 손잡이는 덮지 않는다 — 덮으면 거기서 시작한 끌기가 먹힌다).
- `magRender` 꼬리는 목록을 보고 있으면 **그 날짜를 다시 그린다**(`_magPaintDay(…, keep)` · 스크롤 유지 · 같은 html 이면 손대지 않음). 그 날 자리가 없어졌으면 달력.
- 목록에서 달력으로 돌아오면 날짜를 누르던 때의 달력 스크롤로(`_magCalScroll` · × 로 닫았다 다시 열어도) — 긴 목록 스크롤이 남아 달력 칸이 화면 밖이던 것.
- ⚠ 시트를 닫는 새 탭 경로를 만들지 말 것 — 목록 상태에서 닫기는 × 와 끌어내리기뿐이다. 뒤에서 도는 렌더가 시트 몸통을 바꿀 때는 `_magDayYMD` 를 보고 목록을 지킨다.
- 회귀: 스크래치 `calback/synth_regress.js base touch|mouse`(격자 0 닫힘 · 두 번 탭 · 상세 왕복 · 다시 그리기 · 손잡이·머리말·띠·끌기·touchcancel) · `calback/fix2_check.js`(24건 · 세 화면 크기 기하 · 손잡이 왼쪽 끝 끌기 · iOS 떨림 탭 · 달력 스크롤 복원). 적대 리뷰(4 렌즈 → 확정 2 · 전부 반영 + 기존 스크롤 문제 1).

### 시작화면 사진 슬라이드 — 여러 장 디졸브 (2026-10-07)

`app_config.splash_settings` 에 `bgs:[Storage URL…]` · `interval:초(1~10 · 0.5 단위 · 기본 **1.5**)` 가 더 생겼다. `bg` 는 첫 장으로 같이 둔다(옛 빌드는 한 장만 본다).
사진 2장 이상이면 `_splashSlideStart`(레이어 A 아래=현재 · B 위=들어오는 장)가 `.splash-bg` 와 편집 미리보기에서 돈다. 실제 스플래시는
**시작 장이 무작위**(`{random:true}`), 미리보기는 1번부터(순서 확인용). 디졸브 길이 `--splash-fade` = min(1.4초, 간격×0.8).
⚠ **2026-10-07 「앱이 현격히 느려졌다」 사고.** 첫 판은 타이머가 ① 스플래시가 닫힌 뒤에도 ② 편집 화면이 닫혀 있어도(부팅마다 모든 회원
기기에서 미리보기 타이머 시작) 영원히 돌며 틱마다 `void offsetWidth` 로 **문서 전체 강제 레이아웃**을 일으켰다. 지금은 틱이 레이아웃을
건드리지 않고(두 레이어를 번갈아 켜고 끄며 밑바탕 background 를 「지금 장」으로 둔다), `opts.alive()` 가 거짓이면 스스로 멈추며,
시작은 보일 때만 한다(`_splashIsShowing` · `_splashEditorOpen` · `_splashSlideKick` 은 `_splashHold` 에서). `_splashCloseNow` 와
`closeSubPage('splashMgmtScreen')` 이 명시적으로 멈춘다. 유지 시간은 5초 고정(사진 수만큼 늘리던 것은 「시작이 느려졌다」로 읽혀 뺐다).
적대 리뷰(36 에이전트, 2026-10-08) 뒤 셋 더: 같은 구성 재호출은 **지금 밑바탕**(`run.bgUrl`)을 돌려준다(시작 장을 돌려주면 제3의 사진이 비친다) ·
틱은 `setTimeout` 체인(늦은 틱 뒤 격자로 되돌아가는 `setInterval` 은 페이드 도중 다음 전환을 떨어뜨린다) · 파싱 직후 IDB 페인터가 무작위 장을
한 번 골라 `window._splashStartUrl` 에 두고 엔진이 그 장에서 잇는다(1번 → 다른 장으로 뚝 끊기지 않게). ⚠ 저장된 `interval` 이 라이브를 정한다 —
기본값을 바꿔도 이미 저장된 행(3)은 그대로다. 편집 화면에서 바꾸거나 `app_config` 를 직접 고친다(`updated_at` 도 올려야 롤백 가드가 옛값을 되밀지 않는다).
→ 화면에 영구 타이머를 두는 코드를 쓰면 **「보이는 동안만」** 을 먼저 정한다. 회귀: 스크래치 `splashperf.js`(10건).
사진은 **Storage `splash-media`** 에만(버킷 MIME 에 image 허용돼 있다) —
종전 크롭 경로가 base64 를 설정에 통째로 넣던 것도 이날 Storage URL 로 바꿨다. 여러 장 선택은 크롭 없이 바로(9:16 cover), 한 장은 크롭.
회귀: 스크래치 `splashslide.js`(9건).

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
| 같은 회차 중복 · 같은 날 같은 시간대 | `trg_taam_guard_ticket_unique` | 한 회원 = 한 회차 1건(hold 포함) · 같은 날 점심/저녁 각 1건. **예외는 슈퍼어드민이 회원·회차별로 허용한 것만**(`purchase_rule_exceptions` · 2026-10-22). 운영 행(KSK-/MAN-/INVH- · LINK- 는 memberUid 없을 때만)만 예외 · PAYH-/PAYC- 는 플래그가 있어도 회원 행, 슈퍼어드민·service_role 도 적용 (2026-10-13, 위 「한 회원 = 한 회차 1건」 · 운영 행 판정은 2026-10-18 `20261018_pay_link.sql` 판) |
| 재구매 제한 | `trg_taam_repurchase_guard` | 같은 매장 N일(30·60·90·120·180). **방문일 간격**으로 센다(구매일 아님) · 같은 날은 예외 · 홀드도 기존 예약으로 센다 · ~~발매 7일 뒤 자동 해제~~ **2026-10-13 폐지**(`20261013_repurchase_no_release.sql`). 대신 **회차별 수동 해제** — 슈퍼어드민이 티켓 리스트의 「재구매 해제」로 `ticket_products.repurchase_open` 을 켜면(`taam_ticket_repurchase_open`, `20261014_repurchase_manual_release.sql`) `taam_repurchase_released` 와 앱 `_repReleasedByAge` 가 **그 회차만** true. 매장 설정은 그대로. **풀고 나면 팝업으로 푸시를 묻는다**(2026-10-16 · `_tuRepurchaseAskPush`) — 대상은 옛 자동 해제가 쓰던 `taam_repurchase_release_targets(회차)`(이 매장 재구매 창 안에 방문·예정이고 이 회차를 안 산 회원)뿐, 문구는 옛 서버 알림과 같은 「예약이 열렸습니다 / {매장} · {날짜} {시간} — 재구매 제한이 풀려…」(알림함 EN/JA 는 이미 안다 · 푸시는 i18n 세 벌 · category `repurchase_released`). 대상이 없으면 「티켓 오픈 알림 발송」으로 안내. 자동 발송 없음. 회귀 `bash sql/_test/t_repurchase.sh`(15건) · 스크래치 `rpush.js`(7건) |
| 티켓 필드 | `trg_taam_guard_ticket_row` | 회원은 **취소만**. `price`·`party_size`·`status(hold→active 포함)` 를 못 고침 (2026-09-13 강화) |
| 티켓 INSERT | `trg_taam_guard_ticket_insert` | 회원은 `status='hold'` 만, 매장 어드민은 `hold`·`manual`. **확정 행은 서버(RPC·toss-confirm)만** 만든다 (2026-09-13) |
| 푸시 구독 role | `save_push_subscription` | 클라이언트 `p_role` 무시 — `profiles.role` 로 정한다 (2026-09-13) |
| 초대코드 | `trg_taam_guard_invite_code_row` | 회원은 `used`·`used_by_*` 만. `invitee_tier` 등은 슈퍼어드민만 (2026-09-13) |
| `app_config` | RLS | 읽기 전원, 쓰기 슈퍼어드민만 — 환율(`fx_settings`) 오염 차단 (2026-09-13) |
| 공개 RPC 속도 | `taam_rate_hit(key, limit, window)` | `partner_agree`·`taam_mship_apply`·`taam_corp_inquire`·`taam_notify_admins`·verify/consume-invite·taam-chat. 새 공개 RPC 를 만들면 이걸 부른다 (2026-09-13) |
| 예치금 양수 델타 | `taam_apply_deposit_delta` | 회원은 `ticket_refund` + `purchase_id` 원장으로, **낸 돈 − 이미 환불** 한도 안에서만 (2026-09-13 핫픽스) |
| 원장 INSERT | RLS `deposit_tx_insert_server` | **회원은 `deposit_transactions` 를 직접 못 쓴다** — 슈퍼어드민만. 회원 원장은 RPC 가 쓴다. Edge(service_role)·SQL Editor 도 같은 RPC 를 부른다. 원장을 넘겼는데 잔액이 모자라면 `LEDGER_INSUFFICIENT` (2026-09-14, `sql/ledger_close_member_insert.sql`) |
| 원장 유형 | `trg_taam_guard_ledger_change_type` | **회원 세션은 `admin_*`(admin_grant·admin_deduct) 유형의 원장 줄을 못 쓴다** — `taam_apply_deposit_delta` 가 회원 호출의 음수 항목 change_type 을 안 봐서 회원이 자기 원장에 「관리자 차감」 모양의 줄을 쓸 수 있었다(라벨 위조 · 2026-09-14 부터). BEFORE INSERT · 로그인 호출자가 슈퍼어드민이 아니면 `LEDGER_TYPE_FORBIDDEN`(42501) → RPC 전체 롤백. 서버(auth.uid() null)·슈퍼어드민은 그대로. RPC 본문은 교체하지 않았다(라이브 핵심 함수) (2026-10-18, `20261018_ledger_admin_type_guard.sql` · 회귀 `t_ledger_type_guard.sh` 11건) |
| 좌석 행 결제 링크·초대 연결 칸 | `trg_taam_guard_ticket_linkfacts` | 앱이 직접 보낸 문장(슈퍼어드민 제외)은 `chargeId`·`agencyFee`·`agencyPay`·`inviteId`·`paidAt`·`confirmed_at` 등을 못 바꾼다(되돌림) · LINK-/KSK- 직접 INSERT 거절 · 직접 INSERT 의 연결 칸 지움 — 링크 환불 견적을 전액으로 만들던 길. 서버 함수는 그대로 (2026-10-28, `20261028_ticket_link_facts_guard.sql`) |
| `profiles.is_test` | `trg_taam_guard_is_test` | 테스트 계정 숨김 스위치 — **회원 세션은 되돌림**(감사 칸 `is_test_set_by/at` 는 트리거만). 슈퍼어드민·서버만 (2026-10-19, `20261019_test_accounts.sql` · 위 「테스트 계정은 회원 목록에서 숨긴다」) |
| 매장 어드민 판정 | `taam_rest_admin_ok(_for)` ← `is_ticket_admin_of` · `is_restaurant_admin_of` · `is_venue_admin_of` · `taam_is_rest_admin` · `taam_can_mark_visit` · `taam_can_manage_ticket_as` · `_taam_rest_note_ok` | **`admin_grants.status = 'approved'` 인 매장만**(rest_id 또는 venue_id). 승인 대기·정지는 어느 정책식·RPC 에서도 매장 어드민이 아니다. `restaurant_admins`·`venue_admins` 는 admin_grants 로 옮겨졌고 더 안 본다 (2026-10-29, `20261029_partner_grants.sql` · 아래 「파트너(매장 어드민)」) |
| `admin_grants.status` | `trg_taam_guard_admin_grant` + RLS(`ag write` 슈퍼어드민만) | 승인·정지 도장(`approved_by/at` · `status_set_by/at` · `prev_status` · `suspended_via`)은 트리거만 적는다. 바꾸는 길은 RPC `taam_partner_grant_set`(슈퍼어드민·서버)과 Edge `partner-account`(service_role). **운영 메모 `note` 는 authenticated 가 칸 권한으로 못 읽는다**(파트너가 자기 줄을 직접 select 해 읽던 것) (2026-10-29) |
| 티켓 업로드 승인 | `enforce_ticket_approval` v2 + `ticket_products` 정책 | 매장 어드민은 **자기 매장**에 `pending` 으로만 올리고(`ADMIN_MUST_UPLOAD_PENDING`), `pending → active` 는 슈퍼어드민만(`ONLY_SUPERADMIN_APPROVES` · 도장 `approved_by/at`), **승인된 회차의 내용 수정은 되돌리고 별도 표 `ticket_product_edits`(회차마다 한 줄 · 바뀐 칸 → 새 값 · 회원·anon 은 못 읽는다 · 글자 2,000자/전체 16KB `EDIT_TOO_LONG`)에 큐로** — status 는 그대로 · 슈퍼어드민 「수정 승인」(`taam_ticket_edit_review`)이 반영 · `_taam_tp_revert_cols()`(도장·검토 메모·`repurchase_open`·`audience`·업로더·`rest_name`·`created_at`·`reg_date`·`sale_state`·`sale_open_at`)는 되돌림 · 상태는 매진/판매중/삭제 신청만(슈퍼어드민이 숨긴 상태는 못 바꿈) · 옛 앱이 보내는 'pending' 은 「상태 변경 없음」. `pending` 회차는 회원·anon 에게 안 보인다(`taam_tp_visible`) · 삭제는 **한 번도 승인된 적 없는** 자기 pending 만. **중첩 갱신(`pg_trigger_depth() > 1` — 매진 동기화)은 어느 세션이든(슈퍼어드민·서버 포함) pending 회차의 status 를 지킨다.** 서버(auth.uid() null)·슈퍼어드민은 그대로 (2026-10-29) |
| 좌석 행 INSERT 의 매장 | `taam_guard_ticket_insert` V2 | MAN-·INVH- 는 **승인된 자기 매장**에만(`v_adm`) · 연결 회차가 없거나 다른 매장이면 `TICKET_REST_MISMATCH`(같은 답 — 숨은 회차 존재를 안 알린다 · 도우미 `_taam_tp_seat_check` 는 그 매장 승인 어드민·슈퍼어드민에게만 답한다). 글자 role 'admin' 만으로는 아무 매장도 못 넣는다(종전엔 어느 매장이든 됐다) (2026-10-29) |
| 승인 대기 회차의 좌석 | `trg_taam_guard_ticket_round_open` (security definer · BEFORE INSERT · UPDATE OF ticket_product_id, status) | **승인 대기 회차에 좌석 행을 못 넣는다**(`TICKET_NOT_APPROVED`) — 회원 결제 행(PAYH-·PAYC-)은 **누가 넣든**(서버 카드 확정 폴백 포함 · 숨은 회차 id 로 승인 전 회차를 사던 길) · 로그인한 매장 어드민의 MAN-/INVH-/LINK- · 슈퍼어드민은 MAN-/INVH- 만. 서버의 운영 행(KSK-·LINK-)은 그대로. UPDATE 는 회차를 옮기거나 죽은 행을 되살릴 때만 (2026-10-29) |
| 초대 코드 표 | `invite_codes` 정책·권한 | **비로그인(anon)은 못 읽고 못 쓴다**(`invite_codes_read` 를 authenticated 로 · anon 권한 회수 — 종전엔 roles public · USING true 라 공개 키로 전 초대장의 이름·전화·이메일·등급·코드가 보였다). ⚠ 로그인한 회원끼리는 아직 서로 읽힌다 — 아래 「보안 점검」 (2026-10-29, `20261029_security_audit.sql`) |
| 인원 변경 환불 | `taam_change_party_size` 덧댐 | 운영 행(MAN-·INVH-·KSK-·LINK-)은 `PAX_CHANGE_NOT_FOR_OPS` · 슈퍼어드민이 아니면 자기 구매 `FORBIDDEN_OWN` · **확정(active) 구매만**(`PAX_CHANGE_NOT_PAID`) · 이 매장 회차의 행만(`PAX_CHANGE_BAD_ROUND`) · 환불은 **줄인 인원 몫**(1인 몫 = min(행 금액 ÷ 인원, 회차 정가 1인) − 대행비(구매 30분 뒤) · 앞선 감소가 남긴 대행비는 빼고 나눈다)까지 · 카드가 섞이지 않은 구매는 **원장에 적힌 이 구매의 예치금 결제 − 이미 돌려준 것**까지 — 종전엔 호출자가 적은 금액(결제액 이하 무엇이든)을 그대로 예치금에 넣어 파트너가 자기 수동 좌석으로, 또는 회원이 금액을 적은 미결제 홀드로(2차 리뷰) 예치금을 만들 수 있었다 (2026-10-29) |
| 회원·파트너가 쓰는 그 밖의 표 | `trg_taam_guard_text_input` (tickets · reservation_invites · daegwan_manual · restaurant_visit_notes · restaurants · **profiles**) | 로그인 호출(슈퍼어드민 제외)의 **새로 생긴 글자**에 HTML 태그 모양·`javascript:` 금지 · tickets 구매 id 는 `^[0-9A-Za-z_.:-]{1,100}$` (`BAD_INPUT`) — 수동 좌석·초대 칸이 슈퍼어드민 캘린더·회원 초대 팝업에서 돌던 저장형 XSS (2026-10-29) |
| 파트너가 쓰는 회차 칸 | `_taam_tp_check_input` (enforce_ticket_approval · taam_ticket_edit_submit) | 바뀐 칸만: id `^[0-9A-Za-z_.:-]{1,64}$` · date `(YYYY.)MM.DD` · time `HH:MM` · 그 밖 글자(jsonb 안쪽 포함)에 HTML 태그 모양·`javascript:` 금지(`BAD_INPUT`) — 승인 화면·캘린더·회원 화면이 innerHTML 로 그리는 자리가 있다(저장형 XSS) · 파트너 쓰기의 `updated_at` 은 서버가 `now()` (2026-10-29) |
| 초대의 결제 상태(보낸 사람) | `trg_taam_guard_invite_host` | **host(보낸 어드민) 세션은 `reservation_invites` 를 'paid' 로 넣거나 바꿀 수 없다**(INSERT 는 'sent'·paid_at null 로 · UPDATE 는 `INVITE_HOST_PAID_FORBIDDEN`) · paid 줄의 받는 회원·금액·인원·회차·매장은 되돌림(취소·시각 변경은 그대로). 받는 회원 쪽 가드(20261022)가 host 를 면제해 둬 승인된 파트너가 초대 한 줄을 paid 로 넣어 아무 회원이든 「관계」로 만들 수 있었다 — 파트너 RPC 의 관계 판정도 status 가 아니라 **서버 증거**(`_taam_invite_paid_evidence` — INV- 좌석 행 또는 받는 회원의 원장 결제 줄)만 본다 (2026-10-29) |
| 초대의 매장 | `trg_taam_guard_invite_rest` | `reservation_invites` 의 `ticket_product_id` 회차 매장 = `restaurant_id`(INSERT 언제나 · UPDATE 는 회차·매장이 바뀔 때만 — 옛 불일치 줄의 회원 결제 갱신은 막지 않는다) · 승인 대기 회차에는 초대 못 보냄(`TICKET_NOT_APPROVED`) · 매장을 바꾸려면 승인 권한 · 중첩 갱신은 통과 (2026-10-29) |
| 티켓 연계(패키지) | `trg_taam_guard_ticket_package` · `trg_taam_guard_pkg_order_claim` · `trg_taam_guard_tp_package_delete` | 연계 회차의 회원 구매 행은 패키지 홀드로만 INSERT · active 는 패키지 확정 함수 안에서만(`PACKAGE_ONLY`) · 결제된 패키지의 한 줄 취소(회원·파트너)·인원 변경 막음 · 패키지 카드 주문은 새 Edge 만 paid · 연계 회차 삭제 막음 (2026-10-29, 위 「📦 티켓 연계(패키지)」) |
| 알림 payload 크기 | `trg_taam_notif_payload_cap` | 회원 세션이 쓰는 notifications.payload — 문자열 500자 · 전체 16KB(넘으면 짧은 스칼라만). 서버·슈퍼어드민은 그대로 (2026-10-25, `20261025_notif_payload_cap.sql` · 위 「슈퍼어드민 알림 → 그 내역 화면」) |
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

### 카드 등록(빌링키) — 라이브 `billing_keys` 는 저장소 스키마와 다르다 (2026-10-13 사고)

「카드 저장 실패」가 모든 회원에게 났고 표에 카드가 **0건**이었다. 라이브 표는 포트원 시절에 만든 것이라 `customer_key` 가 없고
`toss_customer_key` · `pg_provider`(NOT NULL, 기본 'portone') · `nickname` 이 있다 — Edge `toss-billing-issue` 가 저장소 `sql/billing_keys.sql`
대로 `customer_key` 를 INSERT 해 42703(컬럼 없음)으로 매번 거절됐고, 함수는 `save_failed` 한 단어만 돌려 원인이 안 보였다.
`toss-billing-charge` 도 `customer_key` 를 select 해 자동결제가 `card_lookup_failed` 로 죽을 모양이었다.
→ issue 는 라이브 컬럼(`toss_customer_key`, `pg_provider='toss'`)으로 쓰고 42703 이면 `customer_key` 로 다시 쓴다. charge 는 그 컬럼을 읽지 않고
customerKey 에 `user.id` 를 쓴다(등록 때 issue 가 auth uid 와 같음을 강제한다). 저장 실패는 이제 응답 `reason` + `app_errors`(kind `billing_save`,
platform `edge`)로 남고 토스트에 코드가 붙는다. 같은 빌링키 23505 는 되살리기.
교훈: **Edge 가 쓰는 표는 라이브 컬럼을 먼저 본다** — 진단은 스크래치 `diag_billing_keys.sql`(컬럼·제약·트리거·정책·권한·최근 행 한 표).
`sql/billing_keys.sql` 을 라이브에 다시 돌리지 말 것.

### 카드 수수료는 회원에게 못 받는다 — 내부 계산만 (2026-10-13)

「카드 결제에 수수료를 얹자」는 요청에 **여신전문금융업법 제19조①④**(카드 회원 불리 대우·가맹점수수료 전가 금지, 벌칙 제70조)로 안 된다고 답하고,
대신 **슈퍼어드민 내부 원가 확인** 화면만 만들었다: 어드민 메뉴 「💳 카드 수수료 계산 (내부용)」(`cardFeeOpen`). 결제수단으로 가격을 가르는 코드
(카드 가산·예치금/계좌이체만 할인)는 앞으로도 넣지 않는다. 비용을 메우려면 결제수단 무관하게 대행비에 균일 반영(「예약 수수료 정책」)하거나 예치금 충전 혜택으로.
- 서버 RPC `taam_card_fee_report(p_from, p_to)`(`sql/card_fee_report.sql` · 실행 필요 · 슈퍼어드민만 · security definer)가 `payment_orders`(paid: card / billing=metadata.paid_via)
  와 `kashikiri_charges`(paid: kashikiri / link=link_invite, 외화는 pay_currency·pay_amount, 원화는 amount_krw)를 한 표로 준다. 수수료율은 서버가 모른다 —
  앱이 `app_config.card_fee_settings`(rate_card·rate_billing·rate_fx·fixed_krw, 부가세 포함 요율로 입력)를 곱한다. 기간은 KST 자정 경계(`_cfKst`).
- 회귀: 스크래치 `cardfee.js`(11건) · RPC 는 스크래치 `cf_fixture.sh`.

### 📊 티켓 판매 현황 — 슈퍼어드민 보고 (2026-10-21 · `20261021_ticket_sales_report.sql` → 2차 `_report2.sql` → 3차 `20261022_ticket_sales_report3.sql` · 빌드 `2026.10.21-a` → `2026.10.22-b`)

「티켓 전체나 월별 판매금액을 볼 수 있는 기능」. 어드민 메뉴 「📊 티켓 판매 현황」(`tsrOpen` · 「📜 전체 티켓 구매내역」 아래 · `data-lang-lock="ko"`) —
기간(이번 달 · 지난 달 · 올해 · 전체 · 직접) · 결제일/방문일 기준 · 채널 칩 · 「테스트 계정 포함」 · 위 칸 넷(총 판매 · 취소·환불 · 순판매 · 대행비(확정/예정)) ·
월별 · 채널별 · 매장별 표(월·매장 줄을 누르면 아래 목록이 그것만 · 위 합계는 그대로) · 판매 목록(300건) · CSV(전체) · 「참고 (합계 제외)」 · 「⚠ 확인 필요」.
- 숫자는 서버 `taam_ticket_sales_report(p_from, p_to, p_basis, p_include_test)` 가 **판매 하나마다** 센다(슈퍼어드민·SQL Editor·service_role 만 · `_taam_fee_caller_ok` · jsonb 한 덩어리 — table 로 돌려주면 PostgREST 1000행에 잘린다).
  앱(`_tsrAgg`)은 거르고 더하기만 한다 — 채널 칩은 다시 부르지 않는다. 기간은 [from, to) · 화면의 끝 날짜는 포함(다음 날 0시 전) · 월은 'YYYY-MM-DD' 글자를 잘라 묶는다(해외 기기 하루 밀림 방지).
- **판매 하나 = 결제 하나** · 돈의 출처는 하나만. 채널: 앱 구매(PAYH-/PAYC- · 예치금·카드·섞음) · 초대(`reservation_invites` paid) · 결제 링크(LINK- · 티켓 용도) · 대관 정산(KSK- 연결 청구) ·
  미연결 정산 · 수동 입력(MAN-) · 수동 기록(`daegwan_manual`) — **뒤의 셋은 기본 꺼짐**(어드민이 적은 금액이라 검증할 수 없다). 멤버십·자유 금액 링크 · 취소된 수동 입력 · 테스트 계정은 「참고」로만.
- 환불은 그 판매에 붙어 **그 판매의 달**에서 빠진다(취소 · 위약 · 인원 줄임 · 카드 환불 대기). 순판매 = 판매 − 그 환불. 방문 후 반환(`returned`)은 순판매에서 안 빼고 따로(TAAM 보유).
  대행비 = 방문 후 반환은 기록된 `agency_held` · 위약은 기록이 0 보다 클 때만 · 그 밖은 1인 대행비(회차) × 인원 — 방문일이 지났으면 「확정」, 아니면 「예정」.
- **금액은 회원이 못 쓰는 기록만 믿는다**(적대 리뷰 25건 → 확정 14 · 전부 반영). 회원은 자기 `tickets.extra_data`·홀드 `price`, 자기 초대 행 전 칸, 원장의 ₩0·음수 줄(metadata 아무거나)을 쓸 수 있다.
  그래서 앱 구매 판매액 = **같은 회원**의 원장 결제 줄(음수 · 정정·자동 되돌림 제외) + **그 회원의** 카드 주문(`payment_orders` paid · 한 주문은 한 판매) — `tickets.price`·`pax_changes`·extra_data 금액은 쓰지 않는다(정가와 다르면 표시만).
  초대 = 초대받은 회원의 원장 결제 줄 − 자동 되돌림 · 대행비는 회차 대행비 이하. 돈 기록이 없는 살아 있는 행 · 원장 없는 paid 초대 · 되돌렸는데 paid 인 초대는 합계 밖 「확인 필요」, 취소된 위조 홀드는 조용히 뺀다.
  방문 전에 단 `returned` 환불은 취소로(`return_before_visit`). 링크 memberUid 는 uuid 모양일 때만 · 통화는 KRW/USD/JPY 만 · 시각은 2020~2100 만(`_taam_sr_ts`) · 숫자는 12자리까지(`_taam_sr_int`).
- 외화 링크는 그 링크의 원화(`amount_krw`)와 낸 외화(「$1,860.00 (₩2,500,000)」) — **오늘 환율로 다시 바꾸지 않는다**(위 「통화」).
- 화면: 불러오는 동안 채널 칩·줄 누르기가 옛 결과를 그리지 않는다(`_tsr.data=null`) · 늦게 온 옛 응답은 버린다(`_tsr.seq`) · 확인 필요 날짜·기준 시각은 KST(`_tsrKst`) ·
  CSV 는 `= + - @ 탭` 으로 시작하는 글자 칸에 `'` 를 붙이고(수식 주입) 깨진 시각에도 저장된다 · 파일 이름은 끝 날짜 포함. 함수가 없으면 「서버 준비 필요」.
- 진단(읽기 전용 · 집계만): `20261021_diag_sales_shape.sql`(라이브: 확정 회원 구매는 PAYH-active · PAYC 0 · 원장 구매 152줄 · 초대 paid 46). 성능: CTE 를 `as materialized` 로(13.5초 → 0.2초).
- **라이브 대사(2026-10-21 · `20261021_diag_sales_recon.sql` · `_recon2.sql` · 읽기 전용).** 원장 티켓 줄은 **전부** 판매에 붙는다 — 구매 152줄 ₩218,547,295 = 앱 87 + 초대 63 + 남는 2줄,
  환불 68줄 ₩51,307,265 = 앱 48 + 초대 14 + 남는 2줄 · 남는 두 쌍은 9/10 사고의 결제·되돌림(`seat_hold_convert_failed` ₩1,790,278 · 판매 아님이 맞다).
  초대 52건 = 판매 44 + 취소 5 + 방문 후 반환 7(초대 paid 46 과 다른 이유) · 취소인데 환불 기록이 없거나 대행비보다 많이 남은 앱 구매 7건은 **전부 테스트 계정·₩1,000대 시험 결제**.
  ⚠ 「방문 전 반환 → 취소로 셈」(9건 ₩8.7M)은 슈퍼어드민 「반환」(`dmConfirmReturn` · 금액 − 대행비 반환)을 방문 하루 전보다 앞서 누른 것 — 사실상 취소라 취소로 센다.
- **2차(같은 날 · `20261021_ticket_sales_report2.sql`).** 대사가 찾은 것: 1차는 정정(`fix`) 줄을 건너뛰어 **2026-09-14 이중 차감 세 건의 판매가 두 번** 잡혔다(「정가와 다름」 3건 ₩3,406,000 · 차액 ₩1,703,000).
  → 돈을 돌려준(+) 정정 줄은 그 판매의 되돌림(판매액에서 뺀다) · 음수 정정 줄은 종전대로 무시(회원도 ₩0·음수 줄에 아무 metadata 나 쓸 수 있다). 같은 이름·인자로 다시 만든다 — 1차 파일은 그대로 둔다(워크플로가 한 번만 돌린다).
  확인 표 ⑦ 정정 줄(뺀 줄 · 무시한 줄) · ⑧ 「정가와 다름」 건수.
- **3차 · 펼쳐 보기(2026-10-22 · `20261022_ticket_sales_report3.sql` · 빌드 `2026.10.22-b`).** 「⚠ 대행비 기록과 다름」이 무엇과 무엇이 다른지 안 보였다 → 서버가 판매마다 **비교 값 `d_*`** 를 함께 준다(계산은 그대로):
  회차 1인 대행비 `d_ag_tp` · 구매 때 티켓에 적힌 값 `d_ag_snap`(회원이 쓸 수 있는 칸 — 표시만) · 초대에 적힌 값 `d_ag_inv` · 실제로 센 값 `d_ag_used` · 1인 식사·주류(초대/회차) · 초대 합계 · 티켓 행 금액 · 원장 결제·되돌림 · 반환 시각·방문 전 반환액 · 기록된 보유 대행비 · 요청 카드 환불.
  `jsonb_build_object` 는 **인자 100개 한도**라 줄 객체를 둘로 나눠 `||` 로 잇는다. 확인 표 ⑨ 가 「대행비 다름」을 (채널·기록·회차·센 값)별 건수로.
  화면: 목록 줄은 경고를 **접어 두고** 오른쪽 「상세 ▾」(경고가 있으면 노란 「⚠ 상세 ▾」)만 — 누르면 그 줄 아래 상세(결제 시각 KST · 방문 · 구매 id · 금액 내역 · 판매액 근거 · 환불 · 순판매 · 대행비 계산 근거 · 경고마다 「무엇 ₩ · 무엇 ₩ → 센 값」).
  위임 클릭(`data-tsr-k` · onclick 문자열에 구매 id 를 넣지 않는다) · 펼친 줄은 `_tsr.open`(채널 바꿔 다시 그려도 유지 · 새로 불러오면 비움) · 옛 서버(d_* 없음)는 「—」. CSV 끝에 「대행비 기록(1인) · 회차 대행비(1인) · 센 대행비(1인)」.
  **라이브 ⑨(2026-10-22)**: 초대 9건 — 7건 「초대 ₩150,000/인 · 회차 ₩100,000/인」, 2건 「초대 ₩100,000/인 · 회차 ₩150,000/인」 → 둘 다 작은 쪽 ₩100,000/인으로 셈(초대 행은 받는 회원이 모든 칸을 고칠 수 있어 큰 쪽을 수익으로 믿지 않는다).
  회귀: `t_ticket_sales.sh` 66건(1차→2차→3차 · D1~D4) · 스크래치 `sales/tsr.js`(37건 · ✎/⚠ 구분 · 순판매 자름 · 확인 필요 유지 · 인원 0 · 접힘·펼침·다시 그려도 유지·접기·구매 id HTML·옛 서버·CSV 세 칸).
- **4차(2026-10-22 운영 결정 「초대·초대 링크로 보낼 때 바꾼 금액을 적용해야 한다」 · `20261022_ticket_sales_report4.sql` · 빌드 `2026.10.22-c`).** 초대 대행비 = **초대에 적힌 값(보낼 때 바꾼 값)** 그대로(순판매 이하) —
  3차까지는 회차 값과 작은 쪽이었다(라이브 7건 ₩150,000/인이 ₩100,000/인으로 덜 잡힘). 같은 날 초대 결제 보안(아래)으로 받는 회원이 그 칸을 못 바꾸게 돼 믿는다. 결제 링크는 종전대로 항목별 금액 수정(`override_parts`).
  앱·초대도 **방문일이 지나면 대행비 「확정」**(종전 「예정」 — 적대 리뷰). 화면: 의도된 수동 변경(초대 대행비 · 링크 금액 수정)은 ⚠ 가 아니라 「✎ 상세 ▾」 · 상세 「✎ 대행비 수동 변경(초대) — 보낼 때 바꾼 ₩…/인 적용 · 회차 ₩…/인」 ·
  순판매로 잘린 대행비는 「→ 순판매 ₩…까지로 자름」 · 카드 환불 대기는 「(그중 카드 환불 대기 ₩…)」 · 인원 0 정산은 「인원 —」 · 「확인 필요」 상자는 다시 그려도 열린 채(`_tsr.excOpen`).
  적대 리뷰(3 렌즈 · 23 에이전트 → 확정 6 · 전부 반영 + 기각 1 의 값싼 정리): 위 넷 + 결제 쪽 둘(아래 「결제 팝업은 남은 홀드를…」).
- 회귀: `bash sql/_test/t_ticket_sales.sh`(69건 — 1차→2차→3차→4차를 올린다 · 4차 V1(초대 ₩150,000·회차 ₩100,000) · V2(지난 방문 확정) · V3(처음 인원 위조 — 인원 줄임 환불 원장이 있을 때만 믿는다 · `invite_closed` 되돌림) · 정정 줄(이중 차감 · 이중 차감 뒤 취소 · 음수 정정 무시) · 채널·환불 종류·대행비·결제일/방문일·테스트 계정·외화 · 위조 홀드 · ₩0 원장 · pax_changes · 남의 원장 줄 · 한 카드 주문 두 행 · 초대 되돌림/원장 없음/대행비 부풀림 · 깨진 uuid·infinity · 재실행) ·
  스크래치 `sales/tsr.js`(25건 · 합계 · 채널 토글 · 월 고르기 · 외화 · 기간 · CSV(수식 주입 · 깨진 시각) · 통화 칸 HTML · KST · 불러오는 중 경주 · 서버 준비 전 · 권한).

### 💳 결제 내역 (카드 · 예치금) — 슈퍼어드민 (2026-10-28 · `20261028_payment_ledger.sql` · Edge `toss-payment-info` · 빌드 `2026.10.28-a`)

「카드로 결제된 내역이랑 예치금으로 결제된 내역 — 구매자 · 일시 · 예상 입금일 · 카드 내역 · 취소 연동 · 모든 내역」. 「토스 화면을 그대로 가져올 수 있나」 → **상점관리자는 앱에 못 넣는다**(로그인·2단계 인증 · 남의 화면에 끼우는 것을 막는다 · 우리 앱에 상점관리자 세션을 두면 보안 위험) — 대신 건마다 **「🧾 토스 영수증」**(토스가 주는 그 화면 · receipt_url)과 위의 **「토스 상점관리자 열기 ↗」**(app.tosspayments.com).
- 어드민 메뉴 「💳 결제 내역 (카드 · 예치금)」(`pmxOpen` · 「📊 티켓 판매 현황」 아래 · `data-lang-lock="ko"`) — 탭 둘(💳 카드 · 💰 예치금) · 기간(이번 달 · 지난 달 · 올해 · 전체 · 직접) · 경로 칩 · 상태 칩 · 검색(이름·전화·매장·주문번호·구매 id·카드 번호) · 테스트 계정 포함 · 합계 칸 · 줄마다 「상세 ▾」(위임 클릭 `data-pmx-k` · 버튼 `data-pmx-a/-v` — id·URL 을 onclick 문자열에 넣지 않는다) · CSV(수식 주입 막음) · `_taamBusyNow` 에 `pmxPopup`(여기서 카드 환불을 누를 수 있다).
- 숫자는 서버 `taam_payment_ledger(p_from, p_to, p_include_test)`(슈퍼어드민·서버만 · `_taam_fee_caller_ok` · jsonb 한 덩어리) — **결제 하나 = 한 줄**:
  카드 = `payment_orders`(앱 티켓 카드 · 등록 카드 · 승인된 것만 — pending·failed 제외 · 자동 취소 canceled 포함) + `kashikiri_charges`(결제 링크 · 링크 초대 · 대관 정산 · 멤버십 · 자유 금액 — 결제키가 있거나 paid/refunded).
  앱 티켓 카드의 티켓은 서버가 적은 `extra_data.order_id` → `hold_purchase_id` → 원장의 주문 줄 순으로 잇는다(toss-confirm 이 metadata 를 `{toss}` 로 덮어 hold id 가 없다). 같이 쓴 예치금 = 그 회원의 원장 `ticket_purchase` 중 `metadata.order_id` 가 같은 줄.
  예치금 = `deposit_transactions` 의 음수 줄을 (회원, 구매 id) 마다 묶는다(티켓 · 초대 INV- · 인원 늘림) · 구매 id 없는 줄(관리 차감·연회비 · 옛 멤버십 결제)은 줄마다 · 그 구매의 양수 줄(취소 환불 · 방문 후 반환 · 위약 · 인원 줄임 · 정정(fix) · 자동 되돌림 · 카드 승인 뒤 되돌림 — 판매 현황과 같은 분류)이 붙는다 · 부여(입금)·부모 없는 환불은 따로(앱이 기본으로 숨김).
  승인 시점 토스 기록(`metadata.toss`)은 **고른 칸만**(`_taam_pl_toss` — 상태·금액·카드·간편결제·취소·영수증) — 원문의 `secret` 같은 칸은 보고서·캐시·로그 어디에도 싣지 않는다.
- **토스 조회 캐시 `toss_payment_cache`**(RLS 켬 · 정책 없음 · anon/authenticated 권한 없음) ← Edge `toss-payment-info`(슈퍼어드민 · `verify_jwt=true` + profiles.role 재확인): 앱이 보낸 ref(주문번호/청구 id)로 **우리 표에서 결제키를 읽어**(앱이 보낸 결제키는 안 믿는다)
  `GET /v1/payments/{key}` — 승인한 MID 의 시크릿으로(승인 기록 mId → 등록 카드 → 통화로 짐작, 안 되면 나머지 키 차례로) · `GET /v1/settlements?dateType=soldDate`(그 키로 승인일 −1 ~ +35일(오늘까지)을 31일씩) → 결제키가 같은 정산 줄만.
  실패하면 옛 값은 두고 `info_error`/`settle_error` 만. 응답은 건수·오류 코드뿐. 화면은 열 때 **한 번도 안 읽었거나 6시간 지난 것만**(지급까지 끝난 것은 일주일에 한 번) 40건까지 자동으로, 「↻ 토스 정보 새로고침」은 보이는 60건.
- 카드 줄 상태(`_pmxCardView`): 토스를 다시 읽었으면 **토스 취소액(total − balance)이 정답**, 아니면 앱 기록(자동 취소 · `app_cancels` · 「완료 표시」 · 링크 환불액)과 승인 시점 기록 중 큰 쪽 → 결제됨 / 부분 취소 / 전액 취소 / **환불 대기**(`card_refund_pending` pending + `card_refund_queue` — 토스 취소로 설명되면 「완료 표시가 남았다」로).
  경고: 토스에 앱 기록 없는 취소(상점관리자 직접) · 앱은 취소인데 토스엔 남음 · 자동 취소 실패(`*_refund_failed`) · 연결 티켓 없음 · 토스 조회 실패. 상세의 「토스 취소」 줄은 거래키로 출처를 가른다(앱 「토스 승인취소」 · 자동 취소 · 결제 링크 「환불」 · 그 밖 = 상점관리자).
- **예상 입금일**: 정산 줄이 있으면 그 지급일(확정 · 지급액 · 수수료 · 취소분) · 없으면 **같은 MID 의 최근 정산에서 「승인일 → 지급일」 영업일 수의 최빈값**으로 ≈(정산 주기는 계약마다 달라 API 가 안 알려 준다 · 은행 휴일 2026~2027 근사 `_PMX_HOL`) · 매입 전 전액 취소는 「정산 없음」. 정산 줄은 승인 다음 날부터·라이브 키에서만 생긴다.
- 원화는 **기록된 값 그대로**(외화 취소는 기록된 원화를 비율로) — 오늘 환율로 다시 바꾸지 않는다. 버튼: 토스 영수증 · 이 결제 토스 새로고침 · (환불 대기) 「💳 토스 승인취소 실행」(`tkCardRefundViaToss`) / 「완료 표시」(`tkMarkCardRefundDone`) · 결제 링크 목록에서 · 회원 원장 · 예치금↔카드 쪽 보기(`_pmxGo`).
- **적대 리뷰(배포 전 · 3 렌즈 → 반영).** ① **앱이 처리한 뒤의 낡은 토스 캐시가 「토스에는 남아 있다」 경보로 두 번째 환불을 부를 뻔했다** — 앱 처리 시각(`_pmxLastApp`: app_cancels · 완료 표시 · 링크 환불)보다 먼저 읽은 토스 정보는 믿지 않고(앱 기록과 큰 쪽) 다시 읽을 대상으로 · 「승인취소/완료 표시」 뒤 언제나 그 결제를 다시 읽고 조회 중이면 줄을 세운다(`tossQ` · 버리지 않는다) · 두 번 눌러도 한 번(`actBusy`).
  ② 정산 조회 창이 승인일 +35일뿐이라 D-31 취소의 정산 줄(soldDate = 취소일)을 놓치고, 한 건 새로고침이 넓게 읽은 줄을 지웠다 → Edge 가 **취소일마다 창**을 더하고 캐시의 옛 줄과 거래키로 합친다 · 상한(키마다 24번)·캐시 읽기 실패면 빈 배열을 쓰지 않고 `SCAN_TRUNCATED`/`CACHE_READ_FAILED`.
  ③ 같은 홀드에 다시 낸 결제 — 자동 취소된 앞 시도를 다음 결제의 티켓에 잇지 않는다(그 티켓의 `extra_data.order_id` 가 다른 주문이면) · 예치금 묶음 열쇠에 주문번호(`p:회원|구매 id|주문`) · 환불 줄은 주문으로 거른다(`_pmxRf`).
  ④ 정산 청구의 어드민 uid(「구매자 불러오기」)는 회원으로 안 본다(role user 만) · 남의 초대 id 를 적은 원장 줄에 그 초대가 안 붙는다 · 공개 로그에 건수 안 찍는다 · 도우미 함수 authenticated 회수.
  ⑤ 대기 금액(회원 요청액)은 카드 결제액으로 자르고 넘으면 ⚠ · mark_failed 뒤 「완료 표시」가 이중으로 안 세지게(같은 구매의 app_cancels 가 있으면 대기 완료는 안 센다) · 매입 전 전액 취소는 「정산 없음」 · 초대 0원 취소 경보 완화 · 시간 순 정렬 · 번호 검색(010-…/+82) · 바깥 끌기로 안 닫힘 · Esc · 잘못된 기간에 옛 목록 지움.
  옛 구멍(보안 렌즈): 아래 「회원 좌석 행의 결제 링크 연결 칸」.
- **2차 리뷰(수정분 · 4 렌즈 20 에이전트 → 확정 15 · 전부 반영).** 「완료 표시」 뒤 토스 조회가 실패해도 목록은 다시 읽는다 · **자동 취소 뒤 같은 홀드를 예치금만으로 다시 결제**하면 두 묶음이 환불을 나눠 가졌다 →
  주문 없는 묶음은 표시 없는 줄만, 주문 묶음은 (티켓 주문 = 이 주문) 또는 (티켓 주문 없음 · 같은 구매에 예치금만 낸 줄 없음(`plain`) · 주문 취소 아님(`ord_st`))일 때만 표시 없는 줄 · 자동 취소 주문은 다시 결제된 홀드에 잇지 않는다 ·
  외화 주문의 대기·인원 줄임·완료 표시 금액은 **원화**(카드 몫 = settle_krw) → 결제 통화로 바꿔 센다 · 토스 기록 없는 전액 환불을 「정산 없음」이라 하지 않는다 · 카드 번호 「5365 1234」 검색 ·
  Edge: 지급 뒤 취소의 취소분 정산 줄이 아직 없으면 `CANCEL_PENDING`(settle_at 안 씀 · 하루 한 번 다시 · 화면 「취소분 정산 대기」) · 긴 창도 **최근 쪽부터 거꾸로** 읽고 「끝까지 읽음」은 읽은 날짜 범위로 · 캐시 읽기 실패면 토스를 부르지 않음 · 거래키 없는 줄은 칸 값으로 열쇠(jsonb 키 순서).
- **3차(수정분 · 2 렌즈 8 에이전트 → 확정 5 · 전부 반영).** 2차에서 넣은 줄마다의 `not exists` 가 계획 비용을 키워 **JIT 가 호출마다 2초** — 예치금만 낸 결제 집합을 한 번만 세고(`v_plain`) 함수에 `set jit = off`(같은 자료로 2.2초 → 0.15초) ·
  전액 취소·환불은 정산 기록이 없으면 입금 예정일을 지어내지 않는다(「전액 취소 — 토스 정산 조회 전」) · 「정산 없음 — 매입 전 취소」는 앱 처리 **뒤에** 읽은 토스 기록일 때만(승인 기록의 「매입 대기」로 몇 주 뒤 환불을 매입 전이라 했다 · 자동 취소는 승인 기록으로도 된다) ·
  아래 가드를 「역할」이 아니라 「문장의 주인」으로(파트너 계정 · 매장 어드민의 새 홀드 우회).
- **2026-10-28 라이브 적용 ✅** — 자동 배포 #89: `20261028_payment_ledger.sql`(①~⑦ ✅) · `20261028_ticket_link_facts_guard.sql`(①~④ ✅) · `새로 적용 2 · state=ok` · Edge `toss-payment-info` 배포(`Deployed Functions`). 앱 빌드 `2026.10.28-a` 는 Vercel 배포로(훅 접수 · 시크릿창으로 빌드 번호 확인).
  토스 조회(카드 정보·정산)는 슈퍼어드민이 화면을 처음 열 때 처음 돈다 — 정산 줄은 라이브 키에서만·승인 다음 날부터. 해외 MID 정산 통화·정산 주기는 첫 정산 줄로 확인한다.
- 회귀: `bash sql/_test/t_payment_ledger.sh`(86건 — 권한 · 연결 · 예치금 묶음 · 분류 · secret 없음 · KST 경계 · 테스트 제외 · 캐시 · 같은 홀드 두 시도 · 정산 청구 어드민 uid · 남의 초대 id · 재실행) · 스크래치 `tpi/harness.mjs`(29건 · Edge — 권한 · ref 검증 · 결제키는 우리 표에서 · 키 짐작·다음 키 · 고른 칸 · 정산 범위·묶음 · 취소일 창 · 옛 줄 합침 · 상한 · 캐시 읽기 실패) · `pmx/pmx.js`(47건) · `pmx/pmx2.js`(16건 · 리뷰 반영) · `pmx/pmx3.js`(8건 · 2·3차) · `tpi/harness.mjs` 31건 · 리뷰어의 `rev2_edgesettle/h2v2.mjs`(상한·거래키·캐시 실패·오늘 취소).

### 회원 좌석 행의 결제 링크 연결 칸 — 주인도 못 바꾼다 (2026-10-28 · `20261028_ticket_link_facts_guard.sql`)

결제 사실 칸 가드(`20261022_card_refund_quote2.sql` A)는 `linkInvite`·`memberUid` 는 지켰지만 **`chargeId`·`agencyFee`·`agencyPay` 는 안 지켰다** — 결제 링크로 회원 소유가 된 LINK- 좌석(10-18 · 10-23 연결)의 주인이 `chargeId` 를 바꾸면 링크 환불 견적(`taam_link_invite_refund_quote`)이 좌석을 못 찾아 **D-1 에도 전액 환불** 견적이 되고 환불 트리거가 좌석을 못 접었다(좌석이 산다) · `agencyPay` 를 0 으로 바꾸면 환불 불가 대행비까지 돌아갔다(보안 렌즈 재현 · 실제 행 가드 위).
→ `trg_taam_guard_ticket_linkfacts`(BEFORE INSERT/UPDATE · **SECURITY INVOKER — 앱이 직접 보낸 문장만** 본다: `current_user` 가 authenticated/anon 일 때 · 기존 INSERT·행 가드와 같은 방식 · 서버 함수(security definer — 링크 만들기·초대 확정·결제 확정·정산 동기화)·Edge·SQL Editor 는 그대로):
  UPDATE — 슈퍼어드민이 아니면 **어느 행이든** `chargeId · token · currency · payAmount · fx · agencyFee · agencyPay · priceOverride · ovsFixed · eventId · convertedFrom · inviteId · memberUidPending · ownerTransferError · createdBy · paidAt · paymentKey · confirmed_at · confirmed_by · invitePaid · inserted` 변경을 **되돌린다**(예외 아님 · 다른 칸은 그대로 · 앱의 어느 화면도 이 칸을 직접 고치지 않는다 — 앱의 갱신은 읽은 extra_data 에 덧붙이는 모양이라 오히려 낡은 사본이 서버 칸을 지우던 것도 막힌다 · `paidAt`·`confirmed_at` 은 연회비 기준일을 움직였다) ·
  INSERT — **결제 링크·정산 좌석(LINK-·KSK-)은 앱이 직접 못 만든다**(`LINK_SEAT_SERVER_ONLY` — 매장 어드민이 같은 chargeId 로 새 홀드를 넣어 견적이 그 행을 집게 하던 길) · 그 밖의 직접 INSERT 는 연결 칸(`chargeId · token · eventId · convertedFrom · inviteId`)을 지운다(매장 어드민의 초대 홀드 INVH- 는 inviteId 를 둔다 · 표시용 `agencyFee` 는 둔다).
  1·2차 판은 `profiles.role` 로 회원/매장 어드민을 갈랐다 — **파트너 계정은 role 'user' + admin_grants** 라 매장 어드민의 결제 링크 만들기가 「회원 홀드」로 잡혀 chargeId 가 지워지고 결제돼도 좌석이 안 열릴 뻔했고(3차 리뷰 · 배포 전), 매장 어드민은 새 LINK- 홀드를 넣어 되돌림을 비켜 갔다. 회귀 `bash sql/_test/t_ticket_linkfacts.sh`(21건 · `set role authenticated` 로 직접 문장 · security definer 흉내 함수로 서버 경로).

### 파트너(매장 어드민) — 매장 권한은 승인된 것만 · 자기 매장 자료만 (2026-10-29 · `20261029_partner_grants.sql` · Edge `partner-account` · 빌드 `2026.10.29-a`)

「곧 파트너 레스토랑들이 어드민 계정으로 들어온다 — 슈퍼어드민이 승인한 매장에 한해 그 매장 예약 전부와 예약한 회원 정보(예치금·다른 매장 구매 제외)를 보고 검색할 수 있게, 그리고 **모든 어드민 계정은 슈퍼어드민 승인 뒤에만** 티켓 업로드·수정」.
조사(4 리더 + 비평 · 라이브 진단 `20261029_diag_admin_surface.sql`)에서 드러난 종전 모양: 매장 어드민 판정 함수가 넷(`is_ticket_admin_of` · `is_restaurant_admin_of` · `is_venue_admin_of` · `taam_is_rest_admin`)에 옛 표 둘(`restaurant_admins` · `venue_admins`)이 섞여 있었고 ·
`profiles` 에 「예약 요청자의 전 칸(잔액 포함)」을 매장 어드민에게 여는 정책 · 글자 role `'admin'` 이면 **어느 매장이든** MAN-/INVH- 를 넣는 INSERT 가드 · `ticket_products` 파트너 정책은 한 번도 안 쓰인 `profiles.admin_rest_id` 를 봐 사실 막혀 있었고 · `_taam_auth_email(uuid)` 가 누구에게나 열려 있었다.
라이브는 admin_grants 1줄 · restaurant_admins 1 · partner_accounts 0 — **파트너 운영은 이 판부터 시작**이다.

| | 무엇 | 어디 |
|---|---|---|
| **권한 상태** | `admin_grants.status` `pending`(발급 기본) → `approved` → `suspended` · 매장(rest_id/venue_id)마다 · 도장 `approved_by/at` `status_set_by/at` 은 트리거만 | 발급 「🔑 파트너 계정 발급 · 권한 승인」(`paOpen` · 「바로 승인」 체크 · 줄마다 승인/정지/대기로 · 계정 없이 권한만 있는 사람도 같은 목록) → RPC `taam_partner_grant_set(user, rest, status, note)`(슈퍼어드민·서버 · 매장 어드민 본인에게 알림 `partner_grant`) · 목록 `taam_partner_grants_list` · 본인 `taam_partner_my_grants` |
| **판정 하나** | `taam_rest_admin_ok_for(uid, rest)` = approved 줄이 있다 · 옛 이름 7개는 전부 이것으로(라이브 인자 이름을 `pg_get_function_identity_arguments` 로 읽어 보존 — CREATE OR REPLACE 는 인자 이름을 못 바꾼다 · 본문은 `$1`) | 정책식 · RPC · Edge 어디서든 같은 답 |
| **승인 대기·정지 계정** | 로그인은 되지만 어드민이 아니다 — 앱 `_applyServerAdminGrant` 가 `status` 를 읽어 approved 만 올리고, 기기에 남은 'admin' 은 **내린다**(조회 성공 때만 · `window._taamGrantStatus`) · 부팅마다 다시 본다(`bootAutoLogin` · 종전엔 로그인 때만) · 로그인 문구 `auth.partner_pending/_suspended` 세 벌 | 서버는 정책식이 막으니 화면이 남아 있어도 자료는 안 나온다 |
| **자기 매장 자료** | RPC 넷 · `taam_partner_reservations(rest, from, to, q, status)`(좌석 홀드 제외 · 회원 구매·초대·결제 링크·정산·수동 · 줄마다 환불(원장·카드·링크)·취소 사유·메모 · 1500건) · `taam_partner_member(rest, uid)`(이름·전화·이메일·등급·국적·통화 + 이 매장 방문/노쇼/취소/예정 + 이 매장 내역·초대 · **관계 = 이 매장 좌석 행(홀드·만료 제외) 또는 결제된(paid) 초대** — 보낸 초대만으로는 `NOT_RELATED` · 초대 줄은 파트너가 어느 회원에게나 넣을 수 있어 관계로 치면 명부 훑기가 된다(리뷰 재현)) · `taam_partner_member_search(rest, q)`(관계 회원만 부분 일치 · 전 칸 `related:true` · 다른 회원은 **전화번호 10자리를 끝까지 정확히** 쳤을 때만 · 그때는 이름·번호·등급·통화만(`related:false` · 이메일·국적 없음) — 단골 초대는 되고 명부 훑기는 안 된다) · `taam_partner_names(rest, uids)`(이름 채우기 · 같은 관계 규칙) | 화면 「📋 예약 · 회원 조회」(`prvOpen` · 파트너 메뉴 첫 칸 · 슈퍼어드민 메뉴에서는 매장을 골라 「파트너 시야」) · 캘린더 회원 줄(`tcalShowInviteMember` 매장 어드민 판 = `_prvMemberHtml`) · 초대 회원 검색(`riSearchMembers` 매장 어드민 판) · 이름 채우기 다섯 자리(`_taamNamesMap` — 오늘 · 예약 탭 · 보낸 초대 · 초대 회수 · 캘린더) |
| **profiles** | 「예약 요청자 전 칸」 정책 삭제 → 매장 어드민은 **자기 행만** · `get_requester_info` 는 그 매장 범위로 다시(⚠ 예약 요청(Request 탭 · 준비 중)의 venue_id 는 restaurants.id 와 다른 체계라 티켓 건수가 0 으로 나온다 — 그 기능을 켤 때 매핑) · `_taam_auth_email` 본인·슈퍼어드민·서버만(옛 판처럼 **소문자** — 화이트리스트가 소문자 상수와 비교) · `taam_user_tier` 등 9 함수 anon 회수 · `taam_rest_admin_ok_for` 는 회원도 못 부른다(definer 함수만) | 예치금 잔액은 서버가 **주지 않는다**(화면이 숨기는 게 아니다). ⚠ 「📅 예약 관리」(`raLoadRequests`) 는 아직 profiles 를 직접 읽어 파트너에겐 요청자 이름이 「회원 abc123」로 뜬다 — Request 탭이 준비 중이라 그대로 둠 |
| **티켓 업로드 · 수정 승인** | 업로드 = `pending` 행 → 슈퍼어드민 「게시 승인」(active) / 거절(삭제 · `ticket_rejected`) · **승인된 회차의 수정 = `ticket_product_edits` 큐**(별도 표 · 서버가 값을 되돌리고 바뀐 칸만 적는다 · 회원에게는 종전 내용 그대로 · 같은 회차의 다음 수정은 큐에 합쳐진다 · 파트너는 RPC `taam_ticket_edit_cancel(id)` 로 자기 신청을 거둔다 · 읽기는 RPC `taam_ticket_edits()` — 슈퍼어드민·그 매장 승인 어드민만 · 2차 리뷰: 행의 칸에 두면 회원·anon 이 `select('*')` 로 미승인 값을 그대로 내려받고 크기 상한도 없었다) → 슈퍼어드민 「승인 대기」 화면의 「수정 신청」 카드(바뀐 칸 · 「수정 승인 / 반려」 · `tuEditReview` → RPC `taam_ticket_edit_review(id, approve, note)` · 승인은 `jsonb_populate_record` 로 큐의 칸만 반영 · 파트너 알림 `ticket_edit_approved/_rejected`) · 신청·재신청 알림 `ticket_upload_request`(payload `edit`) 는 파트너마다 **시간당 30건**(`taam_rate_hit` — 지우고 다시 넣어 알림함을 채우던 길) · 수정 신청 알림은 같은 회차 10분 안 한 번 · 둘 다 `taam_admin_push` 가 있으면 푸시 · 승인 알림은 pending → active **또는 soldout**(정원 찬 회차는 BEFORE 재계산이 soldout 으로 승인한다) · 알림 트리거는 `UPDATE`(열 지정 없음 — BEFORE 가 바꾼 칸은 `UPDATE OF` 가 못 본다) · 승인 대상 칸 = `_taam_tp_free_cols()` 에 없는 모든 칸(값은 `_taam_tp_norm` 으로 0/''/false/null 을 같게 봄 — 앱 payload 의 `x||0`) | 앱: 파트너 「승인된 티켓 리스트」가 자기 매장 전부(「승인 대기」·「삭제 신청 중」·「수정 승인 대기」 배지 · 대기 회차는 「수정」만 · 삭제 신청 중은 「신청 취소」만) · 매장 어드민 편집은 status 를 **원래대로** 보낸다(`uploadTicket` — 'pending' 을 보내면 `BAD_STATUS_CHANGE`) · 저장 뒤 `_tkRefreshFromServer(보낸 id)` 가 로더로 **직접** 다시 읽어 그 회차만 서버 판으로 교체(`taamSyncNow` 는 15초 안·결제 중이면 건너뛰어 로컬에 「반영된 것처럼」 남았다) · 큐가 새로 생기면 토스트 「수정 신청 접수」 · 로더는 매장 어드민·슈퍼어드민일 때만 `taam_ticket_edits` 를 불러 `pendingEdit` 에 붙인다(회원은 안 부른다) · 파트너 업로드의 앱 알림(`taamNotifyAdmins`)은 뺐다 — 서버 트리거가 적는다(옛 서버만 앱이) · 「어드민 코드」 발급·로컬 동기화의 `admin_grants` insert 는 `status:'approved'`(발급 기본값이 pending 이라 「다음 로그인 때 어드민」이 거짓이었다) · 가드 거절 코드는 사람 말로(`saveTicketProductToSupabase`) · `saveTickets()` 는 매장 어드민이면 자기 매장 것만, 업로드·매진 토글·삭제 신청은 **그 회차 id 만** · 읽기 정책은 anon 도 평가하니 `taam_tp_visible` 하나로 묶어 anon·authenticated 에 execute |
| **Edge `partner-account`** | 옛 서버(status 칸 없음) 판정은 **처음 한 번의 탐색**(`select status limit 1` → 42703/PGRST204 · 다른 오류면 auth 유저를 만들기 전에 끝) — insert 실패 뒤 코드로 판정하던 1차 판은 권한·제약 실패를 옛 서버로 읽어 칸 없이 다시 넣을 수 있었다 · create `approve_now` → approved/pending(감사 칸 `status_set_by`·`approved_by` = 발급자 — 트리거가 **서버 호출(auth.uid() null)만** 보낸 값을 받는다) · revoke = 권한 줄 **suspended + `suspended_via='account'`**(안 지움 · 이미 정지된 줄은 `neq` 로 제외 · 트리거가 `prev_status` 에 직전 상태) + 로그인 잠금 + 세션 폐기 · restore = **권한 먼저 — `suspended_via='account'` 인 줄만**(슈퍼어드민이 RPC 로 「정지」한 줄(`rpc`·옛 null)은 계정을 되살려도 그대로 정지 · `prev_status` 가 approved 였던 줄만 approved · 아니면 pending) → 잠금 해제 → 장부 · `needs_approval` 은 처리 **뒤** approved 줄이 없을 때 · 줄이 없으면 pending 으로 다시(새 서버에서 unique 위반은 삼키지 않는다) · 옛 서버 판정은 **오류 코드**(42703 · PGRST204)로만 — 메시지의 'status' 글자로 하면 전송 오류(Deno fetch 메시지에 URL)도 옛 서버로 읽혔다 · 옛 서버 create 응답은 `grant_status:'approved'` + `legacy_server` | 승인·정지 자체는 Edge 가 아니라 앱 RPC. 「대기로」(RPC) 는 **승인 철회** — `approved_at/by` 를 비운다 |

- **J 절 — admin_grants 를 status 없이 직접 읽던 라이브 본문**(`taam_link_invite_create` = 결제 링크 티켓 만들기의 권한 검사 전부 · `taam_kashikiri_link_ticket` · `taam_ksk_seat_set_pax` · `taam_ksk_seat_rows` · storage 정책 `restaurant_videos_partner_insert`)은 옛 이름 함수를 안 거쳐 승인 대기·정지도 어드민으로 쳤다(리뷰) → `pg_get_functiondef` 에서 그 모양만 `select 1 where public.taam_rest_admin_ok_for(v_uid, …)` 로 바꿔 다시 만든다(모양을 못 찾으면 ⚠ 로 두고 건드리지 않는다 · 확인 표 「J … 남은 함수(정보)」가 아직 직접 읽는 함수를 적는다).
- ⚠ **글자 role `'admin'` 은 더 이상 아무 권한도 아니다** — admin_grants 승인 줄이 없으면 tickets 도 안 보이고 MAN-/INVH- 도 못 넣는다. 매장 어드민을 만드는 길은 「파트너 계정 발급」(또는 회원 계정에 승인 줄)뿐.
- **적대 리뷰(배포 전 · 5 렌즈 → 1차 발견 33 · 반영 29 · 기각 4).** 치명 1: **1차 판의 `enforce_ticket_approval` 이 매진 동기화(tickets 트리거)가 보낸 중첩 UPDATE 를 회원 세션 것으로 보고 `NOT_YOUR_RESTAURANT` → 회원의 마지막 좌석 구매·soldout 회차 취소·홀드 반납이 전부 막혔다**(재현) → `pg_trigger_depth()` 통과 + 설계를 「status pending 되돌림」에서 「pending_edit 큐」로(회원이 산 회차가 사라지던 것 · 한 글자 고쳐 pending 으로 만든 뒤 DELETE 로 회원 티켓을 고아로 만들던 것 · 앱이 'pending' 을 보내 내용이 같아도 거절되던 것을 한 번에).
  그 밖: 승인 대기 회차에 MAN-/INVH-·초대 못 넣음 · 관계 = 결제된 초대만 · 정확 번호 검색은 이름·번호·등급만 · `repurchase_open`·`review_note` 되돌림 · 재승인 비교 칸 이름(`_jp`) · 알림 속도 제한 · `taam_rest_admin_ok_for` 회수 · `_taam_auth_email` lower · B 확인식(옛 본문 잔존 0) · prev_status/승인 철회/서버 도장 · Edge 코드 기반 폴백·순서·needs_approval · 앱 내리기가 콘솔 전체(`_acCloseOthers`)·팝업을 닫음 · 상태 none 문구 · 옛 서버 판정은 칸 없음 모양만 + RPC `taam_partner_my_grants` 먼저 · 승인 대기 회차의 「삭제 신청」 버튼 제거 · `_taamBusyNow` 에 `paSheet`(종전 누락)·prv · `_prvKst` 이스케이프 · Esc · 메뉴 라벨 partner.* 키 · `note` 는 파트너에게 안 줌.
  기각·보류: `invite_codes_read USING true`(종전부터 · 전원 공개 명부 — **보안 점검 과제로 넘김**, 가입 흐름 5곳이 직접 읽어 따로 바꿔야 한다) · 예약 관리 화면 이름(위) · `get_requester_info` venue 매핑(위) · 파트너 콘솔 본문 한국어(콘솔 탭이 원래 한국어 — 메뉴 라벨만 세 벌).
- **2차 적대 리뷰(수정분 · 5 렌즈 → 확정 14 · 전부 반영).** HIGH: **승인된 파트너가 초대 한 줄을 `status='paid'` 로 넣어(또는 자기 초대를 paid 로 바꿔) 아무 회원이든 「관계」로 만들어 이름·전화·이메일·국적을 받았다**(재현) → 관계 = 서버 증거(`_taam_invite_paid_evidence`) + host 가드 `trg_taam_guard_invite_host`(위 표). 그 밖: 중첩 갱신의 pending 지킴이 슈퍼어드민·서버 세션에선 비켜 갔다(좌석이 차면 soldout 으로 공개) → depth 검사를 맨 앞으로 + 슈퍼어드민 MAN-/INVH- 도 `TICKET_NOT_APPROVED` ·
  큐를 행의 칸(`pending_edit`)에 두면 회원·anon 이 미승인 값을 내려받고 상한이 없었다 → 별도 표 + `EDIT_TOO_LONG` · 앱 내리기가 `closeSubPage → openAdmin()` 으로 **정지된 파트너에게 슈퍼어드민 메뉴 화면을 열었다**(자료는 서버가 막지만 화면이 거짓) → `_taamHideAdminConsole`(요소 직접 숨김 · GNB 복구 · `_roleGuardByEmail` 도) ·
  Edge restore 가 슈퍼어드민이 RPC 로 정지한 줄까지 되살렸다 → `suspended_via` · INSERT 가드가 RLS 로 숨은 다른 매장 pending 회차를 「없는 회차」로 봤다 → definer 도우미 + `TICKET_NOT_FOUND` · 승인 알림이 soldout 승인을 놓쳤다 · hidden 등 다른 상태의 회차 상태를 파트너가 바꿀 수 있었다 → 잠금 · 옛 앱의 'pending' 저장 거절 → 「상태 변경 없음」 · C 「이미 새 판」 md5 리터럴 비교가 절대 참이 안 됐다 → `prosrc like` · 파트너 업로드 알림이 앱+트리거로 두 번 · `saveTickets` 뒤 `taamSyncNow` 가 15초 규칙에 걸려 로컬이 낡은 채 · 번호 정확 일치 조회 상한(시간당 30 · `partner_phone_lookup:` · CASE 로 평가 순서 보장) · `taam_partner_my_grants` 가 venue 줄을 rest_id 로 올렸다 → 따로 · `tuEditReview` 가 큐 비움(`nothing_pending`)을 「승인」으로 말했다 · 어드민 코드 발급의 insert 가 pending 줄이었다. 리뷰 에이전트 51명 중 다수가 5시간 한도로 멈춰 **발견은 사람이 판정**했다.
- **3차 적대 리뷰(수정분 · 4 렌즈 → 확정 4 + 기각됐지만 재현된 것 7 · 전부 반영).** ① `taam_partner_member_search` 가 **stable** 인데 번호 조회 상한(`taam_rate_hit`)이 표에 적어 PostgREST 의 READ ONLY 트랜잭션에서 10자리 조회가 **전부 25006 으로 실패**했다 → `volatile` · 상한은 10자리 이상 조회마다 **먼저** 센다(맞는 번호일 때만 세면 틀린 번호 훑기가 공짜였다).
  ⚠ **표에 쓰는 함수(속도 제한 포함)를 부르는 RPC 는 stable 로 선언하지 말 것** — psql 에선 통과하고 라이브에서만 터진다(회귀는 `begin read only` 로 본다).
  ② 수정 승인이 RPC 시점의 큐를 통째로 반영해, 슈퍼어드민이 본 뒤 파트너가 더한 칸(정원·요금)이 승인 도장과 함께 나갔다 → `taam_ticket_edit_review(id, approve, note, p_expect)` — 화면이 본 큐와 다르면 `STALE_EDIT` · 지금 값과 같은 칸은 건너뛴다(`applied_fields`) · 설명(`ticket_desc`)을 바꾸면 번역 상태 `pending`(옛 번역이 새 설명 옆에 남았다) · 큐로 간 설명 저장이 같이 찍은 `i18n_status_*` 는 트리거가 되돌린다.
  ③ 판매 오픈(`sale_state`·`sale_open_at`)을 되돌림 칸에 넣어 파트너의 「예약 오픈 · 비공개 보관」이 조용히 버려지고 **승인 순간 바로 판매**됐다 → 내용 칸(승인 전엔 바로 · 승인 뒤엔 큐) · 칸별 정규화 `_taam_tp_normk`(앱이 보내는 'open' = 서버 null — 아니면 매진 토글마다 「판매 상태 open」 신청이 쌓인다).
  ④ 파트너 업로드 알림 중복 판정을 「승인 도장 있는 회차가 있나」로 봐 첫 승인 전까지 늘 두 번 갔다 → 서버 능력(`window._taamPartnerSrv2` — `taam_partner_my_grants` 가 돌았나).
  ⑤ **값을 원래대로 되돌려도 큐에 옛 신청이 남아 그대로 승인됐다**(트리거는 큐에 합치기만 한다 · 앱엔 거두는 입구가 없었다) → 파트너의 폼 저장은 RPC **`taam_ticket_edit_submit(id, p_row)`**(폼 전체를 승인된 값과 견주어 큐를 그 차이로 **바꾼다** · 차이가 없으면 지운다 · 행은 안 건드린다 · 칸 타입으로 바꿔 견준다) · 폼은 신청 값으로 연다(로더가 숨은 칸 `_pendingView`·`_srvRow` 를 단다 — IDB·JSON 에 안 실림) · 파트너 리스트 「신청 거두기」(`partnerCancelEditRequest` → `taam_ticket_edit_cancel`) · 승인 화면은 「지금 값 → 요청」.
  ⑥ **게시 승인(`approveTicket`)이 슈퍼어드민의 로컬 전체를 upsert**(`saveTickets()`)해 파트너가 승인 대기 회차에 방금 고친 값을 옛 값으로 덮고 그 옛 값을 승인했다 → `_tkApprovePending`: 서버 행을 다시 읽어 `updated_at` 이 화면 때와 다르면 멈추고 다시 보여 주며, 같으면 **그 회차의 status 만** `update … eq status pending` · 거절·삭제 신청 반려도 그 회차만.
  ⑦ 운영 행(MAN-·KSK-·INVH-·비회원 LINK-)의 user_id 는 그 행을 넣은 어드민이라 슈퍼어드민이 그 매장에 수동 좌석을 넣으면 파트너가 **슈퍼어드민의 연락처**를 받았다 → 관계·이름 채우기·검색은 회원 행만(`_taam_pt_member_row` · `_taam_pt_related`) · 어드민 계정(role admin/superadmin)은 회원이 아니다 · 예약 목록 검색도 운영 행을 어드민 프로필로 안 찾는다.
  ⑧ 회차 검사 도우미가 아무에게나 매장·상태를 돌려줘 **숨은 승인 대기 회차의 존재를 묻는 오라클** → `_taam_tp_seat_check(회차, 매장)`(그 매장 승인 어드민·슈퍼어드민만 · 없는 회차·남의 매장 회차는 같은 답 'bad') · 승인 대기 회차 좌석 차단은 security definer 트리거 **`trg_taam_guard_ticket_round_open`**(로그인 호출 전부 · 슈퍼어드민은 MAN-/INVH- 만 — 회원이 숨은 회차 id 로 PAYH- 홀드를 넣어 **승인 전 회차를 살 수 있던 길**도 같이 닫힘).
  ⑨ 파트너가 `admin_grants` 를 직접 select 해 **운영 메모(note)** 를 읽었다(RPC 만 빼고 있었다) → 칸 단위 권한(authenticated 는 note 를 뺀 칸만 · 슈퍼어드민 목록은 정의자 RPC). ⑩ 「어드민 코드」 발급·동기화가 이미 있는 대기·정지 줄의 23505 를 성공으로 읽고 「승인」이라 말했다 → `taam_partner_grant_set(approved)`.
  기각·보류: 옛 앱(2026.10.28-a) + 새 서버에서 파트너의 전체 upsert 가 낡은 로컬 값을 「수정 신청」으로 남길 수 있다(파트너 0명이라 실제 창은 없다 · 승인 화면이 「지금 값 → 요청」을 보여 준다) · venue 전용 권한 줄은 티켓 어드민이 아니다(종전과 같음). 리뷰 확인 에이전트 11명이 사용 한도로 멈춰 그 몫은 사람이 판정했다.
- **4차 적대 리뷰(3차 수정분 · 3 렌즈 41 에이전트 → 확정 8(5종) + 기각됐지만 재현된 것 6 · 전부 반영).** ① **「어드민 코드」 화면을 열면 정지·승인 철회한 파트너가 저절로 다시 승인됐다**(3차에서 넣은 23505 → 승인 RPC 가 화면을 열 때마다 도는 동기화에도 걸렸다 · 재현) → 동기화는 이미 있는 줄을 **그대로** 두고, 발급은 상태를 읽어 승인 대기만 묻고 승인 · 정지는 「파트너 권한 승인」에서만 · `taam_partner_grant_set` 은 상태가 같으면 아무것도 안 바꾼다(알림·메모 반복 없음 · `changed`).
  ② **저장형 XSS** — 승인 대기 카드가 파트너가 쓴 날짜·시각을 innerHTML 로, id 를 onclick 에 그대로 넣어 슈퍼어드민 세션에서 돌았다 → 서버 입력 검사 `_taam_tp_check_input`(파트너 쓰기 · 바뀐 칸만 · id/date/time 형식 · 그 밖 글자(jsonb 안쪽 포함)는 HTML 태그 모양·`javascript:` 금지 → `BAD_INPUT`) + 앱 이스케이프·id 정리. ⚠ 파트너가 쓰는 칸을 그리는 새 화면은 반드시 이스케이프한다.
  ③ 승인 카드가 값을 80자에서 잘라 81자째부터 바꾼 설명이 「같은 값 → 같은 값」으로 보였다 → 값 전체(칸 안 스크롤 · 길이 표시). ④ 신청 값 판 없이 열린 폼(IDB 폴백 · 큐 조회 실패)이 저장 때 앞 신청을 조용히 지웠다 → `taam_ticket_edit_submit(id, row, p_expect)`(폼이 열린 때의 큐 · 다르면 `STALE_EDIT`) · 큐 표시만 있고 판이 없으면 먼저 다시 읽고 연다.
  ⑤ 승인 화면의 낡은 화면 검사가 **뒤에서 새로 읽은** 값과 견줘 화면에 없던 값이 승인됐다 → 그린 순간의 스냅샷 `window._paShown`(큐 · 서버 시각)을 보내고 · 뒤에서 다시 읽으면 승인 화면도 다시 그리며 · 파트너 쓰기의 `updated_at` 은 서버가 적는다(옛 값을 보내 비켜 가던 길).
  그 밖: 삭제 승인·업로드 거절은 서버가 그 상태일 때만 지운다(`deleteTicketProductFromSupabase(id, 상태)` → 0행이면 「이미 처리된 회차」 — 다시 팔리는 회차를 낡은 카드가 지우던 길) · 슈퍼어드민의 전체 저장 세 곳(판매 모드 · 삭제 · 마감 연장)을 그 회차만 · 서버 카드 확정 폴백(PAYC-)도 승인 대기 회차엔 못 넣는다(회원 결제 행은 누가 넣든 · UPDATE 로 옮기거나 되살리는 것도) ·
  게스트석·재구매 해제 도장 칸(`guest_*` · `repurchase_open_at`)은 되돌림 칸 · 객체 정규화(빈 값 키 무시 — slots 의 strict:false) · 예약 목록이 어드민 계정의 시험 구매에 그 사람 연락처를 안 붙인다 · 수정 폼이 마감 날짜·시각을 되살린다(종전엔 스위치만 켜고 값을 비워 바꾼 것 없는 저장이 마감을 지웠다 — 슈퍼어드민 수정에도 있던 버그).
  기각: 옛 앱 + 새 서버의 중복 알림 · venue 전용 권한 줄(종전과 같음).
- **5차 검증(4차 수정분 · 2 렌즈 20 에이전트 → 확정 5 · 전부 반영 + 기각 중 값싼 것).** ① **저장형 XSS 두 곳 더** — 승인된 파트너가 REST 로 수동 좌석(tickets MAN-)의 시각·구매 id·손님 이름, 초대(reservation_invites)의 매장 이름·시각에 HTML 을 넣으면 **슈퍼어드민의 티켓 캘린더**와 **회원의 초대 결제 팝업**(회원 세션 — 예치금 결제까지 몰 수 있다)에서 돌았다(재현) →
  서버 **K 절 `trg_taam_guard_text_input`**(tickets · reservation_invites · daegwan_manual · restaurant_visit_notes · restaurants · 로그인 호출(슈퍼어드민 제외) · **새로 생긴 글자만**(`_taam_text_bad` — 같은 칸의 옛 글자는 건너뛴다 · 옛 내용 때문에 취소·출석이 안 막히게) · 구매 id 는 영문·숫자·_.:- 만) + 앱 이스케이프(캘린더 상세 `partHtml` 의 시각·배지·이름·묶음 이름·회차 시각 · onclick id 는 `_q()` 로 정리 · 초대 결제 팝업 `_riEscHtml`).
  ⚠ 회원·파트너가 쓰는 표에 새 칸을 그릴 때는 이스케이프한다 — 서버 검사는 「<영문」 모양만 막는다(따옴표 등 속성 탈출은 그리는 쪽 몫).
  ② 업로드(INSERT)가 게스트석·도장 칸(`guest_*` · `repurchase_open_at` · `audience`)을 위조한 채 들어왔다(UPDATE 만 되돌렸다) → INSERT 에서 기본값으로. ③ 오프라인 폴백에서 수정 폼이 다시 읽어도 신청 값 판이 없으면 승인된 값으로 열려 저장 때 앞 신청을 지웠다 → 열지 않고 「연결 확인」.
  그 밖: 업로드 승인 카드에 **승인할 내용**(가격·요금·정원·설명·판매 상태 …)을 보여 준다 · 게시 승인은 그린 순간의 서버 시각을 조건으로 갱신(`eq updated_at` · 원자적) · 어드민 계정이 회원 모양으로 산 줄은 손님 칸(자기 연락처)·uid 도 안 주고 그 번호로 검색도 안 걸린다(`_taam_pt_admin_owned`) · 입력 검사로 거절된 새 업로드는 화면에서도 치운다.
  기각: 「<A코스>」 같은 영문 꺾쇠 문구 거절(의도된 보수적 규칙 — 안내 문구에 「[A코스]」 예시) · 업로드 카드 스냅샷 재그리기(카드가 이제 내용을 보여 준다).
- ⚠ 매장 어드민이 보는 화면에서 **profiles 를 직접 읽지 말 것**(자기 행만 온다 — 이름이 빈 채 조용히 그려진다). 이름·연락처는 `_taamNamesMap(uids)` · 회원 정보는 `taam_partner_member` · 검색은 `taam_partner_member_search`.
- 배포 순서는 워크플로가 지킨다(SQL → Edge) · 앱은 Vercel. 새 앱 + 옛 서버: status 칸 없음 폴백(줄 있으면 어드민) · RPC 없음 「서버 준비 필요」. 옛 앱 + 새 서버: 매장 어드민의 전체 upsert 가 남의 매장 행에서 거절되고 이름 채우기가 빈칸 — 둘 다 자료 손상은 없다.
- 회귀: `bash sql/_test/t_partner_grants.sh`(253건 — 5차: 수동 좌석 시각·구매 id·손님 이름·extra_data · 초대 매장 이름 · 수동 기록 · 한글 꺾쇠 통과 · 슈퍼어드민 밖 · 옛 태그 남은 행의 취소 · 업로드 게스트석 기본값 · 어드민 시험 구매 손님 칸 / 4차: 입력 검사(시각 HTML · id 따옴표 · 설명 태그 · 한글 꺾쇠 통과 · jsonb 안쪽 · 바뀐 칸만) · 서버 updated_at · submit p_expect · 게스트석 칸 · 객체 정규화 · grant_set 같은 상태 · 서버 PAYC- · UPDATE 옮김·되살림 · 시험 구매 연락처 / 3차: 판매 오픈 · 수정 신청 저장(교체·되돌림·거둠·타입·권한·상한) · STALE_EDIT · 같은 값 건너뜀 · 설명 번역 상태 · 운영 행 관계 · note 칸 권한 · 회차 검사 도우미 · 승인 대기 회차 홀드 · volatile/READ ONLY · 상태 전이·철회·prev_status·`suspended_via`·서버 도장 · 판정 · 글자 role · INSERT 가드(승인 대기 회차 · 슈퍼어드민 · 없는 회차 · 숨은 다른 매장 회차) · 업로드 승인 흐름(upsert · 매진 토글 · **수정 큐 표 · 상한 · 승인/반려/nothing_pending · 거둠 RPC · 되돌림 칸 · hidden 잠금 · 옛 앱 'pending'** · 삭제 · soldout 승인 알림 · 10분 알림 중복) · **중첩 매진 동기화(회원 마지막 좌석 · 취소 · pending 지킴 — 회원·슈퍼어드민·서버 세 세션)** · 초대 매장 · **host 가드 7건** · profiles · RPC 다섯(잔액 없음 · 관계 = 증거 셋 · 검색 두 부류 · 번호 조회 상한) · J 교체·storage · 알림 상한 · 권한 · 재실행 — 픽스처에 **라이브 모양의 `sync_ticket_soldout`(pending 도 soldout 으로 민다)** 과 직접 조회 함수 둘을 올린다) · 스크래치 `pgrant/pg.js`(119건 · 앱 — 5차: 캘린더 상세를 실제로 그려 XSS·onclick 탈출 없음 · 초대 팝업 이스케이프 · 오프라인 폼 막음 · 업로드 카드 내용 · 원자적 승인 · 거절 업로드 치움 / 4차: 승인 카드 XSS·id·값 전체·스냅샷 · 그린 큐로 승인 · 삭제 승인·거절 상태 조건 · 전체 저장 세 곳 · 폼 다시 읽기·마감 복원 · submit p_expect·STALE · 동기화 그대로 / 3차: 수정 신청 저장 경로·옛 서버 폴백 · 로더 숨은 칸 · 신청 값으로 여는 폼 · 신청 거두기 · 지금 값 → 요청 · p_expect/STALE · 게시 승인 그 회차만·바뀌었으면 멈춤 · 반려 그 회차만 · 동기화 23505 → 내리기 뒤 슈퍼어드민 메뉴 없음 · 로더 큐 RPC · 저장 뒤 다시 읽기 · 알림 중복 · 어드민 코드 승인 줄) · `pacct/harness.mjs`(21건 · Edge — 탐색 · suspended_via · rpc 정지 줄 보존).

### 🔐 보안 점검 (2026-10-29 · 6 렌즈 24 에이전트 → 확정 8)

「파트너 기능 뒤에 지금 구멍이나 취약한 보안 부분을 점검해 업그레이드」. 정책·권한 / 서버 함수 / Edge / 화면 XSS / 스토리지 / 로그인·가입 여섯 렌즈 → 발견마다 재현·영향 반박 2명.

| 확정 | 무엇 | 처리 |
|---|---|---|
| **치명** | 회원이 자기 이름(`profiles.display_name`)·이메일·전화에 태그를 넣으면 **슈퍼어드민의 캘린더 회원 정보**(`tcalShowInviteMember`)에서 돌았다 — 슈퍼어드민 세션 탈취 | 이스케이프 + 서버 글자 검사(K 절에 profiles) |
| 높음 | 같은 칸이 「어드민 코드 부여」의 고른 회원 꼬리표(`acSelectMember`)에서 돌았다 | 이스케이프 |
| 높음 | **초대 코드 표가 비로그인에게 공개**(`invite_codes_read` roles public · USING true) — 전 초대장의 이름·전화·이메일·등급·코드·사용 여부 | anon 차단(`20261029_security_audit.sql` ①) · ⚠ 회원끼리는 아직 읽힌다 |
| 높음 | `taam_change_party_size` 가 호출자가 적은 환불액을 그 행 주인의 예치금에 넣었다 — 파트너가 자기 수동 좌석으로 예치금을 만들고, 회원 구매에서 한 명 줄이며 대행비까지 돌려줄 수 있었다 | 서버 덧댐(같은 파일 ②) |
| 중간 | `_taam_auth_email` 이 비로그인 호출을 「서버」로 봐 아무 회원의 이메일을 줬다(파트너 마이그레이션 판) | JWT 역할로 서버 판정 · anon 실행 권한 회수 |
| 낮음 | Edge `notify-guest-booking` — 승인 대기·정지 파트너도 유료 알림톡을 보냈고 속도 제한이 없었다(force 로 무한 재발송) | `status=eq.approved` · 보내는 사람 시간당 40 · 한 예약 하루 4번(`taam_rate_hit`) · 200 「발송 한도」 |
| **높음 · 보류(인증 담당)** | **초대제 가입 우회** — 전화에 묶인 초대 코드를 이메일 OTP 로(또는 그 반대로) 쓰면 문지기(`taam_guard_signup`)가 묶인 채널을 안 본다(양쪽 다 있을 때만 대조) · 가입 문지기와 등급 판정(`taam_invited_tier`)이 회원이 적는 `raw_user_meta_data.phone` 을 믿어 남의 초대 번호로 M 등급을 받는다 | 고치는 안: 초대장이 묶은 채널의 **인증된** 값(auth.users.phone/email)만 대조 · 메타데이터 번호 폴백 삭제 · 「대조할 값 없음」은 거절. ⚠ 소셜 첫 로그인(초대장의 이메일/번호와 다른 채널) 흐름이 막힐 수 있어 운영 결정이 필요하다 |
| **높음 · 보류(인증 담당)** | 로그인한 회원끼리는 초대장을 서로 읽는다(위 anon 차단 뒤에도) | 고치는 안: 가입·로그인 흐름의 다섯 읽기(index.html 프로필 보충 · 가입 직후 등급 조회 두 곳 · OTP 확인 뒤 대조 · 이름 보충)를 인증된 이메일/번호로만 찾는 security definer RPC 로 옮긴 뒤 정책을 「자기 줄 + 슈퍼어드민」으로 |

**수정분 리뷰(2 렌즈 → 확정 2 · 반영).** ① **HIGH — 인원 변경 한도가 회원이 적은 행 금액을 믿었다** — 회원(파트너와 짠 회원·파트너의 두 번째 계정)이 REST 로 금액 ₩1억의 미결제 PAYH- 홀드를 넣고 파트너가 인원을 줄이면 한도(행 금액 ÷ 인원)가 그대로 부풀어 예치금이 생겼다(재현) →
위 표의 확정 구매·회차·정가·원장 한도. 한 명씩 나눠 줄이면 남긴 대행비가 새던 것(기각됐지만 재현)도 같이 — 앱 기본값 `_paxPolicyDefault` 도 같은 식(아니면 두 번째 감소의 제안액이 서버에 거절된다).
② LOW — 오늘 보드·예약 탭(`_tbRow`·`_rvRow`)이 운영 행에도 「인원 변경」을 그려 누르면 언제나 거절 → 운영 행엔 버튼 없음(캘린더와 같은 조건 · 수동은 캘린더 「수정」).
덤(스캔 중 발견): 회원 관리 카드(`renderMemberList`)가 이름을 onclick 문자열에 `_esc` 로 넣어 `');alert(1);//` 같은 이름이 슈퍼어드민 세션에서 돌았다(HTML 이스케이프는 JS 가 돌기 전에 풀린다 · 꺾쇠가 없어 서버 글자 검사도 지난다) → `data-uid` 만.
⚠ 보고만(인증 담당): 가입 때 GoTrue 가 `raw_user_meta_data.display_name` 을 `sync_profile_email_from_auth`(definer · auth.uid() null)로 profiles 에 복사해 K 글자 검사를 비켜 간다 — 화면 이스케이프가 막지만 그 sync 함수에서 `_taam_text_bad` 값은 비우는 것이 맞다.
회귀: `t_security_audit.sh` 35건(+11) · 스크래치 `sa2/t.js`(14건).
기각 1: 서버 전용 함수 일부(`taam_restock_kick` 등)가 public 만 거두고 anon·authenticated 기본 권한이 남은 것 — 회원 세션 안 트리거가 그 함수를 부르는지 먼저 봐야 해서(거두면 취소가 깨질 수 있다) 따로 점검.
회귀: `bash sql/_test/t_security_audit.sh`(24건 — 라이브 모양 정책·저장소의 실제 인원 변경 함수 · 고치기 전 재현 둘 · anon 차단 · 회원·슈퍼어드민 그대로 · 운영 행·자기 구매·한도·30분·슈퍼어드민 · 재실행 · 모르는 판 ⚠) · `t_partner_grants.sh`(260건 · 이메일 조회·회원 이름 검사) · 스크래치 `ngb/harness.mjs`(6건 · 알림톡) · `pgrant/pg.js`(122건 · 두 화면 실제로 그려 XSS 없음).

### 초대 결제 보안 — 받는 회원은 금액을 못 바꾸고, 원장 결제가 있어야 「결제됨」·좌석 확정 (2026-10-22 · `20261022_invite_payment_guard.sql` · **라이브 ✅**)

라이브 진단(`20261022_diag_invite_guard.sql`): `reservation_invites` 의 UPDATE 정책(resinv_update)이 받는 회원에게 자기 초대 행의 **모든 칸**을 허용했고 트리거가 없었다(total_amount · pax · 대행비 · invitee_user_id …).
앱 `riPay` 는 그 행의 `total_amount` 로 예치금을 빼고, 확정 RPC `taam_invite_confirm_hold` 는 `status='paid'` 만 보고 원장을 안 본다 → 금액을 낮춰 덜 내거나, 「결제됨」으로 바꿔 돈 없이 좌석을 확정할 수 있었다.
회원 환불(`taam_refund_cap`)은 티켓 취소 여부를 안 봐서 「결제 → RPC 로 스스로 환불 → 티켓은 살아 있음」도 됐다(PAYH- 공통). 악용 흔적 없음(paid 초대 46건 전부 원장 결제 = 합계).
- **A `trg_taam_guard_invite_row`**(reservation_invites BEFORE UPDATE): 받는 회원 본인 세션은 `status · paid_at · cancelled_at · invitee_seen` 만 바뀐다(나머지는 `jsonb_populate_record` 로 되돌림 — 칸이 늘어도 기본은 못 바꿈) ·
  `paid` 로 바꾸려면 **원장 순결제(`_taam_invite_net_paid` = 이 초대 결제(invite_id 또는 INV-앞8자리) − 그 결제의 환불) ≥ 합계**(`INVITE_NOT_PAID`) · 취소·만료된 초대는 못 되살린다(`INVITE_CLOSED`).
- **B `trg_taam_guard_invite_paid_seat`**(tickets BEFORE INSERT/UPDATE OF status): 초대 좌석(`extra_data.inviteId`)이 받는 회원 세션에서 active 가 될 때 순결제 ≥ 합계 — 「결제 → 결제됨 → 스스로 환불 → 확정」 차단.
- **C `trg_taam_guard_ledger_refund_active`**(deposit_transactions BEFORE INSERT): 회원 세션의 양수 `ticket_refund` 는 그 구매의 본인 티켓이 살아 있으면 `REFUND_TICKET_ACTIVE` — 먼저 취소(앱 `cancelTicketPurchase` 가 이미 그 순서) ·
  홀드·취소·만료·티켓 없음(riPay 확정 실패 되돌림)은 그대로 · 인원 줄임(서버 함수 `ticket_pax_change`)·슈퍼어드민·서버는 그대로.
- 보낸 사람(host)·슈퍼어드민·서버(auth.uid() null)는 전부 그대로. **라이브 함수 본문은 안 건드렸다**(덧대기). 확인 표 ⑤⑥ 0건 · ⑦ 「살아 있는 티켓인데 회원 환불 줄」 2건(정보 — 슈퍼어드민 처리 포함일 수 있다).
- **2차(같은 날 · `20261022_invite_payment_guard2.sql` · 라이브 ✅ · ⑤⑥ 0건).** 적대 리뷰(재현): ① 순결제가 invite_id 와 INV-앞8 구매 id 중 하나만 맞아도 세어 **결제 한 줄로 두 초대** 확정 ·
  ② 구매 id P1 로 내고 P2 로 확정하면 좌석은 P2 로 살고 P1 결제를 전액 스스로 환불(가드 C 는 P1 티켓만 봤다). → `_taam_invite_net_paid(초대, 회원, 구매 id)`: invite_id 가 있으면 **그 초대에만** ·
  가드 B 는 **새 좌석의 purchase_id 로 낸 결제만** · 가드 C 는 환불이 가리키는 초대(결제 줄의 invite_id · 환불의 invite_id)의 좌석이 살아 있으면 거절. riPay 는 원장·확정이 같은 `_riPurchaseId` 라 그대로.
- 앱 `riPay`: 차감 뒤 「결제됨」 갱신이 가드에 막히면(INVITE_CLOSED/INVITE_NOT_PAID — 그 사이 초대가 닫힘) **그 자리에서 되돌린다**(ticket_refund · reason `invite_closed` · 판매 현황은 되돌림으로 센다) · 「예약 완료」로 안 간다.
- 초대 값 변경 흔적 진단(`20261022_diag_invite_tamper*.sql` · 2026-10-22): 61건 모두 합계=(식사+대행+주류)×인원 · 결제=합계 · 확정 좌석=초대 · **보낼 때 홀드 19건 전부 지금 값과 같다** → 흔적 없음.
  회차 정가와 1인 금액이 다른 7건 중 6건은 같은 회차 다른 초대들과 같은 값(어드민 가격), 1건(`09faf15c` · 10/13 스시 사이토 3명 ₩2,550,000)은 보낸 사람 확인 필요.
  ⚠ 슈퍼어드민 「초대 발행」 알림(`invite_sent`)은 DB 에 남지 않는다(0건) — 보낼 때 값의 대조 근거로 못 쓴다.
- 회귀: `bash sql/_test/t_invite_guard.sh`(29건 — 실제 `taam_invite_confirm_hold` 를 올려 결제→결제됨→(환불)→확정 순서 · 2차 G1~G7 · ⚠ 픽스처 초대 id 는 **앞 8자리가 달라야** 한다(INV-앞8자리 구매 id)).

### 카드 결제분 환불을 앱에서 — 토스 승인취소 (2026-10-22 · Edge `toss-card-refund` · 빌드 `2026.10.22-c` → 2차 `2026.10.22-d`)

종전: 회원이 카드가 섞인 티켓을 취소하면 앱은 예치금 몫만 돌려주고 카드 몫은 `tickets.extra_data.card_refund_pending{amount, order_id, status:'pending'}` 로 남겼다 →
슈퍼어드민이 **토스 상점관리자**에서 승인취소 → 앱 「카드 환불 완료」(`tkMarkCardRefundDone` · 회원 알림·푸시).
- ⚠ **적대 리뷰(첫 판 배포 전 · 확정 2 · 재현): 대기(`card_refund_pending`)의 금액·주문번호는 회원이 쓸 수 있는 칸이다** — 취소한 싼 티켓의 대기를 「₩1,700,000 · 살아 있는 비싼 티켓의 주문」으로 바꾸면 슈퍼어드민 클릭에
  그 주문이 환불되고 좌석은 살았고, 완료를 대기로 되돌리고 금액을 1원 바꾸면 중복 방지 키가 달라져 두 번째 실제 취소가 됐다. → **금액·주문은 서버가 센다**(`20261022_card_refund_quote.sql`):
  `trg_taam_guard_ticket_payfacts`(취소 순간 `server_cancelled_at` · 회원·매장 어드민은 결제 사실 칸 card_refund_pending·order_id·cardPaid·depositUsed·paidBy·card_currency·card_amount_fx 를 못 바꾼다 — 대기는 **취소하는 그 갱신에서만** · `set_by_role` member/superadmin) ·
  `taam_card_refund_quote(구매)`(슈퍼어드민·서버만): 이 구매의 주문을 **`payment_orders.metadata.hold_purchase_id`** 로 찾고(없으면 서버가 적은 order_id 의 홀드 없는 주문 = PAYC 폴백) 회원 규정으로 카드 몫을 다시 센다 —
  환불 가능 총액(카드 승인 30분 안 → 총액 · 방문 D-31 이상 → 총액 − 대행비×인원 · 그 뒤 0 · 취소 시각 = 서버 취소 시각 → 첫 환불 원장 → 지금) − 예치금으로 낸 돈 = 카드 몫(0~카드 결제액) ·
  목표 = 회원이 적은 대기면 min(대기, 카드 몫) · 슈퍼어드민이 적은 대기(특별 환불)면 min(대기, 카드 결제액).
- **Edge `toss-card-refund`**(슈퍼어드민 · `verify_jwt=true` + profiles.role 재확인): 입력 `{purchase_id, dry_run | expect_amount}` → 서버 견적 → 토스 `GET` 의 이미 취소된 금액(totalAmount − balanceAmount)을 빼고 **남은 만큼만**(중복 환불이 원리적으로 안 된다) ·
  `dry_run` 은 금액만(앱 확인창) · 실행은 `expect_amount` = 지금 금액이어야(`amount_changed`) · `Idempotency-Key: taam-crf-<구매>-<지금까지 취소된 금액>` · 아래 ② 이후는 종전 설명과 같다(시크릿·기록·mark_failed).
- (첫 판 설명 — 금액·주문을 대기에서 읽던 부분은 위로 대체) 입력 `{purchase_id}` → ① 대기(좌석이 살아 있으면 `ticket_active`) ② `payment_orders`(paid · payment_key · 주인 = 티켓 주인) —
  시크릿은 **승인한 MID 의 것**: 등록 카드 자동결제(`metadata.paid_via='billing_key'`)는 `TOSS_BILLING_SECRET_KEY`(없으면 `TOSS_SECRET_KEY`), 결제창은 `TOSS_SECRET_KEY` · **외화 주문은 막는다**(대기 금액이 원화라 단위가 다르다 → 상점관리자) ③ 토스 `GET /v1/payments/{key}` 의 `balanceAmount`
  (이미 상점관리자에서 취소면 `already_canceled_at_toss` · 넘치면 `exceeds_balance`) ④ `POST …/cancel {cancelReason, cancelAmount}` + **`Idempotency-Key: taam-crf-<구매>-<금액>`**(두 번 눌러도 한 번) ⑤ 대기 → done(+ `toss_tx` · 처리자 · `via:'toss_api'`) ·
  `payment_orders.metadata.app_cancels` 에 한 줄(**status 는 그대로** — 판매 현황·수수료 계산이 paid 로 센다). 기록이 실패해도 토스 취소는 됐다 → `{ok:true, mark_failed:true}` 로 앱이 완료 표시. 업무 오류는 HTTP 200 + `{ok:false,error}`(권한만 403).
- 앱: 「예치금 반환 관리」 카드환불 카드와 「전체 티켓 구매내역」 대기 줄(슈퍼어드민 · 카드 클릭과 분리 `event.stopPropagation`)에 **「💳 토스 승인취소 실행」** — **서버 미리보기**(`dry_run` · 확인창에 서버 금액 · 규정 · 카드 결제·이미 취소 · 대기 기록과 다르면 ※) → 실행(`expect_amount`) · `tkCardRefundViaToss`(바쁨 가드 · 처음부터 끝까지) → 성공하면
  `tkMarkCardRefundDone(pid, {notifyOnly:true})` 로 회원 인앱 알림·푸시(앱은 티켓을 다시 쓰지 않는다) · 이미 토스에서 취소됨 → 「완료로 표시?」 · 함수 미배포 → 「서버 준비 필요」. 종전 「상점관리자에서 처리함 · 완료 표시」는 외화·옛 포트원·API 실패용으로 남김(`via:'manual'`).
- 회귀: `bash sql/_test/t_card_refund_quote.sh`(16건 — 결제 사실 칸 보호 · 30분/D-31/규정 0 · 부풀린 대기 · 슈퍼어드민 대기 · PAYC 폴백 · 다른 구매에 묶인 주문 · 권한) ·
  스크래치 `tcr/harness2.mjs`(15건 · 가짜 토스·Supabase — 미리보기 · amount_changed · 이미 취소된 금액 빼기 · 키 · 시크릿 · 기록 실패) · `crf/crf.js`(16건 · 미리보기→확인→실행 · 대기와 다른 서버 금액 · 구매내역 버튼).
- **2차(배포 뒤 적대 검증 22 에이전트 → 확정 반영 · `20261022_card_refund_quote2.sql` · Edge v2 · 빌드 `2026.10.22-d`).**
  ① 결제 사실 칸 보호가 **UPDATE 만** 봤다 — 회원이 홀드를 **만들 때** `extra_data.order_id` 에 자기의 다른(홀드 없는) 주문을 적고 취소하면 PAYC 폴백이 그 주문을 잡았다(`set_by_role:'superadmin'` 도 만들 때 넣을 수 있었다) →
  `trg_taam_guard_ticket_payfacts_ins`(BEFORE INSERT · 회원·매장 어드민 세션은 보호 칸을 **지운다**) · 보호 칸에 `super_admin_processed_at/_by` · `deposit_return` 추가. PAYC 폴백은 **`PAYC-` 행이고 다른 살아 있는 티켓이 그 주문을 안 쓸 때만** · 주문 메타의 `ticket_id` 가 이 티켓 회차와 다르면 `order_ticket_mismatch`.
  ② 방문일을 회원이 홀드 때 적은 `reservation_date` 에서 먼저 읽어 D-31 을 속일 수 있었다 → 견적은 **회차 날짜 먼저** · 같은 트리거가 회원 홀드(`PAYH-`)의 `reservation_date`·`visit_time` 을 **회차 값으로 맞춘다**(종전 예치금 환불 한도 `taam_refund_cap` 의 D-31 판정도 같은 칸을 봐서 함께 닫힌다).
  ③ (종전부터) toss-order 가 다른 회차의 홀드 id 를 주문에 남기면 toss-confirm 이 그 비싼 홀드를 싼 주문 금액으로 확정할 수 있었다 → `trg_taam_guard_ticket_price_floor`(앱 구매 `PAY*` 의 hold→active 금액 ≥ 회차 정가×인원 · 외화 제외 · `PRICE_BELOW_TICKET`). 근본 원인은 toss-order/toss-confirm(대시보드 판 · 대조 전) — 하한이 받친다.
  ④ Edge 가 「토스에 이미 취소된 금액 전부」를 빼서 **인원 줄임 카드 부분취소**가 있던 결제는 이번 환불이 그만큼 줄었다 → 견적이 `done_for_purchase`(이 구매에 앱이 이미 한 카드 취소 · `payment_orders.metadata.app_cancels`)를 주고 Edge 는 **min(목표 − 그것, 토스 잔액)** · 앱 밖 취소(인원 줄임·상점관리자)는 `other_cancelled` 로 확인창에 ※ 경고.
  키는 `taam-crf-<구매>-<이 구매의 앱 취소 누적>` · 결과 오류 `already_done_by_app` · `nothing_left_at_toss` → 앱 「완료로 표시?」 · 기록 실패(`mark_failed`)면 앱이 **서버가 실제로 돌려준 금액**을 `refunded_amount` 로 적는다(대기 금액 아님).
  ⑤ 이 파일 전에 생긴 대기(라이브 2건)는 서버 취소 시각·`set_by_role` 이 없어 「지금 취소」·「회원 대기」로 셌다 → 채움(요청 시각을 결제~지금 사이로 · 처리자가 실제 슈퍼어드민이면 superadmin).
  ⑥ **배포 전 2차 리뷰(9 에이전트 → 확정 2) + 재검증(2 에이전트 → 확정 7) — 자동 취소는 단순한 경우만.** 인원 줄임(`taam_change_party_size` — price·party_size 를 줄이고 카드 몫은 `card_refund_queue` → 상점관리자) ·
  상점관리자에서 먼저 한 취소 · 같은 구매 id 로 다시 넣은 홀드(회원이 created_at 까지 적는다) · 결제창 확정(toss-confirm)이 주문 메타를 `{toss}` 로 덮는 것 — 이 겹침에서 상한이 처음 금액으로 부풀거나 두 번 환불되는 길이 여럿 나왔다.
  → 견적은 거절하고 상점관리자 + 「완료 표시」로 보낸다: 같은 구매 id 의 행이 둘 이상(`purchase_id_reused`) · 주문은 **티켓 행의 서버 `order_id`** 로만 묶는다(메타 hold_purchase_id 가 있으면 이 구매여야 — `order_other_purchase`) · 그 주문을 다른 행도 씀(`order_shared`) ·
  인원 변경 흔적(원장 `ticket_pax_change` · `pax_changes` · `card_refund_queue` · 금액/인원이 주문 메타와 다름 → `pax_changed`) · Edge 는 **토스에 앱 밖 취소가 하나라도 있으면**(`outside_cancel`) 자동 취소 안 함 → 앱 「이미 했으면 확인 = 완료 표시 · 아니면 상점관리자에서」.
  남는 계산: 총액 = 티켓·메타 중 작은 쪽 · 인원 = 큰 쪽 · 카드 몫 = 규정 − max(낸 예치금, 돌려준 예치금). 회원(소유자) 세션은 `pax_changes`·`card_refund_queue` 를 못 바꾸고(매장 어드민의 인원 변경 함수는 그대로) **이미 있는 구매 id 로 티켓 행을 못 넣는다**(`PURCHASE_ID_TAKEN` · 앱은 언제나 새 id).
  예치금 쪽 덧댐 `trg_taam_guard_ledger_refund_paid`: 회원 `ticket_refund` ≤ 낸 돈 − (환불 + 인원 줄임 원장) — `taam_refund_cap` 이 인원 줄임 원장을 안 세서 섞은 결제를 인원 줄임 뒤 취소하면 예치금이 두 번 나갈 수 있었다(라이브 해당 0건 · `taam_refund_cap` 라이브 본문은 저장소와 md5 가 달라 손대지 않았다 · 진단 `20261022_diag_refund_cap.sql`).
  ⚠ 저장소 toss-confirm 은 paid 때 주문 메타를 `{toss}` 로 **덮는다**(billing-charge 는 합친다) — 대시보드 판과 대조 전이라 손대지 않았다. 견적은 메타 없이도 돈다(order_id 로 묶음).
  회귀: `t_card_refund_quote.sh` 32건(C1~C17) · `tcr/harness2.mjs` 20건 · `crf/crf.js` 20건 · 진단 `20261022_diag_price_floor.sql`(하한을 걸기 전 지난 확정 금액 모양 — 라이브 카드 확정 6건 · 최근 30일 3건 모두 정가 이상).

- **카드환불 탭 「미처리 / 처리 완료」 나눔 (2026-10-23 · 빌드 `2026.10.23-b`).** 「위 카드만 눌렀는데 두 건이 같이 완료됐다」 → 라이브 진단(`20261023_diag_card_refund_bulk.sql`): 그날 완료된 것은 **한 건**(10/22 ₩125,000 · 22:31 「완료 표시」 · 알림 1건)이고,
  바로 밑 카드(8/15 ₩2,000)는 **08-16 08:14 에 이미 완료**된 기록이었다 — 미처리 카드와 완료 카드가 한 목록에 붙어 있고 완료 시각이 없어 방금 같이 처리된 것처럼 보였다(머리 ₩127,000 = ₩125,000 + 남은 8/21 ₩2,000). 처리는 원래 카드마다(구매 id 하나 · Edge 는 행 id 하나).
  → 탭을 「미처리 N건 — 카드마다 따로 처리」 · 「처리 완료 N건 — 최근 완료 순」으로 나누고(완료는 `refunded_at` 최신 먼저), 완료 카드에 「YYYY.MM.DD HH:MM 완료 · 앱에서 토스 승인취소 / 「완료 표시」(상점관리자 처리)」(`_crfDoneLine`), 완료 토스트에 매장·금액·「이 건만」. 회귀: 스크래치 `crfsplit/t.js`(6건) · `crf/crf.js`(20건).

### 결제 팝업은 남은 홀드를 회차·인원이 맞을 때만 다시 쓴다 (2026-10-22 키사누키 5/20 · 빌드 `2026.10.22-a`)

슈퍼어드민 알림 「좌석 전환 실패 — 결제됐는데 티켓이 안 붙었습니다 · 1인 ₩900,000 · PRICE_CHANGED (화면 900000 · 현재 1800000)」. 라이브 진단(`20261022_diag_holdfail_kisanuki.sql`):
13:21:31 **2인** 홀드 → 13:21:37 부족분 카드 주문 ₩325,000(pending · 결제 안 됨) → 토스 창에서 돌아와 **1인으로 줄이고** 다시 결제 → 13:22 PRICE_CHANGED(돈 안 빠짐) → 13:22:45 예치금 부여 → 13:24:11 2인 ₩1,800,000 정상 확정.
- 원인: `openTdPayPopup` 은 메모리에 `_tkSeatHoldId` 가 있으면 **회차·인원을 안 보고** 새 홀드를 안 잡았다. 토스 창으로 나갈 때는 홀드를 일부러 남기므로(`goPortOneCharge`) 돌아와 인원을 바꾸면 옛 인원 홀드로 확정했다 —
  서버(`taam_purchase_confirm_deposit`)는 **홀드 행의 회차 × 홀드 행의 인원**으로 다시 세어 막았다. 부팅 복구(`_tkRestoreSeatHold`)는 회차를 안 가려 **다른 회차의 홀드**가 남을 수도 있고, 금액이 같으면 서버는 그 회차를 확정해 버린다(엉뚱한 회차).
- 고침: 팝업 입구에서 홀드가 이 회차(`_tkHoldsThisTicket`)·이 인원(`_tkSeatHoldPax`)이 아니면 **반납하고 새로 잡는다**(반납 실패면 「좌석 확보 실패」로 멈춤 · 버튼 잠금) · 확정 직전 한 겹 더 — 예치금 전액 경로에서 `_hid` 가 이 회차의 홀드가 아니면 RPC 를 부르지 않는다(`HOLD_MISMATCH` · 카드가 섞인 옛 경로는 이미 승인된 뒤라 막지 않는다).
- 운영 알림 제목: PRICE_CHANGED·잔액 부족·홀드 만료·불일치(예치금 전액 경로)는 서버가 아무것도 안 뺀 것이라 「⚠ 결제 중단 — 예치금은 빠지지 않았습니다 · 다시 시도하면 된다」(종전 「결제됐는데 티켓이 안 붙었습니다」는 운영자에게 돈이 빠진 것으로 읽혔다).
- **적대 리뷰(2026-10-22) 반영 둘.** ① 등록 카드 결제가 도는 동안 「결제하기」를 다시 누르면(인원을 바꿨다면) 새 가드가 그 결제의 홀드를 반납해 카드 승인 뒤 seat_lost 자동 취소 → `tossPayTicketShortage` 가 도는 동안
  `window._tkCardChargeAt`(90초 한도)을 두고 결제 팝업이 「결제 중」으로 멈춘다. ② 카드 결제 성공(`_tossConfirmPayment` ok · `_tossRecoverTrip` paid) 뒤 기억한 홀드 id 를 지운다(등록 카드 경로는 이미 지웠다 · 남기면 같은 회차 재결제가 확정된 행을 「홀드」로 다시 확정하려 든다).
- 회귀: 스크래치 `holdfix/hold.js`(11건 · 카드 결제 중 팝업 · 성공 뒤 홀드 지움 — 2인→1인 · 같은 회차·인원 재사용 · 다른 회차 홀드 · 반납 실패 · 홀드 없음 · 확정 직전 가드 · PRICE_CHANGED 알림 · 정상 확정).

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

### 원장 전수 대사 — 잔액이 맞는지 의심될 때 (2026-09-28)

`sql/diag_ledger_sweep_v4_2026-09-28.sql` 을 SQL Editor 에 통째로 돌린다 (읽기 전용). **결정적인 건 D 구간**이다 —
저장 잔액 ≠ 원장 합계인 회원만 뜬다. `❌` 는 원장 없이 돈이 움직인 것, 「원장 시작 전 잔액 (정상)」은 8/31 서버화 전
잔액, `⚠ 판정 불가` 는 데이터로는 기준선과 유입을 못 가르니 **부여 이력으로 사람이 본다**. E2 는 시각·금액을 찾는
보조 구간이고 완전하지 않다.
- 첫 실행(2026-09-28) 결과: 회원 전원 저장 = 원장. 예외는 Super Admin 테스트 계정 −1,000(8/15 카드+예치금 혼합 테스트)뿐.
- 유수봉 9/12 사이토 「차감이 원장에 없다」는 **화면 배치** 문제였다(관리 차감이 맨 아래 별도 그룹). 데이터는 있었다.
- `balance_after` 는 행마다 총액이기도 주머니 잔액이기도 하다(작성 경로가 바뀌어 옴). 이걸 하나로 맞추는 마이그레이션은
  안 했다 — 새 행은 RPC 가 총액으로 쓴다. 옛 행을 「고치면」 대사 자체가 못 쓰게 된다. 건드리지 말 것.
- 고칠 때는 회귀부터: `bash sql/_test/ledger_sweep/t_sweep.sh` + `t_sweep2.sh` (도난·착시 시드 70여 명, 둘 다 ✅ 여야 한다).
  공격 에이전트가 3라운드 만든 시드다 — 규칙 하나를 바꾸면 반드시 어딘가 다른 시드가 튄다.

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
| `ticket_products.status` (매진/판매중) | `trg_sync_ticket_soldout`(tickets 변동) + `trg_taam_tp_status_recalc`(ticket_products 저장 시, 2026-10-05). 앱은 **로컬만** 바꾼다 |
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
- 시크릿 `SUPABASE_ACCESS_TOKEN` · `SUPABASE_DB_URL`(Session pooler URI) 이 없으면 건너뛴다(런 요약에 ⚠ warning 으로 보인다).
  ⚠ **2026-10-13 확인: 두 시크릿 모두 비어 있다.** 그래서 이 워크플로는 지금까지 SQL 도 Edge 도 한 번도 실제로 올린 적이 없다 —
  잡이 「success」로 끝나도 로그 첫 줄이 「시크릿이 없다 — 건너뜀」이면 아무것도 안 된 것이다. 카드 등록 수리(toss-billing-issue)가
  「배포 성공」인 줄 알고 라이브에서 옛 함수가 계속 돌았다. **Edge 함수 수정은 시크릿을 넣기 전까지 대시보드(Edge Functions → 함수 → Code)에
  TS 를 통째로 붙여 배포한다.** 배포 확인은 Actions 초록불이 아니라 함수가 새 응답(예: reason 필드)을 돌려주는지로 한다.
  손으로 돌리기: Actions → Supabase deploy → Run workflow (functions 칸 `all`).
- 순서는 SQL → Edge 다. 「SQL 을 먼저」 규칙을 워크플로가 지킨다 — ① 이 건너뛰었으면(시크릿 없음) ② 도 안 돈다(`needs.sql.outputs.state == 'ok'`).
- **2026-10-19 개정 — 로직은 `.github/scripts/supabase_migrate.sh` · `supabase_pick.sh` 로 빼서 로컬에서 그대로 검증한다**(`bash sql/_test/t_workflow_scripts.sh` 16건 — 문서만 바뀐 폴더 제외 검사는 **임시 워크트리**에서 커밋한다 · 작업 트리에서 커밋·reset 하면 커밋 안 한 변경이 날아간다(2026-10-19 에 한 번 날렸다)). 켜기 직전 적대 점검(4 렌즈)에서 고친 것:
  ① push 는 `before..sha`(이번 푸시의 커밋 전부)를 본다 — HEAD~1 만 보면 한 번에 여러 커밋이 올라올 때 앞 커밋의 함수 변경을 놓쳤다(before 를 모르면 HEAD~1). ② `_shared/` 변경은 그걸 import 하는 함수만(taam-chat · lineage-summarize) · `config.toml` 변경은 **`[functions.X]` 구역 내용이 달라진 함수만**(머리말 주석은 아무것도 안 올린다) · 함수 폴더에서는 **`.ts` 가 바뀐 것만**(README·SETUP.md·sql 문서 수정은 배포가 아니다) — 종전 「전부 재배포」는 대시보드에서만 손본 함수를 저장소 옛 판으로 덮었다.
  ③ 확인 표 ❌ 는 실패로 끝내되 **기록은 남긴다**(`sha='check-failed:<커밋>'`) — 종전엔 기록을 안 남겨 같은 파일이 푸시마다 다시 돌고(커밋은 이미 됐는데) 뒤 파일·Edge 가 영영 막혔다. 다음 푸시는 그 파일을 건너뛰고 뒤 파일을 돌린다. ④ 기록된 파일이 뒤에 바뀌면 `::warning`(file_md5) — 다시 돌리지 않는다, 새 파일로.
  ⑥ (2026-10-19) config.toml 구역 비교는 **주석·빈 줄을 빼고** 한다 — send-push 설명 줄을 taam-sms-hook 구역 끝에 끼워 넣었다가 픽커가 taam-sms-hook(대조 안 한 함수)까지 집어 #49 를 취소했다. 새 구역은 **파일 끝에 자기 헤더 아래** 적는다(헤더 앞 줄은 윗 구역 것이다).
  ⑤ psql 인용(배열 · `-X` · `PGCONNECT_TIMEOUT`) · `LC_ALL=C` 정렬(edit.sql < edit2.sql) · `ubuntu-24.04` 고정 · CLI `2.121.0` 고정 + `github-token` · 입력값은 env 로. 점검이 짚었지만 안 고친 것(pre · 별건): `lineage-summarize` 호출부(`aiSummarizeLineage`)가 세션 토큰이 아니라 publishable 키를 Bearer 로 보내 ON/OFF 어느 쪽이든 실패한다(「🤖 AI 정리」 버튼) · 크론 함수 셋의 `isServiceCaller` 는 서명을 안 보고 role 만 디코드한다(config.toml 머리말에 「절대 OFF 금지」로 적어 둠).
  **2026-10-18 켜짐 ✅** — 시크릿 둘 설치 뒤 Run workflow #39(functions 비움)가 ① `기록 35 · 안 돌린 파일 0 · state=ok` · ② `배포 대상: (없음)` 으로 통과 — 정확히는 `20261019_test_accounts.sql` 을 SQL Editor 로 먼저 돌렸지만 기록을 안 넣어 워크플로가 한 번 더 돌렸고(멱등 · 「✅ 이미 숨김」 · ⚠ 김우종은) 그 파일을 기록했다(`새로 적용 1`). 즉 **워크플로가 실제 마이그레이션을 적용·기록하는 길까지 검증됐다**. 이날부터 **`supabase/` 가 바뀐 `main` 푸시 = 라이브**. SQL 은 채팅에 붙이지 않고 커밋으로, 결과는 Actions 로그로 본다(미리보기가 필요한 수리 SQL 만 종전처럼 `sql/` + SQL Editor).
  켜는 과정에서 밟은 것: 액세스 토큰은 새 「세분화 토큰」 화면이 기본이라 **Create legacy token**(만료 Never)으로 만들었다 · DB 비밀번호에 `@#$` 가 섞이면 URI 의 `@` 가 호스트로 읽혀 `could not translate host name "#$@aws-…"` — 비밀번호는 **영문·숫자만**으로 재설정했고(실패 로그에 조각이 찍혀 그 비밀번호는 폐기 · 로그 삭제) · 첫 실패는 `password authentication failed for user "postgres"`(대소문자). 호스트는 `aws-1-ap-northeast-2.pooler.supabase.com:5432`(Session pooler).
  첫 함수 배포 #40(`functions=toss-billing-issue`) ✅ — `Deployed Functions … toss-billing-issue`, 대시보드 Verify JWT 는 켜진 채 그대로(CLI 배포가 설정을 안 건드린다). **대조 끝난 함수(2026-10-18)**: `toss-billing-issue`(워크플로 판) · `toss-billing-charge`(대시보드 Code 에 10-13 주석 있고 select 에 `customer_key` 없음 = 저장소와 같음 · 그날 붙여 넣은 것).
  **2026-10-18 밤 저장소 판으로 맞춘 함수(Run workflow #45~#48 · 전부 `Deployed Functions`)**: `taam-format` · `partner-account` · `notify-purchase` · `notify-guest-expiry` · `taam-translate` · `taam-chat`(`_shared/lineage-context.ts` 포함 · 지금 안 쓰는 기능이라 위험 없이 맞춤) · `send-push` · `notify-restock` · `kashikiri-refund`. 앞서 #40 `toss-billing-issue`.
  #51(수동 · `send-push` — 2026-10-19 DB→푸시 401 수리 판 · `[functions.send-push] verify_jwt = true`).
  **아직 저장소 판을 안 올린 것**: `notify-guest-booking`(저장소가 더 새 판 · 10-14 ⑥ 수정 · 덮어도 좋다 — 다음 묶음으로 올리면 된다) · 대조도 배포도 안 한 `consume-invite` · `verify-invite` · `toss-order` · `toss-confirm` · `notify-reservation` · `kashikiri-confirm` · `taam-translate-venues-batch` · `line-webhook` · `taam-sms-hook` · 제외 `lineage-summarize`(호출부 버그 · 별건). `notify-visit-reminder`·`toss-billing-charge` 는 대시보드 = 저장소. 이들이 끝나기 전까지 `functions=all` 금지는 그대로.
- **켜기 전 기준선 (2026-10-18 · `sql/migrations_baseline_2026-10-18.sql`).** `_taam_migrations` 가 비어 있으면 워크플로는 `2*.sql` 30개를 **전부** 「안 돌린 파일」로 보고 다시 돌리려 든다 —
  대부분 create or replace 라 무해하지만 md5 가드 파일(seat_sync2)에서 ❌ 로 멈추고 시드·백필이 또 돌 수 있다. 기준선 파일이 파일마다 대표 객체(함수·트리거·표·컬럼)의 존재를 보고
  **있는 것만** 기록한다(여러 번 RUN 가능 · 「⚠ 라이브에 없음」은 직접 돌리거나 워크플로에 맡긴다 — 옛 파일은 직접이 안전). 워크플로에는 **기준선 가드**가 있다: 기록 0건인데 안 돌린 파일이 3개 이상이면
  `::error` 로 멈춘다. 켜는 순서: ① 기준선 SQL → ② GitHub 시크릿 둘(`SUPABASE_ACCESS_TOKEN` · `SUPABASE_DB_URL` Session pooler URI · 값은 채팅에 적지 않는다) → ③ `main` 에 supabase/ 가 바뀌는 커밋.
  첫 Edge 배포는 「그 커밋에서 바뀐 함수만」이라 안전하지만, 대시보드에서 직접 고친 함수가 저장소보다 새 판이면 저장소 판으로 **덮인다** — 켜기 전에 둘이 같은지 본다(2026-10-18 기준: `notify-visit-reminder`·`toss-billing-issue` 는 저장소 판을 대시보드에 붙여 같다 · `notify-guest-booking` 은 저장소가 더 새 판 · 덮여도 좋다 · `taam-format` 은 저장소 판(09-16)을 대시보드에 올린 기록이 없어 **모름**).
  ⚠ `functions` 칸에 `all` 을 넣거나 `_shared/`·`config.toml` 이 바뀌면 **22개 전부** 저장소 판으로 덮인다 — 대조하지 않은 함수가 있는 동안은 `all` 을 쓰지 않고, 첫 수동 실행은 칸을 비워(바뀐 함수 없음 → SQL 연결만 확인) 돌린다. 기준선 SQL · 20261019 네 파일 기록은 2026-10-18 라이브 완료 ✅(_taam_migrations 34건) — 남은 것은 시크릿 둘뿐.

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
