// ════════════════════════════════════════════════════════════
// notify-visit-reminder — 방문일이 다가오면 알린다 (2026-09-07)
// ════════════════════════════════════════════════════════════
// 무엇을
//   구매한 티켓의 방문 **7일 전 · 3일 전 · 1일 전**에 알린다.
//   회원이 설정에서 켠 것만 나간다. 안 만졌으면 3일·1일만 (7일은 기본 꺼짐).
//
// 누가 정하나
//   ⚠ 「누구에게 무엇을」은 전부 SQL(taam_visit_reminder_notify)이 정한다.
//     이 함수는 그 결과를 받아 **쏘기만** 한다. 규칙을 두 곳에 두면
//     인앱 알림(종)과 푸시가 서로 다른 말을 하는 날이 온다.
//     notify-guest-expiry 와 같은 구조다.
//
// 왜 서버에서 하나
//   종전에는 구매 시점에 발송시각을 계산해 두고, 회원이 앱을 열면 그때
//   놓친 것을 토스트로 잠깐 보여주는 게 전부였다. 앱을 안 열면 영영 안 왔다.
//   서버가 매일 「지금의 방문일」을 보게 하면 아래 셋이 저절로 해결된다.
//     ① 초대로 받은 티켓에도 리마인드가 간다 (예전엔 일정이 빈 배열이었다)
//     ② 구매 뒤에 설정을 켜도 다음 날부터 바로 반영된다
//     ③ 방문일이 바뀌면 그날 기준으로 다시 계산된다
//
// 하루 한 번
//   SQL 이 **티켓id + 남은 일수를 열쇠로** 중복을 막는다. 이 함수를 하루에
//   여러 번 불러도 새로 들어간 것이 없으면 아무것도 안 쏜다.
//
// 배포: Supabase 대시보드 → Edge Functions → notify-visit-reminder
// 예약: 대시보드 Cron 에서 매일 한 번 (한국시간 오전 11시 권장)
//   ⚠ SQL 쪽에 pg_cron 을 걸지 말 것 — 그러면 알림이 먼저 들어가 버려
//     이 함수가 쏠 것을 못 본다 (guest_expiry 에서 이미 겪었다).
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
  id: string; user_id: string; title: string; body: string; url: string;
  days: number; ticket_id: string | null; rest: string | null; vtime: string | null;
};

// 회원의 언어로 보낸다. send-push 가 payload.i18n 을 받으면 기기 lang 으로 고른다.
//   ⚠ 핸드폰 OS 언어로는 안 바뀐다 — OS 언어는 OS 가 만든 알림에만 적용된다.
//     우리가 고르지 않으면 아무도 안 골라준다.
function build(r: Row) {
  const rest = (r.rest || '').trim();
  const time = (r.vtime || '').trim();
  const d = r.days;
  const withTime = (nm: string) => (time ? `${nm} · ${time}` : nm);

  const ko = {
    title: d === 1 ? '내일 방문 예정입니다'
         : d === 3 ? '3일 뒤 방문 예정입니다'
         : `방문 ${d}일 전입니다`,
    body: `${withTime(rest || '예약하신 매장')} ` +
          (d === 1 ? '예약이 내일입니다.' : `예약이 ${d}일 남았습니다.`),
  };
  const en = {
    title: d === 1 ? 'Your reservation is tomorrow'
         : `Your reservation is in ${d} days`,
    body: `${withTime(rest || 'Your reservation')} — ` +
          (d === 1 ? 'see you tomorrow.' : `${d} days to go.`),
  };
  const ja = {
    title: d === 1 ? '明日ご来店の予定です'
         : `ご来店${d}日前です`,
    body: `${withTime(rest || 'ご予約')} — ` +
          (d === 1 ? '明日のご予約です。' : `あと${d}日です。`),
  };
  return { ko, en, ja };
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const url = Deno.env.get('SUPABASE_URL')!;
  const svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin = createClient(url, svc, { auth: { persistSession: false } });

  try {
    // ① 오늘 보낼 것을 SQL 에게 물어본다 (인앱 알림도 여기서 들어간다)
    const { data, error } = await admin.rpc('taam_visit_reminder_notify');
    if (error) return json({ ok: false, error: error.message }, 500);

    const rows = (data?.rows || []) as Row[];

    // ② 푸시로도 쏜다. 인앱만 두면 앱을 안 열어 본 사람에게는 안 닿는다.
    let sent = 0, failed = 0;
    for (const r of rows) {
      try {
        const i18n = build(r);
        const res = await fetch(`${url}/functions/v1/send-push`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${svc}` },
          body: JSON.stringify({
            to: `uid:${r.user_id}`,
            payload: {
              // 기기가 언어를 못 고를 때 쓸 기본값 — SQL 이 만든 한국어 그대로
              title: r.title, body: r.body, url: r.url || '/',
              i18n,
              // 설정 존중은 send-push 도 한 번 더 본다 (SQL 에서 이미 걸렀지만
              // 두 겹으로 두는 편이 안전하다). remind7 / remind3 / remind1
              category: `remind${r.days}`,
              // 같은 티켓으로 여러 건이 쌓이지 않게 — 기기에서 하나로 합쳐진다.
              //   D-7 알림이 남아 있는데 D-3 이 오면 새 것으로 대체된다.
              tag: `visit-reminder-${r.ticket_id || r.id}`,
            },
          }),
        });
        res.ok ? sent++ : failed++;
      } catch (_e) {
        // ⚠ 한 건이 실패해도 멈추지 않는다. 한 사람의 기기 토큰이 죽었다고
        //   나머지 사람들이 알림을 못 받으면 안 된다.
        failed++;
      }
    }

    return json({ ok: true, made: data?.made ?? 0, push_sent: sent, push_failed: failed });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
