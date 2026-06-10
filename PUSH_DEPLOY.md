# 🔔 TAAM Web Push 알림 — 배포 가이드

완전한 푸시 알림 인프라가 코드로 준비되었습니다. 배포 전 **딱 4가지 작업**만 하면 활성화됩니다.

---

## 📋 체크리스트

- [ ] **A. VAPID 키 생성** (1회, 영구)
- [ ] **B. Supabase 테이블 생성** (1회)
- [ ] **C. Edge Function 배포 + Secrets 설정** (1회)
- [ ] **D. 클라이언트 VAPID Public Key 입력 + 아이콘 파일 추가** (코드)

---

## A. VAPID 키 생성

VAPID(Voluntary Application Server Identification) 키 쌍은 푸시 발송자 인증용입니다.
Public Key는 클라이언트에, Private Key는 서버(Edge Function)에 박힙니다.

### 방법 1: Node.js (가장 간단)

```bash
npx web-push generate-vapid-keys
```

결과:
```
=======================================
Public Key:
BNBl4...........(약 87자)............
Private Key:
3KAYzL.........(약 43자).............
=======================================
```

### 방법 2: 온라인 생성기 (Node.js 없을 때)

https://www.attheminute.com/vapid-key-generator
또는
https://vapidkeys.com/

⚠️ **Private Key 는 절대 git/공개 코드에 커밋 X**

---

## B. Supabase 테이블 생성

1. Supabase Dashboard → SQL Editor 열기
2. `sql/push_subscriptions_schema.sql` 파일 내용 복사 → 붙여넣기 → Run
3. `public.push_subscriptions` 테이블 생성됨 (RLS 자동 적용)

---

## C. Edge Function 배포

### 1) 함수 배포

**옵션 A: Supabase Dashboard (수동, GUI)**
1. Dashboard → Edge Functions → Create function
2. 이름: `send-push`
3. `supabase/functions/send-push/index.ts` 내용 통째로 복사 → 붙여넣기 → Deploy

**옵션 B: CLI**
```bash
cd 프로젝트루트
supabase functions deploy send-push
```

### 2) Secrets 설정 (필수)

Supabase Dashboard → **Settings** → **Edge Functions** → **Secrets**

추가할 환경변수 3개:

| 키 | 값 |
|---|---|
| `VAPID_PUBLIC_KEY` | A 단계의 Public Key (BNBl4... 형식) |
| `VAPID_PRIVATE_KEY` | A 단계의 Private Key (3KAYzL... 형식) |
| `VAPID_SUBJECT` | `mailto:관리자@이메일.com` 또는 `https://taam-app.vercel.app` |

> 💡 `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` 는 Edge Functions에 자동 주입됨 (직접 설정 불필요)

---

## D. 클라이언트 측 설정

### 1) VAPID Public Key 입력

`index.html` 검색해서:
```js
var VAPID_PUBLIC_KEY = 'BBKEY__REPLACE_AFTER_DEPLOY__';   // ← 여기를 교체
```

→ A 단계에서 받은 **Public Key 로 교체**

### 2) 아이콘 파일 추가

`/icons/` 디렉토리에 다음 2개 파일 추가:
- `icon-192.png` (192×192px)
- `icon-512.png` (512×512px)

(없으면 푸시 알림 작동은 하지만 기본 아이콘으로 표시됨. 권장)

### 3) 배포

Vercel 자동 배포 (push to main).

---

## 🧪 테스트

### 1) 권한 허용 + 구독 등록

1. PWA 새로고침 (Ctrl+Shift+R)
2. 마이페이지 → 알림 설정
3. 최상단 "📱 기기 푸시 알림" → [허용하기]
4. 브라우저/iOS 권한 팝업 → 허용
5. 콘솔에 `[Push] 구독 저장 완료: https://fcm.googleapis.com/...` 출력 확인
6. Supabase `push_subscriptions` 테이블에 1개 row 생성 확인

### 2) 다른 기기 발송 테스트

**조건**: 같은 계정으로 다른 기기 1개에서도 권한 허용 + 구독 등록

1. 기기 A 에서 예치금 충전 (예: 30,000원)
2. 기기 B (PC/다른 폰)에 **OS 푸시 알림 도착** 확인
3. 알림 클릭 → 앱 포커스 또는 새 탭 오픈

### 3) 콘솔 확인 명령어

