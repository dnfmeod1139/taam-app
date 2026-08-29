# iOS 1.02 출시 절차

> 2026-08-28 작성. `docs/APP_REVIEW_NOTES.md`(심사 문구)와 짝으로 쓴다.
> 이 문서는 **1.02 를 App Store 에 올려 출시하기까지** 무엇을 어떤 순서로 하는지만 적는다.

---

## ⚠ 2026-08-29 갱신 — 다시 빌드해야 한다

`capacitor.config.json` 에 `server.allowNavigation` 을 넣었다. 네이티브 설정이라
**새 빌드를 내야 반영된다.** ipa #35 는 이 수정이 없다.

왜 넣었나 — Capacitor 는 웹뷰가 외부 도메인으로 가면 시스템 브라우저로 내보낸다.
그래서 토스 결제창이 Chrome 에서 열렸고, 결제·취소 후 돌아오는 리다이렉트도
Chrome 으로 떨어졌다. Chrome 에는 다른 계정이 로그인돼 있어 회원 눈에는
「결제했는데 티켓이 없다」 가 된다. (승인 자체는 `toss-confirm` 이 주문 주인과
호출자 JWT 를 대조해 막으므로 남의 결제가 붙지는 않는다.)

**빌드번호가 바뀐다.** 아래 문서와 `sql/app_version_force_update.sql` 의 `35` 는
옛 값이다. Codemagic 빌드 로그의 `agvtool what-version` 출력(= ipa 번호)을 보고
그 숫자를 쓴다. Codemagic 빌드 이름보다 항상 1 크다.

> `capacitor.config.json` 은 iOS 워크플로의 `when.changeset` 에 들어 있어
> **main 에 머지되면 iOS 빌드가 자동으로 돈다.** 안드로이드는 자동 트리거가 없어
> Codemagic 에서 손으로 돌린다 (`TAAM Android Play Build`).

---

## (참고) 종전 상태

**ipa #35 (2026-08-27, 커밋 `f64ee77`)** 까지는 네이티브 변경이 없어 재빌드가
필요 없었다. 그 뒤 변경은 안드로이드 전용 한 건이었다
(`286b604` — 상태바 알림 아이콘. codemagic.yaml 의 android 워크플로에만 들어갔다).

오늘 하루 `index.html` 을 열몇 번 고쳤지만 **그건 새 빌드가 필요 없다.**
`capacitor.config.json` 의 `server.url` 이 `https://taam-app.vercel.app` 이라,
설치된 앱은 웹 배포를 그대로 불러온다. 화면·로직 수정은 웹만 올리면 전 기기에 즉시 닿는다.

> 다시 빌드해야 하는 때는 이런 것들이다 —
> `package.json` · `capacitor.config.json` · `assets/**` · `codemagic.yaml` 의 iOS 워크플로 ·
> 플러그인 추가 · 권한(Info.plist·entitlements) 변경.
> iOS 워크플로의 `when.changeset` 이 정확히 그 목록으로 걸려 있다.

**빌드가 필요해지면**: Codemagic → taam-app → Start new build →
Branch `main` · Workflow **`TAAM iOS TestFlight Build`**.
`MARKETING_VERSION` 은 이미 `1.02` 이고, 빌드번호는 `BUILD_NUMBER + 1` 로 자동으로 올라간다.

---

## 1.02 에 들어간 것 (1.01 대비, 네이티브만)

| | 무엇 |
|---|---|
| **배지 자동 초기화** | `UIBackgroundModes: remote-notification` + AppDelegate. 알림 없이 숫자만 바꾸는 푸시(content-available)를 받을 수 있게 됐다. 1.01 은 이걸 못 받아 배지가 남았다 |
| **APNs 콜백** | AppDelegate 에 토큰 수신 콜백 주입. 1.01 초기 빌드에서 토큰이 JS 까지 오지 못하던 문제 |
| **빌드 표식** | User-Agent 에 `TAAM/1.02(35)` 를 새긴다. 앱이 자기 빌드번호를 알게 되어 업데이트 안내가 정확해진다 |

화면·기능 개선은 전부 웹으로 이미 나가 있다. 스토어 업데이트는 위 세 가지를 위한 것이다.

---

## 제출 순서

### ① 심사 전 준비 (제출 버튼 누르기 전에)

