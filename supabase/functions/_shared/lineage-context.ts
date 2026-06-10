// ════════════════════════════════════════════════════════════════
// 계보 컨텍스트 헬퍼 (taam-chat Edge Function 에서 import)
// ────────────────────────────────────────────────────────────────
// 목적:
//   1) 사용자 쿼리에서 계보 키워드 감지 → 발행된 계보 full_text 를 시스템 프롬프트에 주입
//   2) 매장 단위 컨텍스트 조립 시 restaurants.chef_lineage_text 자동 결합
// ════════════════════════════════════════════════════════════════

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// 계보 키워드 (한글 + 영문 + 일본어 한자) — 어떤 식으로 들어와도 매칭
// chef_lineage_knowledge.lineage_id 와 1:1 매핑되는 alias 도 포함
const LINEAGE_TRIGGER_TERMS: Array<{ key: string; lineage_ids: string[] }> = [
  // 일반어
  { key: "계보", lineage_ids: [] },         // 빈 배열 = "발행된 모든 계보 주입"
  { key: "사사", lineage_ids: [] },
  { key: "직계", lineage_ids: [] },
  { key: "분파", lineage_ids: [] },
  { key: "출신", lineage_ids: [] },
  { key: "스승", lineage_ids: [] },
  { key: "제자", lineage_ids: [] },
  { key: "lineage", lineage_ids: [] },
  { key: "succession", lineage_ids: [] },

  // 스시 — 트리별 키워드
  { key: "스기타",   lineage_ids: ["sugita"] },
  { key: "Sugita",   lineage_ids: ["sugita"] },
  { key: "杉田",     lineage_ids: ["sugita"] },

  { key: "카네사카", lineage_ids: ["kanesaka"] },
  { key: "Kanesaka", lineage_ids: ["kanesaka"] },
  { key: "金坂",     lineage_ids: ["kanesaka"] },
  { key: "鮨かねさか", lineage_ids: ["kanesaka"] },

  { key: "큐베이",   lineage_ids: ["kyubey"] },
  { key: "큐베에",   lineage_ids: ["kyubey"] },
  { key: "Kyubey",   lineage_ids: ["kyubey"] },
  { key: "久兵衛",   lineage_ids: ["kyubey"] },

  { key: "사이토",   lineage_ids: ["saito"] },
  { key: "Saito",    lineage_ids: ["saito"] },
  { key: "齋藤",     lineage_ids: ["saito"] },
  { key: "齊藤",     lineage_ids: ["saito"] },

  { key: "우미",     lineage_ids: ["umi"] },
  { key: "Umi",      lineage_ids: ["umi"] },
  { key: "海味",     lineage_ids: ["umi"] },

  { key: "지로",     lineage_ids: ["jiro"] },
  { key: "Jiro",     lineage_ids: ["jiro"] },
  { key: "次郎",     lineage_ids: ["jiro"] },
  { key: "스시지로", lineage_ids: ["jiro"] },
  { key: "스기야바시", lineage_ids: ["jiro"] },
  { key: "数寄屋橋",   lineage_ids: ["jiro"] },

  { key: "아라이",   lineage_ids: ["arai"] },
  { key: "Arai",     lineage_ids: ["arai"] },
  { key: "新井",     lineage_ids: ["arai"] },

  { key: "스시 쇼", lineage_ids: ["sho"] },
  { key: "스시쇼",  lineage_ids: ["sho"] },
  { key: "Sushisho", lineage_ids: ["sho"] },
  { key: "Sushi Sho", lineage_ids: ["sho"] },
  { key: "鮨匠",     lineage_ids: ["sho"] },

  { key: "기요타",   lineage_ids: ["new9"] },
  { key: "Kiyota",   lineage_ids: ["new9"] },
  { key: "清田",     lineage_ids: ["new9"] },

  { key: "아라키",   lineage_ids: ["new10"] },
  { key: "Araki",    lineage_ids: ["new10"] },
  { key: "荒木",     lineage_ids: ["new10"] },

  { key: "미타니",   lineage_ids: ["new11"] },
  { key: "Mitani",   lineage_ids: ["new11"] },
  { key: "三谷",     lineage_ids: ["new11"] },

  { key: "요시타케", lineage_ids: ["new12"] },
  { key: "Yoshitake", lineage_ids: ["new12"] },
  { key: "吉武",     lineage_ids: ["new12"] },
];

export interface PublishedLineage {
  lineage_id: string;
  lineage_name_ko: string;
  lineage_name_en: string | null;
  lineage_kind: string;
  summary: string | null;
  full_text: string | null;
  reference_urls: string[];
  chef_count: number | null;
  last_verified_at: string | null;
}

/**
 * 사용자 쿼리에서 계보 키워드 감지 → 매칭되는 lineage_id 집합 반환
 * - 일반어 ("계보", "사사" 등) 매칭 시 빈 Set 반환 → 호출 측은 "전체 주입" 으로 해석
 * - 특정 트리 키워드 매칭 시 해당 lineage_id 만 Set 에 포함
 *
 * 반환:
 *   { matched: true,  lineageIds: Set("kanesaka") }   // 특정 트리만
 *   { matched: true,  lineageIds: Set() }              // 전체
 *   { matched: false, lineageIds: Set() }              // 미매칭 → 주입 안 함
 */
