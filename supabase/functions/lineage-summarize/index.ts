// ════════════════════════════════════════════════════════════════
// lineage-summarize — 계보 챗 두뇌 학습 자동화 (Option B)
// ────────────────────────────────────────────────────────────────
// 입력 (POST JSON):
//   {
//     lineage_id: string,            // 'sugita', 'kanesaka' ...
//     lineage_name_ko: string,
//     lineage_name_en?: string,
//     reference_urls: string[],      // 참고 자료 URL 배열 (최대 8개 fetch)
//     curator_notes?: string         // 큐레이터가 입력한 자유 텍스트
//   }
//
// 처리:
//   1) chefs 테이블에서 lineage_id 의 노드 목록 조회
//   2) reference_urls 를 서버에서 fetch (timeout + size 제한)
//   3) HTML → 텍스트 추출 (script/style 제거 후 태그 스트립)
//   4) Claude 4.5 Sonnet 에 종합 정리 요청 (한국어 답변)
//   5) full_text + summary 반환
//
// 출력 (200 JSON):
//   {
//     full_text: string,             // 챗 두뇌가 받는 정리 본문
//     summary: string,               // 한 문단 요약
//     model: string,                 // 'claude-sonnet-4-5'
//     token_usage: { input, output, cache_read },
//     fetched_urls: number,
//     chef_count: number
//   }
//
// 환경 변수:
//   ANTHROPIC_API_KEY        (필수)
//   SUPABASE_URL             (자동 — Supabase 가 주입)
//   SUPABASE_SERVICE_ROLE_KEY (필수 — chefs 테이블 read 용)
// ════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// ── 상수 ─────────────────────────────────────────────────────────
const CLAUDE_MODEL = "claude-sonnet-4-5";
const ANTHROPIC_VERSION = "2023-06-01";
const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";

const MAX_URLS = 8;                       // 한 번 호출에 fetch 하는 URL 최대 개수
const URL_FETCH_TIMEOUT_MS = 12_000;      // 개별 URL 타임아웃
const URL_MAX_BYTES = 2_000_000;          // 2MB. 입력 자료는 풀로 받음 (대용량 큐레이터 자료 수용)
const TEXT_PER_URL_TRIM = 30_000;         // URL 1개당 30K 자 — 입력 자료 풍부하게.
const CLAUDE_MAX_OUTPUT_TOKENS = 6_144;   // 🔧 2026.05.10 v4: 4K → 6K.
                                          // Edge Function 무료 티어 timeout = 150s.
                                          // 6K = 한국어 ~3,800자, 생성 ~80s → timeout 안전 + 새 「인물·에피소드·시그니처·큐레이션 메모」 구조 수용.
                                          // 6K 도 부족하면 8K 까지 가능 (생성 ~110s).

