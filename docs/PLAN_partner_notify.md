# 작업 계획 — 파트너 매장 알림 (티켓 결제 + LINE 자동 연결)

작성 2026-08-31 · 파트너십 준비

---

## 1. 지금 있는 것

파트너 매장에 알림을 보내는 길은 **이미 하나 깔려 있다.**

```
회원이 예약 요청  →  Edge Function `notify-reservation`  →  3채널
                       ① 앱 푸시   admin_grants 로 찾은 그 매장 어드민 전원
                       ② 알림톡     venue_partners.notify_phone
                       ③ LINE      venue_partners.notify_line_id
```

| 무엇 | 어디 |
|---|---|
| 수신처 저장 | `venue_partners.notify_phone` · `notify_line_id` (`sql/venue_notify_fields.sql`) |
| 입력 화면 | 파트너 어드민 → 「나의 레스토랑」 하단 (`index.html:52421`) · 저장 `prsSave()` |
| 발송 함수 | `supabase/functions/notify-reservation/index.ts` |
| 호출 지점 | `index.html:25875` — 예약 요청 INSERT 직후 |
| 셋업 문서 | `supabase/functions/notify-reservation/SETUP.md` |

**시크릿이 없으면 ②③은 조용히 `skip`** 하고 ①만 나간다. 그래서 지금 배포돼 있어도
알림톡·LINE 은 안 나가고 있을 수 있다 — 확인이 필요하다(4장).

---

## 2. 없는 것 — 이번에 만들 것

### 구멍 ① 티켓 결제 알림이 파트너에게 안 간다

`notify-reservation` 은 **예약 요청(`reservation_requests`)** 에만 걸려 있다.
회원이 그 매장 티켓을 결제하면 `taamNotifyAdmins()` 가 도는데, 그건
**슈퍼어드민 전원**에게만 간다. 파트너는 수신 대상이 아니다.

지금 파트너는 「오늘」·「예약 관리」 화면을 **직접 열어봐야** 안다.
파트너십을 맺으면 이건 안 된다 — 당일 예약이 들어와도 매장이 모른다.

### ~~구멍 ② LINE userId 를 자동으로 못 받는다~~ → **이미 있었다**

처음에 「없다」고 적었는데 **틀렸다.** `SETUP.md` 만 보고 판단했다.
`supabase/functions/line-webhook/index.ts` 가 이미 있고, 하는 일이 정확히 그것이다.

```
매장 담당자가 OA 를 친구 추가
  → line-webhook 이 follow 이벤트를 받아
  → 그 사람의 userId 를 카드(Flex)로 답장
  → 앱 「나의 레스토랑 → LINE ID」에 붙여넣으면 끝
```

서명 검증(`X-Line-Signature`)도 들어 있다 (`LINE_CHANNEL_SECRET` 설정 시).
배포는 반드시 `--no-verify-jwt` 로 — LINE 은 인증 헤더 없이 호출한다.

**그래서 이번에 만들 것은 ①뿐이다.**

---

## 3. 어떻게 만들 것인가

### 3-1. 왜 앱에서 직접 푸시하면 안 되나

오늘 오전에 `send-push` 에 게이트를 걸었다 — **회원 세션은 자기에게만**,
어드민 상향 통지(`role:admin` 등)만 예외다. 회원이 파트너의 uid 로 푸시를 쏘는 건
막혀 있다(그리고 막혀 있어야 한다).

그래서 **Edge Function 이 service role 로 대신 보내는** 구조를 쓴다.
`notify-reservation` 이 이미 그 모양이다 — 앱은 `id` 하나만 넘기고,
함수가 **DB 를 다시 읽어서** 진짜인지 확인하고 보낸다.
회원이 아무 id 나 넘겨도 그 건이 실제로 존재하고 결제됐을 때만 나간다.

### 3-2. 새 Edge Function `notify-purchase`

