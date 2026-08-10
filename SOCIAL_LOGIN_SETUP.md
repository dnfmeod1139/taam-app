# 소셜 로그인(구글·애플) 셋업 가이드

> 상태: 코드 `USE_SOCIAL_LOGIN=true`(구글 웹 테스트 ON). 해외(EN) 인증화면에만 노출, 국내(KR) 본인확인 흐름 불변.
> 클라이언트엔 시크릿 없음 — 구글 secret·애플 `.p8` 은 전부 Supabase 대시보드.

## 진행 현황 (2026-08)
- [x] Google Cloud: 동의화면(Google Auth Platform) + **Web / iOS** OAuth 클라이언트 발급
      - Web redirect URI: `https://edfsmzbcixfnqabrsvut.supabase.co/auth/v1/callback`
      - iOS Bundle: `com.playtaam.app`
- [x] Supabase: **Google provider Enabled** (Client IDs = Web,iOS 콤마 / Secret 등록)
- [x] Supabase: URL Configuration (Site `https://taam-app.vercel.app` + Redirect `/**`)
- [x] index.html: 소셜 로그인 코드 (웹 OAuth / 네이티브 idToken / 초대코드 보존·복귀 / i18n)
- [ ] **Google 동의화면 Test users 에 테스트 Gmail 추가** (Testing 모드라 필수)
- [ ] 웹 구글 로그인 실동작 테스트 (EN 초대코드 + 초대이메일=구글이메일)
- [ ] Apple provider (아래 STEP A)
- [ ] 네이티브 재빌드 (아래 STEP B) — 앱에서 소셜 쓰려면
- [ ] Google 동의화면 **Production 게시** (Testing 100명 제한 해제, 기본 스코프라 검수 불필요)

## 코드에 들어간 것
| 위치 | 내용 |
|---|---|
| `index.html` `var USE_SOCIAL_LOGIN` | 전환 스위치 |
| `#vpSocialBox` | 구글·애플 버튼. 웹=항상 / 네이티브=플러그인 탑재 시만 노출 |
| `socialLogin()` 외 모듈 | 웹/네이티브 분기, 초대코드 리다이렉트 보존, 가입 verify-invite→_doProfileAndConsume, 로그인 보안검증 |
| i18n `social_*` | KO/EN/JA |

---

## STEP A — Apple provider

1. **Apple Developer → Identifiers → App ID `com.playtaam.app`** → Sign In with Apple 체크.
2. **Services ID** 생성(예 `com.playtaam.app.web`) → Sign In with Apple Configure:
   - Domains: `edfsmzbcixfnqabrsvut.supabase.co`
   - Return URLs: `https://edfsmzbcixfnqabrsvut.supabase.co/auth/v1/callback`
3. **Keys → 새 Key** → Sign In with Apple → **`.p8` 다운로드**(1회). Key ID / Team ID 기록. (`.p8`는 저장소 금지)
4. **Supabase → Authentication → Providers → Apple** 활성 → Services ID, Team ID, Key ID, `.p8` 내용 등록 → Save.

## STEP B — 네이티브 앱 재빌드 (앱에서 소셜 쓰려면)

> 웹은 위 STEP 까지면 됨. 앱은 구글이 웹뷰 OAuth 를 막아 네이티브 SDK 필요.

1. 플러그인 설치 (버전은 Capacitor 8 호환 확인):
   ```
   npm i @capacitor-community/apple-sign-in @codetrix-studio/capacitor-google-auth
   npx cap sync
   ```
   ※ peer-deps(ERESOLVE) 뜨면 최신 호환 버전으로 조정. **이 의존성은 웹 배포(Vercel)엔 넣지 말 것** — 빌드 install 깨질 수 있음. 네이티브 빌드에서만.
2. `capacitor.config.json` `plugins.GoogleAuth.serverClientId` = **Web Client ID**.
3. iOS: Xcode → **Sign In with Apple** capability 추가 + `Info.plist` 에 구글 **reversed client ID** URL scheme(다운받은 `.plist` 참고).
4. Android: 릴리즈 keystore SHA-1 을 Google Cloud Android client 에 등록.
5. Codemagic 재빌드 → TestFlight. (플러그인 감지되면 앱에서도 버튼 자동 노출)

## 주의
- **초대 이메일 = 소셜 이메일** 이어야 가입 통과(verify-invite). 다르면 "초대 불일치"로 막힘(정상).
- 애플 네이티브 idToken 은 Supabase 설정에 따라 nonce 필요할 수 있음(실패 시 Skip nonce 또는 nonce 전달).
- 롤백: `USE_SOCIAL_LOGIN=false` → 버튼 숨김 + 함수 비활성. 데이터/스키마 변경 없음.