// ── HTML → 텍스트 ────────────────────────────────────────────────
function htmlToText(html: string): string {
  let s = html;
  // 스크립트/스타일/주석 제거
  s = s.replace(/<script[\s\S]*?<\/script>/gi, " ");
  s = s.replace(/<style[\s\S]*?<\/style>/gi, " ");
  s = s.replace(/<noscript[\s\S]*?<\/noscript>/gi, " ");
  s = s.replace(/<!--[\s\S]*?-->/g, " ");
  // 블록 요소는 줄바꿈으로
  s = s.replace(/<\/(p|div|li|h[1-6]|br|tr|article|section|header|footer)>/gi, "\n");
  s = s.replace(/<br\s*\/?\s*>/gi, "\n");
  // 태그 제거
  s = s.replace(/<[^>]+>/g, " ");
  // HTML 엔티티 (간이)
  s = s.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
       .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
       .replace(/&quot;/g, '"').replace(/&#39;/g, "'");
  // 공백 정규화
  s = s.replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  return s;
}

// ── URL fetch (timeout + size 제한) ──────────────────────────────
async function fetchUrlAsText(url: string): Promise<{ ok: boolean; text: string; error?: string }> {
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), URL_FETCH_TIMEOUT_MS);
    const res = await fetch(url, {
      signal: ctrl.signal,
      headers: {
        // 일부 사이트는 UA 없으면 차단 — 평범한 브라우저 UA 표기
        "User-Agent":
          "Mozilla/5.0 (compatible; TaamLineageBot/1.0; +https://taam.app)",
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
      },
    });
    clearTimeout(timer);
    if (!res.ok) return { ok: false, text: "", error: `HTTP ${res.status}` };

    const ct = res.headers.get("content-type") || "";
    const reader = res.body?.getReader();
    if (!reader) return { ok: false, text: "", error: "no body" };

    const chunks: Uint8Array[] = [];
    let received = 0;
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value) {
        received += value.length;
        if (received > URL_MAX_BYTES) {
          chunks.push(value.subarray(0, Math.max(0, URL_MAX_BYTES - (received - value.length))));
          try { reader.cancel(); } catch (_) { /* ignore */ }
          break;
        }
        chunks.push(value);
      }
    }
    const buf = new Uint8Array(received > URL_MAX_BYTES ? URL_MAX_BYTES : received);
    let off = 0;
    for (const c of chunks) {
      buf.set(c, off);
      off += c.length;
      if (off >= buf.length) break;
    }
    const decoded = new TextDecoder("utf-8", { fatal: false }).decode(buf);
    const text = ct.includes("text/html") || decoded.includes("<html")
      ? htmlToText(decoded)
      : decoded;
    const trimmed = text.length > TEXT_PER_URL_TRIM
      ? text.slice(0, TEXT_PER_URL_TRIM) + "\n…(이하 생략)"
      : text;
    return { ok: true, text: trimmed };
  } catch (e: any) {
    return { ok: false, text: "", error: e?.message || String(e) };
  }
}

// ── chefs 테이블에서 lineage 노드 조회 ───────────────────────────
async function fetchChefsForLineage(
  sb: any,
  lineage_id: string,
): Promise<Array<{ id: string; name: string | null; sub_title: string | null; linked_rest_id: string | null }>> {
  const { data, error } = await sb
    .from("chefs")
    .select("id, name, sub_title, linked_rest_id")
    .eq("lineage_id", lineage_id)
    .order("name", { ascending: true });
  if (error) {
    console.warn("[lineage-summarize] chefs fetch error:", error.message);
    return [];
  }
  return data || [];
}

// ── Claude API 호출 ──────────────────────────────────────────────
interface ClaudeResp {
  content: Array<{ type: string; text?: string }>;
  usage?: { input_tokens: number; output_tokens: number; cache_read_input_tokens?: number };
  model: string;
  error?: { type: string; message: string };
}

async function callClaude(
  apiKey: string,
  systemPrompt: string,
  userMessage: string,
): Promise<ClaudeResp> {
  const body = {
    model: CLAUDE_MODEL,
    max_tokens: CLAUDE_MAX_OUTPUT_TOKENS,
    // 큐레이터 노트 + URL 내용은 자주 재사용되지 않지만, 시스템 프롬프트는 캐시에 적합
    system: [
      {
        type: "text",
        text: systemPrompt,
        cache_control: { type: "ephemeral" },
      },
    ],
    messages: [{ role: "user", content: userMessage }],
  };

  const res = await fetch(ANTHROPIC_API_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": ANTHROPIC_VERSION,
      // 🔧 FIX 2026.05.09: extended-output-2025-02-19 헤더 제거.
      // 그 beta는 Claude 3.7 Sonnet 의 128K 출력용이고 Sonnet 4.5 는 인식 안 함.
      // Sonnet 4.5 는 native 로 max_tokens 64K 까지 지원 — 별도 헤더 불필요.
      "anthropic-beta": "prompt-caching-2024-07-31",
    },
    body: JSON.stringify(body),
  });
  const json = await res.json();
  if (!res.ok) {
    throw new Error(
      "Anthropic API error: " +
        (json?.error?.message || `HTTP ${res.status}`),
    );
  }
  return json as ClaudeResp;
}

