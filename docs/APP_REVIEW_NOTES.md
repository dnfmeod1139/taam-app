# TAAM — 앱스토어 심사 제출 노트

> App Store Connect "App Review Information → Notes" / Google Play "테스트 안내"에 붙여넣는 문구.
> 핵심 목적: ① 초대제라 심사자가 못 들어가는 문제 해결 ② **외부 결제가 규정상 정당함**을 명확히 설명(인앱결제 리젝 방지) ③ 계정 삭제 경로 안내.

---

## ⚠️ 제출 전 반드시 채울 것

| 항목 | 값 |
|---|---|
| 데모 계정 (전화/이메일) | `__________` |
| 데모 계정 비밀번호 | `__________` |
| 초대 코드 (미사용 1개) | `__________` |
| 인증번호 수신 방법 | 문자 수신 불가 시 → 고정 OTP 또는 담당자 연락처 기재 |
| 담당자 이메일 | dnfmeod@playtaam.com |

> 데모 계정은 **심사 기간 내내 유효**해야 하며, 예치금 잔액을 넉넉히 넣어두면 결제 흐름 확인이 쉬워 리젝 확률이 낮아집니다.

---

## 1) App Store Connect — Review Notes (English)

```
[About TAAM]
TAAM is an invitation-only membership concierge service for premium dining in
Korea and Japan. Members browse restaurants and chef lineage content, and
request/purchase reservation tickets for real restaurants. All bookings are
fulfilled in the physical world at partner restaurants.

[Demo Account — required because the app is invitation-only]
Phone / Email : ____________________
Password      : ____________________
Invite code   : ____________________  (unused, for the sign-up flow)
Note: Sign-up requires an invitation code. Please use the account above to log
in directly, or the invite code to test the full registration flow.
If SMS verification cannot be received during review, please contact
dnfmeod@playtaam.com and we will assist immediately.

[Payments — why In-App Purchase is not used]
All payments in this app are for PHYSICAL, REAL-WORLD SERVICES consumed
outside of the app:
 • Reservation tickets = an actual meal at a physical restaurant, on a set date
   and time, paid for the dining service and our offline reservation-agency work.
 • Membership fee = fee for our offline concierge/reservation-agency service
   (staff securing hard-to-book restaurant seats on the member's behalf),
   plus a prepaid balance (deposit) usable for those real-world reservations.
 • The membership does NOT unlock any digital content or app features.
   All in-app content (restaurant information, chef lineage, magazine) is
   available to every signed-in member regardless of plan.
Per App Store Review Guideline 3.1.5(a) (Goods and Services Outside of the App),
these transactions must use payment methods other than In-App Purchase.
We use Toss Payments (a licensed Korean PG) for card payments and bank
transfer for deposit top-ups.

[Account Deletion — Guideline 5.1.1(v)]
In-app account deletion is available at:
  My Page → Settings (⚙️) → Delete Account
The flow shows remaining balance / upcoming reservations, requires typing a
confirmation phrase, then permanently deactivates the account and masks
personal data. Transaction records are retained only as required by Korean
e-commerce law.

[Age Rating]
The service is for adults aged 19+ (Korean legal drinking age) because
reservations may include alcohol pairing/minimum beverage orders. Users must
confirm they are 19+ during sign-up.

[Contact]
dnfmeod@playtaam.com
```

---

## 2) Google Play — 테스트 안내 (한국어/영문 병기)

```
[서비스 개요]
TAAM은 한국·일본 프리미엄 다이닝을 위한 초대제 멤버십 컨시어지 서비스입니다.
회원은 레스토랑 정보와 셰프 계보 콘텐츠를 열람하고, 실제 레스토랑의 예약
티켓을 구매합니다. 모든 예약은 오프라인 제휴 레스토랑에서 이행됩니다.

[테스트 계정 — 초대제 앱이므로 필수]
로그인 정보 : ____________________
비밀번호    : ____________________
초대 코드   : ____________________ (회원가입 흐름 테스트용, 미사용 코드)

[결제 구조]
앱 내 모든 결제는 앱 외부에서 소비되는 실물 서비스에 대한 것입니다.
 · 예약 티켓 = 실제 레스토랑에서의 식사(날짜·시간 지정) 및 예약 대행 용역
 · 멤버십 = 오프라인 예약 대행·컨시어지 용역 이용료 + 선결제 예치금
 · 멤버십은 앱 내 디지털 콘텐츠나 기능을 잠금 해제하지 않습니다.
   레스토랑 정보·계보 콘텐츠는 모든 로그인 회원에게 동일하게 공개됩니다.
결제는 토스페이먼츠(국내 등록 PG) 카드 결제 및 계좌이체로 처리됩니다.

[계정 삭제]
마이페이지 → 설정 → 계정 삭제 에서 앱 내 삭제가 가능합니다.
웹 요청 경로: https://taam-app.vercel.app/legal/account_deletion.html

[연령 등급]
주류 페어링·최소 주류 주문이 포함될 수 있어 만 19세 이상 대상입니다.

[문의] dnfmeod@playtaam.com
```

---

## 3) 리젝 리스크 & 사전 점검

| # | 리스크 | 대응 | 상태 |
|---|---|---|---|
| 1 | 초대제라 심사자가 진입 불가 → **가장 흔한 리젝** | 데모 계정 + 초대코드 노트 기재 | ⚠️ 값 채우기 |
| 2 | 멤버십을 "디지털 구독"으로 판정 → IAP 요구 | 위 결제 문구로 오프라인 용역임을 명시 | ✅ 문구 준비 |
| 3 | 인앱 계정 삭제 없음 (5.1.1(v)) | 마이페이지 → 설정 → 계정 삭제 구현 | ✅ 완료 |
| 4 | SMS 인증을 심사자가 못 받음 | 노트에 담당자 연락처 + 즉시 대응 명시 | ⚠️ 확인 |
| 5 | 개인정보 라벨 / 데이터 안전 양식 미작성 | 수집 항목(이름·연락처·결제·기기ID) 신고 | ⚠️ 작성 필요 |
| 6 | 연령 등급 미설정 | 17+/19+ 로 설정 | ⚠️ 설정 필요 |

### 콘텐츠 등급 게이팅 관련 (중요)
티켓 등급 제한(M/T/A)은 **실제 레스토랑 예약(현실 서비스)의 응대 범위 차등**입니다.
**앱 내 디지털 콘텐츠(계보도·매거진·레스토랑 정보)는 등급과 무관하게 전원 공개**로 유지해야
"디지털 구독" 판정 리스크를 피할 수 있습니다. 현재 구현은 티켓에만 적용되어 이 원칙을 지키고 있습니다.

---

## 4) 제출 순서

1. 토스페이먼츠 가맹 심사 완료 → 실결제 동작 확인
2. 위 표의 데모 계정·초대코드 채우기 → 심사 노트 복사
3. 연령 등급 설정 + 개인정보 라벨/데이터 안전 양식 작성
4. iOS: Codemagic 빌드 → TestFlight 확인 → 심사 제출
5. Android: AAB 업로드 → 내부 테스트 → 프로덕션 심사 제출
6. (병행) 통신판매업 신고 — 토스 구매안전 이용확인증 발급 후 정부24
