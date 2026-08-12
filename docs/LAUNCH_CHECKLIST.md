# TAAM — iOS / Android 출시 체크리스트

> 목표: **토스페이먼츠 최종 승인 = 버튼만 누르면 출시**되는 상태 유지.
> 마지막 점검: 2026-08

---

## 0. 콘솔 바로가기

| 용도 | 주소 |
|---|---|
| **Google Play Console** | https://play.google.com/console |
| **App Store Connect** | https://appstoreconnect.apple.com |
| **Codemagic 빌드** | https://codemagic.io/apps |
| Apple Developer (인증서/기기) | https://developer.apple.com/account |
| Supabase (백엔드) | https://supabase.com/dashboard/project/edfsmzbcixfnqabrsvut |
| Vercel (웹 배포) | https://vercel.com |

패키지/번들 ID: **`com.playtaam.app`** (iOS·Android 동일)

---

## 1. 빌드 실행 방법

### iOS — 자동 ✅
`main` 브랜치에 **네이티브 관련 파일**이 푸시되면 Codemagic 이 자동 빌드 → **TestFlight 자동 업로드**.
수동 실행: Codemagic → `TAAM iOS TestFlight Build` → **Start new build**

### Android — 수동 (키스토어 등록 후)
Codemagic → `TAAM Android Play Build` → **Start new build** → 산출물 `*.aab` 다운로드 → Play Console 업로드

**⚠ 최초 1회만: Codemagic → 앱 Settings → Environment variables → 그룹 `android_keystore`**

| 변수명 | 값 | Secure |
|---|---|---|
| `KEYSTORE_B64` | `openssl base64 -A -in taam-release.keystore` 출력 전체 | ✓ |
| `CM_KEYSTORE_PASSWORD` | 키스토어 비밀번호 | ✓ |
| `CM_KEY_ALIAS` | `taam` | |
| `CM_KEY_PASSWORD` | 키 비밀번호 | ✓ |

> 등록 전에 빌드하면 반드시 실패합니다. 등록 후에는 자동 트리거로 바꿀 수 있습니다.

---

## 2. 빌드 파이프라인이 자동 처리하는 것 (신경 안 써도 됨)

**iOS**
- Capacitor iOS 플랫폼 생성/동기화
- 수출규정 면제(`ITSAppUsesNonExemptEncryption=NO`) — TestFlight 질문 자동 회피
- **권한 사용 목적 문자열** 주입 (사진·카메라·위치·마이크) ← 없으면 앱 크래시 + 확정 리젝
- **PrivacyInfo.xcprivacy** 생성 (Apple 개인정보 매니페스트, 2024.05~ 필수)
- 소셜 로그인 설정 (Google URL scheme + Apple Sign In entitlement)
- 앱 아이콘 생성 (`assets/icon.png` 1024px 기준)
- 코드 서명 자동 (인증서·프로파일 자동 발급)
- 빌드 번호 자동 증가 → TestFlight 업로드

**Android**
- Capacitor Android 플랫폼 생성/동기화
- 앱 아이콘 생성
- **AndroidManifest 권한 주입** (위치·카메라, 하드웨어는 optional)
- JDK 21 (Capacitor 8 필수)
- 키스토어 복원 + 릴리스 서명 → `bundleRelease` → AAB

---

## 3. 출시 전 남은 작업 (사람이 해야 하는 것)

### 🔴 필수 — 토스 승인 후
- [ ] 토스페이먼츠 가맹 심사 완료 → **실결제 1건 성공 확인**
- [ ] 데모 계정에 **예치금 넉넉히 부여**(₩5,000,000 권장) → 심사자가 카드 결제창 없이 구매 완결 가능
- [ ] `docs/APP_REVIEW_NOTES.md` 의 데모 계정·초대코드 채워서 심사 노트 제출

### 🟡 지금 병행 가능
- [ ] **Play Console 계정 유형 확인** — 개인 계정(2023.11 이후 생성)이면 프로덕션 전 **테스터 12명 × 14일 비공개 테스트** 필요 → 즉시 시작해야 일정 안 밀림. 법인 계정이면 해당 없음
- [ ] 스토어 등록정보: 스크린샷(iOS 6.7"·6.5" / Android 폰·태블릿), 앱 설명, 키워드, 프로모션 텍스트
- [ ] **연령 등급 설문** — 만 19세 이상 (주류 페어링 포함)
- [ ] **개인정보 라벨**(App Store) / **데이터 안전 양식**(Play) 작성
  - 수집: 이름·전화번호·이메일·결제정보·기기ID·위치(선택)
  - 제3자 공유 없음 / 추적 없음
- [ ] 개인정보처리방침 URL 등록: `https://taam-app.vercel.app/legal/privacy.html`
- [ ] 계정 삭제 URL 등록(Play 필수): `https://taam-app.vercel.app/legal/account_deletion.html`
- [ ] Android 키스토어 환경변수 등록 → AAB 1회 빌드 → **내부 테스트 트랙**에 올려두기

### 🟢 완료됨
- [x] 인앱 계정 삭제 (App Store 5.1.1(v)) — 마이페이지 → 설정 → 계정 삭제
- [x] iOS 권한 문자열 + PrivacyInfo.xcprivacy 자동 주입
- [x] Android 매니페스트 권한 자동 주입
- [x] 심사 노트 문안 (`docs/APP_REVIEW_NOTES.md`)
- [x] 앱 아이콘 (`assets/icon.png`) · 스플래시
- [x] 약관·개인정보처리방침·환불정책 페이지
- [x] 만 19세 이상 가입 동의
- [x] TestFlight 파이프라인 동작 확인

---

## 4. 출시 당일 순서

1. 토스 승인 확인 → 실결제 테스트 1건
2. 데모 계정 예치금 충전 + 심사 노트 최종본 작성
3. **iOS**: main 푸시(또는 수동 빌드) → TestFlight 확인 → App Store Connect 에서 **심사 제출**
4. **Android**: Codemagic AAB 빌드 → Play Console → 프로덕션(또는 내부→프로덕션 승급) → **심사 제출**
5. 심사 통과 후 출시 버튼

## 5. 리젝 시 대응
- 결제 관련 리젝 → `APP_REVIEW_NOTES.md` 의 **결제 구조 영문 문구**로 회신 (Guideline 3.1.5(a) 근거)
- 진입 불가 리젝 → 데모 계정·초대코드 재확인 후 회신
- 그 외 → 리젝 사유 원문을 그대로 공유해주시면 대응 문안 작성
