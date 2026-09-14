// ═══════════════════════════════════════════════════════════════
// TAAM — 메모 정형화 Edge Function (어드민/슈퍼어드민 전용)
// 함수명: taam-format
//
// 역할:
//   어드민이 매장에 대한 자유 메모를 입력 → Claude가 restaurants 테이블
//   스키마에 맞춰 구조화. 블로거/유튜버 컨텐츠 인풋용으로도 활용.
//
// 호출 흐름:
//   프론트(taamFormatMemo) → Edge Function →
//   ① 권한 검증 (호출자가 admin 또는 superadmin)
//   ② Claude API 호출 (구조화 JSON 강제)
//   ③ [선택] Google Places API 매칭 (place_id, lat/lng, rating 보강)
//   ④ trust_score 재계산 (breakdown 합산 + verified 보너스)
//   ⑤ { ok, data, google_found, raw } 반환
//
// 보안:
//   - JWT 검증 ON 으로 배포
//   - 호출자 user_id로 profiles.role 확인 — 'admin' 또는 'superadmin'/'super_admin' 만 허용
//   - 🆕 2026-09-14 회원당 시간당 30회 (taam_rate_hit · 함수 없으면 통과) · 예외 원문 비노출
//   - 응답의 문자열은 앱이 전부 이스케이프해서 그린다 (index.html taamRenderResultCard)
//
// 2026-09-14 까지 소스가 대시보드에만 있었다. 그날 저장소로 가져왔다 — 여기 파일이 원본이다.
//
// 환경변수 (Supabase Edge Function Secrets):
//   - ANTHROPIC_API_KEY      (필수)
//   - ANTHROPIC_MODEL        (선택, 기본값: claude-sonnet-4-6)
//   - GOOGLE_PLACES_API_KEY  (선택 — 없으면 Google 매칭 스킵)
//   - SUPABASE_URL           (자동)
//   - SUPABASE_SERVICE_ROLE_KEY (자동)
// ═══════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const DEFAULT_MODEL = "claude-sonnet-4-6";
const MAX_MEMO_LEN = 5000; // 블로거/유튜버 본문 인풋도 받을 수 있도록 여유롭게

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // ────────────────────────────────────────
    // 입력 검증
    // ────────────────────────────────────────
    const body = await req.json();
    const memo = (body.memo || "").trim();
    const verifiedByTaam = !!body.verified_by_taam;

    if (!memo) {
      return jsonRes({ ok: false, error: "메모를 입력해주세요" }, 400);
    }
    if (memo.length > MAX_MEMO_LEN) {
      return jsonRes(
        { ok: false, error: `메모가 너무 깁니다 (${MAX_MEMO_LEN}자 초과)` },
        400,
      );
    }

    // ────────────────────────────────────────
    // 환경변수
    // ────────────────────────────────────────
    const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!anthropicKey) {
      console.error("[taam-format] ANTHROPIC_API_KEY 미설정");
      return jsonRes({ ok: false, error: "서버 설정 오류 (API 키 없음)" }, 500);
    }
    const model = Deno.env.get("ANTHROPIC_MODEL") || DEFAULT_MODEL;
    const googleKey = Deno.env.get("GOOGLE_PLACES_API_KEY"); // 없어도 OK

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const sb = createClient(supabaseUrl, serviceKey);

    // ────────────────────────────────────────
    // 권한 검증 — 호출자가 admin 또는 superadmin이어야 함
    // ────────────────────────────────────────
    const authHeader = req.headers.get("Authorization") || "";
    if (!authHeader.startsWith("Bearer ")) {
      return jsonRes({ ok: false, error: "로그인이 필요합니다" }, 401);
    }
    const token = authHeader.slice(7);
    const { data: userData, error: uErr } = await sb.auth.getUser(token);
    if (uErr || !userData?.user) {
      return jsonRes({ ok: false, error: "인증 실패" }, 401);
    }
    const userId = userData.user.id;
    const { data: profile, error: pErr } = await sb
      .from("profiles")
      .select("role")
      .eq("id", userId)
      .single();
    if (pErr || !profile) {
      return jsonRes({ ok: false, error: "프로필 조회 실패" }, 403);
    }
    // role 값은 환경에 따라 'superadmin' / 'super_admin' 둘 다 있다 (CLAUDE.md) — 둘 다 받는다
    const role = String(profile.role || "");
    if (role !== "admin" && role !== "superadmin" && role !== "super_admin") {
      return jsonRes({ ok: false, error: "어드민 권한 필요" }, 403);
    }

    // 🆕 2026-09-14 속도 제한 — 호출 1회 = Claude 1회 + Google 1회. 어드민 토큰이 새면 비용 공격이 된다.
    //   taam_rate_hit 는 audit_hardening_2026-09-13.sql 이 만든다 (service_role 실행 가능). 없으면 통과.
    try {
      const { data: allowed, error: rlErr } = await sb.rpc("taam_rate_hit", {
        p_key: "taam-format:" + userId, p_limit: 30, p_window: "1 hour",
      });
      if (!rlErr && allowed === false) {
        return jsonRes({ ok: false, error: "요청이 너무 잦습니다. 잠시 후 다시 시도해주세요" }, 429);
      }
    } catch (_e) { /* 제한기 미설치·오류 → 통과 */ }

    // ────────────────────────────────────────
    // ① Claude 호출 — 메모 정형화
    // ────────────────────────────────────────
    const systemPrompt = `당신은 TAAM 어드민의 데이터 정형화 어시스턴트입니다. 어드민이 입력한 자유 메모(또는 블로거/유튜버 컨텐츠 발췌)를 받아, TAAM의 restaurants 데이터베이스 스키마에 맞춰 구조화된 JSON으로 변환합니다.

# 정형화 원칙
- 메모에 명시된 정보만 사용. 추측은 금지. 정보 없으면 null 또는 빈 배열.
- 한국어 가게명은 한국어 그대로, 일본어/영문 가게명은 원문 유지
- city_en, country_en, genre_en은 영문 (예: "Tokyo", "Japan", "Sushi")
- district는 현지 표기 (예: "강남구", "Roppongi", "Marais")
- vibe_tags: 분위기 형용사 한국어로 (예: "데이트", "아늑한", "캐주얼")
- signature_keywords: 시그니처 메뉴/특징 (예: "한우오마카세", "흑돼지", "오마카세")
- best_for: 추천 상황 (예: "데이트", "비즈니스", "혼밥", "기념일")

# local_popularity 분류 (4단계)
- "tourist_trap": 관광객 위주, 현지인 외면 (인스타용 핫플)
- "mixed": 관광객도 현지인도 가는 곳
- "local_favorite": 현지인이 일상적으로 가는 곳
- "hidden_gem": 숨은 명소, 알 만한 사람만 아는 곳

# trust_score_breakdown 가중치 (각 항목 0이상 정수)
메모 내용 + Google 데이터(있을 시)에서 추정. 합산 = trust_score (0-100):
- google_rating: Google 평점 4.5+ → 15점, 4.0-4.5 → 10점, 미만 → 5점
- google_reviews: 1000+ → 15점, 500-1000 → 10점, 100-500 → 5점
- tabelog: 食べログ 점수 메모에 언급되면 3.5+ → 15점, 3.0-3.5 → 10점
- michelin: 미슐랭 별/빕구르망 언급 → 별 1개=20점, 2개=30점, 3개=40점, 빕구르망=10점
- list_features: 'Asia 50 Best' 같은 권위 리스트 등재 → 10-20점
- taam_verified: 어드민이 직접 가본 곳(verified=true)이면 +20점, 아니면 0

# 응답 형식 (필수)
**다른 텍스트 없이 오직 JSON만 반환. 코드 펜스도 쓰지 말 것.**

{
  "name": "가게 이름 (현지어 그대로)",
  "country_en": "Country in English",
  "city_en": "City in English",
  "district": "지역구/동/지구 (현지 표기)",
  "genre_en": "Cuisine genre in English",
  "price_tier": "$" | "$$" | "$$$" | "$$$$",
  "popularity_score": 0-10 정수,
  "signature_keywords": ["문자열 배열"],
  "vibe_tags": ["문자열 배열"],
  "best_for": ["문자열 배열"],
  "concierge_note": "TAAM 톤의 추천 멘트 1-2문장 (절제되고 인사이트 있게)",
  "local_popularity": "tourist_trap" | "mixed" | "local_favorite" | "hidden_gem",
  "trust_score_breakdown": {
    "google_rating": 정수,
    "google_reviews": 정수,
    "tabelog": 정수,
    "michelin": 정수,
    "list_features": 정수,
    "taam_verified": 정수
  },
  "trust_score": 정수 (위 breakdown 합산, 최대 100)
}`;

    const userPrompt = `메모:
"""
${memo}
"""

어드민 검증 (직접 가본 곳): ${verifiedByTaam ? "예" : "아니오"}

위 메모를 정형화해주세요.`;

    const claudeBody = {
      model: model,
      max_tokens: 1500,
      system: systemPrompt,
      messages: [{ role: "user", content: userPrompt }],
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
      console.error("[taam-format] Claude API 실패:", claudeRes.status, errText.slice(0, 500));
      return jsonRes({ ok: false, error: "AI 정형화 실패" }, 502);
    }

    const claudeData = await claudeRes.json();
    const claudeText = claudeData?.content?.[0]?.text || "";

    if (claudeData.usage) {
      console.log(
        "[taam-format] tokens:",
        "input=" + (claudeData.usage.input_tokens || 0),
        "output=" + (claudeData.usage.output_tokens || 0),
      );
    }

    // ────────────────────────────────────────
    // ② JSON 파싱
    // ────────────────────────────────────────
    let parsed: any;
    try {
      const cleaned = claudeText.replace(/```json\s*|\s*```/g, "").trim();
      parsed = JSON.parse(cleaned);
    } catch (e) {
      console.error("[taam-format] JSON 파싱 실패. raw:", claudeText.slice(0, 300));
      // raw 는 어드민 디버깅용 — 앱이 이스케이프해서 <pre> 에 넣는다
      return jsonRes({
        ok: false,
        error: "AI 응답을 JSON으로 파싱하지 못했습니다. 다시 시도해주세요",
        raw: claudeText.slice(0, 1000),
      });
    }

    // verified_by_taam은 입력값 그대로 데이터에 박음 (LLM이 잘못 판단할 수 있음)
    parsed.verified_by_taam = verifiedByTaam;
    if (verifiedByTaam) {
      // taam_verified 보너스 강제 부여 (LLM이 누락했더라도)
      parsed.trust_score_breakdown = parsed.trust_score_breakdown || {};
      if (!parsed.trust_score_breakdown.taam_verified) {
        parsed.trust_score_breakdown.taam_verified = 20;
      }
    }

    // ────────────────────────────────────────
    // ③ Google Places 매칭 (선택적)
    // ────────────────────────────────────────
    let googleFound = false;
    if (googleKey && parsed.name) {
      try {
        const queryParts = [
          parsed.name,
          parsed.district,
          parsed.city_en,
          parsed.country_en,
        ].filter(Boolean).join(" ");

        // Places API (New) - Text Search
        const gRes = await fetch(
          "https://places.googleapis.com/v1/places:searchText",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-Goog-Api-Key": googleKey,
              "X-Goog-FieldMask":
                "places.id,places.displayName,places.location,places.rating,places.userRatingCount,places.formattedAddress",
            },
            body: JSON.stringify({ textQuery: queryParts, maxResultCount: 1 }),
          },
        );

        if (gRes.ok) {
          const gData = await gRes.json();
          const top = gData?.places?.[0];
          if (top) {
            parsed.google_place_id = top.id;
            parsed.google_rating = top.rating || parsed.google_rating;
            parsed.google_review_count = top.userRatingCount || parsed.google_review_count;
            // 좌표는 별도 변수로 (restaurants 테이블에 lat/lng 컬럼)
            if (top.location) {
              parsed.lat = top.location.latitude;
              parsed.lng = top.location.longitude;
            }
            if (top.formattedAddress) {
              parsed.address = top.formattedAddress;
            }
            googleFound = true;

            // Google 데이터로 trust_score_breakdown 재계산 (LLM 추정값보다 실측치 우선)
            const bk = parsed.trust_score_breakdown || {};
            const r = parsed.google_rating || 0;
            const n = parsed.google_review_count || 0;
            bk.google_rating = r >= 4.5 ? 15 : r >= 4.0 ? 10 : r >= 3.5 ? 5 : 0;
            bk.google_reviews = n >= 1000 ? 15 : n >= 500 ? 10 : n >= 100 ? 5 : 0;
            parsed.trust_score_breakdown = bk;
          }
        } else {
          console.warn("[taam-format] Google Places 응답 실패:", gRes.status);
        }
      } catch (gErr) {
        console.warn("[taam-format] Google Places 호출 예외 (무시):", gErr);
      }
    }

    // ────────────────────────────────────────
    // ④ trust_score 합산 (breakdown 기반 — 백엔드 결정값)
    // ────────────────────────────────────────
    const bk = parsed.trust_score_breakdown || {};
    const sum = (Object.values(bk) as number[]).reduce(
      (a, b) => a + (typeof b === "number" ? b : 0),
      0,
    );
    parsed.trust_score = Math.min(100, Math.max(0, Math.round(sum)));

    // ────────────────────────────────────────
    // ⑤ 응답
    // ────────────────────────────────────────
    return jsonRes({
      ok: true,
      data: parsed,
      google_found: googleFound,
    });
  } catch (e) {
    // 🔒 예외 원문(내부 URL·스택)은 로그에만
    console.error("[taam-format] 예외:", e);
    return jsonRes({ ok: false, error: "서버 오류가 났습니다. 잠시 후 다시 시도해주세요" }, 500);
  }
});

function jsonRes(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