```
입력   { purchase_id }
동작   ① tickets 에서 purchase_id 로 읽는다 (service role)
       ② status='active' 가 아니면 아무것도 안 한다  ← 위조 방지의 핵심
       ③ restaurant_id 로 admin_grants → 그 매장 어드민 uid 목록
       ④ venue_partners 로 notify_phone / notify_line_id
       ⑤ 3채널 발송 (알림톡·LINE 은 시크릿 없으면 skip)
       ⑥ 보낸 표시를 남긴다 — 재시도로 두 번 가지 않게
반환   { ok, admins, push, kakao, line }
```

`notify-reservation/index.ts` 를 복사해서 조회 부분만 바꾸면 된다.
푸시·알림톡·LINE 발송 함수는 그대로 재사용한다.

**보낼 내용** — 파트너가 「오늘」 화면에서 이미 보는 것과 같게 맞춘다.
새로 노출되는 정보가 없어야 한다.

```
[TAAM] 새 예약 확정
{매장} · {방문일} {시각} · {인원}명
예약자 {이름} · {연락처}
```

> ⚠ 개인정보: 예약자 이름·연락처를 매장에 보내는 것은 **제3자 제공**이다.
> 파트너 매장에 예약 정보를 전달한다는 내용이 이용약관·개인정보처리방침에
> 들어 있는지 확인할 것. 앱 화면에서 이미 보이는 정보라도, 외부 채널
> (알림톡·LINE)로 나가는 건 별개로 본다.

**중복 방지**: 티켓 `extra_data.partner_notified_at` 에 시각을 남기고,
있으면 건너뛴다. (앱이 재시도하거나 사용자가 새로고침해도 한 번만)

### 3-3. 앱에서 부르는 자리

구매가 확정된 직후 — `taamNotifyAdmins()` 를 부르는 그 옆.

```js
try {
  window.sb.functions.invoke('notify-purchase', { body: { purchase_id: purchaseId } })
    .catch(function(){});
} catch(_e){}
```

**실패해도 구매 흐름에 영향이 없어야 한다** (`.catch` 로 삼킨다).
`notify-reservation` 호출부(`index.html:25875`)와 같은 모양이다.

취소 알림도 같은 함수에 `kind:'cancel'` 로 넣을 수 있지만 **2차로 미룬다** —
먼저 결제 알림이 실제로 도착하는 걸 보고 나서.

### 3-4. ~~LINE userId 자동 수집~~ — 이미 만들어져 있다

아래는 처음에 「만들어야 한다」고 적었던 설계다. 실제로는 `line-webhook` 이
이미 같은 일을 하고 있다(연결코드 대신 userId 를 직접 답장하는 방식 —
단계가 하나 적어서 더 낫다). 기록으로만 남긴다.

<details><summary>처음 설계 (미사용)</summary>


```
LINE Developers → Messaging API → Webhook URL 에
  https://<project>.supabase.co/functions/v1/line-webhook

동작   ① follow 이벤트를 받는다 → event.source.userId
       ② line_pending(userId, 받은시각) 에 저장
       ③ 그 사람에게 6자리 연결코드를 답장한다
파트너 ④ 앱 「나의 레스토랑」 → 「LINE 연결」 에 그 코드를 입력
       ⑤ 코드가 맞으면 venue_partners.notify_line_id 에 userId 를 넣는다
```

이러면 파트너가 **userId 를 몰라도** 친구 추가 → 코드 입력만으로 연결된다.
지금처럼 콘솔에서 U로 시작하는 문자열을 찾아 옮겨 적을 필요가 없다.

⚠ LINE webhook 은 **서명 검증**(`X-Line-Signature`, channel secret 으로 HMAC)을
해야 한다. 안 하면 아무나 가짜 follow 를 밀어 넣을 수 있다.
(실제 `line-webhook` 에는 이미 들어 있다)

</details>

---

## 4. 하기 전에 확인할 것

노트북을 여시면 **이 세 가지부터** 봐야 그다음이 정해진다.

### ⓐ 지금 매장별 설정 상태 (Supabase SQL Editor)

```sql
select r.name                              as "매장",
       coalesce(vp.notify_phone,'—')       as "알림톡번호",
       coalesce(vp.notify_line_id,'—')     as "LINE ID",
       case when vp.is_partner then '예약받음' else '꺼짐' end as "예약",
       (select count(*) from admin_grants g
         where g.venue_id::text = vp.venue_id::text
            or g.rest_id::text  = vp.venue_id::text) as "어드민수"
from venue_partners vp
left join restaurants r on r.id::text = vp.venue_id::text
order by r.name;
```

