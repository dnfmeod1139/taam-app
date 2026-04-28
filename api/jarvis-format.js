import Anthropic from "@anthropic-ai/sdk";

// ============================================================
// Google Places API 헬퍼
// ============================================================
async function googlePlacesSearch(query, apiKey) {
  try {
    let placeId = null;
    
    // 일본어 우선 시도
    for (const lang of ['ja', 'ko', 'en']) {
      const url = `https://maps.googleapis.com/maps/api/place/findplacefromtext/json?` +
        `input=${encodeURIComponent(query)}&inputtype=textquery&` +
        `fields=place_id&language=${lang}&key=${apiKey}`;
      const res = await fetch(url);
      const data = await res.json();
      if (data.candidates && data.candidates.length > 0) {
        placeId = data.candidates[0].place_id;
        break;
      }
    }
    if (!placeId) return null;
    
    // 상세 정보
    const detailsUrl = `https://maps.googleapis.com/maps/api/place/details/json?` +
      `place_id=${placeId}&` +
      `fields=place_id,name,formatted_address,geometry,rating,user_ratings_total,types,price_level,website&` +
      `language=ko&key=${apiKey}`;
    const detailsRes = await fetch(detailsUrl);
    const detailsData = await detailsRes.json();
    
    if (detailsData.status !== 'OK') return null;
    return detailsData.result;
  } catch (err) {
    console.error('[googlePlacesSearch]', err.message);
    return null;
  }
}

// ============================================================
// trust_score 자동 계산
// ============================================================
function calcTrustScore(data) {
  let score = 0;
  const breakdown = {};
  
  if (data.google_rating != null) {
    let pts = 0;
    if (data.google_rating >= 4.5) pts = 15;
    else if (data.google_rating >= 4.3) pts = 10;
    else if (data.google_rating >= 4.0) pts = 5;
    if (pts > 0) { score += pts; breakdown.google_rating = pts; }
  }
  
  if (data.google_review_count != null) {
    let pts = 0;
    if (data.google_review_count >= 1000) pts = 10;
    else if (data.google_review_count >= 300) pts = 7;
    else if (data.google_review_count >= 100) pts = 5;
    if (pts > 0) { score += pts; breakdown.google_reviews = pts; }
  }
  
  if (data.tabelog_score != null) {
    let pts = 0;
    if (data.tabelog_score >= 3.7) pts = 30;
    else if (data.tabelog_score >= 3.5) pts = 20;
    else if (data.tabelog_score >= 3.3) pts = 10;
    if (pts > 0) { score += pts; breakdown.tabelog = pts; }
  }
  
  if (data.michelin && data.michelin !== 'none') {
    let pts = 0;
    if (data.michelin.startsWith('star')) pts = 30;
    else if (data.michelin === 'bib_gourmand') pts = 20;
    else if (data.michelin === 'recommended') pts = 10;
    if (pts > 0) { score += pts; breakdown.michelin = pts; }
  }
  
  if (Array.isArray(data.list_features) && data.list_features.length > 0) {
    const pts = Math.min(data.list_features.length * 7, 20);
    score += pts;
    breakdown.list_features = pts;
  }
  
  if (data.verified_by_taam) {
    score += 20;
    breakdown.taam_verified = 20;
  }
  
  return { score: Math.min(Math.round(score), 100), breakdown };
}

