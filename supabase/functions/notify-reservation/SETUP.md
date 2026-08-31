# notify-reservation — 예약 요청 어드민 알림 (3채널) 셋업

새 예약 요청 → 매장 어드민에게 ①앱푸시 ②카카오 알림톡 ③LINE 발송.
①은 배포만 하면 작동. ②③은 외부 계정 + 시크릿 설정 시 자동 활성화(미설정이면 skip).

## 1. 배포 (필수 — 이것만 해도 앱푸시 작동)
Supabase Dashboard → Edge Functions → **New function** → 이름 `notify-reservation`
→ `index.ts` 내용 붙여넣기 → Deploy.
(또는 CLI: `supabase functions deploy notify-reservation`)

SQL 1개 실행: `sql/venue_notify_fields.sql` (notify_phone / notify_line_id 컬럼)

> 앱푸시 전제: 기존 send-push 가 배포돼 있고 VAPID/FCM 시크릿이 설정돼 있을 것.
> 어드민이 앱에서 알림 허용(푸시 구독)을 해야 수신됨.

## 2. 카카오 알림톡 (선택 — 한국 매장)
필요한 것:
1. **카카오 비즈니스 채널** 개설 + 비즈니스 인증 → `pfId` 발급
2. 발송 대행: **Solapi**(solapi.com) 가입 → API Key/Secret 발급, **발신번호 등록**
3. Solapi에서 카카오 채널 연동 후 **알림톡 템플릿 등록·승인** (심사 1~3일)
   - 템플릿 변수: `#{shop}` `#{date}` `#{party}` 포함해서 작성
   - 예: `[TAAM] 새 예약 요청\n#{shop}\n#{date} · #{party}명\n앱에서 수락/거절해주세요.`
4. Supabase 시크릿 설정 (Dashboard → Edge Functions → Secrets):
   ```
   SOLAPI_API_KEY=...
   SOLAPI_API_SECRET=...
   SOLAPI_SENDER=0212345678        ← 등록된 발신번호
   KAKAO_PF_ID=...
   KAKAO_TEMPLATE_NEW_REQUEST=...  ← 승인된 템플릿 ID
   ```
5. 어드민이 앱 → 나의 레스토랑 → "카카오 알림톡 전화번호" 입력

## 3. LINE (선택 — 일본 매장)
필요한 것:
1. **LINE Official Account** 개설 → LINE Developers 에서 **Messaging API** 채널 활성화
2. **Channel access token (long-lived)** 발급
3. Supabase 시크릿:
   ```
   LINE_CHANNEL_ACCESS_TOKEN=...
   ```
4. 매장 담당자가 OA를 **친구 추가** → 그 사람의 **userId**(U로 시작) 확보
   - ✅ **`line-webhook` 함수가 이미 이걸 한다.** 친구 추가하면 userId 를
     카드로 답장해 준다. 콘솔 로그를 뒤질 필요 없다.
   - 배포: `supabase functions deploy line-webhook --no-verify-jwt`
     (LINE 은 인증 헤더 없이 호출하므로 `--no-verify-jwt` 필수)
   - LINE Developers → Messaging API → Webhook URL 에
     `https://<project-ref>.supabase.co/functions/v1/line-webhook`
     → Verify → **Use webhook ON**
   - 서명 검증을 켜려면 시크릿에 `LINE_CHANNEL_SECRET` 추가 (권장)
5. 어드민이 앱 → 나의 레스토랑 → "LINE ID" 에 userId 입력

## 4. 테스트
회원으로 예약 요청 1건 → Edge Functions 로그에서 notify-reservation 응답 확인:
`{ ok:true, admins:1, push:1, kakao:"ok|skip(...)", line:"ok|skip(...)" }`
