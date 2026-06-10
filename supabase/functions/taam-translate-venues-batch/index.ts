// ════════════════════════════════════════════════════════════════
// taam-translate-venues-batch — venues 테이블 일괄 AI 번역
// ────────────────────────────────────────────────────────────────
// venues 테이블의 KO 필드를 EN/JP 로 일괄 번역해서 자동 채워넣는다.
// 기존 taam-translate Edge Function 을 내부에서 재사용 (도메인 가이드 공유).
//
// 호출:
//   POST or GET /functions/v1/taam-translate-venues-batch
//   - 인증: SUPABASE_SERVICE_ROLE_KEY (admin only)
//   - Body (optional): { batch_size?: number, only_pending?: boolean, venue_ids?: string[] }
//
// 동작:
//   1) venues 에서 번역 필요한 row 가져오기
//      - i18n_status_en/_jp 가 'pending' 또는 NULL
//      - 또는 venue_ids 가 명시되면 그것들만
//   2) 각 venue 마다:
//      - 비어있는 EN/JP 필드 확인 (name, style_summary, holistic_signature, neighborhood)
//      - taam-translate 호출 → 결과 받기
//      - venues UPDATE (EN/JP + i18n_status='ai_draft' + i18n_updated_at)
//   3) 남은 venues 수 반환 (반복 호출용)
//
// 응답:
//   {
//     ok: true,
//     processed: 5,
//     remaining: 23,    // 0 이면 완료
//     done: false,
//     results: [ { venue_id, translated: [...], skipped?, error? } ]
//   }
//
// 권장 운영:
//   - 어드민 페이지의 "venues 자동 번역" 버튼이 done:false 동안 반복 호출
//   - 또는 pg_cron 으로 매일 새벽 1회 자동 실행
//
// 환경 변수:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (필수)
//   ANTHROPIC_API_KEY                         (taam-translate 가 사용)
// ════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

// 한 번에 처리할 venues 수 (Edge Function 5분 제한 + Claude API 응답 4096 토큰 고려)
const DEFAULT_BATCH_SIZE = 5;
const MAX_BATCH_SIZE     = 10;

// venues 테이블에서 다국어 처리할 필드 정의
// (KO 컬럼 이름, romanize 여부, kind=array 여부)
const TRANSLATABLE_FIELDS: Array<{
  base: string;        // 컬럼 prefix (예: 'name' → name_ko/_en/_jp)
  koCol: string;       // KO 원본 컬럼명
  romanize?: boolean;  // 매장명·지명 → 로마자/카타카나
  kind?: "text" | "array";
}> = [
  { base: "name",                 koCol: "name_ko",                 romanize: true },
  { base: "style_summary",        koCol: "style_summary_ko" },
  { base: "holistic_signature",   koCol: "holistic_signature_ko" },
  { base: "neighborhood",         koCol: "neighborhood",           romanize: true },
];

interface ReqBody {
  batch_size?: number;
  only_pending?: boolean;
  venue_ids?: string[];
}

