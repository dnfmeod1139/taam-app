# 🌐 TAAM i18n 로드맵 (한국어 ⇄ English)

작업 시작: 2026-05-11
대상 사용자: 해외 관광객 (일본 미식 여행 중 TAAM 사용)
완성 목표: UI + 거래 + 컨텐츠 + 어드민 풀 번역
**상태: ✅ KO ↔ EN ↔ JA 풀 i18n 완료 (2026-05-11)**

## 🔤 글로벌 폰트 (2026-05-11 변경)

**스택**: `'Oswald', 'Noto Sans KR', 'Noto Sans JP', sans-serif`
- 영문/숫자 → Oswald (tall narrow capital-friendly)
- 한글 → Noto Sans KR (per-glyph fallback)
- 일본어 → Noto Sans JP (per-glyph fallback)

Google Fonts 로더 업데이트: Oswald 300/400/500/600/700 + Noto Sans KR/JP 400/500/700/900

기존 `'Montserrat',sans-serif` / `'Noto Sans KR',sans-serif` 모든 declaration을 일괄 치환 (1000+ 개)

## 📐 인프라 (✅ 완료)

### 핵심 시스템
- `TRANSLATIONS` 전역 객체 — `ko` / `en` / `ja` (ja는 en 폴백)
- `t(key, fallback)` 함수 — dot notation 지원 (`'common.confirm'`)
- `applyI18n(root)` 함수 — `data-i18n*` 속성 스캔하고 갱신
- `tkPickLang(code)` → 토글 시 `applyI18n()` 자동 호출
- localStorage 영속화 (`tkLang`)
- 부팅 시 자동 적용

### HTML 마크업 규칙
```html
<!-- 텍스트 -->
<span data-i18n="common.confirm">확인</span>

<!-- placeholder -->
<input data-i18n-ph="search.placeholder" placeholder="검색...">

<!-- title 속성 -->
<button data-i18n-title="action.delete" title="삭제">

<!-- aria-label -->
<button data-i18n-aria="common.close" aria-label="닫기">

<!-- HTML 마크업 (innerHTML 갱신) -->
<div data-i18n-html="welcome.body">환영 <b>합니다</b></div>
```

### JS 사용법
```js
showToast('✓', t('toast.purchase_done'), t('toast.purchase_msg'));
btn.textContent = t('common.save');
```

## 📋 Phase별 진행 상태

### ✅ Phase 1a — 인프라 + 데모 (이번 세션 완료)
- [x] TRANSLATIONS 사전 구조
- [x] t() / applyI18n() 함수
- [x] 토글 핸들러 연결
- [x] 필터 pill 바 마크업 (날짜/시간/장르/인원/지역/판매중만/초기화)
- [x] 알림 설정 페이지 마크업 (제목, 모든 항목 라벨·서브)

### ✅ Phase 1b — 핵심 UI 완성 (이번 세션)

#### ✅ 완료
- [x] **필터 시트 (Tk 시리즈)** — `filter.*`
  - 날짜 캘린더 (헤더 동적 EN/KO, 요일 라벨, 확인 버튼, 선택 후 라벨)
  - 시간/인원 휠 피커 (타이틀, 항목, 선택 버튼, 단/복수)
  - 장르 시트 (13개 버튼)
  - 지역 드롭다운 (전체/한국/일본)
  - Pill 라벨 + ↺ 초기화
- [x] **마이페이지 본체** — `my_page.*`
  - 회원정보 변경, 인증/인증완료 배지, 예치금/충전, 4개 메뉴 행
  - Super Admin / 어드민 페이지 (역할별 동적), 로그아웃
- [x] **시작화면 / 초대 / 인증 / 약관 / 관리자 코드** — `auth.*` (이번 세션)
  - 스플래시 (Invite-Only Membership / enter code / 관리자 코드)
  - 초대 코드 화면 (제목, 안내, 입장하기, 에러)
  - 본인 인증 (제목, 이름/이메일 placeholder, 발송, 코드 입력, 확인)
  - 약관 동의 6종 (전체/이용약관/개인정보/환불·취소/19세 이상/마케팅 + 보기 링크)
  - skip 팝업 (제목 HTML 줄바꿈, 설명, 확인)
  - 슈퍼어드민 PIN (ADMIN 라벨, 비밀번호 placeholder, 확인)
  - 관리자 비밀번호 변경 (제목, 라벨 3종, 규칙 4종, 취소/저장)
