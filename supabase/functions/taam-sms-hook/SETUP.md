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

## 5. Phone Provider 활성화

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
| `SEND_SMS_HOOK_SECRET 미설정` | 4번 시크릿 누락 |
| `서명 불일치` | 시크릿 값이 훅 발급값과 다름 |
| `SOLAPI_* 시크릿 미설정` | 3번 누락 |
| `Solapi 발송 실패 (4xx)` | 발신번호 미등록 / 잔액 부족 / 수신번호 형식 |

## 보안 메모

- 인증번호는 **로그에 남기지 않는다**. 수신번호도 뒤 4자리를 가려 기록한다.
- 서명 검증 + **5분 타임스탬프 창**으로 재전송 공격을 막는다.
- 문자 본문에 인증번호 외 정보를 넣지 않는다 (문자 유출 시 피해 최소화).
- 발송 실패 시 Supabase 에 오류를 그대로 돌려줘야 회원 화면에 "발송 실패" 가 뜬다.

## 비용

국내 SMS 약 8~20원/건. 알림톡과 같은 Solapi 잔액을 쓴다.
