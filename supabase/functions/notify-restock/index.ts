// ════════════════════════════════════════════════════════════
// notify-restock — 취소표(재입고)가 나면 알린다 (2026-09-29)
// ════════════════════════════════════════════════════════════
// 무엇을
//   매진이던 회차에 자리가 다시 나면(회원 취소·수동 삭제·정산 좌석 취소·홀드 만료·어드민 토글…)
//   살 수 있는 회원 전원에게, 그리고 슈퍼어드민에게 푸시한다.
//
// 누가 정하나
//   ⚠ 「어느 회차가 · 누구에게」는 전부 SQL(taam_ticket_restock_process)이 정한다 — 이벤트 표(ticket_restock_events)의
//     pending 을 집어 커밋 이후 상태를 다시 확인하고, 인앱 알림(notifications)을 넣고, 수신자 id 만 돌려준다.
//     이 함수는 그 결과를 받아 **쏘기만** 한다. notify-visit-reminder 와 같은 구조.
//
// 언제 도나
//   ① 전이 트리거가 taam_restock_kick() 으로 즉시 부른다 (app_config 'restock_push' 에 Vault 시크릿 이름·URL 이 있을 때)
//   ② 1분 크론이 같은 kick 을 불러 놓친 것을 줍는다 (pending 이 없으면 kick 은 아무것도 안 한다)
//   두 번 불려도 안전하다 — SQL 이 for update skip locked 로 이벤트를 한 번만 처리한다.
//
// 배포: 대시보드 → Edge Functions → notify-restock (Verify JWT 켬 — Vault 의 legacy service_role JWT 로 부른다)
// 필요 시크릿: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY (기본 제공)
// ════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });

type Row = {
  event_id: number; ticket_id: string; title: string; body: string; url: string;
  rest: string | null; date: string | null; time: string | null; seats_left: number;
  member_ids: string[]; admin_ids: string[];
};

// 회원의 언어로 보낸다. send-push 가 payload.i18n 을 받으면 기기 lang 으로 고른다.
function build(r: Row) {
  const rest = (r.rest || '').trim() || '매장';
  const when = [(r.date || '').trim(), (r.time || '').trim()].filter(Boolean).join(' ');
  const n = r.seats_left;
  return {
    ko: { title: '🎫 취소표가 나왔습니다', body: `${rest} · ${when} · 잔여 ${n}석 — 지금 예약할 수 있어요` },
    en: { title: '🎫 A seat just opened up', body: `${rest} · ${when} · ${n} left — book now` },
    ja: { title: '🎫 キャンセル席が出ました', body: `${rest} · ${when} · 残り${n}席 — 今すぐご予約いただけます` },
  };
}

// 🔒 호출자 확인 — 서버(service_role)만 부른다. cron 은 Vault 의 legacy JWT 로 부른다.
function isServiceCaller(req: Request, svc: string): boolean {
  const t = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!t) return false;
  if (t === svc) return true;
  try {
    const seg = t.split('.')[1] || '';
    const pad = seg.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - seg.length % 4) % 4);
    const claims = JSON.parse(atob(pad));
    return claims && claims.role === 'service_role';
  } catch (_e) { return false; }
}

async function push(url: string, svc: string, to: string, payload: Record<string, unknown>): Promise<boolean> {
  try {
    const res = await fetch(`${url}/functions/v1/send-push`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${svc}` },
      body: JSON.stringify({ to, payload }),
    });
    return res.ok;
  } catch (_e) { return false; }
}

async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const url = Deno.env.get('SUPABASE_URL')!;
  const svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin = createClient(url, svc, { auth: { persistSession: false } });
  if (!isServiceCaller(req, svc)) return json({ ok: false, error: 'forbidden' }, 403);

  try {
    // ① 이번에 보낼 것을 SQL 에게 물어본다 (인앱 알림도 여기서 들어간다)
    const { data, error } = await admin.rpc('taam_ticket_restock_process', { p_limit: 10 });
    if (error) {
      console.error('[notify-restock] rpc 실패', error.message);
      return json({ ok: false, error: 'rpc_failed' }, 500);
    }
    const rows = (data?.rows || []) as Row[];

    // ② 푸시. 회원은 uid 마다(설정은 send-push 가 한 번 더 본다) · 슈퍼어드민은 role 로 한 번.
    let sent = 0, failed = 0;
    for (const r of rows) {
      const i18n = build(r);
      const base = { title: r.title, body: r.body, url: r.url || '/', i18n, category: 'ticket_restock', tag: `restock-${r.ticket_id}` };
      let evSent = 0;
      const ids = Array.isArray(r.member_ids) ? r.member_ids : [];
      for (let i = 0; i < ids.length; i += 5) {
        const chunk = ids.slice(i, i + 5);
        const results = await Promise.all(chunk.map((uid) => push(url, svc, `uid:${uid}`, base)));
        results.forEach((ok) => { ok ? (sent++, evSent++) : failed++; });
      }
      if ((r.admin_ids || []).length) {
        const ok = await push(url, svc, 'role:superadmin', { ...base, tag: `restock-admin-${r.ticket_id}` });
        ok ? (sent++, evSent++) : failed++;
      }
      try { await admin.rpc('taam_ticket_restock_mark_pushed', { p_event_id: r.event_id, p_push_sent: evSent }); } catch (_e) { /* 통계일 뿐 */ }
    }
    return json({ ok: true, events: data?.events ?? 0, notified: rows.length, push_sent: sent, push_failed: failed });
  } catch (e) {
    console.error('[notify-restock] 예외', e);
    return json({ ok: false, error: 'exception' }, 500);
  }
}

const TAAM_ORIGINS = ['https://taam-app.vercel.app', 'https://playtaam.com', 'https://www.playtaam.com'];
function taamOrigin(req: Request): string {
  const o = req.headers.get('Origin') || '';
  if (TAAM_ORIGINS.includes(o) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o)) return o;
  return TAAM_ORIGINS[0];
}
serve(async (req: Request) => {
  let res: Response;
  if (req.method !== 'OPTIONS' && req.method !== 'POST') {
    res = new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: { ...cors, 'Content-Type': 'application/json' } });
  } else {
    res = await handle(req);
  }
  try { res.headers.set('Access-Control-Allow-Origin', taamOrigin(req)); res.headers.append('Vary', 'Origin'); } catch (_e) { /* */ }
  return res;
});
