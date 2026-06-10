# TAAM 배포 로드맵 (2026-05-23)

> 라이니지 라우팅 동결 → 안드로이드 출시 마무리 → iOS 작업 진입.
> 모든 결정은 본 문서 우선. 변경 시 날짜 갱신.

---

## 현재 상태 스냅샷

| 항목 | 상태 |
|---|---|
| PWA (Vercel) | 운영 중 — taam-app.vercel.app, SW v1.45 |
| Capacitor | v8.3.3, appId `com.playtaam.app` |
| Android AAB | `android/app/release/app-release.aab` 빌드 존재 — **재빌드 필요** (versionCode 갱신) |
| iOS | 미생성 — Capacitor ios 플랫폼 추가 안 됨 |
| 푸시 (FCM) | `secrets/firebase-service-account.json` 보유 |
| 푸시 (APNs) | 미설정 (iOS 단계에서) |
| 스토어 자산 | descriptions_v2.md 작성됨, feature graphic 1개 / **스크린샷 0장** |
| 법무 페이지 | privacy / terms / refund / marketing / account_deletion 작성 완료 (legal/) |

---

## PHASE 1 — Android Play Store 출시 마무리

### 1-A. 빌드 재생성 (versionCode 갱신)

Play 콘솔은 동일 versionCode 재업로드 거부. 매 빌드마다 +1.

```powershell
# 1. version 증가 — android/app/build.gradle
#    versionCode 1 → 2
#    versionName "1.0" → "1.0.1"

# 2. PWA 최신 빌드 동기화
cd C:\TAAM
npx cap sync android

# 3. AAB 빌드 (Android Studio 권장 — keystore 자동 처리)
#    또는 CLI:
cd C:\TAAM\android
.\gradlew bundleRelease

# 결과: android/app/build/outputs/bundle/release/app-release.aab
```

체크리스트:
- [ ] versionCode = 2, versionName = "1.0.1"
- [ ] `cap sync android` 성공 (www/ 가 최신 index.html 반영)
- [ ] capacitor.config.json 의 `server.url` 이 `https://taam-app.vercel.app` (live URL — 앱이 PWA 를 wrap)
- [ ] AAB 서명 검증 (jarsigner)

### 1-B. 스크린샷 8장 (Play Console 필수)

- **휴대전화** 최소 2장 / 권장 8장 — 1080×1920 또는 1080×2400 권장
- 캡쳐 대상:
  1. 홈 (랜딩 + 로그인 진입)
  2. 계보도 (대표: 카네사카)
  3. 노드 클릭 시 ndm-modal (사진 + 설명)
  4. 레스토랑 상세 + 예약/티켓 버튼
  5. 슈퍼어드민 예치금 관리 (텍스트만 — 민감정보 가림)
  6. 푸시 알림 수신 화면
  7. AI 추천
  8. 마이페이지 (멤버십 잔액)

> Chrome DevTools — Device Toolbar → Pixel 7 Pro (1080×2400) 로 캡쳐 → `store_assets/screenshots/phone/01_home.png` 식으로 저장.

### 1-C. Play Console 등록 단계

1. **앱 만들기**: 이미 생성된 앱이라면 그대로 사용. 없으면 신규.
2. **앱 정보**:
   - 앱 이름: TAAM (30자 이내)
   - 짧은 설명: descriptions_v2.md
   - 자세한 설명: descriptions_v2.md
3. **그래픽 자산**:
   - 앱 아이콘 512×512 (`resources/icon.png` 활용 — 리사이즈)
   - Feature graphic 1024×500 (`store_assets/taam_feature_graphic_burgundy.png` 사용)
   - 휴대전화 스크린샷 8장 (1-B)
4. **분류 / 등급**:
   - 카테고리: 음식 및 음료 (Food & Drink)
   - 콘텐츠 등급: IARC 질문지 → 만 3세 이상 예상
5. **개인정보 처리방침**:
   - URL: `https://taam-app.vercel.app/legal/privacy.html`
6. **데이터 보안 양식** (Data Safety):
   - 수집: 이메일, 휴대전화, 결제정보 (PortOne), 위치(선택), 사진(선택)
   - 공유: 결제 처리 외 제3자 공유 없음
   - 암호화: TLS 1.2+
   - 삭제 요청: `legal/account_deletion.html`
