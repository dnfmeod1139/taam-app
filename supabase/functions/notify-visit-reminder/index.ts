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
// 🆕 2026-10-19 비회원 손님(결제 링크 LINK- · 캘린더 수동 추가 MAN-)에게는 **카카오 알림톡**으로 간다 — 앱 계정이 없어 푸시가 갈 곳이 없다.
//   대상·기록은 SQL(taam_guest_reminder_targets · taam_guest_reminder_mark · 20261019_guest_reminder.sql)이 정하고, 여기선 솔라피로 쏘기만 한다.
//   템플릿 변수: #{name} #{shop} #{date} #{party} #{dday}  — 시크릿 KAKAO_TEMPLATE_GUEST_REMIND (카카오 비즈니스 채널에 등록·승인된 템플릿 id).
//   국내 번호(010·011·016·017·018·019)만 보낸다 — 해외 번호는 skip 으로 기록한다(알림톡은 국내만). 템플릿이 없으면 기록하지 않고 건너뛴다(나중에 설정되면 그때 나간다).
//   회원 소유 LINK-(extra_data.memberUid)는 위 회원 푸시가 맡는다 — 두 번 가지 않는다.
//
// 배포: Supabase 대시보드 → Edge Functions → notify-visit-reminder
// 예약: 대시보드 Cron 에서 매일 한 번 (한국시간 오전 11시 권장)
//   ⚠ SQL 쪽에 pg_cron 을 걸지 말 것 — 그러면 알림이 먼저 들어가 버려
//     이 함수가 쏠 것을 못 본다 (guest_expiry 에서 이미 겪었다).
// 필요 시크릿: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY (기본 제공) · 알림톡: SOLAPI_API_KEY SOLAPI_API_SECRET SOLAPI_SENDER KAKAO_PF_ID (notify-guest-booking 과 공유) · KAKAO_TEMPLATE_GUEST_REMIND
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

// 응답에 실어 어느 판이 도는지 net._http_response 에서 보이게 한다 (2026-10-27 · SQL 이 준 i18n 을 쓰는 판)
const VR_EDGE_VER = 'vr-2026-10-27b';   // b: 슈퍼어드민 몫 건수(admin_made·admin_skipped)를 응답에