// ── 시스템 프롬프트 ──────────────────────────────────────────────
// 설계 의도 (2026.05.10 v4 — 인물·에피소드·시그니처·큐레이션 메모 구조):
//   목표: 딱딱한 사실 나열 X → **인물 중심의 흥미로운 에피소드 + 임팩트 시그니처 + 큐레이션 메모** 로
//         사용자가 기억에 남도록 정리. 일반 기사에서 못 보는 내용 강조.
//
//   각 쉐프 = [짧은 캐치프레이즈] + [연혁 압축] + [에피소드 1~2] + [시그니처 핵심]
//   계보 단위 = 마지막에 「탐 큐레이션 메모」 (왜 이 계보인가 / 어떤 코스 가능)
const SYSTEM_PROMPT = `너는 일본/한국 미식 컨시어지 "탐(TAAM)" 의 백엔드 큐레이션 보조다.
역할: 자료(URL fetch + 큐레이터 노트 + chef DB)를 「**쉐프 계보 챗 두뇌**」가 사용할 학습 본문으로 정리한다.

【설계 철학】
- **딱딱한 사실 나열은 절대 금지.** 신문 기사 같은 톤 X.
- 사용자가 **기억에 남길 수 있도록** 인물 중심 + 흥미로운 에피소드 + 임팩트 있는 시그니처로 구성.
- 일반 미식 기사·블로그에 잘 안 나오는 **인사이드 에피소드**를 적극 활용 (첫 만남, 결정적 사건, 어록, 가족 이야기 등).
- 한 마디 어록·결정적 일화는 **그대로 따옴표 인용**해서 임팩트를 살릴 것.

【원칙】
1. **사실만**. 자료에 명시된 내용만. 추측/창작 금지.
2. **한국어**. 매장명·쉐프명·지명은 첫 등장 시 한글(한자) 병기.
3. **출처 우선순위**: 큐레이터 노트 > URL 자료 > chef DB. 충돌은 본문에 명시.
4. **시점 명확화**: 연도/월 명시 가능한 사건은 반드시 시기 표기 (예: 2008.06).

【본문 구조 — 각 쉐프 1명】
다음 4개 항목 순서대로:
  1. **캐치프레이즈** (1줄, 진하게) — 그 인물을 한 마디로
  2. **연혁** (글머리 4~6개) — 시기 / 사건. 핵심만 압축
  3. **에피소드 1~2개** — 일반 기사에서 못 보는 인물 캐릭터를 보여 주는 일화 (어록 인용 적극)
  4. **시그니처 핵심** (글머리 2~4개) — 임팩트 있는 한 점 (왜 이게 시그니처인가)

【분량 가이드】
- 본가/시조: 400~600자 (캐릭터·에피소드·시그니처 풍부하게)
- 직계: 250~400자
- 손자/하위 노드: 150~250자
- 본문 전체 절대 상한: **3,500자**. (Edge Function timeout 150초 제약)
- 같은 내용 반복 금지. 각 인물이 가진 **고유한 한 가지** 부각.

【계보 마무리 — 「탐 큐레이션 메모」】
본문 마지막에 반드시 「## 탐 큐레이션 메모」 섹션:
  - **왜 이 계보인가**: 2~4 줄. 다른 계보와 차별점 / 미식가가 이 계보를 알아야 할 이유
  - **추천 코스**: 가능하면 1~2개 (예: 「본가 + 직계 2곳 = 1박 2일 코스」)
  - **현실적 주의사항**: 예약 난이도, 가격대, 룰 등 — 사용자가 실제로 가게 될 때 알아야 할 것

【출력 형식】 반드시 아래 두 XML 태그만 사용. 태그 외 다른 텍스트 일체 금지:

<summary>한 문단(2~3 문장, 250자 이내). 시조 + 분파 규모 + 이 계보의 한 줄 임팩트.</summary>
<full_text>
# [계보명]

## 본가
**[쉐프 / 매장]**
> [캐치프레이즈 한 줄]

**연혁**
- 1973 — 출생
- 2004 — 30세 독립
- 2017 — 미슐랭 1성
- 2023 — 미슐랭 2성

**에피소드 — [에피소드 제목]**
[일반 기사에 없는 흥미로운 일화. 어록 인용 적극.]

**시그니처**
- [네타1] — 임팩트 한 줄
- [네타2] — 임팩트 한 줄

## 직계
**[쉐프 / 매장]**
> [캐치프레이즈]

[연혁·에피소드·시그니처를 압축한 250~400자]

## 손자/한국·해외
**[쉐프 / 매장]**: [150~250자 압축]

## 탐 큐레이션 메모
**왜 이 계보인가**
- ...
- ...

**추천 코스**
- ...

**현실적 주의사항**
- ...

**중요**:
- 본문 3,500자 이내 절대 엄수.
- 마지막 반드시 </full_text> 로 닫기.
- 「탐 큐레이션 메모」 섹션 누락 금지.
- 어록 적극 인용. 흥미 유발 우선.
</full_text>`;

