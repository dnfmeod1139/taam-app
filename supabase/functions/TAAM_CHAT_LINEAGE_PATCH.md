# taam-chat 계보 컨텍스트 통합 가이드

`lineage-summarize` 가 만든 **발행된 계보 지식** 을 `taam-chat` 의 답변 컨텍스트에 자동 주입하는 패치.

작은 변경 3곳:
1. import 한 줄 추가
2. 사용자 쿼리 처리 직후 계보 시스템 절(節) 빌드
3. 매장별 답변 시 `restaurants.chef_lineage_text` 결합

## 변경 위치 요약

### 1) import 추가 (파일 상단)

```ts
// ↓ 추가
import {
  buildLineageSystemSection,
  getRestaurantLineageLine,
} from "../_shared/lineage-context.ts";
```

### 2) 사용자 쿼리 → 시스템 프롬프트 빌드 직전

기존 코드에서 `userQuery` (또는 `messages[last].content` 등 사용자 입력 변수)
를 가져온 직후, 시스템 프롬프트를 만들기 직전에 **한 줄** 추가:

```ts
// 사용자 쿼리에서 계보 키워드 감지 → 발행된 계보 지식 자동 주입
// (감지 안 되면 빈 문자열 반환 → 시스템 프롬프트에 영향 없음)
const lineageSection = await buildLineageSystemSection(userQuery, sbAdminClient);
```

> `sbAdminClient` 는 기존에 사용 중인 Supabase 클라이언트.
> Service Role 또는 anon 어느 쪽이든 OK (v_published_chef_lineages 뷰는 RLS 통과).

그리고 시스템 프롬프트 합성 시 합쳐주기:

```ts
const systemPrompt = [
  ORIGINAL_SYSTEM_PROMPT,           // 기존 시스템 프롬프트
  lineageSection,                    // ← 빈 문자열이면 무시됨
].filter(Boolean).join("\n\n");
```

> ⚠ **프롬프트 캐시 사용 시 주의**: `lineageSection` 은 쿼리마다 달라지므로
> `cache_control` 영역 **밖** 에 배치하세요. (캐시 hit 률을 깨지 않도록)
> 추천 구성:
>
> ```ts
> system: [
>   { type: "text", text: ORIGINAL_SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
>   { type: "text", text: lineageSection },   // ← 캐시 X
> ].filter(b => b.text)
> ```

### 3) 매장 컨텍스트에 chef_lineage_text 결합

매장 정보를 LLM 컨텍스트에 직렬화하는 부분 (예: `restaurantToContextText(rest)`)
에서 한 줄 추가:

```ts
function restaurantToContextText(rest: Restaurant): string {
  // ... 기존 필드 직렬화 ...
  const lineageLine = getRestaurantLineageLine(rest);
  if (lineageLine) parts.push(`[쉐프 계보] ${lineageLine}`);
  // ...
}
```

`restaurants` 쿼리에 `chef_lineage_text` 컬럼이 SELECT 되도록 확인:

```ts
.select("id, name, name_ko, ..., concierge_note, chef_lineage_text, chef_lineage_id, ...")
```

## 동작 시나리오

### 케이스 A — 일반 질문 ("강남 데이트 파인다이닝 추천해줘")

- `detectLineageIntent` 미매칭 → `buildLineageSystemSection` 빈 문자열 반환 → 시스템 프롬프트 변동 없음
- **토큰 비용 0**, 기존 동작 그대로

### 케이스 B — 트리 특정 질문 ("카네사카 출신 쉐프 어디?")

- "카네사카" 키워드 매칭 → `kanesaka` lineage_id 만 fetch
- `kanesaka` 의 `full_text` (1500~3000 자) 만 시스템 프롬프트에 추가
- LLM 이 정확한 계보 지식으로 답변

### 케이스 C — 일반 계보 질문 ("스시 계보 알려줘")

- "계보" 키워드 매칭 + 일반어 → `injectAll = true`
- 발행된 모든 계보 (예: 12개 × 2k = 24k 토큰) 시스템 프롬프트에 주입
- 답변 후 회수 → 캐시 영향 최소화

### 케이스 D — 매장 단위 답변 ("스시 사이토 어떤 곳?")

- 매장 검색 → 'restaurants' row 가져옴 → `chef_lineage_text` 가 있으면 컨텍스트에 자동 결합
- "사이토 계보 (사이토 타카시 본가, 도쿄 록폰기)" 같은 한줄이 답변 근거로 사용됨

## 토큰 영향

| 시나리오 | 추가 토큰 | 비고 |
|---|---|---|
| 일반 질문 (계보 키워드 X) | 0 | 무영향 |
| 특정 트리 질문 | ~3,000 (1개) | 캐시 X — 매번 |
| 일반 계보 질문 | ~25,000 (12개 합) | 사용 빈도 낮음 |
| 매장 답변 | +50 ~ +200 | restaurant row 자체 |

`v_published_chef_lineages` 뷰가 발행된 행만 반환하므로,
초기에는 학습 안 된 계보가 자동 제외됨 → 점진적 토큰 증가.

## 테스트 시나리오 (배포 후)

1. 슈퍼어드민에서 1개 계보 (예: 스시 쇼) 학습 + 발행
2. 챗에서 "스시 쇼 계보 알려줘" 입력
3. 답변에 `chef_lineage_knowledge.full_text` 내용이 반영되는지 확인
4. 일반 질문 ("강남 한우 추천") 후 응답 시간이 늘어나지 않는지 확인 (계보 미주입 검증)

## 배포 명령

```bash
# lineage-summarize (신규)
supabase functions deploy lineage-summarize --no-verify-jwt

# taam-chat (위 패치 적용 후 재배포)
supabase functions deploy taam-chat
```

## 환경 변수 설정 (lineage-summarize 만 필요)

```bash
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
# SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY 는 자동 주입됨
```