7. **앱 액세스 권한** (테스터용 자격증명):
   - 초대코드 발급 필요 → 테스터에게 별도 전달
8. **출시 트랙**:
   - 우선 **내부 테스트** 트랙 → 본인 + 코어 테스터 (1~5명) 검증
   - 통과 시 **비공개 테스트** (closed) → 최대 100명
   - 안정 확인 후 **프로덕션** 출시

### 1-D. 푸시 알림 (FCM) 검증

- [ ] `secrets/firebase-service-account.json` 이 Supabase Edge Function `send-push` 에 환경변수로 등록되어 있는지
- [ ] AAB 빌드 후 실기기에서 토큰 발급 → Supabase `push_tokens` 테이블에 row 생성 확인
- [ ] 테스트 알림 발송 → 수신 확인

---

## PHASE 2 — iOS App Store 출시

### 2-A. 사전 준비 (계정 / 하드웨어)

1. **Apple Developer Program 가입**: 연 $99 USD (~14만원)
   - https://developer.apple.com/programs/enroll/
   - 법인 등록 시 D-U-N-S 번호 필요 (주식회사 쓰리피프틴) → 영업일 1-2주 소요
   - **개인 계정으로 빠르게 시작 후 → 법인 이관도 가능**
2. **Mac 환경**: Xcode 는 macOS 에서만 동작
   - 옵션 A: 본인 Mac (있다면)
   - 옵션 B: Mac Mini 구매 (M2 ~80만원)
   - 옵션 C: 클라우드 macOS (MacStadium, Codemagic) — 빌드 전용으로 월 $30~
3. **Xcode 16+ 설치** (App Store)
4. **iOS 18 SDK 이상** 권장 (현재 시점)

### 2-B. Capacitor iOS 플랫폼 추가

Mac 환경에서:

```bash
cd ~/TAAM
npm install @capacitor/ios
npx cap add ios
npx cap sync ios
```

생성 결과: `ios/App/App.xcworkspace` (Xcode 로 오픈)

### 2-C. iOS 빌드 설정

Xcode 내 작업:
1. **Signing & Capabilities**:
   - Team = 본인 Apple Developer 팀
   - Bundle Identifier = `com.playtaam.app` (Capacitor 자동 매핑)
   - Capabilities 추가:
     - Push Notifications
     - Background Modes → Remote notifications, Background fetch
2. **App Icon**: `npx capacitor-assets generate --ios` (icon.png 1024×1024 자동 분할)
3. **Launch Screen**: splash.png 자동 적용
4. **Info.plist** 필수 키:
   - `NSCameraUsageDescription` — "프로필 사진 등록을 위해"
   - `NSPhotoLibraryUsageDescription` — "사진 첨부를 위해"
   - `NSLocationWhenInUseUsageDescription` — "주변 레스토랑 검색을 위해"
   - `NSUserTrackingUsageDescription` — 광고 미사용 시 불필요
5. **APNs 키 생성** (`.p8`):
   - developer.apple.com → Keys → "+" → Apple Push Notifications service
   - 다운로드 (한 번만 가능) → `secrets/apns-key.p8` 보관
   - Supabase Edge Function 에 환경변수: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_KEY_CONTENT`

### 2-D. App Store Connect 등록

1. **앱 만들기**: appstoreconnect.apple.com → 내 앱 → "+" → 새 앱
   - 플랫폼: iOS
   - 이름: TAAM
   - 기본 언어: 한국어
   - 번들 ID: com.playtaam.app
   - SKU: TAAM-001 (내부 식별자, 임의)
2. **앱 정보**:
   - 카테고리: 음식 및 음료
   - 콘텐츠 권한 (Content Rights): 직접 권한 보유
3. **가격 및 사용 가능 여부**: 무료
4. **앱 개인정보처리방침 URL**: `https://taam-app.vercel.app/legal/privacy.html`
5. **App Privacy** (개인정보 nutrition label):
   - Play Console Data Safety 와 동일 항목 입력
