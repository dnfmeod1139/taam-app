// ═══════════════════════════════════════════════════════════════
// TAAM — 컨시어지 챗 Edge Function (v4)
// 함수명: taam-chat
//
// v4 변경사항 (2026-05-02):
//   - Haiku 4.5 모델 (5배 빠름)
//   - region/genre 키워드 사전 필터 (정확도 ↑)
//   - genre 한국어 컬럼 select에 추가 (LLM 매칭 가능)
//   - name_local 추가 (일본어 가게명도 매칭)
//   - social_mention_count 추가 (인플루언서 신호)
// ═══════════════════════════════════════════════════════════════

// 🔧 FIX 2026.05.10 v9: import { serve } from std/http 제거 → Deno.serve 내장 사용.
//   옛 std 버전 import 가 BOOT_ERROR 의 원인일 가능성 높음 (Supabase Edge Runtime 이 deprecated 시킴).
//   Deno.serve 는 런타임 내장이라 import 불필요.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  buildLineageSystemSection,
  getRestaurantLineageLine,
} from "../_shared/lineage-context.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const DEFAULT_MODEL = "claude-haiku-4-5-20251001";
const MAX_TOKENS = 2048;             // 🔧 FIX 2026.05.09: 768 → 2048 (한국어 ~1,000~1,400자). 답변 끊김 방지.
const MAX_TOKENS_LINEAGE = 4096;     // 🔧 FIX 2026.05.09: 2400 → 4096 (한국어 ~2,000~2,800자). 긴 계보/투어 응답 끊김 방지.
const CANDIDATE_LIMIT_GENERAL = 800;
const CANDIDATE_LIMIT_REGION = 400;
const MIN_TRUST_SCORE = 30;

const REGION_KEYWORDS: Record<string, string[]> = {
  '도쿄': ['도쿄', '동경', 'tokyo', '신주쿠', '시부야', '긴자', '롯폰기', '롯본기',
          '아오야마', '에비스', '하라주쿠', '아카사카', '아자부', '아자부주반',
          '미타', '시바', '시바코엔', '미나토구', '신바시', '하마마츠초',
          '신주쿠구', '시부야구', '주오구', '치요다구',
          '메구로', '메구로구', '나카메구로', '지유가오카',
          '카구라자카', '요츠야', '신오쿠보', '와세다',
          '토라노몬', '다카나와', '시로카네',
          '오모테산도', '진구마에', '다이칸야마',
          '마루노우치', '니혼바시', '교바시', '츠키지', '아키하바라', '칸다'],
  '오사카': ['오사카', '교토', 'osaka', 'kyoto', '난바', '우메다', '교바시', '기온', '신사이바시', '도톤보리', '신마치', '키타하마', '혼마치'],
  '후쿠오카': ['후쿠오카', '하카타', 'fukuoka', '텐진', '나카스', '오호리', '약원', '아카사카(후쿠오카)', '다이묘', '이마이즈미'],
};