// ── 사용자 프롬프트 빌더 ────────────────────────────────────────
interface BuildArgs {
  lineage_id: string;
  lineage_name_ko: string;
  lineage_name_en?: string;
  curator_notes?: string;
  chefs: Array<{ id: string; name: string | null; sub_title: string | null }>;
  fetched: Array<{ url: string; ok: boolean; text: string; error?: string }>;
}
function buildUserPrompt(a: BuildArgs): string {
  const parts: string[] = [];
  parts.push(`# 계보 ID: ${a.lineage_id}`);
  parts.push(`# 계보 한글명: ${a.lineage_name_ko}`);
  if (a.lineage_name_en) parts.push(`# 계보 영문명: ${a.lineage_name_en}`);

  // chefs DB
  parts.push("\n## 시스템에 등록된 쉐프 노드 (chefs 테이블)");
  if (a.chefs.length === 0) {
    parts.push("(등록된 쉐프 노드 없음)");
  } else {
    for (const c of a.chefs) {
      const sub = c.sub_title ? ` — ${c.sub_title}` : "";
      parts.push(`- ${c.name || "(이름 미입력)"}${sub} [chef_id=${c.id}]`);
    }
  }

  // 큐레이터 노트
  if (a.curator_notes && a.curator_notes.trim()) {
    parts.push("\n## 큐레이터 노트 (최우선 출처)");
    parts.push(a.curator_notes.trim());
  }

  // fetch 자료
  parts.push("\n## 참고 자료 (URL fetch 결과)");
  if (a.fetched.length === 0) {
    parts.push("(URL 자료 없음)");
  } else {
    a.fetched.forEach((f, i) => {
      parts.push(`\n### [자료 ${i + 1}] ${f.url}`);
      if (!f.ok) {
        parts.push(`(fetch 실패: ${f.error || "unknown"})`);
      } else {
        parts.push(f.text || "(빈 본문)");
      }
    });
  }

  parts.push(
    "\n---\n위 자료를 종합해 **<summary>...</summary><full_text>...</full_text>** XML 태그 형식으로만 출력하라. " +
      "태그 외 다른 텍스트(설명/markdown 코드블록/JSON)는 절대 포함하지 마라.\n" +
      "**중요**: 시스템 프롬프트의 「캐치프레이즈 → 연혁 → 에피소드 → 시그니처 → 큐레이션 메모」 구조를 그대로 따를 것. " +
      "딱딱한 사실 나열 금지. 어록 인용 적극, 인물 캐릭터 부각.",
  );
  return parts.join("\n");
}

