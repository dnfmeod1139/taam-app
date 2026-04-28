import Anthropic from "@anthropic-ai/sdk";
import { createClient } from "@supabase/supabase-js";

const SUPABASE_URL = "https://edfsmzbcixfnqabrsvut.supabase.co";
const SUPABASE_KEY = "sb_publishable_NlJp3lRtSVvkgFGRBesoog_q4XlGEPC";

const SYSTEM_PROMPT = `너는 TAAM의 컨시어지 AI "탐(Taam)"이야.
한국·일본의 F&B 멤버십 컨시어지로, 회원이 자연어로 묻는 질문에 답하고 적합한 가게를 추천해.

[정체성]
- 한국인이 일본 갈 때, 일본인이 한국 올 때 사이드 캐주얼 식사를 추천하는 게 주 역할.
- 비싼 메인 코스는 TAAM 티켓이 따로 있음 (네 영역 아님).
- 마케팅으로 떠 있는 곳보다 푸디·로컬이 인정하는 곳을 우선.

[작업 흐름]
사용자 메시지에서 의도 파악 → search_restaurants 도구 호출 → 결과를 자연스럽게 풀어 응답.
- 도시·지역·장르·가격대·분위기 키워드 추출.
- 검색 결과 없으면 솔직히 "데이터에 적합한 곳이 없어요" 라고 답하고, 비슷한 옵션 제안.
- DB에 없는 가게는 절대 만들어내지 마. 할루시네이션 금지.

[응답 톤]
- 사용자 언어 자동 감지 (한국어/일본어/영어)
- 따뜻하고 박식한 컨시어지 톤. 짧고 명확하게.
- 가게 추천 시: 추천 이유 한 줄 + 가게 1-3곳 언급 (이름·구역·간단한 매력).
- "지도에 표시했어요" 같은 안내는 자연스럽게 포함.

[금지]
- 가격·영업시간 추측해서 단정 X.
- 멤버십 등급 분기는 다음 단계에서 처리. 지금은 안내만.

[TAAM 계보도 셰프]
- 검색 결과에 chef_name 필드 있으면 = TAAM 스시 계보도에 등재된 셰프의 가게.
- 이런 가게는 응답에 자연스럽게 셰프 이름 언급. 예: "○○ 셰프의 가게로, ..."
- TAAM 큐레이션 신뢰도 최상위. 적극 추천.
`;

const TOOL_SEARCH_RESTAURANTS = {
  name: "search_restaurants",
  description: "TAAM이 큐레이션한 레스토랑 DB에서 조건에 맞는 가게 검색. 신뢰 점수와 로컬 인기도 기반.",
  input_schema: {
    type: "object",
    properties: {
      country: { type: "string", enum: ["korea", "japan"], description: "korea 또는 japan" },
      city: { type: "string", description: "도시명 영문 (Seoul, Tokyo, Osaka 등)" },
      genre: { type: "string", description: "장르 영문 (ramen, sushi, korean_pork_bbq 등)" },
      keywords: { type: "array", items: { type: "string" }, description: "검색 키워드 배열 (한국어 OK)" },
      min_trust_score: { type: "number", description: "최소 trust_score (기본 50)" },
      limit: { type: "number", description: "최대 결과 수 (기본 5)" }
    }
  }
};

async function searchRestaurants(input, sb) {
  let query = sb.from('restaurants').select(
    'id, name, country_en, city_en, district, genre_en, price_tier, popularity_score, ' +
    'signature_keywords, vibe_tags, best_for, concierge_note, local_popularity, ' +
    'google_rating, google_review_count, trust_score, ' +
    'lat, lng, photoHero, photo'
  ).eq('is_concierge_active', true);
  
  if (input.country) query = query.eq('country_en', input.country);
  if (input.city) query = query.ilike('city_en', input.city);
  if (input.genre) query = query.eq('genre_en', input.genre);
  
  query = query.gte('trust_score', input.min_trust_score || 50);
  query = query.in('local_popularity', ['local_favorite', 'hidden_gem', 'mixed']);
  query = query.order('trust_score', { ascending: false });
  query = query.limit(input.limit || 5);
  
  const { data, error } = await query;
  if (error) {
    console.error('[searchRestaurants]', error);
    return { error: error.message, results: [] };
  }
  
  let results = data || [];
  
  if (input.keywords && input.keywords.length > 0) {
    const kws = input.keywords.map(k => k.toLowerCase());
    results = results.filter(r => {
      const hay = [
        r.name, r.district, r.concierge_note,
        ...(r.signature_keywords || []),
        ...(r.vibe_tags || []),
        ...(r.best_for || [])
      ].join(' ').toLowerCase();
      return kws.some(kw => hay.includes(kw));
    });
  }
  
  results = results.slice(0, input.limit || 5);
  
  // 계보도 셰프 정보 통합 — chefs.linked_rest_id 로 매칭
  if (results.length > 0) {
    const restIds = results.map(r => r.id);
    const chefRes = await sb.from('chefs')
      .select('id, name, sub_title, linked_rest_id')
      .in('linked_rest_id', restIds);
    
    if (chefRes.data && chefRes.data.length > 0) {
      const chefByRest = {};
      chefRes.data.forEach(c => { chefByRest[c.linked_rest_id] = c; });
      results.forEach(r => {
        const c = chefByRest[r.id];
        if (c) {
          r.chef_name = c.name;
          r.chef_id = c.id;
          r.chef_sub_title = c.sub_title;
        }
      });
    }
  }
  
  return { results: results };
}

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  
  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  
  const { message } = req.body || {};
  if (!message || typeof message !== "string") {
    return res.status(400).json({ error: "message 필드 필요" });
  }
  
  if (!process.env.ANTHROPIC_API_KEY) {
    return res.status(500).json({ error: "ANTHROPIC_API_KEY 환경변수 없음" });
  }
  
  try {
    const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
    const sb = createClient(SUPABASE_URL, SUPABASE_KEY);
    
    let messages = [{ role: "user", content: message }];
    let foundRestaurants = [];
    let finalText = "";
    let usage = null;
    
    for (let i = 0; i < 3; i++) {
      const response = await client.messages.create({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 1500,
        system: SYSTEM_PROMPT,
        tools: [TOOL_SEARCH_RESTAURANTS],
        messages: messages
      });
      
      usage = response.usage;
      
      if (response.stop_reason === "tool_use") {
        const toolBlock = response.content.find(b => b.type === "tool_use");
        if (!toolBlock) break;
        
        let toolResult;
        if (toolBlock.name === "search_restaurants") {
          const r = await searchRestaurants(toolBlock.input, sb);
          if (r.results) foundRestaurants = r.results;
          toolResult = JSON.stringify(r);
        } else {
          toolResult = JSON.stringify({ error: "Unknown tool" });
        }
        
        messages.push({ role: "assistant", content: response.content });
        messages.push({
          role: "user",
          content: [{ type: "tool_result", tool_use_id: toolBlock.id, content: toolResult }]
        });
      } else {
        finalText = response.content
          .filter(b => b.type === "text")
          .map(b => b.text)
          .join("")
          .trim();
        break;
      }
    }
    
    return res.status(200).json({
      ok: true,
      message: finalText.replace(/\n/g, '<br>'),
      restaurants: foundRestaurants,
      usage: usage
    });
  } catch (err) {
    console.error('[taam-chat]', err);
    return res.status(500).json({ error: err.message || "Unknown error" });
  }
}