6. **버전 정보**:
   - 스크린샷 — iPhone 6.5" 디스플레이 (1284×2778) + iPhone 6.9" (1320×2868)
   - 설명 — descriptions_v2.md (영문은 필수, 한국어/일본어는 현지화)
   - 키워드 (100자) — `fine dining,sushi,reservation,michelin,chef,Korea,Japan,concierge`
   - 지원 URL — `https://taam-app.vercel.app`
   - 마케팅 URL — 동일
7. **App Review 정보**:
   - 데모 계정 — `demo@taam.example.com` / `Demo!2026` 등 테스트용 (초대코드 우회 가능한 슈퍼테스트 계정 필요)
   - 메모 — "Invite-only app. Use provided demo credentials to access full features."
8. **TestFlight**: 내부 테스터 / 외부 테스터 (최대 10,000명)
   - 외부 테스터는 Apple 의 베타 리뷰 통과 필요 (보통 24h)
9. **App Review 제출**:
   - Review 통과 시간: 평균 24-48h
   - 거절 사유 1순위: **데모 계정 누락**, 가이드라인 4.2 (Minimum Functionality)
   - 통과 시 "수동 출시" 옵션 선택 → 원하는 시간에 출시 가능

### 2-E. iOS 특수 사항

- **Web Push (현 PWA 방식) 미사용**: iOS 네이티브 앱에서는 Capacitor `@capacitor/push-notifications` 사용 → APNs 직접 통신
- **In-App Purchase**: 디지털 콘텐츠(예치금) 판매 시 Apple IAP 강제 — 현재 PortOne 사용 중 → **Apple 거절 가능성 높음**
  - 해결: 예치금/티켓 결제는 **외부 웹에서만 진행**, 앱에서는 "잔액 확인" 만
  - 또는 IAP 추가 (Apple 30% 수수료)
  - → **우선 외부 결제 우회 안으로 제출** (가이드라인 3.1.5(a) — 실물 서비스 예약은 외부 결제 허용)
- **App Bound Domains**: capacitor.config.json `limitsNavigationsToAppBoundDomains: false` 유지 (현재 그대로)

---

## PHASE 3 — 출시 후 운영

| 항목 | 주기 |
|---|---|
| PWA 핫픽스 (Vercel) | 즉시 — `npx vercel --prod` (앱 재배포 불필요, server.url 라이브 wrap 구조라서) |
| 네이티브 SDK 업데이트 (Capacitor) | 분기 1회 |
| Android versionCode +1 | 네이티브 변경 시마다 |
| iOS Build Number +1 | 네이티브 변경 시마다 |
| Apple/Google 정책 변경 모니터링 | 월 1회 |

---

## 주의사항 / 함정

1. **Capacitor server.url 로 PWA wrap 방식** — 앱에 코드 안 넣고 vercel 라이브 페이지를 보여줌. 장점: 즉시 핫픽스. 단점: **오프라인 사용 불가** + **iOS Apple 리뷰가 "thin wrapper" 로 보고 거절 가능**.
   - 거절 방어 논리: 앱에서 OS 통합 기능 (푸시, 위치, 카메라, 햅틱) 사용 — 단순 wrap 이 아님.
2. **개인정보 변경** 시 양 스토어 동시 업데이트 필요 (Play Data Safety + App Privacy).
3. **Supabase 환경변수** 노출 금지 — `anon key` 만 클라이언트에 둠, `service_role` 은 Edge Function 만.
4. **앱 삭제 / 계정 삭제 흐름**: Apple 가이드라인 5.1.1(v) — 계정 삭제 기능을 앱 내에 둬야 함. 현재 마이페이지에 있는지 확인.

---

## 즉시 다음 액션 (오늘)

1. ☐ Android `versionCode` 2 로 올리고 `cap sync` + `gradlew bundleRelease`
2. ☐ DevTools 로 스크린샷 8장 캡쳐 → `store_assets/screenshots/phone/`
3. ☐ Play Console 내부 테스트 트랙에 AAB 업로드
4. ☐ 본인 기기에서 내부 테스트 링크로 설치 → 푸시 알림 / 결제 / 계보도 / 슈퍼어드민 정상 동작 확인