export function detectLineageIntent(query: string): {
  matched: boolean;
  lineageIds: Set<string>;
  injectAll: boolean;
} {
  const q = (query || "").toLowerCase();
  if (!q) return { matched: false, lineageIds: new Set(), injectAll: false };

  let matched = false;
  let injectAll = false;
  const ids = new Set<string>();

  for (const term of LINEAGE_TRIGGER_TERMS) {
    if (q.includes(term.key.toLowerCase())) {
      matched = true;
      if (term.lineage_ids.length === 0) {
        injectAll = true;
      } else {
        for (const id of term.lineage_ids) ids.add(id);
      }
    }
  }
  return { matched, lineageIds: ids, injectAll };
}

/**
 * 발행된 계보 데이터를 가져옴 (선택적 lineage_id 필터)
 * - injectAll=true → 전체 published 행
 * - lineageIds 가 있으면 그 행들만
 */
export async function fetchPublishedLineages(
  sb: SupabaseClient,
  opts: { injectAll: boolean; lineageIds: Set<string> },
): Promise<PublishedLineage[]> {
  let q = sb.from("v_published_chef_lineages").select("*");
  if (!opts.injectAll && opts.lineageIds.size > 0) {
    q = q.in("lineage_id", Array.from(opts.lineageIds));
  }
  const { data, error } = await q;
  if (error) {
    console.warn("[lineage-context] fetch error:", error.message);
    return [];
  }
  return (data || []) as PublishedLineage[];
}

/**
 * 발행된 계보 행들 → LLM 에 주입할 시스템 프롬프트 절(節) 텍스트로 직렬화
 * 토큰 절감을 위해 full_text 만 사용 (summary 는 제목 옆에 1줄)
 */
export function formatLineagesForSystemPrompt(
  lineages: PublishedLineage[],
): string {
  if (!lineages.length) return "";
  const blocks = lineages.map((L) => {
    const parts: string[] = [];
    parts.push(`### ${L.lineage_name_ko}${L.lineage_name_en ? ` (${L.lineage_name_en})` : ""}`);
    if (L.summary) parts.push(`_${L.summary}_`);
    if (L.full_text) parts.push(L.full_text);
    return parts.join("\n");
  });
  return [
    "--- 쉐프 계보 지식 (큐레이터 검증 완료) ---",
    [
      "아래 정보를 바탕으로 사용자 질문에 답변하세요.",
      "",
      "## 계보 질문 답변 규칙 (위 시스템 프롬프트 '답변 길이' 규칙보다 우선)",
      "- 사용자가 **계보 / 사사 / 제자 / 직계 / 분파 / 명단 / 누구있어** 등을 물으면,",
      "  발행된 학습 본문에 등장하는 **모든 쉐프와 매장을 누락 없이** 답변에 포함할 것.",
      "- '4곳 이상은 톱 1~2곳만 짧게' 규칙은 **매장 추천 질문에만** 적용. 계보 명단 질문에는 적용하지 말 것.",
      "- 세대(1세대/2세대/3세대)나 본가/직계/분파 등 **구조를 유지**해서 답변. 평탄한 리스트로 압축하지 마라.",
      "- HTML 태그(<b>, <br>) 또는 마크다운(##, **, -) 모두 사용 가능. 챗 UI 가 렌더링한다.",
      "- 출처 충돌 시 신중히 표시하고, 발행 시점 이후 변경 사항은 알지 못한다고 안내.",
      "- 본문에 명시된 인물/매장만 사용. 추측/창작 금지.",
      "",
      "## 계보 답변 톤 (매우 중요)",
      "- **딱딱한 사실 나열 금지.** 신문 기사 톤 X. 사용자가 기억에 남도록 작성.",
      "- 본문의 **에피소드·어록·결정적 사건**을 적극 인용. 일반 기사에선 못 보는 인사이드 정보 강조.",
      "- 어록은 \"…\" 형태로 그대로 인용 (예: \"식재료가 스스로 말하게 하라\").",
      "- 시그니처는 단순 나열 X → \"왜 이게 시그니처인가\" 임팩트 살리기.",
      "- 본문에 「탐 큐레이션 메모」 섹션이 있으면 그 내용을 답변 마지막에 자연스럽게 녹일 것 (예: \"왜 이 계보를 알아야 하는가\" 한 줄 마무리).",
      "- 한 인물 한 답변에선 그 인물의 **고유한 한 가지** (가장 임팩트 있는 에피소드 1개 + 가장 임팩트 있는 시그니처 1개) 부각.",
    ].join("\n"),
    blocks.join("\n\n"),
    "--- 끝 ---",
  ].join("\n\n");
}

/**
 * 한 번에 처리: 쿼리 감지 → fetch → 시스템 프롬프트 절 반환
 * 매칭 안 되면 빈 문자열 반환 (시스템 프롬프트에 추가 텍스트 없음)
 */
export async function buildLineageSystemSection(
  query: string,
  sb: SupabaseClient,
): Promise<string> {
  const intent = detectLineageIntent(query);
  if (!intent.matched) return "";
  const lineages = await fetchPublishedLineages(sb, intent);
  return formatLineagesForSystemPrompt(lineages);
}

/**
 * 매장 단위 컨텍스트 조립 시 — concierge_note 옆에 결합할 한줄
 * (taam-chat 이 매장별 답변을 만들 때 사용)
 */
export function getRestaurantLineageLine(rest: {
  chef_lineage_text?: string | null;
}): string {
  return (rest && rest.chef_lineage_text) ? rest.chef_lineage_text.trim() : "";
}