// ============================================================
// 시스템 프롬프트
// ============================================================
const SYSTEM_PROMPT = `너는 TAAM의 컨시어지 AI "탐(Taam)"의 데이터 입력 어시스턴트야.
우종님(슈퍼어드민)의 짧은 메모와 Google Places 자동 수집 데이터를 받아서
TAAM의 큐레이션 철학에 맞는 정형 JSON으로 변환해.

[TAAM 큐레이션 철학]
- 마케팅으로 떠 있는 곳 X. 푸디·로컬이 인정하는 곳 O.
- 한국인이 일본 갈 때, 일본인이 한국 올 때 사이드용 캐주얼 식사가 핵심.
- 비싼 메인 코스는 TAAM 티켓이 따로 있음.

[출력 — 마크다운 코드블록 없이 순수 JSON만]
{
  "name": "가게명 (현지 표기)",
  "country_en": "korea | japan",
  "city_en": "Seoul | Busan | Tokyo | Osaka | Kyoto | Fukuoka 등 영문",
  "district": "동/구 단위",
  "genre_en": "korean_pork_bbq | korean_bbq | korean_traditional | korean_hanjeongsik | ramen | sushi | tempura | izakaya | omakase | yakitori | tonkatsu | soba | udon | unagi | italian | french | etc",
  "price_tier": "$ | $$ | $$$ | $$$$",
  "popularity_score": 1~10 정수,
  "signature_keywords": ["키워드"] 2~5개,
  "vibe_tags": ["분위기"] 1~3개,
  "best_for": ["적합상황"] 1~3개,
  "concierge_note": "탐이 회원에게 추천 시 참고할 자유 서술 100~250자 한국어",
  "local_popularity": "tourist_trap | mixed | local_favorite | hidden_gem"
}

[규칙]
- popularity_score: 메모에 "핫", "인기", "1순위" 또는 Google 평점 4.5+ / 리뷰 1000+이면 8~10. 그 외 5~7.
- price_tier (한국): 1인 4만원 이하 $, 4~8만원 $$, 8~15만원 $$$, 15만원+ $$$$.
- price_tier (일본): 1인 3000엔 이하 $, 3000~8000엔 $$, 8000~15000엔 $$$, 15000엔+ $$$$.
- vibe_tags 풀: 데이트, 비즈니스, 감성, 가성비, 프리미엄, 캐주얼, 모던, 전통, 분위기있는, 활기찬, 조용한, 뷰맛집.
- best_for 풀: 커플, 4인, 혼밥, 회식, 가족, 특별한 날, 출장, 친구.
- local_popularity 판단:
  * tourist_trap: 마케팅으로 떠 있고 외국인 관광객 비중 높음.
  * mixed: 관광객도 가지만 로컬도 가는 곳.
  * local_favorite: 로컬이 사랑하는 곳. "로컬", "현지인 인기", "푸디" 신호.
  * hidden_gem: 잘 안 알려진 진짜 좋은 곳.
- concierge_note: 핵심 매력 + 누구에게 좋은지 한 단락. 추정 부분은 [추정] 표기.
- 도시명·지역명은 Google formatted_address를 우선 신뢰.
- 메모와 Google 데이터에도 없으면 빈 문자열 또는 빈 배열.
`;

// ============================================================
// 메인 핸들러
// ============================================================
export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  const { memo, verified_by_taam } = req.body || {};
  if (!memo || typeof memo !== "string" || memo.trim().length < 3) {
    return res.status(400).json({ error: "memo 필드가 필요합니다 (3자 이상)" });
  }

  if (!process.env.ANTHROPIC_API_KEY) {
    return res.status(500).json({ error: "ANTHROPIC_API_KEY 환경변수 없음" });
  }
  if (!process.env.GOOGLE_MAPS_API_KEY) {
    return res.status(500).json({ error: "GOOGLE_MAPS_API_KEY 환경변수 없음" });
  }

  try {
    // 1. Google Places로 객관 데이터
    const googleData = await googlePlacesSearch(memo.trim(), process.env.GOOGLE_MAPS_API_KEY);

    // 2. Claude 정형화
    const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

    const userMessage = `[우종님 메모]
${memo.trim()}

[Google Places 자동 수집]
${googleData ? JSON.stringify({
  name: googleData.name,
  address: googleData.formatted_address,
  rating: googleData.rating,
  review_count: googleData.user_ratings_total,
  price_level: googleData.price_level,
  types: googleData.types,
  location: googleData.geometry?.location,
  website: googleData.website
}, null, 2) : "Google 매칭 결과 없음. 메모만 사용."}

위 정보로 정형 JSON만 출력.`;

    const message = await client.messages.create({
      model: "claude-sonnet-4-5",
      max_tokens: 1500,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: userMessage }]
    });

    const rawText = message.content
      .filter(b => b.type === "text")
      .map(b => b.text)
      .join("")
      .trim();

    const cleanText = rawText
      .replace(/^```json\s*/i, "")
      .replace(/^```\s*/i, "")
      .replace(/```$/, "")
      .trim();

    let parsed;
    try {
      parsed = JSON.parse(cleanText);
    } catch (e) {
      return res.status(500).json({
        error: "Claude의 JSON 파싱 실패",
        raw: rawText
      });
    }

    // 3. 객관 데이터 병합
    if (googleData) {
      parsed.google_place_id = googleData.place_id;
      parsed.google_rating = googleData.rating || null;
      parsed.google_review_count = googleData.user_ratings_total || null;
    }
    
    // 4. trust_score 자동 계산
    const verified = verified_by_taam === true;
    const trustData = {
      google_rating: parsed.google_rating,
      google_review_count: parsed.google_review_count,
      verified_by_taam: verified
    };
    const { score, breakdown } = calcTrustScore(trustData);
    parsed.trust_score = score;
    parsed.trust_score_breakdown = breakdown;
    parsed.verified_by_taam = verified;
    parsed.source_type = 'taam_personal';
    parsed.is_concierge_active = true;

    return res.status(200).json({
      ok: true,
      data: parsed,
      google_found: !!googleData,
      usage: message.usage
    });
  } catch (err) {
    console.error("[taam-format]", err);
    return res.status(500).json({
      error: err.message || "Unknown error",
      type: err.constructor?.name
    });
  }
}