- [x] **티켓 리스트 + 카드 동적** — `ticket.*` 확장 (이번 세션)
  - `renderTicketGenres()` — 장르 헤더 EN 매핑 (스시→Sushi), empty 메시지 EN/KO, filter 배지
  - `_ticketCardHtml()` — 매진 → Sold Out, 잠김 → Locked, 구매하기 → Book Now, pax 단위, 날짜 형식 (Jul 15 / 7월 15일)
  - tkPickLang 토글 시 renderTicketGenres 자동 호출 (모든 카드 즉시 재렌더)
- [x] **토스트 메시지 (`toast.*` 확장)** — 30+ 키 추가 (이번 세션)
  - 충전 완료 / 카드 등록 / 주카드 / 회원정보 저장 / 인증 완료 / 반환 완료 / 복사 완료 / 카드 번호·만료일·CVC 확인
  - 변환된 callsite ~15곳 (충전·결제·인증 핵심 경로)
- [x] **티켓 상세 + 구매 흐름** — `ticket.*` (이전 세션)
  - 글래스 시트 4버튼 (PURCHASE / RULES / LOCATION + 메뉴 보기/내리기 토글)
  - 구매하기 CTA + 가격/날짜 라벨
  - House Rules 시트 (제목, 부제, No Camera 항목, 빈 상태)
  - Description 풀스크린 오버레이
  - Restaurant Info 풀스크린 (RESTAURANT / GALLERY)
  - Full Map 오버레이 (주소 복사 / 길안내)
  - Location 바텀시트 (LOCATION / GALLERY / empty)
  - Purchase Sheet (탭 2개, PAYMENT DETAIL / 인원 / CANCEL POLICY / 동의 / RESTAURANT DETAIL / 결제하기)
  - Confirm Payment 팝업 (제목 / 결제 완료 / 취소)
  - 예약 완료 팝업 (제목 / 동적 메시지 EN/KO / 확인)
- [x] **컨텐츠 화면** — `content.*`
  - 패널 헤더 (TAAM Library)
  - TAAM Genealogy Map 폴더 + 14개 계보 카드 (data-i18n KO/EN 모두)
  - TAAM Atlas 폴더 + 국가 탭(KR/JP) + 4개 섹션 (TAAM Verified KR/JP, Tabelog Award, MICHELIN Guide Seoul)
  - 조건 검색 (장르별/지역별/한국/일본/초기화/지도에서 보기/placeholder)
  - 애니메이션 효과 토글
  - TAAM Atlas 풀스크린 모듈 (헤더, 칩 필터 3종, 액션 버튼 체크인/챌린지, Tabelog 링크, 내 위치 FAB)
  - 라멘 폴더 + 본류 트렁크 그룹 헤더
- [x] **마이페이지 하위 화면들** — `mp_sub.*`
  - 핸드폰 인증 팝업 (제목, 라벨, placeholder, 발송/재발송, 확인, 메시지 4종)
  - 프로필 편집 (제목, 이름/번호/주소 라벨, 변경 버튼, 검색/생략, 안내 문구, 저장)
  - 프로필 확인 팝업 (제목, 3개 키, 취소/확인)
  - 주소 검색 (제목, placeholder, 검색, empty)
  - 티켓 구매 내역 (제목, 3개 탭)
  - 예치금 사용 내역 (제목, 2개 탭)
  - 예치금 충전 (제목, 정보 박스, 금액/방법 섹션, 카드/계좌이체, 충전 버튼)
  - 결제수단 (기존 cp 페이지) (모든 라벨 + 버튼)
  - 결제 수단 관리 (cm 페이지) (안내, 로딩, 추가 버튼)
  - 카드 메뉴 시트 (주카드 설정 / 카드 삭제)
  - 주카드 설정 모달 / 카드 삭제 모달 / 삭제 완료 팝업
