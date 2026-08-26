# taam-sms-hook — SMS 본인인증(OTP)을 Solapi 로 발송

앱의 **SMS 인증번호 로그인/가입**을 국내 문자사(Solapi)로 보내는 설정이다.

## 왜 이 방식인가

| 방식 | 문제 |
|---|---|
| Supabase 기본(Twilio 등) | 한국 번호는 국제 경로 → 도달률↓, 단가 5~10배 |
| OTP 를 직접 구현 | 코드 생성·해시 저장·만료·재발송 제한·무차별 대입 방어를 전부 새로 구현 |
| **Send SMS Hook** ⭐ | OTP 로직은 Supabase 그대로, **발송만** Solapi 로 |

앱 코드는 **한 줄도 바뀌지 않는다.** 기존 `signInWithOtp({phone})` / `verifyOtp` 가 그대로 동작한다.

---

## 1. 사전 준비 (이미 돼 있으면 건너뛴다)

`notify-reservation`(카카오 알림톡)을 이미 쓰고 있다면 **1번은 끝나 있다.**

1. **Solapi** 가입 → API Key / Secret 발급
2. **발신번호 사전등록** (사업자등록증 필요, 보통 1~2일)
   - 국내 문자는 등록된 번호로만 발송 가능 — 법정 요건이다

## 2. Edge Function 배포

Supabase Dashboard → **Edge Functions** → **New function** → 이름 `taam-sms-hook`
→ `index.ts` 내용 붙여넣기 → **Deploy**

## 3. 시크릿 설정

Dashboard → Edge Functions → **Secrets**

```
SOLAPI_API_KEY=...
SOLAPI_API_SECRET=...
SOLAPI_SENDER=0212345678        ← 사전 등록된 발신번호
```

> `notify-reservation` 과 같은 값을 그대로 쓴다. 이미 설정돼 있으면 추가할 게 없다.

## 4. 훅 등록 → 시크릿 하나 더

Dashboard → **Authentication** → **Hooks** → **Send SMS hook**

- **Enable** 체크
- Type: **HTTPS**
- URL: `https://<프로젝트ref>.supabase.co/functions/v1/taam-sms-hook`
- 저장하면 **Secret** 이 발급된다 (`v1,whsec_...`)

그 값을 Edge Functions → Secrets 에 추가:

```
SEND_SMS_HOOK_SECRET=v1,whsec_...
```

> ⚠️ 이 시크릿이 없으면 함수가 **모든 요청을 거부**한다.
> 서명 검증 없이 열어두면 아무나 호출해 문자를 무한 발송시킬 수 있기 때문이다.

## 5. ⭐ JWT 검증 끄기 — 여기서 막힌다

Dashboard → Edge Functions → **taam-sms-hook** → **Settings**
→ **Verify JWT / Enforce JWT Verification** 를 **끈다**.

왜 꺼야 하나. Edge Function 은 기본적으로 요청에 Supabase JWT 가 붙어 있어야 통과시킨다.
그런데 Auth 훅은 JWT 를 보내지 않는다 — 대신 Standard Webhooks 서명
(`webhook-id` · `webhook-timestamp` · `webhook-signature`)을 보낸다.
그래서 JWT 검증이 켜져 있으면 **함수 코드가 실행되기도 전에 게이트웨이가 막는다.**

증상이 아주 특징적이다:

| 어디 | 보이는 것 |
|---|---|
| Auth 로그 | `Hook errored out` · `/user` 500 |
| **taam-sms-hook 로그** | **텅 비어 있음** (호출 기록조차 없다) |
| Solapi 대시보드 | 오늘 발송 0건 |

훅은 「등록됨·Enabled」로 멀쩡히 보이고, 함수도 배포돼 있고, Solapi 잔액도 있는데
문자만 안 간다. 세 군데를 다 봐도 원인이 안 보이는 이유가 이것이다.

> 보안은 약해지지 않는다. 이 함수는 **서명 검증 + 5분 타임스탬프 창**으로 스스로를 지킨다
> (`SEND_SMS_HOOK_SECRET`). JWT 검증은 애초에 이 경로에 맞는 자물쇠가 아니다.

CLI 로 배포한다면 `--no-verify-jwt` 를 붙인다:

```
supabase functions deploy taam-sms-hook --no-verify-jwt
```

---

## 6. Phone Provider 활성화

Dashboard → Authentication → **Sign In / Providers** → **Phone**

- **Enable Phone provider** 켜기
- SMS Provider 는 무엇을 골라도 **훅이 우선**한다 (실제 발송은 이 함수가 한다)
- **OTP Expiry**: 180초(3분) 권장 — 문자 본문의 "3분 안에" 문구와 맞춘다

