# TAAM 좌석 엔진 v3 — 최종 통합 설계 (코딩 직전 단계)

> 작성: 2026-07-16 · "좌석 배치·판매 시스템 명세서"(우종) + 기존 자유 구성 구현(PR #76) 통합.
> **상태: 설계 확정 + 알고리즘 검증 완료 (25/25, 무작위 5,000회 불변식 통과). 승인 시 코딩 착수.**

---

## 1. 두 설계에서 뽑은 것

| 출처 | 채택한 것 | 이유 |
|---|---|---|
| 명세서 | **조각 사전 차단** (팔면 못 채우는 잔여석이 생기는 구매를 선택 단계에서 막음) | 1인 한도를 지키면서 공석 0 — 사후 수습(lastSingle)보다 우월 |
| 명세서 | blockReason (막힌 이유 안내), strict/loose 모드, 관리자 오버라이드, 취소 시 토큰 복원 | 운영 유연성 + UX |
| 기존 구현 | **허용 인원 칩 1~10** (짝수 전용 등 임의 조합) | 명세서엔 없는 기능 — 그대로 유지 |
| 기존 구현 | 서버 트리거 강제 + RPC + 취소 자동복원(비취소 rows 카운트) | 명세서 §9 요구를 이미 충족하는 구조 |
| 🆕 통합 산물 | **DP(동적계획법) 채움 검사 `fillable()`** | 명세서의 "잔여 1석" 규칙은 1~8 연속 허용일 때만 충분. 칩 조합({2,4,6,8}, {3,5} 등)까지 일반화하려면 "잔여석이 허용 인원 조합으로 채워지는가"를 DP 로 검사해야 함 |
| 폐기 | 기존 lastSingle(잔여 1석 1인 예외) | 1인이 2팀이 되는 규칙 위반 — strict 모드가 완전 대체 |

## 2. 최종 파라미터 (티켓별, slots jsonb)

```json
{ "mode": "flex",
  "allowed": [1,2,3,4,5,6,7,8],   // 허용 인원 칩
  "solo": 1,                       // 1인 허용 팀 수 (allowed 에 1 있을 때)
  "strict": true }                 // true=조각 사전 차단(기본) / false=완화
```
- 기존 고정 구성(s1/s2/s4)은 변경 없음. 기존 flex 티켓의 `lastSingle` 은 `strict:true` 로 해석 (마이그레이션 규칙).

## 3. 핵심 알고리즘 (검증 완료)

```javascript
// rem 석을 허용 인원 조합으로 채울 수 있는가 (1인은 soloRem 팀까지, 2+ 무제한)
function fillable(rem, allowed, soloRem){
  if(rem === 0) return true;
  if(rem < 0) return false;
  var groups = allowed.filter(function(n){ return n >= 2; });
  var maxSolo = (allowed.indexOf(1) >= 0) ? Math.max(0, soloRem) : 0;
  var dp = new Array(rem + 1).fill(false); dp[0] = true;
  for(var r = 1; r <= rem; r++)
    for(var i = 0; i < groups.length; i++){
      var g = groups[i];
      if(g <= r && dp[r - g]){ dp[r] = true; break; }
    }
  for(var s = 0; s <= Math.min(maxSolo, rem); s++) if(dp[rem - s]) return true;
  return false;
}

// 현재 상태에서 판매 가능한 인원 목록 (UI 활성화 + 서버 재검증 공용)
function availableSizes(R, soloRem, cfg){
  var out = [];
  for(var i = 0; i < cfg.allowed.length; i++){
    var g = cfg.allowed[i];
    if(g > R) continue;
    if(g === 1 && soloRem < 1) continue;
    if(cfg.strict){
      var nextSolo = (g === 1) ? soloRem - 1 : soloRem;
      if(!fillable(R - g, cfg.allowed, nextSolo)) continue;
    }
    out.push(g);
  }
  return out;
}
```
- `soloRem = cfg.solo - (party_size=1 비취소 구매 건수)` — 취소 시 자동 복원 (별도 토큰 관리 불필요).
- blockReason: 허용 안 됨 / 1인 마감 / 좌석 부족(잔여 N) / "이 인원으로 예약하면 남는 좌석을 채울 수 없어 불가".

## 4. 검증 결과 (seat_engine_sim.js — 25/25 PASS)

- **케이스 A (명세서)**: C=10·solo1 — 3,2,1,3(차단→2로 유도),2 → **공석 0, 1인 정확히 1팀** ✅
- **케이스 B**: C=9 홀수 — 2×4 후 잔여1 + 토큰有 → 1인으로 완판 ✅
- **케이스 C/D**: 토큰 소진/solo=0 시 1인 원천 불가 ✅
- **짝수 전용** {2,4,6,8,10}: 홀수 선택지 아예 없음, 4+6 완판 ✅
- **DP 필요 케이스** {3,5}·C=10: 3인 판매 시 잔여 7을 못 채움을 감지해 차단 (명세서 규칙만으론 불가) ✅
- **완판 불가 구성 감지**: {4}·C=10, 홀수C+solo0+짝수칩 → 업로드 시점 경고 대상 ✅
- **무작위 5,000회** (구성·판매순서 랜덤): 마감 시 **공석 0 위반 0건 · 1인 한도 위반 0건** ✅
- 취소 복원 / loose 모드 동작 ✅

## 5. 구현 작업 목록 (승인 시 착수)

| # | 파일/위치 | 작업 |
|---|---|---|
| 1 | index.html (전역 JS) | `fillable` / `availableSizes` / `blockReason` 추가 (`_tse` 접두) |
| 2 | 업로드 폼 (tuFlexPanel) | lastSingle 체크박스 → **판매 모드 선택**: `엄격(조각 방지·권장)` / `완화(조각 허용)` + **완판 가능성 실시간 검사** — `fillable(total, allowed, solo)` false 면 경고 배너 (예: "이 구성은 완판이 불가능합니다 — 1인 팀 수를 1 이상으로") |
| 3 | tuSubmit | slots 저장을 `{mode,allowed,solo,strict}` 로 (lastSingle 제거), 완판 불가 구성 업로드 시 확인 팝업 |
| 4 | 티켓 상세 열기 | 동적 선택지를 `availableSizes(remain, soloRem, cfg)` 로 교체 (현행 단순 필터 대체) — RPC `taam_ticket_sold_slots` 재사용 |
| 5 | 인원 스테퍼 | `_tdAllowedPax` = availableSizes 결과 (기존 칩 스테퍼 메커니즘 재사용). 선택 불가 인원 시도 시 blockReason 토스트 |
| 6 | completePurchase | 사전 검증을 availableSizes 재계산으로 교체 + blockReason 메시지 |
| 7 | sql/ticket_capacity_guard.sql v3 | 트리거에 strict 분기: plpgsql 로 동일 DP (boolean 배열 루프, C≤20) — INSERT 후 잔여가 fillable 아니면 거부. loose 는 allowed+solo+총정원만 |
| 8 | 편집 복원 | strict/모드 복원 + 기존 lastSingle→strict 해석 |
| 9 | (2차, 선택) | 인원 선택 UI 를 버튼 그리드 + 비활성 사유 표시로 업그레이드 (명세서 §10) — 1차는 스테퍼 유지 |

- **관리자 오버라이드**: 예약 초대 발송(INV- 구매)은 트리거 미적용 → 이미 존재. "3명 손님 놓치기 아까울 때 초대 발송으로 수동 판매" 로 운영 (감사 로그 = reservation_invites 기록).
- **하위 호환**: 고정 구성 티켓·구버전 티켓 로직 무변경. RPC 미설치 환경 폴백 유지.

## 6. 리스크/주의

- 명세서 §6-D: 홀수 좌석 + solo=0 은 물리적으로 완판 불가 → **#2 의 업로드 시점 검사로 사전 경고** (이번 설계에서 해결).
- strict 는 "조각 남기는 손님"을 거절함 — 운영상 아까우면 티켓별로 loose 선택 또는 초대 발송 오버라이드.
- SQL 트리거 v3 재실행 필요 (idempotent).