- [x] **알림 설정** — `notif_settings.*` (2시간 전 항목 삭제됨)
- [x] **공통 버튼** — `common.*` (confirm/cancel/save/delete/close/back/all/select/logout 등)
- [x] **언어 시트** — `lang_sheet.*`
- [x] **알림 시트** — `notif_sheet.*`
- [x] **상단 바** — `top.*` (lang/notif/menu/brand)
- [x] **GNB** — `gnb.*` (Ticket/Contents/Home/Chat/My Page)
- [x] **멤버십 안내 페이지** — `membership.*` (60+ 키, M/T 등급 카드 전체, 약관 링크 4개)
- [x] **파트너(일반) 어드민 마이페이지** — `partner.*`
- [x] **도메인 상수** — `status.*`, `chef.*`, `lineage.*`, `curation.*`, `award.*`

#### 🐛 해결한 핵심 버그
- `window._tkCurrentLang` 부팅 시 초기화 누락 → 모든 t()/applyI18n 호출이 KO로 fallback되던 문제 (2026-05-11 수정)
- `tkAccUpdateValueLabel` 하드코딩 "전체" / "명" → t() 사용
- 부팅 시 `tkPillSyncAll()` + `tkLangCurrent` 라벨 동기화 추가
- 캘린더 헤더 / 휠 피커 / 멤버십 / 마이페이지 sub-page 진입 시 `applyI18n(scope)` 자동 호출

#### 🔄 남은 일 (Phase 1c)
- [ ] 햄버거 메뉴 (FILTER 섹션 잔여 정리 필요)
- [ ] **JS 동적 렌더 텍스트** ← ⚠️ 일본어 작업 전 반드시 확인
  - [x] `renderTicketGenres()` / `_ticketCardHtml()` — 완료 (장르 매핑 + EN/KO 분기)
  - [x] `_notifRenderList()` — 완료 (이전 세션)
  - [x] `renderTicketHist()` / `ticketHistRender()` — 완료 (이번 세션: empty 메시지, 배지, 인원, 알 수 없음 EN/JA/KO)
  - [x] `dhTab()` — 완료 (이번 세션: 총 충전 금액, 반환/부분환불/대행비차감/환불불가/사유 라벨)
  - [x] `loadMyCards()` — 완료 (이번 세션: 로딩, 카드 default, 기본 배지, 기본으로/삭제 액션, 에러 메시지)
  - [ ] `renderCarousel()` — 홈 캐러셀 (런칭 시점에서 비공개 상태)
  - [ ] `renderPendingApproval()` — 슈퍼 어드민 승인 대기 (어드민 전용 — 후순위)
- [x] **showToast 호출처 ~200곳** — `_toastAutoMap` 도입으로 자동 처리
  - 기존 callsite 무수정 동작 (60+ 핵심 키워드 자동 매핑)
  - `t:키.경로` prefix 지원으로 명시적 호출도 가능 (예: `showToast('✓','t:toast.charge_done_title','...')`)
  - 의도 명확화가 필요한 어드민 토스트는 점진적으로 명시 변환

### Phase 2 — 거래·금융 흐름 (다음 세션 2-3)
- [ ] 티켓 상세 화면
- [ ] 티켓 구매 시트 (인원 선택, 식사비/대행비, 약관 동의)
- [ ] 구매 확인 팝업
- [ ] 결제 진행 / 완료 / 실패 토스트
- [ ] 예치금 충전 페이지
- [ ] 예치금 환불 / 위약금 처리
- [ ] 결제 카드 등록 / 변경
- [ ] 휴대폰 인증 흐름

### Phase 3 — 컨텐츠 (다음 세션 4-5)
- [ ] 계보도 노드 팝업 텍스트
- [ ] Atlas (TAAM Verified, 미쉐린, Tabelog Award)
- [ ] 가게 카드 (가게 이름은 `name_en` 사용)
- [ ] 멤버십 안내 페이지
- [ ] 서비스 약관 / 개인정보 / 환불 약관 / 마케팅 동의
- [ ] Contact Us / About Us / FAQ
- [ ] 시작 화면 / 로그인 페이지