type Row = {
  id: string; user_id: string; title: string; body: string; url: string;
  days: number; ticket_id: string | null; rest: string | null; vtime: string | null;
  // 2026-10-27 판(VR_FMT_20261027)부터 SQL 이 세 언어 문구를 만들어 싣는다 — 「예약 안내」 + 레스토랑·날짜·시간·인원(+ 매장 유의사항·안내말씀).
  //   있으면 그대로 쓰고, 옛 SQL 판이면 아래 build() 가 옛 문구를 만든다.
  i18n?: Record<string, { title?: string; body?: string }> | null;
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


// ── 🆕 2026-10-19 비회원 알림톡 (notify-guest-booking 의 sendKakao 와 같은 솔라피 호출) ──
type GuestRow = { ticket_id: string; name: string; phone: string; rest: string; date: string | null; vtime: string; pax: number; d: number; purchase_id: string };

async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}
// 국내 휴대폰만 — '+82 10…' · '8210…' 은 '010…' 으로. 그 밖(해외)은 null.
function krMobile(raw: string): string | null {
  let d = String(raw || '').replace(/[^0-9]/g, '');
  if (d.startsWith('82')) d = '0' + d.slice(2);
  return /^01[016789]\d{7,8}$/.test(d) ? d : null;
}
// '2027.05.01' · '2027-05-01' → '5월 1일(토)' (KST 요일)
function fmtKoDate(raw: string | null, vtime: string): string {
  const m = String(raw || '').match(/(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})/);
  if (!m) return String(raw || '') + (vtime ? ' ' + vtime : '');
  const dt = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  const wd = ['일', '월', '화', '수', '목', '금', '토'][dt.getUTCDay()];
  return `${+m[2]}월 ${+m[3]}일(${wd})` + (vtime ? ' ' + vtime : '');
}
type KakaoCfg = { apiKey: string; apiSecret: string; sender: string; pfId: string; template: string };
function kakaoCfg(): KakaoCfg | string {
  const apiKey = Deno.env.get('SOLAPI_API_KEY'), apiSecret = Deno.env.get('SOLAPI_API_SECRET'), sender = Deno.env.get('SOLAPI_SENDER'),
        pfId = Deno.env.get('KAKAO_PF_ID'), template = Deno.env.get('KAKAO_TEMPLATE_GUEST_REMIND');
  if (!apiKey || !apiSecret || !sender || !pfId) return 'skip(솔라피 미설정)';
  if (!template) return 'skip(템플릿 미설정 KAKAO_TEMPLATE_GUEST_REMIND)';
  return { apiKey, apiSecret, sender, pfId, template };
}
async function sendGuestKakao(cfg: KakaoCfg, phone: string, vars: Record<string, string>, fallbackText: string): Promise<string> {
  try {
    const date = new Date().toISOString(), salt = crypto.randomUUID();
    const signature = await hmacHex(cfg.apiSecret, date + salt);
    const res = await fetch('https://api.solapi.com/messages/v4/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `HMAC-SHA256 apiKey=${cfg.apiKey}, date=${date}, salt=${salt}, signature=${signature}` },
      body: JSON.stringify({ message: { to: phone, from: cfg.sender, subject: '[TAAM] 방문 안내', text: fallbackText,
                                        kakaoOptions: { pfId: cfg.pfId, templateId: cfg.template, variables: vars } } }),
    });
    if (!res.ok) return `fail(http ${res.status})`;
    let body: any = null; try { body = await res.json(); } catch (_) { /* 아래 */ }
    if (!body) return 'fail(응답 없음)';
    const code = String(body.statusCode ?? body.groupInfo?.status ?? '');
    const failed = Number(body.groupInfo?.count?.registeredFailed ?? 0) + Number(body.failedMessageList?.length ?? 0);
    if (failed > 0 || (code && code !== '2000')) return 'fail(' + String(body.failedMessageList?.[0]?.statusMessage || body.statusMessage || code || '알 수 없음').slice(0, 80) + ')';
    return 'sent';
  } catch (e) { return 'fail(' + String((e as Error)?.message || e).slice(0, 80) + ')'; }
}
// 비회원 손님에게 — 대상·기록은 SQL. 템플릿이 없으면 기록하지 않고 건너뛴다(설정되면 그때 나간다).
async function remindGuests(admin: ReturnType<typeof createClient>): Promise<{ sent: number; failed: number; skipped: number; reason?: string }> {
  const out = { sent: 0, failed: 0, skipped: 0 } as { sent: number; failed: number; skipped: number; reason?: string };
  const { data, error } = await admin.rpc('taam_guest_reminder_targets');
  if (error) { console.error('[notify-visit-reminder] guest rpc 실패', error.message); out.reason = 'guest_rpc_failed'; return out; }
  const rows = (data || []) as GuestRow[];
  if (!rows.length) return out;
  const cfg = kakaoCfg();
  if (typeof cfg === 'string') { out.skipped = rows.length; out.reason = cfg; return out; }
  for (const r of rows) {
    let result: string;
    const phone = krMobile(r.phone);
    if (!phone) result = 'skip(해외번호)';
    else {
      const dday = r.d === 1 ? '내일' : `${r.d}일 뒤`;
      const when = fmtKoDate(r.date, r.vtime);
      const vars = { '#{name}': r.name || '고객', '#{shop}': r.rest || '예약하신 매장', '#{date}': when, '#{party}': String(r.pax || 1), '#{dday}': dday };
      const fallback = `[TAAM 방문 안내]\n${r.name || '고객'}님, ${r.rest || '예약하신 매장'} 예약이 ${dday}입니다.\n· 일시: ${when}\n· 인원: ${r.pax || 1}명\n변경·취소는 TAAM 컨시어지로 연락해 주세요.`;
      result = await sendGuestKakao(cfg, phone, vars, fallback);
    }
    if (result === 'sent') out.sent++; else if (result.startsWith('skip')) out.skipped++; else out.failed++;
    try { await admin.rpc('taam_guest_reminder_mark', { p_ticket: r.ticket_id, p_d: r.d, p_result: result, p_phone_key: (r.phone || '').replace(/[^0-9]/g, '').replace(/^82/, '').replace(/^0+/, '') }); }
    catch (e) { console.error('[notify-visit-reminder] guest mark 실패', (e as Error)?.message); }
  }
  return out;
}

