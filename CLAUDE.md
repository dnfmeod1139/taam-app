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
| 서버리스 | `api/` = Vercel 함수(taam-chat, taam-format) / `supabase/functions/` = Edge Functions |
| 결제 | **PortOne(포트원) V2**, 원화(KRW), 카드·계좌이체 |
| AI | Anthropic Claude (컨시어지 챗 `taam-chat`, 번역 `taam-translate`) |
| 배포 | Vercel(웹, `taam-app.vercel.app`), Codemagic(iOS TestFlight) / 기본 브랜치 `main` |

## 디렉토리 구조
- `index.html` — **앱 본체**. 거의 모든 UI·로직·i18n이 여기 있음 (단일 파일)
- `api/` — Vercel 서버리스 함수 (taam-chat.js, taam-format.js)
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

## 작업 규칙 (중요)
1. **index.html 수정 시**: 거대 단일 파일이므로 Grep으로 위치를 먼저 찾고, 주변 코드 스타일(바닐라 JS, 한국어 주석, `var`)에 맞춰 작성.
2. **SQL은 저장소에 두는 것 ≠ DB 적용**. `sql/`의 스크립트는 사용자가 **Supabase SQL Editor에서 직접 RUN** 해야 반영됨. 새 SQL을 만들면 사용자에게 "실행 필요"를 명시.
3. **비밀키 금지**: API 키·service_role·firebase 키 등은 절대 코드/커밋에 넣지 말 것. 모두 Vercel/Supabase 대시보드 또는 Edge Function 시크릿에 있음. `.gitignore`가 secrets/·*.keystore·*.p8·.env 차단.
4. **결제·환불·예치금 로직**은 금전 관련이라 신중히. 수정 시 거래기록(deposit_transactions) 정합성 확인.
5. 커밋/푸시는 사용자가 요청할 때. 기본 브랜치는 `main`.

## 라이브러리/외부 API 문서
라이브러리·API(Supabase, PortOne, Capacitor, Vercel 등)의 최신 문서·설정·코드 생성이 필요하면 **항상 Context7를 자동으로 사용**한다 (설치돼 있는 경우).
