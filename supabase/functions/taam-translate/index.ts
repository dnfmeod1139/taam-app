// ════════════════════════════════════════════════════════════════
// taam-translate — KO → EN / JA 번역 보조 (Claude 4.5 Sonnet)
// ────────────────────────────────────────────────────────────────
// 입력 (POST JSON):
//   {
//     items: [
//       { id: 'concierge_note', value: '미니멀한 카운터 8석에서 정통 에도마에를 즐기는...' },
//       { id: 'vibe_tags', value: ['미니멀','정통'], kind: 'array' },
//       { id: 'name', value: '정식당', romanize: true },
//       ...
//     ],
//     target_langs: ['en','ja'],     // 기본 둘 다
//     context?: string,              // 추가 문맥 (예: "고급 스시 오마카세 레스토랑")
//   }
//
// 처리:
//   1) 항목별로 type 분기 (텍스트 vs 배열 vs 로마자 이름)
//   2) Claude 에 한 번 호출로 EN+JA 동시 번역 요청 (JSON 응답)
//   3) tableall.com / omakase.in 미식 도메인 용어 가이드 prompt 주입
//   4) restaurants/tickets 등에 그대로 upsert 가능한 형태로 반환
//
// 출력 (200 JSON):
//   {
//     translations: {
//       concierge_note: { en: '...', ja: '...' },
//       vibe_tags: { en: ['minimal','authentic'], ja: ['ミニマル','正統'] },
//       name: { en: 'Jungsik', ja: 'チョンシクダン' },
//       ...
//     },
//     model: 'claude-sonnet-4-5',
//     token_usage: { input, output },
//     warnings: []
//   }
//
// 환경 변수:
//   ANTHROPIC_API_KEY  (필수)
// ════════════════════════════════════════════════════════════════

// 🆕 CORS 헤더 인라인 (Web Editor 배포 호환 — _shared import 사용 X)
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

const CLAUDE_MODEL = "claude-sonnet-4-5";
const ANTHROPIC_VERSION = "2023-06-01";
const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const CLAUDE_MAX_OUTPUT_TOKENS = 4_096;

// ── 도메인 용어 가이드 (system prompt 에 삽입) ──────────────────
const DOMAIN_GUIDE = `
## TAAM 미식 플랫폼 번역 가이드

당신은 한국·일본 프리미엄 미식 예약 플랫폼 TAAM의 콘텐츠를 영어와 일본어로 번역한다.
참고 표준: tableall.com (일본 미식 영문 예약 사이트), omakase.in/en/

### 도메인 표준 용어 (이 표를 우선 적용)

| 한국어 | English | 日本語 |
|---|---|---|
| 장르 | Genre | ジャンル |
| 대행비 | Reservation Fee | 予約手数料 |
| 활성/판매중 | Available | 販売中 |
| 매진 | Sold Out | 完売 |
| 노출 제어 | Display Settings | 表示設定 |
| 쉐프 한 줄 소개 | Chef Profile | シェフ紹介 |
| 계보도 | Lineage | 系譜 |
| 큐레이션 | Curation | キュレーション |
| 빕 구르망 | Bib Gourmand | Bib Gourmand |
| 예약 | Reservation | 予約 |
| 코스 | Course | コース |
| 카운터 | Counter | カウンター |
| 룸 (개실) | Private Room | 個室 |
| 점심 / 저녁 | Lunch / Dinner | ランチ / ディナー |
| 영업시간 | Hours | 営業時間 |
| 정기휴일 | Closed | 定休日 |
| 1인 | per guest | お一人様 |
| 한 줄 평 | Description / Highlights | 紹介 |
| 시그니처 | Signature | シグネチャー |
| 식사비 | Meal Price | お食事代 |
| 위약금 | Cancellation Fee | キャンセル料 |
| 예치금 | Deposit | デポジット |
| 본가 / 분점 | Origin / Branch | 本家 / 分店 |
| 분위기 | Vibe | 雰囲気 |

### 미식 음식 용어
- 스시 → Sushi / 寿司
- 텐푸라 → Tempura / 天ぷら
- 카이세키 → Kaiseki / 懐石
- 야키니쿠 → Yakiniku / 焼肉
- 야키토리 → Yakitori / 焼鳥
- 우나기/장어 → Unagi / 鰻
- 라멘 → Ramen / ラーメン
- 소바 → Soba / そば
- 한식 → Korean / 韓国料理
- 미즈타키 → Mizutaki / 水炊き

### 매장/셰프 이름 (number-id 'romanize:true')
- 번역하지 않고 **로마자 표기 (헵번식)** 사용
- 예: 정식당 → "Jungsik" / 日本語: "ジョンシクダン"
- 예: 안성재 → "Sungjae Ahn" / 日本語: "アン・ソンジェ"
- 일본어는 카타카나 표기 우선

### 톤 가이드
- 영어: 친근하지만 정제된 톤. 미식 잡지 (Eater, Robb Report) 스타일.
- 일본어: 「です・ます」체. 食ベログ レビュー 풍의 정중한 정보 전달.
- 분위기 태그/시그니처 키워드는 **한 단어 또는 짧은 구절** (1-3 단어). 풀 문장 X.

### 출력 형식 (반드시 JSON, 코드블록 없이)
{
  "translations": {
    "<id>": { "en": "...", "ja": "..." },
    "<id>": { "en": ["..."], "ja": ["..."] }   // 배열 입력은 배열 출력
  }
}
`;