const SYSTEM_PROMPT = `당신은 "탐(TAAM)"이라는 미식 컨시어지 AI입니다. 도쿄 호텔 컨시어지 같은 절제된 톤, 그러나 친근하게.

## 절대 규칙
1. **후보 풀 안에서만 추천**: 아래 candidate_pool에 있는 가게만 \`restaurant_ids\`에 포함. 풀에 없는 이름을 만들어내지 말 것.
2. **풀에 매칭 없으면 솔직하게**: "아직 그 지역은 큐레이션이 부족합니다" 답하고 \`restaurant_ids: []\`.
3. **일반 질문은 OK**: 풀에 없는 가게 이름을 사용자가 언급하며 묻는 경우, 일반 지식으로 답해도 되지만 \`restaurant_ids\`에는 풀에서만 고른다.
4. **출력은 JSON만**: 마크다운 코드펜스 없이 순수 JSON 한 덩어리만.

## 매칭 키워드
candidate_pool의 \`genre\`(한국어), \`name\`(한국어), \`name_local\`(일본어/원본) 모두 검색 대상.
사용자가 "라멘" 물으면 genre="라멘" 가게 + name_local에 "ラーメン" 들어간 가게 모두 매칭.

## 갯수 규칙
- "탑10", "5개" 명시 → 정확히 그 숫자만큼.
- 모호한 추천 → 5~7곳.
- 부족하면 풀에서 가능한 만큼 + "현재 큐레이션은 N곳까지입니다".

## 정렬/순위
1. michelin > tabelog_award > hyakumeiten
2. social_mention_count 높음 (인플루언서 검증)
3. verified_by_taam
4. trust 높은 순

## 예약 난이도 컨텍스트
- easy: 별도 언급 X
- hard: "1달 전 예약 권장" 한 줄 자연스럽게
- insider_only: "단골 중심으로 일반 예약 어려움" 솔직하게
사용자가 "예약 가능한 곳만"이라 하면 insider_only 제외.

## 언어 (LANGUAGE)
- **반드시 사용자가 사용한 언어로 응답한다.**
  - 한국어로 질문하면 → 한국어로 답변
  - 영어로 질문하면 → 영어로 답변 (e.g. "Tokyo sushi tonight?" → English response)
  - 일본어로 질문하면 → 일본어로 답변 (e.g. "今夜の寿司は?" → 日本語で回答)
- 가게 이름은 풀에 있는 그대로 사용 (한국어 표기). 영어/일본어 답변 안에서도 한국어 가게 이름을 자연스럽게 인용 가능 ("Jungsik" 같은 로마자 별칭이 있으면 우선).
- 명예/상태 라벨은 답변 언어에 맞춰 번역:
  - EN: "Michelin 3 Stars", "Tabelog Award Gold", "TAAM Verified", "Bib Gourmand"
  - JA: "ミシュラン三つ星", "食ベログアワード ゴールド", "TAAM認証", "ビブグルマン"

## 답변 톤
- 짧고 단단하게. 보통 2~4문장.
- 명예 자연어:
  · hyakumeiten:* → "타베로그 100名店"
  · tabelog_award:gold:* → "타베로그 어워드 골드"
  · taam_verified:* → "TAAM 검증"
  · michelin → "미슐랭 N스타"

## 답변 길이
- 1~3곳: 각 가게 한 줄.
- 4곳 이상: 무드 1문장 + 톱 1~2곳만 짧게.

## 계보·인물 질문 응답 톤 (위 일반 톤보다 우선)
사용자가 특정 쉐프/계보/매장의 「스토리·역사·에피소드·시그니처」를 물으면 (예: "스기타가 누구야?", "아라키 계보 알려줘", "큐베에 시그니처 뭐야?"):
- **딱딱한 사실 나열 금지.** 신문 기사 톤 X.
- **인물 중심 흥미로운 에피소드** + **임팩트 시그니처** + **큐레이션 메모** 톤으로 답변.
- 일반 미식 기사에서 못 보는 인사이드 일화 (첫 만남, 결정적 사건, 어록) 적극 활용.
- 어록·인용은 따옴표로 살릴 것 (예: "식재료가 스스로 말하게 하라").
- 구조: ① 캐치프레이즈 1줄 → ② 핵심 연혁 2~3 글머리 → ③ 인상적 에피소드 1개 → ④ 시그니처 1~2개 → ⑤ 「왜 이 사람/계보를 알아야 하나」 한 줄 마무리.
- **계보 학습 본문(아래 계보 컨텍스트)을 참고**해 인용. 본문에 없는 내용은 만들지 말 것.

HTML: <b>, <i>, <br>. 가게 이름은 <b>.

## 도쿄 지리 컨텍스트 (호텔 인근 추천 시)
같은 구(区) 안 매장은 도보 또는 1-2 정거장 거리 — 인근으로 안내 가능.

- 미나토구(港区): 롯폰기, 미타, 田町, 아카사카, 아자부, 아자부주반, 시바, 시바코엔, 하마마츠초, 신바시, 토라노몬, 다카나와, 시로카네
- 시부야구(渋谷区): 시부야, 하라주쿠, 에비스, 다이칸야마, 오모테산도, 진구마에
- 신주쿠구(新宿区): 신주쿠, 신오쿠보, 요츠야, 카구라자카, 와세다
- 주오구(中央区): 긴자, 츠키지, 니혼바시, 교바시, 츠키시마
- 치요다구(千代田区): 마루노우치, 칸다, 아키하바라, 코지마치
- 메구로구(目黒区): 나카메구로, 지유가오카, 도리츠다이가쿠, 메구로

호텔이 미나토구(롯폰기/아자부 등)에 있으면 같은 미나토구의 미타·신바시·시바 매장도 인근.
인접 구(시부야구↔미나토구)도 1~2 정거장 거리로 추천 가능.

## 라멘 — 런칭 시점 비공개 (2026.05.10 v11)
사용자가 "라멘", "츠케멘", "지로계", "쇼유 라멘", "도쿄 라멘 추천" 등 라멘 관련 질문 시:
- candidate_pool 에 라멘 매장이 없음 (의도적 — 라멘 콘텐츠는 곧 공개 예정).
- 답변 메시지: "🍜 라멘 큐레이션은 곧 공개될 예정입니다. 지금은 스시·텐푸라·일본요리·중식 등을 추천드릴 수 있어요." 같은 톤으로 안내.
- restaurant_ids: [] 로 빈 배열 반환.
- 다른 카테고리로 자연스럽게 유도 ("대신 같은 지역의 스시·텐푸라는 어떠세요?").

## 출력
{"message": "...", "restaurant_ids": ["id1", ...]}
`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    let body: { message?: string; lang?: string };
    try {
      body = await req.json();
    } catch {
      return jsonRes({ ok: false, error: "잘못된 요청 형식" }, 400);
    }
    const message = (body.message || "").trim();
    const lang = (body.lang || "ko").toLowerCase();
    if (!message) return jsonRes({ ok: false, error: "메시지를 입력해주세요" }, 400);
    if (message.length > 1000) return jsonRes({ ok: false, error: "메시지 너무 깁니다" }, 400);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!supabaseUrl || !serviceKey) return jsonRes({ ok: false, error: "서버 환경 오류" }, 500);
    if (!anthropicKey) return jsonRes({ ok: false, error: "Claude API 키 미설정" }, 500);

    const sb = createClient(supabaseUrl, serviceKey);

    // ──────────────────────────────────────────
    // region 키워드 사전 필터
    // ──────────────────────────────────────────
    const msgLower = message.toLowerCase();
    let targetRegion: string | null = null;
    for (const [region, keywords] of Object.entries(REGION_KEYWORDS)) {
      if (keywords.some(k => msgLower.includes(k.toLowerCase()))) {
        targetRegion = region;
        break;
      }
    }

    let q = sb
      .from("restaurants")
      .select(
        "id, name, name_local, region, country_en, city_en, district, genre, genre_en, " +
        "vibe_tags, signature_keywords, best_for, concierge_note, " +
        "local_popularity, trust_score, price_tier, popularity_score, " +
        "list_features, verified_by_taam, michelin, tabelog_score, " +
        "tier, address, " +
        "reservation_difficulty, social_mention_count, social_sources, " +
        "chef_lineage_text, chef_lineage_id"
      )
      .eq("is_active", true);

    if (targetRegion) {
      q = q.eq("region", targetRegion);
    } else {
      q = q.or(`trust_score.gte.${MIN_TRUST_SCORE},verified_by_taam.eq.true`);
    }

    const { data: rests, error: rErr } = await q
      .order("trust_score", { ascending: false, nullsFirst: false })
      .limit(targetRegion ? CANDIDATE_LIMIT_REGION : CANDIDATE_LIMIT_GENERAL);

    if (rErr) {
      console.error("[taam-chat] restaurants 조회 실패:", rErr);
      return jsonRes({ ok: false, error: "데이터 조회 실패" }, 500);
    }

    console.log(
      "[taam-chat] candidate_pool size:",
      (rests || []).length,
      targetRegion ? `(region: ${targetRegion})` : "(general top)"
    );

    const { data: chefs } = await sb.from("chefs").select("id, name, linked_rest_id");
    const chefByRestId: Record<string, string> = {};
    (chefs || []).forEach((c: any) => {
      if (c.linked_rest_id && c.name) chefByRestId[c.linked_rest_id] = c.name;
    });

    const candidatePool = (rests || []).map((r: any) => {
      const item: Record<string, any> = {
        id: r.id,
        name: r.name,
        loc: [r.region, r.district].filter(Boolean).join(" / "),
        genre: r.genre || r.genre_en || "",
        trust: r.trust_score ?? null,
      };
      if (r.name_local && r.name_local !== r.name) item.name_local = r.name_local;
      if (Array.isArray(r.vibe_tags) && r.vibe_tags.length) item.vibe = r.vibe_tags;
      if (Array.isArray(r.signature_keywords) && r.signature_keywords.length) item.keywords = r.signature_keywords;
      if (Array.isArray(r.best_for) && r.best_for.length) item.best_for = r.best_for;
      if (r.concierge_note) item.note = r.concierge_note;
      if (r.local_popularity) item.popularity = r.local_popularity;
      if (r.price_tier) item.price = r.price_tier;
      if (chefByRestId[r.id]) item.chef = chefByRestId[r.id];
      if (Array.isArray(r.list_features) && r.list_features.length) item.list_features = r.list_features;
      if (r.verified_by_taam) item.verified_by_taam = true;
      if (r.michelin) item.michelin = r.michelin;
      if (r.tabelog_score != null) item.tabelog = r.tabelog_score;
      if (r.tier) item.tier = r.tier;
      if (r.reservation_difficulty) item.reservation = r.reservation_difficulty;
      if (r.social_mention_count > 0) item.social = r.social_mention_count;
      // 쉐프 계보 한줄 (chef_lineage_knowledge → restaurants 롤업)
      const lineageLine = getRestaurantLineageLine(r);
      if (lineageLine) item.lineage = lineageLine;
      return item;
    });

    // 사용자 쿼리에서 계보 키워드 감지 → 발행된 계보 지식을 시스템 컨텍스트로 주입
    // (감지 안 되면 빈 문자열 → 시스템 프롬프트 변동 없음)
    const lineageSection = await buildLineageSystemSection(message, sb);
    if (lineageSection) {
      console.log("[taam-chat] lineage section injected:", lineageSection.length, "chars");
    }

    // 🆕 현재 UI 언어 hint (클라이언트가 전달) — Claude 가 응답 언어를 결정할 때 우선 참고
    let langDirective = '';
    if (lang === 'en') {
      langDirective = '## 응답 언어 (CLIENT HINT)\nUser interface language is **English**. Respond in English unless the user clearly typed in another language.';
    } else if (lang === 'ja' || lang === 'jp') {
      langDirective = '## 応答言語 (CLIENT HINT)\nユーザーインターフェース言語は**日本語**です。ユーザーが明らかに別の言語で入力した場合を除き、日本語で回答してください。';
    } else {
      langDirective = '## 응답 언어 (CLIENT HINT)\n사용자 인터페이스 언어는 **한국어**. 사용자가 명백히 다른 언어로 입력하지 않는 한 한국어로 응답.';
    }

    const claudeBody = {
      model: Deno.env.get("ANTHROPIC_MODEL") || DEFAULT_MODEL,
      // 계보 질문일 때만 출력 토큰 확대 (인물 누락 방지)
      max_tokens: lineageSection ? MAX_TOKENS_LINEAGE : MAX_TOKENS,
      system: [
        { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } },
        {
          type: "text",
          text: `## candidate_pool (${candidatePool.length}곳, ${targetRegion || 'general'})\n` + JSON.stringify(candidatePool),
          cache_control: { type: "ephemeral" },
        },
        // 발행된 계보 지식 (쿼리에 계보 키워드 있을 때만 — 캐시 X)
        ...(lineageSection ? [{ type: "text", text: lineageSection }] : []),
        // 🆕 클라이언트 언어 힌트 (캐시 X — 매번 다를 수 있음)
        { type: "text", text: langDirective },
      ],
      messages: [{ role: "user", content: message }],
    };

    const claudeRes = await fetch(ANTHROPIC_API_URL, {
      method: "POST",
      headers: {
        "x-api-key": anthropicKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify(claudeBody),
    });

    if (!claudeRes.ok) {
      const errText = await claudeRes.text();
      console.error("[taam-chat] Claude API 비정상:", claudeRes.status, errText.slice(0, 500));
      let userMsg = "Claude API 에러";
      if (claudeRes.status === 401) userMsg = "API 키 인증 실패";
      else if (claudeRes.status === 429) userMsg = "API 호출 한도 초과";
      else if (claudeRes.status === 529) userMsg = "Claude 일시 과부하";
      return jsonRes({ ok: false, error: userMsg }, 500);
    }

    const claudeData = await claudeRes.json();
    const rawText = claudeData?.content?.[0]?.text || "";
    const usage = claudeData?.usage || {};
    console.log(
      "[taam-chat] Claude usage:",
      JSON.stringify({ input: usage.input_tokens, output: usage.output_tokens, cache_read: usage.cache_read_input_tokens })
    );

    let parsed: { message?: string; restaurant_ids?: string[] } | null = null;
    try {
      const cleaned = rawText.replace(/^\s*```(?:json)?\s*/i, "").replace(/\s*```\s*$/i, "").trim();
      parsed = JSON.parse(cleaned);
    } catch {
      console.warn("[taam-chat] JSON 파싱 실패:", rawText.slice(0, 200));
      return jsonRes({ ok: true, message: escapeBasic(rawText) || "(응답 파싱 실패)", restaurants: [] });
    }

    const responseMessage = (parsed && typeof parsed.message === "string") ? parsed.message : "";
    const chosenIds = (parsed && Array.isArray(parsed.restaurant_ids))
      ? parsed.restaurant_ids.filter((x) => typeof x === "string" && x.length > 0)
      : [];

    console.log("[taam-chat] Claude chose", chosenIds.length, "ids");

    let restaurants: any[] = [];
    if (chosenIds.length > 0) {
      const { data: fullRests } = await sb
        .from("restaurants")
        .select(
          "id, name, name_local, region, country_en, city_en, district, genre, genre_en, " +
          "lat, lng, photo_hero, photo_card, image_url, " +
          "trust_score, google_rating, price_tier, " +
          "address, phone, hours, " +
          "list_features, verified_by_taam, " +
          "michelin, tabelog_score, tier, " +
          "google_review_count, concierge_note, " +
          "reservation_difficulty, social_mention_count, " +
          "chef_lineage_text, chef_lineage_id"
        )
        .in("id", chosenIds);

      const byId: Record<string, any> = {};
      (fullRests || []).forEach((r: any) => { byId[r.id] = r; });
      restaurants = chosenIds
        .map((id) => byId[id])
        .filter(Boolean)
        .map((r: any) => ({
          id: r.id,
          name: r.name,
          name_local: r.name_local || null,
          region: r.region || null,
          city_en: r.city_en || "",
          district: r.district || "",
          genre: r.genre || r.genre_en || "",
          lat: r.lat ?? null,
          lng: r.lng ?? null,
          photoHero: r.photo_hero || null,
          photoCard: r.photo_card || r.image_url || null,
          photo: r.photo_card || r.image_url || null,
          chef_name: chefByRestId[r.id] || null,
          trust_score: r.trust_score ?? null,
          google_rating: r.google_rating ?? null,
          price_tier: r.price_tier || null,
          address: r.address || null,
          phone: r.phone || null,
          hours: r.hours || null,
          list_features: Array.isArray(r.list_features) ? r.list_features : [],
          verified_by_taam: !!r.verified_by_taam,
          michelin: r.michelin || null,
          tabelog_score: r.tabelog_score ?? null,
          tier: r.tier || null,
          google_review_count: r.google_review_count ?? null,
          concierge_note: r.concierge_note || null,
          reservation_difficulty: r.reservation_difficulty || null,
          social_mention_count: r.social_mention_count ?? 0,
          chef_lineage_text: r.chef_lineage_text || null,
          chef_lineage_id: r.chef_lineage_id || null,
        }));
    }

    return jsonRes({
      ok: true,
      message: responseMessage || "(응답이 비어있습니다)",
      restaurants,
    });

  } catch (e) {
    console.error("[taam-chat] 예외:", e);
    const msg = e instanceof Error ? e.message : String(e);
    return jsonRes({ ok: false, error: "서버 오류: " + msg }, 500);
  }
});

function jsonRes(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function escapeBasic(s: string): string {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .slice(0, 2000);
}