### ✅ Phase 4 — DB 컬럼 확장 + 운영 컨텐츠 (이번 세션 완료)
- [x] `sql/i18n_columns.sql` 작성 — restaurants/tickets/splash_settings/chef_lineage_knowledge 일괄
  - restaurants: `name_jp`, `chef_name_jp`, `chef_name_en`, `concierge_note_en/jp`, `vibe_tags_en/jp`, `signature_keywords_en/jp`, `address_en/jp`, `genre_en/jp`, `i18n_status_en/jp`, `i18n_updated_at`
  - tickets: `desc_en`, `desc_jp`
  - splash_settings: `text1_en`, `text1_jp`, `text2_en`, `text2_jp`
  - chef_lineage_knowledge: `summary_en/jp`, `full_text_en/jp`
- [x] `pickI18nField(row, base)` helper 작성 — 현재 언어 우선 → KO 폴백
- [x] `_ticketCardHtml`, `tdRestName`, `tdGenreAddr`, `openLocationSheet` 에 적용
- [x] `applySplashSettings()` 에 EN/JA 분기 추가
- [x] `tkPickLang` 토글 시 splash 재적용 hook

### ✅ Phase 5 — 어드민 + AI 번역 보조 (이번 세션 완료)
- [x] `supabase/functions/taam-translate/index.ts` 작성 — Claude 4.5 Sonnet 기반
  - 도메인 가이드 prompt (tableall.com / omakase.in 표준 + JA 카타카나 표기)
  - 텍스트/배열 입력 동시 처리 + 로마자 변환 지원
  - JSON 응답 자동 파싱 (코드블록 제거)
- [x] 큐레이션 편집 화면에 [🤖 번역 실행] 버튼 + EN/JA 8개 필드 추가
  - 한 줄 평 EN/JA · 분위기 EN/JA · 시그니처 EN/JA · 이름 EN/JA
  - `taamRestEditAiTranslate()` — Claude 호출 → 자동 폼 채우기
- [x] `taamRestEditSave` 에 i18n 컬럼 9개 저장 추가
- [x] 클라이언트 helper `window.taamTranslate(items, context)` — 다른 어드민 화면에서 재사용 가능
- [x] **자동 토스트 i18n** — `_toastAutoMap` 함수가 KO 토스트를 EN/JA로 자동 변환 (60+ 키)
  - 기존 callsite 200+곳 무수정 동작
  - `showToast('✓','충전 완료','...')` → EN 사용자에겐 자동으로 `Charge Complete` 표시
- [ ] 어드민 sub-screens (티켓 업로드, 회원 목록, 승인 대기) — 추후
- [ ] 노출 제어, 시작화면 편집 — 추후

### ✅ Phase 6 — 일본어 (이번 세션 완료)
- [x] TRANSLATIONS.ja 전체 작성 (~600+ 키, tableall.com / omakase.in 표준 용어)
- [x] tkPickLang JA 분기 추가 (lang_changed_msg_ja)
- [x] JS 동적 함수 JA 분기 추가:
  - [x] tkPillSync — genre/region JA 매핑 (스시→寿司 등 12종 + 한국→韓国/일본→日本)
  - [x] tkPillSync — date format 7月15日 / pax 名
  - [x] tkRenderCal — 2026年7月
  - [x] tkOpenPaxWheel — 1名, 2名...
  - [x] _ticketCardHtml — 날짜/인원/메뉴 JA
  - [x] renderTicketGenres — 장르 헤더 JA 매핑
  - [x] ticketHistRender — 来店/不明/名
  - [x] confirmReservation — 예약 완료 메시지 JA
- [ ] DB 테이블 `_jp` 컬럼 추가 (Phase 4 — DB 작업과 연계)
- [ ] AI 번역 버튼에 일본어 옵션 추가 (Phase 5)

## 🇯🇵 일본어 마이그레이션 마스터 체크리스트