```js
// 구독 상태
navigator.serviceWorker.ready
  .then(reg => reg.pushManager.getSubscription())
  .then(sub => console.log(sub));

// 강제 푸시 발송 (본인 다른 기기에)
pushSend('user', {
  title: '🔔 테스트',
  body: '푸시 알림 테스트입니다',
  category: 'system',
});
```

---

## 🚨 iOS Safari 주의사항

iOS PWA 푸시는 **iOS 16.4 이상**에서만 작동.

설정 순서:
1. Safari 에서 PWA 사이트 열기
2. 공유 → "홈 화면에 추가"
3. **홈 화면 아이콘에서 앱 실행** (Safari 에서 X)
4. 마이페이지 → 알림 설정 → 권한 허용
5. iOS 설정 → 알림 → TAAM → 알림 허용 추가 확인

---

## 📊 발송 범위 (`to` 파라미터)

```js
pushSend('user', payload);          // 본인의 모든 기기 (예: PC + 폰)
pushSend('all', payload);            // 모든 구독자 (대량 공지)
pushSend('role:admin', payload);     // 어드민 역할만
pushSend('role:superadmin', payload);
pushSend('topic:ticket', payload);   // 'ticket' 토픽 구독자만
pushSend('uid:<UUID>', payload);     // 특정 사용자 user_id 지정
```

`payload` 형식:
```js
{
  title: 'TAAM',
  body: '메시지 본문',
  icon: '/icons/icon-192.png',  // 옵션
  url: '/',                       // 클릭 시 이동할 URL
  category: 'ticket',             // 'ticket'|'charge'|'refund'|'remind' 등
  tag: 'taam-12345',              // 중복 알림 통합용
  requireInteraction: false,      // true면 사용자 액션 전까지 알림 유지
}
```

---

## 🔧 트러블슈팅

### "Service Worker not available"
- HTTPS 환경인지 확인 (localhost / vercel.app 은 OK, file:// 은 X)
- `/sw.js` 가 루트 경로에 있는지 확인

### "VAPID keys not configured"
- Edge Function Secrets 에 VAPID_PUBLIC_KEY / PRIVATE_KEY 둘 다 등록됐는지
- 키 형식이 정확한지 (URL-safe base64)

### "주체(VAPID Subject)가 잘못됨"
- VAPID_SUBJECT 는 `mailto:` 또는 `https://` 로 시작해야 함

### iOS 에서 알림 안 옴
- iOS 16.4 이상 확인
- 홈 화면에 추가 후 PWA 로 실행 (Safari 직접 실행 X)
- 시스템 설정 → 알림 → TAAM 허용 확인
- 백그라운드/다른 앱에서 테스트 (앱이 포커스되어 있으면 OS 알림 안 뜸)

### "VAPID public key length is invalid"
- 클라이언트의 VAPID_PUBLIC_KEY 가 87자 정도 (BNBl4... 시작) 인지 확인
- Edge Function 의 환경변수도 같은 키 인지 확인

---

## 📁 추가된 파일 정리

```
/sw.js                                       — Service Worker (푸시 수신 + 알림 표시)
/manifest.json                               — PWA 매니페스트 (설치 가능하게)
/sql/push_subscriptions_schema.sql           — DB 테이블 생성 SQL
/supabase/functions/send-push/index.ts       — 발송 Edge Function
/icons/icon-192.png                          — 192×192 아이콘 (사용자가 추가)
/icons/icon-512.png                          — 512×512 아이콘 (사용자가 추가)
```

index.html 변경:
- `<head>` 에 manifest + theme-color + apple-mobile-web-app 메타
- Web Push 인프라 JS (서비스워커 등록, 구독, 발송)
- 핵심 이벤트 (티켓예약/충전/환불) → `notifPushSelf()` 호출

---

## 💡 향후 확장 아이디어

1. **DB 트리거 → 자동 푸시**: Supabase Database Webhook으로 `purchases.insert` 시 자동으로 send-push 호출
2. **토픽별 구독 관리 UI**: 사용자가 알림 설정에서 토픽 토글 시 push_subscriptions.topics 업데이트
3. **알림 액션 버튼**: payload.actions 로 "예약 보기 / 무시" 등 인앱 액션 추가
4. **다국어 페이로드**: 사용자 언어 설정에 따라 title/body 번역
5. **빈도 제한**: 같은 사용자에게 1분에 10개 이상 발송 시 Rate Limit
