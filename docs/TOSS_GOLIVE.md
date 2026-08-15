# 토스페이먼츠 카드 결제 오픈 절차

> 1차 범위: **예치금 카드 충전**. 티켓 부족분 카드 결제·정기결제(빌링)는 이후 단계.
> 이 문서의 5단계를 다 마치기 전에는 `CARD_PAY_LIVE` 를 절대 `true` 로 두지 않는다.

## 왜 이 순서인가

토스 V2 결제는 2단계다.

```
① 결제창 인증 (브라우저 · 클라이언트 키)  →  paymentKey 발급
② 서버 승인 confirm (시크릿 키)          →  실제 매입
```

②가 없는 상태로 결제창만 열면 회원이 카드 인증을 마쳐도 승인이 일어나지 않고
미승인 건으로 자동 취소된다. 회원에게는 "결제했는데 아무것도 안 됨"이 되고
카드사에는 승인 흔적이 남는다. 그래서 ②가 검증되기 전까지는 카드 경로를 막는다.

---

## 1. SQL 실행

Supabase SQL Editor 에서 `sql/toss_payment_orders.sql` 전체를 실행한다.

`payment_orders` 테이블이 생긴다. 결제창을 열기 **전에** 주문번호·회원·기대금액을
여기 박아두고, 승인할 때 이 행의 `amount` 와 대조한다.
브라우저가 보낸 금액을 믿으면 ₩1,000 결제하고 ₩1,000,000 적립받는 위변조가 가능하다.

RLS 상 회원은 **자기 주문을 pending 으로 만들고 조회**만 할 수 있다.
`paid` 로 바꾸는 것과 예치금 적립은 service_role 을 쓰는 Edge Function 만 한다.

## 2. 시크릿 키 등록

```
Supabase Dashboard → Project Settings → Edge Functions → Secrets → Add new secret
  이름: TOSS_SECRET_KEY
  값  : live_sk_...
```

⚠ 시크릿 키는 코드·커밋·채팅 어디에도 넣지 않는다. 여기에만 있어야 한다.

## 3. Edge Function 배포

`supabase/functions/toss-confirm/index.ts`

CLI:
```bash
supabase functions deploy toss-confirm --project-ref edfsmzbcixfnqabrsvut
```

CLI 가 없으면 Dashboard → Edge Functions → Create function → 이름 `toss-confirm`
→ 파일 내용 붙여넣기 → Deploy.

이 함수가 지키는 것:

| 항목 | 방법 |
|---|---|
| 금액 위변조 차단 | 브라우저 금액이 아니라 `payment_orders.amount` 로 승인·적립 |
| 소유권 확인 | 주문의 `user_id` 와 호출자 JWT 의 uid 대조 |
| 멱등성 | `status='paid'` 면 재적립 안 함 + `payment_key` 유니크 인덱스 + `Idempotency-Key` |
| 동시 요청 | `.eq('status','pending')` 조건부 UPDATE 로 한쪽만 적립 |
| 부분 실패 | 승인 성공·적립 실패 시 잔액 롤백 후 `fail_reason` 기록 |

적립은 기존 구조를 그대로 쓴다 — `profiles.general_deposit_balance` 를 더하고
`deposit_transactions` 에 `change_type='charge'` 한 줄 넣으면
`trg_sync_split_balance` 트리거가 `charged_general_balance` 를 맞춘다.

## 4. 클라이언트 키 교체

`index.html` 의 `TOSS_CLIENT_KEY` 를 실키로 교체한다.

```js
var TOSS_CLIENT_KEY = 'live_ck_...';
```

⚠ **`live_ck_` 여야 한다.** `live_gck_` 는 결제위젯 전용 키다.
현재 코드는 개별연동 결제창(`.payment()` → `requestPayment()`)을 쓰므로
`gck` 키를 넣으면 결제창이 열리지 않는다.

클라이언트 키는 브라우저에 노출되는 게 정상이라 `index.html` 에 두어도 된다.

## 5. 실결제 검증 후 플래그 해제

`CARD_PAY_LIVE = false` 인 상태로 배포한 뒤, 슈퍼어드민 계정에서 한 번만 임시로
`true` 로 바꿔 **₩1,000 실결제 1건**을 끝까지 돌린다.

확인할 것:

```sql
-- 주문이 paid 로 바뀌었는가
select order_id, status, amount, payment_key, approved_at, fail_reason
from public.payment_orders order by created_at desc limit 5;

-- 거래기록이 1건만 들어갔는가 (2건이면 멱등성 실패)
select id, change_type, amount, balance_after, description, metadata->>'order_id'
from public.deposit_transactions
where change_type = 'charge' order by created_at desc limit 5;

-- 잔액 합계가 맞는가
select general_deposit_balance, charged_general_balance, granted_general_balance
from public.profiles where id = auth.uid();
```

- 성공 토스트 `충전 완료 · ₩1,000 예치금에 반영되었습니다` 확인
- **복귀 페이지를 새로고침**해서 두 번 적립되지 않는지 확인 (`이미 처리된 결제입니다` 가 떠야 정상)
- 토스 상점관리자에서 승인 건이 `DONE` 인지 확인
- 확인 후 토스 상점관리자에서 **결제 취소**로 ₩1,000 환불

전부 통과하면 `CARD_PAY_LIVE = true` 로 배포한다.
웹 배포라 앱 심사 재제출은 필요 없다.

---

## 미구현 (다음 단계)

- **티켓 부족분 카드 결제** — 티켓 가격을 서버에서 재계산해야 안전하다.
  지금은 "카드로 충전 → 예치금으로 구매" 로 같은 결과에 도달하며 기존 티켓 로직을 건드리지 않는다.
- **빌링(정기결제)** — `requestBillingAuth` 복귀 처리와 빌링키 저장 함수가 없다.
  MID4(`bill_`) 전용 키 발급도 필요하다.
- **취소·환불 API** — 현재 환불은 예치금 반환으로 처리한다. 카드 원거래 취소는 별도 함수가 필요하다.
- **미완료 주문 정리** — 결제창을 닫으면 `pending` 주문이 남는다. 무해하지만
  주기적으로 정리하려면 `created_at < now() - interval '1 day'` 조건으로 `canceled` 처리한다.
