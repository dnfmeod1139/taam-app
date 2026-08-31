# notify-purchase — 티켓 결제 → 파트너 매장 알림 (3채널) 셋업

회원이 티켓을 결제하면 **그 매장 파트너 어드민**에게
①앱푸시 ②카카오 알림톡 ③LINE 발송.

`notify-reservation`(예약 요청 알림)과 같은 구조다. 다른 점은 **무엇을 읽느냐**뿐이다.

| | notify-reservation | notify-purchase |
|---|---|---|
| 입력 | `reservation_id` | `purchase_id` |
| 읽는 표 | `reservation_requests` | `tickets` |
| 발송 조건 | 요청이 있으면 | **`status='active'` 일 때만** |
| 알림톡 템플릿 | `KAKAO_TEMPLATE_NEW_REQUEST` | `KAKAO_TEMPLATE_NEW_PURCHASE` |

---

## 1. 배포 (이것만 해도 앱푸시 작동)

Supabase Dashboard → Edge Functions → **New function** → 이름 `notify-purchase`
→ `index.ts` 내용 붙여넣기 → Deploy.

새로 만들 SQL 은 **없다.** `venue_partners.notify_phone / notify_line_id` 와
`admin_grants` 를 그대로 쓴다 (예약 알림이 쓰던 것과 같다).

> 앱푸시 전제: `send-push` 가 배포돼 있고, 파트너 어드민이 앱에서 알림을
> 허용(푸시 구독)했을 것.

## 2. 카카오 알림톡 — **새 템플릿이 필요하다**

예약 요청 템플릿은 그대로 두고 **결제 알림용을 하나 더** 등록·승인받는다.
변수 이름이 다르면 발송이 실패하므로 아래 넷을 반드시 포함할 것.

```
#{shop}   매장명
#{date}   방문일시   (예: 9/30 (수) 11:00)
#{party}  인원        (숫자만)
#{guest}  예약자 이름
```

**문구 초안**

```
[TAAM] 새 예약이 확정되었습니다
#{shop}
#{date} · #{party}명
예약자 #{guest}

앱에서 자세히 확인하실 수 있습니다.
```

승인되면 시크릿 하나만 추가한다 (나머지는 예약 알림과 공유):

```
KAKAO_TEMPLATE_NEW_PURCHASE=...   ← 승인된 '결제' 템플릿 ID
```

> ⚠ 이미 승인된 템플릿이 **예약 요청용 하나뿐**이면 그걸 그대로 쓸 수 없다.
> `#{guest}` 가 없기 때문이다. 결제용을 새로 올려야 한다.
> (승인된 템플릿에 예약자 변수가 이미 있다면 그 ID 를 그대로 넣으면 된다)

## 3. LINE — 추가 설정 없음

`LINE_CHANNEL_ACCESS_TOKEN` 을 예약 알림과 공유한다.
카드(Flex Message)는 이 함수 안에 따로 들어 있다 — 「ご予約が確定しました」.

수신처(`notify_line_id`)는 이미 있는 `line-webhook` 으로 붙인다:
매장 담당자가 OA 를 친구 추가하면 **userId 를 카드로 답장**해 주고,
그걸 앱 「나의 레스토랑 → LINE ID」에 붙여넣으면 끝이다.

## 4. 앱 호출

`index.html` 의 구매 완료 처리 마지막에 이미 들어 있다 (BUILD 2026.08.31-w 이상):

```js
window.sb.functions.invoke('notify-purchase', { body: { purchase_id: purchaseId } })
  .catch(function(){});
```

**실패해도 구매 흐름에 영향이 없다.** 알림은 부가 기능이다.

## 5. 테스트

티켓 1건을 예치금으로 결제 → Edge Functions 로그에서 응답 확인:

```
{ ok:true, admins:1, push:1, kakao:"ok|skip(...)", line:"ok|skip(...)", marked:true }
```

| 값 | 뜻 |
|---|---|
| `admins:0` | `admin_grants` 에 그 매장 어드민이 없다 — 파트너 계정을 먼저 연결 |
| `push:0` | 어드민이 앱에서 알림 허용을 안 했다 |
| `kakao:"skip(미설정)"` | 시크릿이 없다 (템플릿 ID 포함) |
| `kakao:"skip(수신번호없음)"` | 「나의 레스토랑」에 알림톡 번호가 비었다 |
| `line:"skip(수신ID없음)"` | 「나의 레스토랑」에 LINE ID 가 비었다 |
| `skip:"상태 hold"` | 아직 결제 확정 전 — 정상 |
| `skip:"이미 보냄"` | 중복 방지가 동작한 것 — 정상 |

---

## 설계에서 지킨 것

**앱이 넘긴 값을 믿지 않는다.**
`purchase_id` 하나만 받고 DB 를 다시 읽는다. `status='active'` 가 아니면
아무것도 안 한다. 회원이 아무 id 나 넘겨도 없는 건은 아무 일도 안 일어난다.

**두 번 보내지 않는다.**
보낸 뒤 `tickets.extra_data.partner_notified_at` 에 시각을 남긴다.
재시도·새로고침으로 같은 알림이 또 가면 매장은 예약이 두 건인 줄 안다.
단 **하나도 못 보냈으면 표시를 남기지 않는다** — 다음에 다시 시도할 수 있어야 한다.

**연락처는 뒤 4자리만 내보낸다.**
매장이 손님을 알아보는 데는 그걸로 충분하다. 전체 번호는 앱에서 본다.
외부 채널(알림톡·LINE)로 전체를 흘리지 않는다.

> ⚠ 그래도 예약자 **이름**은 나간다. 이건 개인정보 제3자 제공이다.
> 파트너 매장에 예약 정보를 전달한다는 내용이 이용약관·개인정보처리방침에
> 있는지 확인할 것.
