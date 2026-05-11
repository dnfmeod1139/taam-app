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

    // ── Claude API 호출 ──
    const claudeRes = await fetch(ANTHROPIC_API_URL, {
      method: "POST",
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

    if (!claudeRes.ok) {
      const errText = await claudeRes.text();
      console.error("Claude API error:", claudeRes.status, errText);
      return jsonResp(
        { error: `Claude API ${claudeRes.status}`, detail: errText },
        500,
      );
    }

    const claudeData = await claudeRes.json();
    const text = claudeData?.content?.[0]?.text ?? "";

    // ── JSON 파싱 (코드블록 제거 후) ──
    let parsed: any;
    try {
      const cleaned = text
        .replace(/^```(?:json)?\s*/i, "")
        .replace(/\s*```\s*$/i, "")
        .trim();
      parsed = JSON.parse(cleaned);
    } catch (e) {
      console.error("JSON parse failed:", text);
      return jsonResp(
        {
          error: "Claude 응답 JSON 파싱 실패",
          raw: text.slice(0, 2000),
        },
        500,
      );
    }

    const translations = parsed.translations ?? parsed;

    return jsonResp({
      translations,
      model: CLAUDE_MODEL,
      token_usage: claudeData.usage ?? null,
      target_langs: targetLangs,
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