---

## 확인

1. 앱에서 휴대폰 번호로 인증번호 요청
2. 문자 수신: `[TAAM] 인증번호 123456 / 3분 안에 입력해주세요.`
3. 입력 → 로그인/가입 완료
4. 실패하면 Dashboard → Edge Functions → `taam-sms-hook` → **Logs** 확인

| 로그 | 원인 |
|---|---|
| **로그가 아예 없음** + Auth 로그에 `Hook errored out` | **5번 — JWT 검증이 켜져 있다** |
| `SEND_SMS_HOOK_SECRET 미설정` | 4번 시크릿 누락 |
| `서명 불일치` | 시크릿 값이 훅 발급값과 다름 |
| `SOLAPI_* 시크릿 미설정` | 3번 누락 |
| `Solapi 발송 실패 (4xx)` | 발신번호 미등록 / 잔액 부족 / 수신번호 형식 |

첫 줄이 제일 헷갈린다. **함수 로그가 비어 있으면 함수를 의심하지 말고 게이트웨이를 의심한다.**
로그가 없다는 건 「함수가 실패했다」가 아니라 「함수가 불리지도 않았다」는 뜻이다.
단, 5번이 이미 꺼져 있다면 로그 화면 쪽 문제일 수도 있다 — 그때는 아래를 본다.

### 사유는 앱 화면에도 뜬다

이 함수는 오류를 **HTTP 200 + 본문의 error 객체**로 돌려준다. Supabase Auth 훅 규약이 그렇다.
HTTP 상태로 4xx·5xx 를 주면 GoTrue 는 본문을 읽지 않고 `Hook errored out` 한 줄만 남긴 채
회원에게 일반 500 을 준다 — 무엇이 막았는지 어디에도 안 남는다.

200 으로 주면 message 가 그대로 앱 화면까지 올라온다.

| 앱 화면에 뜨는 문구 | 원인 |
|---|---|
| `[sms-hook] SEND_SMS_HOOK_SECRET 미설정` | 4번 누락 |
| `[sms-hook] 서명 불일치 …` | 시크릿 값이 훅 발급값과 다름 |
| `[sms-hook] 서명 헤더 누락 (id=x …)` | 훅이 아닌 곳에서 호출됨 |
| `[sms-hook] SOLAPI 시크릿 미설정 (key=o secret=x …)` | 3번 중 무엇이 빠졌는지 그대로 나온다 |
| `[sms-hook] 보낼 번호/인증번호 없음 (type=phone_change …)` | 페이로드에서 번호를 못 찾음 — 아래 참조 |
| `[sms-hook] Solapi 4xx: …` | 발신번호 미등록 · 잔액 부족 · 번호 형식 — Solapi 가 준 사유가 그대로 |
| `[sms-hook] Solapi 접수 거부 3xxx: …` | HTTP 는 200 인데 접수가 거부됐다 — 수신거부 번호 · 발신번호 반려 · 스팸 차단 등 |

### 보낼 번호는 경로마다 다른 칸에 온다

| 경로 | `sms_type` | 목적지 번호가 있는 칸 |
|---|---|---|
| 가입·로그인 `signInWithOtp({phone})` | `signup` · `sms` | `user.phone` |
| 마이페이지 번호 인증 `updateUser({phone})` | `phone_change` | **`user.phone_change`** (또는 `new_phone`) |

번호 변경 경로에서 `user.phone` 은 **기존** 번호다. 계정에 번호가 아직 없으면 빈 문자열이라,
`user.phone` 만 보면 그 경로가 통째로 죽는다. 실제로 그렇게 죽어 있었다 —
훅도 서명도 다 통과한 뒤 마지막 검사에서 걸려서, 겉으로는 "그냥 발송 실패" 로만 보였다.

로그를 못 봐도 폰 화면 한 줄로 원인이 갈린다.

## 보안 메모

- 인증번호는 **로그에 남기지 않는다**. 수신번호도 뒤 4자리를 가려 기록한다.
- 서명 검증 + **5분 타임스탬프 창**으로 재전송 공격을 막는다.
- 문자 본문에 인증번호 외 정보를 넣지 않는다 (문자 유출 시 피해 최소화).
- 발송 실패 시 Supabase 에 오류를 그대로 돌려줘야 회원 화면에 "발송 실패" 가 뜬다.

## 비용

국내 SMS 약 8~20원/건. 알림톡과 같은 Solapi 잔액을 쓴다.