### ⓑ Edge Function 이 배포돼 있나

Supabase Dashboard → Edge Functions → `notify-reservation` 이 목록에 있는지.
없으면 `SETUP.md` 1장부터.

### ⓒ 시크릿이 들어 있나

Dashboard → Edge Functions → Secrets 에서 이름만 확인 (값은 볼 필요 없다).

```
SOLAPI_API_KEY  SOLAPI_API_SECRET  SOLAPI_SENDER
KAKAO_PF_ID     KAKAO_TEMPLATE_NEW_REQUEST
LINE_CHANNEL_ACCESS_TOKEN
```

없는 게 있으면 그 채널은 지금 **안 나가고 있다.**

---

## 5. 외부 준비 — 이미 되어 있다

사장님 확인(2026-08-31): **카카오 채널·Solapi·LINE OA·템플릿 심사까지 끝났고
한 번 테스트도 해봤다.** 그래서 리드타임 걱정은 없다.

남은 것은 하나뿐이다 — **결제 알림용 템플릿이 승인돼 있는가.**

| 경우 | 할 일 |
|---|---|
| 승인된 템플릿이 **예약 요청용 하나뿐** | 결제용을 새로 올려야 한다 (아래 초안). `#{guest}` 가 없으면 못 쓴다 |
| 결제용도 이미 승인돼 있다 | 그 **템플릿 ID 만** `KAKAO_TEMPLATE_NEW_PURCHASE` 시크릿에 넣으면 끝 |

**결제 알림 템플릿 초안** (변수는 `#{}` 로 · 넷 다 있어야 한다)

```
[TAAM] 새 예약이 확정되었습니다
#{shop}
#{date} · #{party}명
예약자 #{guest}

앱에서 자세히 확인하실 수 있습니다.
```

---

## 6. 작업 순서

각 단계가 끝나야 다음이 의미 있다.

| # | 무엇 | 배포 | 비고 |
|---|---|---|---|
| 1 | 4장 ⓐⓑⓒ 확인 | — | 지금 무엇이 켜져 있는지부터 |
| 2 | ✅ `notify-purchase` 코드 작성 | — | **끝남** (`supabase/functions/notify-purchase/`) |
| 3 | ✅ 앱 호출부 붙이기 | 앱 1회 | **끝남** (BUILD 2026.08.31-w) |
| 4 | Edge Function 배포 | 대시보드 | 붙여넣고 Deploy. 앱푸시만으로도 동작한다 |
| 5 | `KAKAO_TEMPLATE_NEW_PURCHASE` 시크릿 | — | 결제용 템플릿 ID. 없으면 알림톡만 skip |
| 6 | 실제 결제 1건으로 확인 | — | 로그의 `admins/push/kakao/line` 값을 본다 |
| 7 | ~~`line-webhook`~~ | — | **이미 있다.** 배포·Webhook URL 등록만 확인 |

2·3 은 노트북 없이 끝냈다. 남은 건 **4(붙여넣기)·5(시크릿)·6(확인)** 뿐이고,
앱 배포는 오늘 밀린 것들과 함께 한 번에 나간다.

---

## 7. 이 작업에서 조심할 것

* **앱 호출 실패가 결제를 막으면 안 된다.** 알림은 부가 기능이다.
  `notify-reservation` 처럼 `.catch(function(){})` 로 삼킨다.
* **Edge Function 은 DB 를 다시 읽는다.** 앱이 넘긴 값을 믿지 않는다 —
  `status='active'` 확인이 위조 방지의 전부다.
* **두 번 보내지 않는다.** 재시도·새로고침으로 같은 알림이 두 번 가면
  매장은 예약이 두 건인 줄 안다.
* **개인정보 제3자 제공** — 약관 확인 (3-2 참조).
* SQL 을 먼저 넣고 앱을 배포한다 (`CLAUDE.md` 규칙).