- [ ] **데모 계정에 `single_device_exempt` 를 켠다**
      슈퍼어드민 → 회원 관리에서 토글. Apple 은 iPad·iPhone **두 기기로 심사**하므로,
      단일 기기 규칙에 묶이면 리뷰어에게 "로그인이 자꾸 풀리는 앱" 이 되어 2.1 리젝이 난다.
      ⚠ 심사용 계정에 `super_admin` 을 주면 안 된다 — 면제만 필요한데 어드민이 통째로 열린다.
- [ ] **데모 계정에 예치금을 넉넉히 넣는다** — 결제 흐름을 끝까지 볼 수 있어야 리젝 확률이 낮다
- [ ] **미사용 초대 코드 1개** 준비 (가입 흐름 확인용)
- [ ] `docs/APP_REVIEW_NOTES.md` 의 빈칸(전화/이메일·비밀번호·초대코드)을 채워
      App Store Connect → App Review Information → Notes 에 붙여넣는다

### ② 심사 중에 하지 말 것

`server.url` 이 웹이라 **웹 배포가 곧 심사자 화면**이다.

- [ ] 심사 기간에 **기능 플래그를 올리지 않는다** — 켜는 순간 심사자에게도 보인다
      (`NEW_HOME_LIVE` · `CARD_PAY_LIVE` 등)
- [ ] 큰 화면 개편을 `main` 에 머지하지 않는다. 급한 버그 수정만

### ③ App Store Connect

- [ ] 1.02 버전 페이지에서 빌드 **#35** 를 선택
- [ ] "이번 버전의 새로운 기능" 에 아래 문구를 넣는다
- [ ] 심사 제출

### ④ 출시된 뒤에 (스토어에 실제로 보인 다음)

- [ ] **강제 업데이트를 건다** — `sql/app_version_force_update.sql` 의 ② 블록.
      숫자 `35` 하나만 확인하고 실행하면 된다.

> **정책 (2026-08-28 결정): 새 빌드를 내면 그 빌드로 강제한다.** 두 스토어 모두.
> 화면은 웹이라 최신이어도 네이티브 껍데기(푸시·플러그인·권한)는 스토어
> 업데이트를 받아야만 바뀌고, 그 차이를 회원은 스스로 알 방법이 없다.
> "화면은 최신인데 알림만 안 오는" 회원을 만들지 않는 쪽을 택했다.
>
> ⚠ **심사 통과 ≠ 출시다.** App Store 에서 직접 보이는 것을 확인하고 돌린다.
> 출시 전에 걸면 회원은 앱이 잠긴 채 스토어엔 옛 버전밖에 없다.
> 잘못 걸었으면 같은 파일 ⑤ 블록으로 즉시 푼다.

- [ ] **데모 계정의 `single_device_exempt` 를 되돌린다.** 켜둔 채로 두면 계정 공유가 가능해진다

확인: `select value from public.app_config where key = 'app_version';`

---

## 「이번 버전의 새로운 기능」 문구

**한국어**
```
· 알림을 확인하면 앱 아이콘의 빨간 배지가 자동으로 사라집니다.
· 푸시 알림 수신이 더 안정적으로 동작합니다.
· 안정성 개선 및 세부 오류 수정.
```

**English**
```
· The red badge on the app icon now clears automatically once you have read your notifications.
· Push notification delivery is more reliable.
· Stability improvements and minor bug fixes.
```

**日本語**
```
· 通知を確認すると、アプリアイコンの赤いバッジが自動で消えるようになりました。
· プッシュ通知の受信がより安定しました。
· 安定性の向上と細かな不具合の修正。
```

---

## 막혔을 때

| 증상 | 원인 |
|---|---|
| `Invalid Pre-Release Train` / `must contain a higher version than [1.0]` | `MARKETING_VERSION` 이 이미 출시된 값과 같다. codemagic.yaml 에서 올린다 (`1.02` → `1.03`). ⚠ 애플은 `1.01` 을 `1.1` 로 읽으므로 이 앱은 앞으로 `1.1` 을 쓸 수 없다 — `1.03`, `1.04` 로 이어간다 |
| 같은 빌드번호 재업로드 거부 | 빌드번호는 `BUILD_NUMBER + 1` 로 자동 증가한다. Codemagic 빌드 이름(#34)과 ipa 에 박히는 값(#35)이 하나 어긋나니, **넣어야 할 값은 항상 ipa 쪽**이다 |
| 설치는 되는데 푸시 토큰이 안 옴 | 프로비저닝 프로파일이 푸시 권한을 허용하지 않아 서명에서 조용히 빠진 것. iOS 워크플로의 「서명된 앱의 푸시 권한 확인(aps-environment)」 단계 로그를 본다 |