interface I18nItem {
  id: string;
  value: string | string[];
  kind?: "text" | "array";
  romanize?: boolean;
}

interface ReqBody {
  items: I18nItem[];
  target_langs?: string[];
  context?: string;
}

// ── 메인 핸들러 ──────────────────────────────────────────────────
Deno.serve(async (req) => {
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
    const body: ReqBody = await req.json();
    const items = Array.isArray(body.items) ? body.items : [];
    const targetLangs = body.target_langs ?? ["en", "ja"];
    const context = body.context ?? "";

    if (items.length === 0) {
      return jsonResp({ error: "items 배열이 비어있습니다" }, 400);
    }

    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) {
      return jsonResp({ error: "ANTHROPIC_API_KEY 미설정" }, 500);
    }

    // ── Claude 프롬프트 구성 ──
    const itemsBlock = items
      .map((it) => {
        const v = Array.isArray(it.value)
          ? JSON.stringify(it.value)
          : JSON.stringify(it.value ?? "");
        const flags: string[] = [];
        if (it.kind === "array" || Array.isArray(it.value)) flags.push("kind:array");
        if (it.romanize) flags.push("romanize:true");
        const flagStr = flags.length ? ` [${flags.join(", ")}]` : "";
        return `- id="${it.id}"${flagStr}: ${v}`;
      })
      .join("\n");

    const userPrompt = [
      context ? `## 추가 문맥\n${context}\n` : "",
      "## 번역할 항목 (한국어 → " + targetLangs.join(", ") + ")",
      itemsBlock,
      "",
      "위 항목을 JSON 으로만 번역해. 코드블록(```)은 쓰지 마. translations 객체 하나만.",
    ].join("\n");

    // ── Claude API 호출 (재시도 포함) ──
    //   🆕 2026.08: 예전에는 첫 호출이 실패하면 그대로 500 을 반환했다.
    //   Anthropic 은 트래픽에 따라 429(rate limit) · 529(overloaded) 를 수시로 돌려주는데,
    //   재시도가 없으니 일괄 번역에서 40% 가 실패하고 그 노드는 계속 미번역으로 남았다.
    //   재시도할 가치가 있는 상태코드에 지수 백오프를 걸고, 응답이 JSON 이 아니면
    //   한 번 더 물어본다 (모델이 코드블록이나 설명을 덧붙이는 경우).
    const claude = await callClaudeWithRetry(apiKey, userPrompt);
    if (!claude.ok) {
      console.error("Claude 호출 최종 실패:", claude.status, claude.detail);
      return jsonResp(
        { error: claude.error, status: claude.status, detail: claude.detail, attempts: claude.attempts },
        claude.status === 429 || claude.status === 529 ? 503 : 500,
      );
    }

    return jsonResp({
      translations: claude.translations,
      model: CLAUDE_MODEL,
      token_usage: claude.usage ?? null,
      target_langs: targetLangs,
      attempts: claude.attempts,
    }, 200);
  } catch (e) {
    console.error("taam-translate error:", e);
    return jsonResp({ error: String(e?.message ?? e) }, 500);
  }
});