interface ProcessResult {
  venue_id: string;
  translated?: string[];
  skipped?: boolean;
  reason?: string;
  error?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST" && req.method !== "GET") {
    return jsonResp({ error: "POST or GET only" }, 405);
  }

  if (!SUPABASE_URL || !SERVICE_KEY) {
    return jsonResp({ error: "SUPABASE_URL/SERVICE_ROLE_KEY 미설정" }, 500);
  }

  // ── 옵션 파싱 ──
  let body: ReqBody = {};
  if (req.method === "POST") {
    try {
      body = await req.json();
    } catch (_) { /* empty body OK */ }
  } else {
    // GET — query string 파싱
    const url = new URL(req.url);
    const bs = url.searchParams.get("batch_size");
    if (bs) body.batch_size = parseInt(bs);
    const op = url.searchParams.get("only_pending");
    if (op !== null) body.only_pending = (op !== "false" && op !== "0");
    const vids = url.searchParams.get("venue_ids");
    if (vids) body.venue_ids = vids.split(",").map((s) => s.trim()).filter(Boolean);
  }

  const batchSize = Math.min(
    Math.max(1, body.batch_size || DEFAULT_BATCH_SIZE),
    MAX_BATCH_SIZE,
  );

  try {
    const sb = createClient(SUPABASE_URL, SERVICE_KEY);

    // ── 1. 번역이 필요한 venues 조회 ──
    let query = sb
      .from("venues")
      .select([
        "venue_id",
        "name_ko", "name_en", "name_jp",
        "style_summary_ko", "style_summary_en", "style_summary_jp",
        "holistic_signature_ko", "holistic_signature_en", "holistic_signature_jp",
        "neighborhood", "neighborhood_en", "neighborhood_jp",
        "city",
        "i18n_status_en", "i18n_status_jp",
      ].join(","));

    if (body.venue_ids && body.venue_ids.length > 0) {
      // 특정 venue 만 (재처리 / 검증용)
      query = query.in("venue_id", body.venue_ids);
    } else if (body.only_pending !== false) {
      // 기본값: status 가 pending/null 인 것만
      query = query.or(
        "i18n_status_en.is.null,i18n_status_en.eq.pending," +
        "i18n_status_jp.is.null,i18n_status_jp.eq.pending",
      );
    }

    const { data: venues, error: selErr } = await query.limit(batchSize);
    if (selErr) {
      return jsonResp({ error: "venues select 실패", detail: selErr.message }, 500);
    }
    if (!venues || venues.length === 0) {
      return jsonResp({
        ok: true,
        processed: 0,
        remaining: 0,
        done: true,
        message: "번역 필요한 venues 없음",
      });
    }

    // ── 2. 각 venue 마다 번역 ──
    const results: ProcessResult[] = [];

    for (const v of venues as any[]) {
      try {
        // 비어있는 EN/JP 가 있는 필드만 items 에 추가
        const items: Array<{ id: string; value: any; romanize?: boolean; kind?: string }> = [];

        for (const f of TRANSLATABLE_FIELDS) {
          const koVal = v[f.koCol];
          if (!koVal || (typeof koVal === "string" && koVal.trim() === "")) continue;

          const enCol = f.base + "_en";
          const jpCol = f.base + "_jp";
          const hasEn = v[enCol] && String(v[enCol]).trim() !== "";
          const hasJp = v[jpCol] && String(v[jpCol]).trim() !== "";
          if (hasEn && hasJp) continue; // 둘 다 이미 있으면 skip

          items.push({
            id: f.base,
            value: koVal,
            ...(f.romanize ? { romanize: true } : {}),
            ...(f.kind === "array" ? { kind: "array" } : {}),
          });
        }

        if (items.length === 0) {
          results.push({
            venue_id: v.venue_id,
            skipped: true,
            reason: "all_fields_already_filled",
          });
          // status 만이라도 'manual' 로 갱신 (재처리 방지)
          await sb.from("venues").update({
            i18n_status_en: v.i18n_status_en || "manual",
            i18n_status_jp: v.i18n_status_jp || "manual",
            i18n_updated_at: new Date().toISOString(),
          }).eq("venue_id", v.venue_id);
          continue;
        }

        // ── 3. taam-translate 호출 ──
        const context = [
          v.name_ko && `매장: ${v.name_ko}`,
          v.city && `도시: ${v.city}`,
          v.neighborhood && `동네: ${v.neighborhood}`,
        ].filter(Boolean).join(", ");

        const trRes = await fetch(`${SUPABASE_URL}/functions/v1/taam-translate`, {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${SERVICE_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            items,
            target_langs: ["en", "ja"],
            context: context || "TAAM 미식 큐레이션",
          }),
        });

        if (!trRes.ok) {
          const errText = await trRes.text();
          results.push({
            venue_id: v.venue_id,
            error: `taam-translate ${trRes.status}: ${errText.substring(0, 200)}`,
          });
          continue;
        }

        const trData = await trRes.json();
        const translations = trData?.translations || {};

        // ── 4. UPDATE 페이로드 구성 ──
        const updatePayload: Record<string, any> = {
          i18n_status_en: "ai_draft",
          i18n_status_jp: "ai_draft",
          i18n_updated_at: new Date().toISOString(),
        };
        const translatedIds: string[] = [];

        for (const itemId of Object.keys(translations)) {
          const t = translations[itemId] || {};
          if (t.en !== undefined && t.en !== null && t.en !== "") {
            updatePayload[itemId + "_en"] = t.en;
          }
          if (t.ja !== undefined && t.ja !== null && t.ja !== "") {
            updatePayload[itemId + "_jp"] = t.ja;
          }
          translatedIds.push(itemId);
        }

        // ── 5. venues 테이블 UPDATE ──
        const { error: upErr } = await sb
          .from("venues")
          .update(updatePayload)
          .eq("venue_id", v.venue_id);

        if (upErr) {
          results.push({
            venue_id: v.venue_id,
            error: "UPDATE 실패: " + upErr.message,
          });
        } else {
          results.push({
            venue_id: v.venue_id,
            translated: translatedIds,
          });
        }

        // Rate limit 보호 — Claude API 와 Supabase 모두 (호출 간 약간의 지연)
        await new Promise((r) => setTimeout(r, 300));
      } catch (e: any) {
        results.push({
          venue_id: v.venue_id || "unknown",
          error: e.message || String(e),
        });
      }
    }

    // ── 6. 남은 venues 카운트 (반복 호출 종료 판정용) ──
    let remaining = 0;
    if (!body.venue_ids) {
      const { count } = await sb
        .from("venues")
        .select("venue_id", { count: "exact", head: true })
        .or(
          "i18n_status_en.is.null,i18n_status_en.eq.pending," +
          "i18n_status_jp.is.null,i18n_status_jp.eq.pending",
        );
      remaining = count || 0;
    }

    return jsonResp({
      ok: true,
      processed: results.length,
      remaining,
      done: !body.venue_ids && remaining === 0,
      results,
    });
  } catch (e: any) {
    console.error("[venues-batch] fatal error:", e);
    return jsonResp({ error: e.message || String(e) }, 500);
  }
});

function jsonResp(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
