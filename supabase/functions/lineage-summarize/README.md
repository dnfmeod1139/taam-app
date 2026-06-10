# lineage-summarize

쉐프 계보 학습 자동화 Edge Function. 슈퍼어드민이 [🤖 AI 정리] 클릭 시 호출됨.

## 동작

```
인앱 [🤖 AI 정리]
  → POST /functions/v1/lineage-summarize
    { lineage_id, lineage_name_ko, reference_urls[], curator_notes }
  → 1) chefs 테이블에서 lineage 노드 조회
    2) reference_urls 서버 측 fetch (timeout 12s, 800KB 제한)
    3) HTML → 텍스트 추출
    4) Claude 4.5 Sonnet 으로 종합 정리 (한국어, JSON 응답)
    5) chef_lineage_knowledge.ai_model/ai_generated_at/ai_token_usage/chef_count 자동 갱신
  → 응답
    { full_text, summary, model, token_usage, fetched_urls, failed_urls, chef_count }
```

## 환경 변수

`supabase secrets set` 으로 설정:

| 변수 | 값 | 비고 |
|---|---|---|
| `ANTHROPIC_API_KEY` | `sk-ant-...` | 필수 |
| `SUPABASE_URL` | (자동 주입) | — |
| `SUPABASE_SERVICE_ROLE_KEY` | (자동 주입) | chefs 테이블 read 용 |

## 배포

```bash
supabase functions deploy lineage-summarize --no-verify-jwt
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```

> `--no-verify-jwt` 옵션은 인앱에서 anon key 로 호출하기 위함.
> 슈퍼어드민 검증은 클라이언트에서 이미 수행 (`_isSuperAdmin()`).
> 추가 보안이 필요하면 함수 안에서 service role 토큰 검증 또는 IP 제한 추가.

## 안전장치

- URL 최대 8개 fetch
- 개별 URL 12s 타임아웃
- 800KB 단일 URL 캡 + URL 1개당 텍스트 12,000 자 트림
- Claude 출력 4,096 토큰 제한
- HTML 스크립트/스타일/주석 제거 후 태그 스트립
- 잘못된 JSON 응답은 raw 텍스트를 그대로 full_text 로 사용 (실패해도 빈 응답 X)

## 토큰 비용 (대략)

- 입력: chef DB 노드 100 + URL 5개 × 12,000 자 = ~70,000 토큰
- 출력: 1,500 ~ 3,000 자 (= ~ 1,000 ~ 2,000 토큰)
- 시스템 프롬프트 캐싱 적용 → 같은 세션 재호출 시 비용 95% 감소

## 호출 예 (curl)

```bash
curl -X POST https://YOUR_REF.supabase.co/functions/v1/lineage-summarize \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "lineage_id": "kanesaka",
    "lineage_name_ko": "카네사카 계보",
    "lineage_name_en": "Kanesaka Lineage",
    "reference_urls": [
      "https://ja.wikipedia.org/wiki/%E9%89%A4_%E3%81%8B%E3%81%AD%E3%81%95%E3%81%8B",
      "https://tabelog.com/tokyo/A1301/A130101/13003639/"
    ],
    "curator_notes": "카네사카 신이치로 (1969~) 가 시조. 긴자 본점 + 13명 직계."
  }'
```