**원칙**: `TRANSLATIONS.ko` 의 모든 키는 `TRANSLATIONS.en` 에 존재하고, **그대로 `TRANSLATIONS.ja` 에도 존재해야 한다.**
누락 시 `t()` 가 자동으로 ko → en → key 순으로 fallback 하므로 사용자가 그 항목만 한글로 보게 된다.

### 📋 모든 네임스페이스 (`grep -c "ko: {" → en: { → ja: {` 로 키 개수 일치 검증)

| 네임스페이스 | 내용 | 키 개수 (참고) |
|---|---|---|
| `common.*` | 확인/취소/저장/삭제/닫기/뒤로/로그인/로그아웃/select/all 등 | ~40 |
| `gnb.*` | Ticket/Contents/Home/Chat/My Page | 5 |
| `top.*` | brand/lang/notif/menu | 4 |
| `filter.*` | 날짜/시간/장르/인원/지역 + sheet 내부 + 13개 장르 | ~30 |
| `lang_sheet.*` | LANGUAGE 라벨 | 1 |
| `notif_sheet.*` | 알림 시트 (제목, empty, clear, time relative) | 6 |
| `notif_settings.*` | 알림 설정 페이지 (권한, 버튼, 항목 9개 + sub) | ~30 |
| `my_page.*` | 마이페이지 본체 (배지/메뉴/인증완료/Admin) | ~20 |
| `mp_sub.*` | **마이페이지 하위 화면 8개 전부** | ~80 |
| `content.*` | **컨텐츠 화면** (계보 14종 / Atlas 4섹션 / 조건 검색 / 라멘) | ~55 |
| `ticket.*` | **티켓 상세 / 구매 / 결제 / 리스트 / 카드** | ~50 |
| `auth.*` | **스플래시 / 초대 / 인증 / 약관 / 관리자 코드** | ~35 |
| `toast.*` | **토스트 메시지** (충전·결제·환불·인증·카드·복사 등) | ~35 |
| `membership.*` | 멤버십 안내 (M/T 등급, 혜택, 약관) | ~60 |
| `info_menu.*` | Contact/About/FAQ | 3 |
| `partner.*` | 파트너 어드민 마이페이지 | ~5 |
| `admin.*` | 슈퍼어드민 마이페이지 | ~35 |
| `status.*` | available/soldout/cancelled/upcoming/completed/pending 등 | 8 |
| `chef.*` | profile/background/lineage/mentor/students | 5 |
| `lineage.*` | title/tree/genealogy/master/branch/generation | 6 |
| `curation.*` | curation/taam_verified/curator_note/signature/vibe | 5 |
| `award.*` | Michelin/Tabelog 등급들 | ~10 |
| `toast.*` | 토스트 메시지 (현재 일부만 완료) | TBD |

### ⚠️ JS 동적 텍스트 (data-i18n 으로 자동 갱신 안됨 — t() 호출 필수)

다음 함수들은 한글 문자열을 직접 setText 하므로 일본어 작업 시 **함수 내부의 모든 문자열을 t() 로 치환** 필요:

```
[필터/메뉴]
- tkPillSync (genre/region 매핑 테이블 → ja 매핑도 추가)
- tkAccUpdateValueLabel (전체/명 → 全て/名)
- tkRenderCal (월 이름 → 1月/2月... 또는 EN 폴백)
- tkSelectDate (확인 버튼 dynamic label)
- tkOpenPaxWheel / tkOpenTimeWheel (타이틀, 항목)

[마이페이지]
- updateMpAdminBtn (Super Admin / 어드민 페이지)
- openMyPage (인증완료/인증하기 배지)
- pvSendCode / pvVerifyCode (메시지 4종)

[리스트 렌더링]
- renderTicketHist / ticketHistRender — 카드 내부 모든 텍스트
- dhTab / renderDepositHist — 충전/사용 내역
- loadMyCards / renderCardList — 카드 행
- _notifRenderList — 알림 항목 시간 표시 (방금/N분 전)
- renderCarousel / renderHomeTickets / renderTicketGenres
- renderPendingApproval

[토스트 / 다이얼로그]
- showToast() 호출처 (검색: `showToast\(`)
- alert() 호출처
- confirm() / window.confirm()

[Edge Function 메시지]
- Supabase Edge Function 응답에 한글이 있다면 별도 변환
```

### 🔍 일본어 작업 시작 시 체크리스트

1. `var TRANSLATIONS = {` 검색 → `ko:` / `en:` 의 모든 키 dump
2. `ja: {` 를 새로 만들고 ko 구조 그대로 복붙 → 일본어로 번역
3. 누락 검증 스크립트:
   ```js
   function diff(a, b, path='') {
     Object.keys(a).forEach(k => {
       const p = path ? path+'.'+k : k;
       if (!(k in b)) console.warn('MISSING in ja:', p);
       else if (typeof a[k] === 'object') diff(a[k], b[k], p);
     });
   }
   diff(TRANSLATIONS.ko, TRANSLATIONS.ja);
   ```
4. 토글 후 모든 페이지 순회:
   - 홈 / 티켓 / 컨텐츠 / 채팅 / 마이페이지 GNB
   - 필터 sheets 5종 (날짜/시간/장르/인원/지역)
   - 마이페이지 sub-pages 8종 (위 표 `mp_sub.*` 참조)
   - 햄버거 메뉴 → 멤버십 / 약관 4종 / Contact / About / FAQ
   - 알림 시트 + 알림 설정
   - 슈퍼어드민 / 파트너 어드민 진입 시 모든 메뉴
5. JS 동적 텍스트 항목 (위 ⚠️ 섹션) 전수 검사

### 📝 일본어 도메인 용어 표준 (확정 시 추가)

| KO | EN | JA |
|---|---|---|
| 장르 | Genre | ジャンル |
| 대행비 | Reservation Fee | 予約手数料 |
| 판매중 | Available | 販売中 |
| 매진 | Sold Out | 完売 |
| 예치금 | Deposit | 預り金 |
| 멤버십 | Membership | メンバーシップ |
| 계보도 | Lineage | 系譜 |
| 큐레이션 | Curation | キュレーション |
| 본가 / 분점 | Origin / Branch | 本家 / 分店 |
| 카운터 / 룸 | Counter / Private Room | カウンター / 個室 |
| 점심 / 저녁 | Lunch / Dinner | ランチ / ディナー |
| 1인 | per guest | お一人様 |
| (그 외는 작업 시점에 추가) |

## 🎯 데이터 측 결정 사항

| 데이터 | 처리 방식 |
|---|---|
| 가게 이름 | `name_en` 사용 (로마자 표기 — 정식당 → Jungsik) |
| 쉐프 이름 | `chef_background_ko` → 로마자 변환 (안성재 → Sungjae Ahn) |
| 도시 | `city` (이미 영문 — Seoul, Tokyo) |
| 장르 | `genre_en` 사용 (스시 → Sushi, 텐푸라 → Tempura) |
| 한 줄 평 | `concierge_note_en` 컬럼 추가 (Phase 4) |
| 분위기 태그 | `vibe_tags_en` 컬럼 추가 (Phase 4) |
| 시그니처 키워드 | `signature_keywords_en` 컬럼 추가 (Phase 4) |
| 통화 | ₩ 유지 (한국 결제 시스템) — 환율 표시 옵션 추가 가능 |
| 날짜 형식 | EN: MMM DD, YYYY / KO: YYYY.MM.DD |

## 🛠 다음 세션 시작 시 체크리스트

1. 본 문서의 ✅ 완료 항목 확인
2. 다음 Phase의 미완료 [ ] 항목 중 우선순위 선택
3. `TRANSLATIONS.ko` 와 `TRANSLATIONS.en` 양쪽에 키 추가
4. HTML 요소에 `data-i18n="key"` 마크업
5. JS 호출처는 `t('key')` 로 치환
6. PWA 새로고침 → 토글 → 즉시 변환 확인

## 📚 추가 자료

- 번역 키 네이밍 규칙: `섹션.항목` (예: `notif_settings.fav_open`)
- 같은 단어라도 맥락이 다르면 다른 키 사용 권장 (예: `common.confirm` vs `dialog.confirm`)
- 영어 톤: 친근 + 간결 ("Got it" 보다는 "OK" 같은 표준어)
- 한국 음식 용어는 일반 영어 음역 우선 (sushi, tempura, ramen)

## 🌐 참고 사이트 표준 용어 (★ 우선 채택)

일본 미식 예약 플랫폼의 표준 영문 용어 — 이 사이트들의 표기를 우선으로 채택.

### 1차 레퍼런스
- **https://www.tableall.com/restaurants** — 일본 미식 영문 예약 플랫폼
- **https://omakase.in/en/** — 오마카세 영문 예약

### 확정된 표준 용어 (사용자 검증 2026-05-11)

| 한국어 | English (TAAM) | 비고 |
|---|---|---|
| **장르** | **Genre** ⭐ | Cuisine 아닌 Genre 사용 (tableall/omakase 표준) |
| **대행비** | **Reservation Fee** ⭐ | Agency Fee, Booking Fee 아님 |
| **활성 / 판매중** | **Available** ⭐ | Live, Selling 아님 |
| **노출 제어** | **Display Settings** ⭐ | Visibility 아님 (어드민 메뉴) |
| **쉐프 한 줄 소개** | **Chef Profile** ⭐ | Chef Note, About the Chef 아님 |
| **계보도** | **Lineage** ⭐ | Family Tree, Genealogy 아님 |
| **큐레이션** | **Curation** ⭐ | Selection 아님 |
| **빕 구르망** | **Bib Gourmand** ⭐ | 그대로 (Michelin 공식 표기) |
| 예약 | Reservation | (Booking 도 OK) |
| 코스 | Course | |
| 카운터 | Counter | |
| 룸 (개실) | Private Room | |
| 점심 | Lunch | |
| 저녁 | Dinner | |
| 영업시간 | Hours | (Opening Hours) |
| 정기휴일 | Closed | (Regular Closed Days) |
| 1인 | per guest | (per person) |
| 손님 / 인원 | Guests | |
| 한 줄 평 | Description / Highlights | (맥락 따라) |
| 시그니처 | Signature | |
| 식사비 | Meal Price | |
| 와인 최소 | Wine Minimum | |
| 서비스 차지 | Service Charge | |
| 합계 | Total | |
| 위약금 | Cancellation Fee | (Penalty 아님) |
| 반환 예정 | Pending Return | |
| 반환 완료 | Returned | |
| 환불 불가 | Non-refundable | |
| 예치금 | Deposit | (Wallet 아님) |
| 예치금 잔액 | Deposit Balance | |
| 매진 | Sold Out | |
| 취소됨 | Cancelled | |
| 예정 | Upcoming | |
| 완료 | Completed | |
| 본가 | Origin | (Master 아님, 계보 맥락에서) |
| 분점 | Branch | |
| 세대 | Generation | (계보 맥락) |
| 큐레이터 노트 | Curator Note | |
| 분위기 | Vibe | (atmosphere 아님 — 캐주얼) |
| TAAM 인증 | TAAM Verified | |
| Tabelog Gold/Silver/Bronze | Gold / Silver / Bronze | 그대로 |
| ★★★ / ★★ / ★ | Three Stars / Two Stars / One Star | Michelin 공식 |
| 미쉐린 선정 | Michelin Selected | (Plate) |
| 그린 스타 | Green Star | |

### 미식 도메인 용어 (음식)
- 스시 → Sushi
- 텐푸라 / 덴푸라 → Tempura
- 카이세키 → Kaiseki
- 야키니쿠 → Yakiniku
- 야키토리 → Yakitori
- 우나기 / 장어 → Unagi
- 라멘 → Ramen
- 소바 → Soba
- 한식 → Korean
- 한식 컨템포러리 → Modern Korean (또는 Korean Contemporary)
- 모던 / 이노베이티브 → Innovative
- 미즈타키 → Mizutaki
- 카마메시 → Kamameshi (gama-pot rice)

### 매장 이름 / 셰프 이름
- **번역하지 않음** — 로마자 표기 사용
- 예: 정식당 → Jungsik / 모수 → Mosu / 안성재 → Sungjae Ahn
- DB의 `name_en`, `chef_name_en` 필드 활용