function jsonResp(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ── Claude 호출 + 재시도 ────────────────────────────────────────
//   재시도 대상: 429(rate limit) · 529(overloaded) · 5xx · 네트워크 오류 · JSON 파싱 실패
//   재시도 안 함: 400(잘못된 요청) · 401/403(키 문제) — 다시 불러도 같은 결과다
const RETRY_STATUS = new Set([408, 409, 429, 500, 502, 503, 504, 529]);
const MAX_ATTEMPTS = 3;

// ⏱ 시간 예산 — Edge Function 게이트웨이가 응답을 기다려주는 시간 안에 반드시 끝내야 한다.
//   재시도를 넣었더니 (4회 × Anthropic 15~20초 + 백오프 7초 = 최대 87초) 게이트웨이가
//   먼저 끊어 504 Gateway Timeout 이 났다. 재시도가 없던 때보다 더 나빠진 것이다.
//   → 전체 예산 안에서만 재시도하고, 남은 시간이 부족하면 즉시 포기해 정상 응답을 돌려준다.
//     클라이언트는 그 노드를 pending 으로 남겨두므로 다음 실행에서 자연스럽게 다시 시도된다.
const TOTAL_BUDGET_MS = 50_000;   // 함수 전체
const ATTEMPT_TIMEOUT_MS = 22_000; // 호출 1회

type ClaudeOk = {
  ok: true; translations: unknown; usage: unknown; attempts: number;
};
type ClaudeFail = {
  ok: false; error: string; status: number; detail: string; attempts: number;
};

async function callClaudeWithRetry(
  apiKey: string,
  userPrompt: string,
): Promise<ClaudeOk | ClaudeFail> {
  let lastStatus = 0;
  let lastDetail = "";
  const startedAt = Date.now();
  const remaining = () => TOTAL_BUDGET_MS - (Date.now() - startedAt);

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    if (attempt > 1) {
      // 0.5s → 1.5s (+ 지터). 동시에 여러 건이 돌 때 같은 순간에 몰리지 않게 흔든다.
      const wait = Math.pow(2, attempt - 2) * 500 + Math.floor(Math.random() * 400);
      // 남은 예산이 "대기 + 최소 한 번의 호출" 을 감당 못 하면 더 시도하지 않는다.
      if (remaining() < wait + 8_000) {
        console.warn(`[taam-translate] 시간 예산 소진 — 재시도 중단 (남은 ${remaining()}ms)`);
        break;
      }
      console.warn(`[taam-translate] 재시도 ${attempt}/${MAX_ATTEMPTS} — ${wait}ms 대기 (직전: ${lastStatus} ${lastDetail.slice(0, 120)})`);
      await new Promise((r) => setTimeout(r, wait));
    }

    // 한 번의 호출이 통째로 매달려 게이트웨이 타임아웃을 유발하지 않도록 상한을 둔다
    const ctrl = new AbortController();
    const budget = Math.max(5_000, Math.min(ATTEMPT_TIMEOUT_MS, remaining() - 1_000));
    const timer = setTimeout(() => ctrl.abort(), budget);

    let res: Response;
    try {
      res = await fetch(ANTHROPIC_API_URL, {
        method: "POST",
        signal: ctrl.signal,
        headers: {
          "Content-Type": "application/json",
          "anthropic-version": ANTHROPIC_VERSION,
          "x-api-key": apiKey,
        },
        body: JSON.stringify({
          model: CLAUDE_MODEL,
          max_tokens: CLAUDE_MAX_OUTPUT_TOKENS,
          system: DOMAIN_GUIDE,
          messages: [{ role: "user", content: userPrompt }],
        }),
      });
    } catch (e) {
      // 네트워크 오류 · 타임아웃 — 재시도 가치가 있다
      lastStatus = 0;
      lastDetail = String((e as Error)?.message ?? e);
      continue;
    } finally {
      clearTimeout(timer);
    }

    if (!res.ok) {
      lastStatus = res.status;
      lastDetail = await res.text().catch(() => "");
      if (RETRY_STATUS.has(res.status)) continue;
      // 400/401/403 등은 다시 불러도 같으므로 즉시 포기
      return {
        ok: false, error: `Claude API ${res.status}`,
        status: res.status, detail: lastDetail.slice(0, 500), attempts: attempt,
      };
    }

    const data = await res.json().catch(() => null);
    const text = data?.content?.[0]?.text ?? "";
    const parsed = extractJson(text);

    if (parsed === null) {
      // 모델이 코드블록·설명을 덧붙였거나 출력이 잘렸다. 다시 물어본다.
      lastStatus = 200;
      lastDetail = "JSON 파싱 실패: " + String(text).slice(0, 300);
      console.warn("[taam-translate] JSON 파싱 실패 — 재시도 예정");
      continue;
    }

    return {
      ok: true,
      translations: (parsed as Record<string, unknown>).translations ?? parsed,
      usage: data?.usage ?? null,
      attempts: attempt,
    };
  }

  return {
    ok: false,
    error: lastStatus === 200 ? "Claude 응답 JSON 파싱 실패" : `Claude API ${lastStatus}`,
    status: lastStatus || 503,
    detail: lastDetail.slice(0, 500),
    attempts: MAX_ATTEMPTS,
  };
}

// 코드블록·앞뒤 설명이 섞여 있어도 JSON 객체를 뽑아낸다. 실패하면 null.
function extractJson(text: string): unknown | null {
  if (!text) return null;
  const cleaned = String(text)
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();
  try {
    return JSON.parse(cleaned);
  } catch (_e) { /* 아래에서 한 번 더 시도 */ }
  // 설명이 앞뒤로 붙은 경우 — 첫 '{' 부터 마지막 '}' 까지만 떼어 본다
  const s = cleaned.indexOf("{");
  const e = cleaned.lastIndexOf("}");
  if (s >= 0 && e > s) {
    try {
      return JSON.parse(cleaned.slice(s, e + 1));
    } catch (_e2) { /* 포기 */ }
  }
  return null;
}
