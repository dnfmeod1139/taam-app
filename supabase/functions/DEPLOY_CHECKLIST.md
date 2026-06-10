# 계보 챗 두뇌 — 배포 체크리스트

이번 작업으로 만들어진 것 → 운영 적용까지 순서대로.

## ① DB 마이그레이션 (Supabase Studio)

`supabase/migrations/0003_chef_lineage_knowledge.sql` 전체를 SQL Editor 에 붙여넣고 RUN.

검증:
```sql
SELECT lineage_kind, count(*) FROM public.chef_lineage_knowledge GROUP BY lineage_kind;
-- 기대: sushi=12

SELECT column_name FROM information_schema.columns
WHERE table_name='restaurants' AND column_name LIKE 'chef_lineage%';
-- 기대: chef_lineage_text, chef_lineage_id, chef_lineage_synced_at
```

## ② Edge Function 배포

프로젝트 루트(`supabase` 폴더가 있는 곳)에서:

```bash
# Supabase CLI 로그인 + 링크 (한 번만)
supabase login
supabase link --project-ref edfsmzbcixfnqabrsvut

# 새 함수 배포
supabase functions deploy lineage-summarize --no-verify-jwt

# 환경 변수 설정 (Anthropic API 키)
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```

> `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` 는 자동 주입되므로 별도 설정 불필요.

## ③ taam-chat 패치 적용

`supabase/functions/TAAM_CHAT_LINEAGE_PATCH.md` 참고. 변경 3곳:

1. `import { buildLineageSystemSection, getRestaurantLineageLine } from "../_shared/lineage-context.ts";`
2. 사용자 쿼리 → 시스템 프롬프트 빌드 직전:
   ```ts
   const lineageSection = await buildLineageSystemSection(userQuery, sb);
   ```
   (시스템 프롬프트에 합치되 cache_control 영역 **밖**)
3. 매장 컨텍스트 직렬화 함수에:
   ```ts
   const lineageLine = getRestaurantLineageLine(rest);
   if (lineageLine) parts.push(`[쉐프 계보] ${lineageLine}`);
   ```
   `restaurants` 쿼리에 `chef_lineage_text, chef_lineage_id` 추가.

재배포:
```bash
supabase functions deploy taam-chat
```

## ④ 동작 테스트

### (a) 인앱 학습

1. 슈퍼어드민으로 로그인 → ☰ → AI 컨시어지 → 🧬 계보 챗 두뇌 동기화
2. "스시 쇼 계보" 클릭 → 자료 URL 1~2개 입력 + 큐레이터 노트 작성
3. **[🤖 AI 정리]** → 본문이 자동 채워짐 (10~30초)
4. 본문 검수 후 **[발행]**
5. 목록에서 ✅ 발행됨 뱃지 확인

### (b) 매장 롤업

상단 **[📡 매장 롤업 동기화]** → 발행된 계보의 chef → 매장 일괄 업데이트.

### (c) 챗 검증

탐 채팅에서 "스시 쇼 계보 알려줘" → 발행된 full_text 가 답변에 반영되는지 확인.

일반 질문 ("강남 한우 추천") → 응답 시간/품질 변동 없는지 확인.

## ⑤ 알려진 제한 / 향후 개선 후보

- **현재**: 라멘 계보는 시드/UI 미포함 (`스시부터` 정책). 추후 `0004` 마이그레이션 + UI 추가 예정.
- **현재**: chefs.parent_id (스승 ↔ 제자) 데이터는 SVG 좌표로만 존재. AI 정리 시 큐레이터 노트로 보완.
- **개선**: 매장별 한줄 (`chef_lineage_text`) 을 더 풍부하게 만들고 싶으면, `syncAllRestaurantLineages` 의 line 생성 로직을 chef 단위 LLM 호출로 교체 가능.

## 파일 트리 (이번 작업분)

```
supabase/
├── migrations/
│   └── 0003_chef_lineage_knowledge.sql        ← DB 스키마
├── functions/
│   ├── DEPLOY_CHECKLIST.md                    ← (이 파일)
│   ├── TAAM_CHAT_LINEAGE_PATCH.md             ← taam-chat 통합 가이드
│   ├── _shared/
│   │   ├── cors.ts                            ← 공통 CORS
│   │   └── lineage-context.ts                 ← 키워드 감지 + 프롬프트 빌더
│   └── lineage-summarize/
│       ├── index.ts                           ← 신규 Edge Function
│       └── README.md                          ← 개별 함수 가이드

index.html
├── (line 22~)        window.SUPABASE_URL/ANON_KEY 노출
├── (line 6492~)      어드민 메뉴 항목 추가
├── (line 7748~)      서브스크린 + 편집 모달 HTML
└── (line 41460~)     계보 동기화 JS (목록/편집/저장/AI/매장롤업)
```