// 🔒 2026-09-14 호출자 확인 — 서버(service_role)만 부른다.
//   종전엔 anon key 만 있으면 누구나 발송 시점을 정하고 무제한으로 부를 수 있었다.
//   cron 은 Vault 의 service_role(legacy JWT)로 부른다. 게이트웨이의 Verify JWT 가 서명을
//   확인하므로 여기서는 role 클레임만 본다. 시크릿 값과 같으면 바로 통과.
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

async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const url = Deno.env.get('SUPABASE_URL')!;
  const svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const admin = createClient(url, svc, { auth: { persistSession: false } });
  if (!isServiceCaller(req, svc)) return json({ ok: false, error: 'forbidden' }, 403);

  try {
    // ① 오늘 보낼 것을 SQL 에게 물어본다 (인앱 알림도 여기서 들어간다)
    const { data, error } = await admin.rpc('taam_visit_reminder_notify');
    if (error) {
      // DB 오류 원문은 로그에만 — 호출자에게 스키마·함수 이름을 흘리지 않는다
      console.error('[notify-visit-reminder] rpc 실패', error.message);
      // 🆕 2026-10-27 회원 쪽이 실패해도 비회원 알림톡은 따로 보낸다 — 종전엔 여기서 끝나 손님 리마인드까지 그날 통째로 빠졌다
      let guest0: { sent: number; failed: number; skipped: number; reason?: string } = { sent: 0, failed: 0, skipped: 0 };
      try { guest0 = await remindGuests(admin); } catch (e) { console.error('[notify-visit-reminder] guest 예외', e); guest0.reason = 'guest_exception'; }
      return json({ ok: false, error: 'rpc_failed', guest: guest0, ver: VR_EDGE_VER }, 500);
    }

    const rows = (data?.rows || []) as Row[];

    // ② 푸시로도 쏜다. 인앱만 두면 앱을 안 열어 본 사람에게는 안 닿는다.
    let sent = 0, failed = 0;
    for (const r of rows) {
      try {
        const i18n = (r.i18n && typeof r.i18n === 'object' && r.i18n.ko && r.i18n.ko.title) ? r.i18n : build(r);
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

    // ③ 🆕 비회원 손님 — 알림톡. 회원 쪽이 끝난 뒤, 실패해도 회원 결과는 그대로 돌려준다
    let guest: { sent: number; failed: number; skipped: number; reason?: string } = { sent: 0, failed: 0, skipped: 0 };
    try { guest = await remindGuests(admin); } catch (e) { console.error('[notify-visit-reminder] guest 예외', e); guest.reason = 'guest_exception'; }

    // admin_made · admin_skipped — 슈퍼어드민 몫(캘린더 전 일정 · 2026-10-27)과 상한(50)으로 빠진 수. net._http_response 에서 보이게
    return json({ ok: true, made: data?.made ?? 0, admin_made: data?.admin_made ?? 0, admin_skipped: data?.admin_skipped ?? 0,
                  push_sent: sent, push_failed: failed, guest, ver: VR_EDGE_VER });
  } catch (e) {
    console.error('[notify-visit-reminder] 예외', e);
    return json({ ok: false, error: 'exception' }, 500);
  }
}

// ── 🔒 2026-09-15 CORS 는 우리 출처만 · 메서드는 POST/OPTIONS 만 ──
//   (다른 10개 함수와 같은 마무리. Access-Control-Allow-Origin '*' 는 위 cors 상수에 남아 있지만 여기서 덮어쓴다)
const TAAM_ORIGINS = ['https://taam-app.vercel.app', 'https://playtaam.com', 'https://www.playtaam.com'];
function taamOrigin(req: Request): string {
  const o = req.headers.get('Origin') || '';
  if (TAAM_ORIGINS.includes(o) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o)) return o;
  return TAAM_ORIGINS[0];
}
serve(async (req: Request) => {
  let res: Response;
  if (req.method !== 'OPTIONS' && req.method !== 'POST') {
    res = new Response(JSON.stringify({ error: 'method_not_allowed' }),
      { status: 405, headers: { ...cors, 'Content-Type': 'application/json' } });
  } else {
    res = await handle(req);
  }
  try { res.headers.set('Access-Control-Allow-Origin', taamOrigin(req)); res.headers.append('Vary', 'Origin'); } catch (_e) { /* 헤더 잠긴 응답이면 그대로 */ }
  return res;
});