// ── XML 태그 응답 파싱 (<summary>...</summary><full_text>...</full_text>) ──
//    JSON 보다 안전 — 본문의 줄바꿈/따옴표를 escape 할 필요 없음.
function parseClaudeTagged(raw: string): { summary?: string; full_text?: string } {
  const out: { summary?: string; full_text?: string } = {};
  if (!raw) return out;
  // 마크다운 코드블록 래퍼가 잘못 들어왔을 경우 제거 (방어)
  let s = raw.trim().replace(/^```(?:xml|html)?\s*/i, "").replace(/```\s*$/i, "");
  const sumMatch = s.match(/<summary>([\s\S]*?)<\/summary>/i);
  const fullMatch = s.match(/<full_text>([\s\S]*?)<\/full_text>/i);
  if (sumMatch) out.summary = sumMatch[1].trim();
  if (fullMatch) out.full_text = fullMatch[1].trim();
  // 태그가 없으면 — 호환 모드 (옛 JSON 응답 또는 raw 텍스트)
  if (!out.summary && !out.full_text) {
    // 방어: ```json …``` 또는 { …json… } 형태에서 추출 시도
    const stripped = s.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/i, "");
    const start = stripped.indexOf("{");
    const end = stripped.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        const j = JSON.parse(stripped.slice(start, end + 1));
        if (j && typeof j === "object") {
          if (j.summary) out.summary = String(j.summary).trim();
          if (j.full_text) out.full_text = String(j.full_text).trim();
        }
      } catch (_) { /* ignore — fall through */ }
    }
  }
  return out;
}

// ── HTTP 핸들러 ──────────────────────────────────────────────────
Deno.serve(async (req) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const body = await req.json();
    const lineage_id: string = (body.lineage_id || "").trim();
    const lineage_name_ko: string = (body.lineage_name_ko || "").trim();
    const lineage_name_en: string | undefined = body.lineage_name_en;
    const reference_urls: string[] = Array.isArray(body.reference_urls)
      ? body.reference_urls.filter((u: any) => typeof u === "string" && u.trim())
      : [];
    const curator_notes: string = (body.curator_notes || "").trim();

    if (!lineage_id || !lineage_name_ko) {
      return new Response(
        JSON.stringify({ error: "lineage_id 및 lineage_name_ko 필수" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) {
      return new Response(
        JSON.stringify({ error: "ANTHROPIC_API_KEY 미설정" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceKey) {
      return new Response(
        JSON.stringify({ error: "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 미설정" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }
    const sb = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // 1) chefs 노드 조회
    const chefs = await fetchChefsForLineage(sb, lineage_id);

    // 2) URL fetch (병렬)
    const urlsToFetch = reference_urls.slice(0, MAX_URLS);
    const fetched = await Promise.all(
      urlsToFetch.map(async (url) => {
        const r = await fetchUrlAsText(url);
        return { url, ...r };
      }),
    );

    // 3) Claude 호출
    const userPrompt = buildUserPrompt({
      lineage_id,
      lineage_name_ko,
      lineage_name_en,
      curator_notes,
      chefs,
      fetched,
    });

    const claudeResp = await callClaude(apiKey, SYSTEM_PROMPT, userPrompt);
    const rawText = (claudeResp.content || [])
      .filter((b) => b.type === "text")
      .map((b) => b.text || "")
      .join("\n")
      .trim();

    const parsed = parseClaudeTagged(rawText);
    const full_text = parsed.full_text || rawText;
    const summary = parsed.summary || "";

    // 4) AI 메타 자동 저장 (best-effort — 실패해도 응답은 OK)
    try {
      await sb
        .from("chef_lineage_knowledge")
        .update({
          ai_model: claudeResp.model || CLAUDE_MODEL,
          ai_generated_at: new Date().toISOString(),
          ai_token_usage: claudeResp.usage || null,
          chef_count: chefs.length,
        })
        .eq("lineage_id", lineage_id);
    } catch (e) {
      console.warn("[lineage-summarize] meta update skipped:", e);
    }

    return new Response(
      JSON.stringify({
        full_text,
        summary,
        model: claudeResp.model || CLAUDE_MODEL,
        token_usage: claudeResp.usage || null,
        fetched_urls: fetched.filter((f) => f.ok).length,
        failed_urls: fetched.filter((f) => !f.ok).map((f) => ({ url: f.url, error: f.error })),
        chef_count: chefs.length,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (e: any) {
    console.error("[lineage-summarize] error:", e);
    return new Response(
      JSON.stringify({ error: e?.message || String(e) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
