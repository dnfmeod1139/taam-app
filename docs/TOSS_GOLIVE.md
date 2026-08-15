# 토스페이먼츠 카드 결제 오픈 절차

## 운영 정책 (확정)

| 항목 | 결제 수단 |
|---|---|
| **예치금 충전** | **법인계좌 이체만.** 카드 안 씀 — 충전하기 → 계좌 안내 팝업 → 입금 확인 후 수동 반영 |
| **티켓 부족분** | **카드 결제.** 예치금이 모자랄 때만. 원화 · 달러 · 엔 |
| 정기결제(빌링) | 안 씀 |

**환불 = 결제된 금액 그대로 카드 원거래 취소.** 통화 불문.
$100 결제했으면 $100 취소, ¥15,000 결제했으면 ¥15,000 취소.
환율이 움직여 우리가 손해를 보더라도 차액 정산은 하지 않는다 — 설명이 어렵고 분쟁 소지가 크다.
부분 환불이 필요하면 카드가 아니라 예치금 반환으로 처리한다.

> 이 규칙 덕분에 FX 위험이 구조적으로 사라진다. 승인 금액과 취소 금액이 같은 통화·같은 숫자이므로
> 환율이 어디로 가든 회원과 우리 사이에 정산할 차액이 생기지 않는다.

> 아래 단계를 다 마치기 전에는 `CARD_PAY_LIVE` 를 절대 `true` 로 두지 않는다.

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

## 3. Edge Function 배포 (두 개)

```bash
supabase functions deploy toss-order   --project-ref edfsmzbcixfnqabrsvut
supabase functions deploy toss-confirm --project-ref edfsmzbcixfnqabrsvut
```

CLI 가 없으면 Dashboard → Edge Functions → Create function → 이름 입력
→ 파일 내용 붙여넣기 → Deploy. 두 개 다 해야 한다.

### toss-order — 결제 금액을 서버가 정한다

예전에는 결제 금액이 브라우저가 계산한 `window._pendingShortage` 였다.
DevTools 로 그 값을 바꾸면 **₩500,000 짜리 티켓을 ₩1,000 에 살 수 있었다.**
`payment_orders` 를 브라우저가 INSERT 하는 구조로는 막을 수 없다 — 회원이 금액을 정하기 때문이다.

```
POST toss-order { ticketId, pax, currency }
  ① ticket_products 조회 · 판매 상태 확인
  ② 이용 등급(min_tier) 검증        ← profiles.membership_tier + expires_at
  ③ 좌석 검증                        ← taam_ticket_sold_slots RPC (총 정원 · 인원석 슬롯)
  ④ total = (meal_fee + agency_fee + wine_min) × pax     ← 서버 계산
  ⑤ shortage = max(0, total - 예치금 잔액)                ← 서버 조회
  ⑥ payment_orders 생성 (service_role)
  → { orderId, amount }
```

브라우저는 이 `orderId` / `amount` 로만 결제창을 연다.
`payment_orders` 에 회원 INSERT 정책이 없으므로 다른 경로로는 주문을 만들 수 없다.

### toss-confirm 이 지키는 것

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
`true` 로 바꿔 **실결제 1건**을 끝까지 돌린다.

검증용 티켓을 하나 만들어 두면 좋다 — 식사비 ₩1,000 / 대행비 ₩0 / 주류 ₩0,
예치금 잔액 0 인 계정으로 1인 구매하면 부족분이 ₩1,000 이 된다.

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

- 성공 토스트 `충전 완료 · ₩1,000 예치금에 반영되었습니다` 확인 후 티켓 구매까지 완료되는지 확인
- **금액 위변조 시도** — 결제 전 콘솔에서 `window._pendingShortage = 1` 로 바꿔도
  실제 결제 금액이 서버가 계산한 금액 그대로인지 확인 (이게 toss-order 의 존재 이유다)
- **복귀 페이지를 새로고침**해서 두 번 적립되지 않는지 확인 (`이미 처리된 결제입니다` 가 떠야 정상)
- 토스 상점관리자에서 승인 건이 `DONE` 인지 확인
- 확인 후 토스 상점관리자에서 **결제 취소**로 ₩1,000 환불

전부 통과하면 `CARD_PAY_LIVE = true` 로 배포한다.
웹 배포라 앱 심사 재제출은 필요 없다.

---

## 미구현 (다음 단계)

- **해외 통화 결제 (USD / JPY)** — MID 는 개설됐지만 토스 승인 대기 중이라 키를 넣지 않았다.
  승인되면 아래만 하면 된다. **원장 구조는 바꾸지 않는다.**

  | 할 일 | 내용 |
  |---|---|
  | `TOSS_KEYS.USD` | MID `playtaamusd` 의 개별 연동 키(`live_ck_`) 입력 |
  | 주문 생성 | `currency:'USD'`, `amount` 는 달러 금액. `settle_krw` 는 화면 표시용으로만 넣는다 |
  | 적립 | `toss-confirm` 의 `convertToKrw()` 가 `app_config.fx_settings` 로 **서버에서 다시 계산**한다 |
  | JPY | `fx_settings` 에 통화별 기준율을 추가하고 `convertToKrw()` 에 분기 추가 (지금은 명시적으로 거부) |

  설계 요지 — 한 주문 안에 **"얼마를 승인했나(amount·currency)"** 와
  **"얼마를 적립했나(settle_krw)"** 를 각각 자기 통화로 고정한다.
  주문 시점의 적용환율을 `fx_rate` 에 얼려두므로, 이후 환율이 움직여도
  이 주문의 두 숫자는 변하지 않아 정산·환불이 어긋나지 않는다.

  ⚠ `settle_krw` 를 브라우저가 보낸 값 그대로 믿으면 **$1 결제하고 ₩10,000,000 적립**받는
  위변조가 가능하다. RLS 로는 막을 수 없으므로 반드시 Edge Function 이 다시 계산해야 한다.

  **환불 규칙 (정하고 시작할 것)** — 여기가 유일하게 FX 위험이 남는 자리다.
  - 전액 취소 → 카드 원거래 취소. $100 승인했으면 $100 그대로 환원되어 오차 0
  - 부분 환불 → 어느 환율로 되돌릴지 정해야 하므로 차액이 생긴다
  - **권장: 카드 원거래 취소는 전액만, 부분 환불은 예치금 반환으로.** FX 위험이 사라진다

  토스 해외 MID 는 "외화 승인 · 원화 정산" 이라 실제 입금 원화가 `settle_krw` 와 몇 원 다르다.
  그 차이를 흡수하라고 마진(`fx_settings.margin_pct`, 현재 3.5%)을 둔 것이다 — 정상 동작이다.
- **빌링(정기결제)** — `requestBillingAuth` 복귀 처리와 빌링키 저장 함수가 없다.
  MID4(`bill_`) 전용 키 발급도 필요하다.
- **취소·환불 API** — 현재 환불은 예치금 반환으로 처리한다. 카드 원거래 취소는 별도 함수가 필요하다.
- **미완료 주문 정리** — 결제창을 닫으면 `pending` 주문이 남는다. 무해하지만
  주기적으로 정리하려면 `created_at < now() - interval '1 day'` 조건으로 `canceled` 처리한다.
