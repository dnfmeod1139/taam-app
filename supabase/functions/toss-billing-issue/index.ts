// ════════════════════════════════════════════════════════════
// toss-billing-issue — 카드 등록 완료(빌링키 발급) Edge Function
// ════════════════════════════════════════════════════════════
// 작성일: 2026-08
//
// 토스 빌링(카드 등록)은 2단계다.
//   ① 브라우저 requestBillingAuth() → 복귀 URL 로 customerKey + authKey 만 온다
//   ② 서버가 시크릿 키로 authKey 를 빌링키로 교환한다  ← 이 함수
// ②가 없으면 회원이 카드 정보를 다 입력해도 저장되는 게 없다.
// (실제로 그동안 복귀 핸들러가 "결제 수단 관리는 준비 중입니다" 만 띄웠다)
//
// authKey 는 짧게 만료되므로 복귀 즉시 교환해야 한다.
//
// 이 함수가 지키는 것
//   · 소유권   — customerKey 는 호출자 JWT 의 uid 와 같아야 한다.
//               (남의 customerKey 로 발급한 카드를 자기 계정에 심는 것을 막는다)
//   · 최소보관 — 카드번호 전체·CVC 는 받지도 저장하지도 않는다. 마스킹 번호만.
//   · 멱등     — 같은 빌링키가 다시 오면 새로 만들지 않고 되살린다(재등록).
//
// 필요한 시크릿
//   TOSS_BILLING_SECRET_KEY = live_sk_...  ← 자동결제 MID(bill_taam315) 시크릿
//   (없으면 TOSS_SECRET_KEY 로 폴백)     ⚠ 코드·커밋에 절대 넣지 말 것
// ════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const TOSS_ISSUE_URL = 'https://api.tosspayments.com/v1/billing/authorizations/issue';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    // 🆕 2026.08: 빌링은 자동결제 MID(bill_taam315) 전용 키를 쓴다.
    //   토스는 MID 별로 키가 다르다 — 일반결제 MID(playtauif6) 키로 빌링 API 를 부르면
    //   "자동결제 계약이 없다" 로 거절된다. 실제로 그렇게 막혔다.
    //   두 MID 의 시크릿이 같은 환경도 있으므로 TOSS_SECRET_KEY 로 폴백한다.
    const secretKey = Deno.env.get('TOSS_BILLING_SECRET_KEY') || Deno.env.get('TOSS_SECRET_KEY');
    if (!secretKey) {
      console.error('[toss-billing-issue] TOSS_BILLING_SECRET_KEY / TOSS_SECRET_KEY 둘 다 미설정');
      return json({ ok: false, error: 'server_not_configured' });
    }

    const body = await req.json().catch(() => ({}));
    const customerKey = String(body.customerKey || '').trim();
    const authKey = String(body.authKey || '').trim();
    if (!customerKey || !authKey) return json({ ok: false, error: 'missing_params' });

    // ── 호출자 신원 ──
    const authHeader = req.headers.get('Authorization') || '';
    if (!authHeader.startsWith('Bearer ')) return json({ ok: false, error: 'unauthorized' }, 401);

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { data: userData, error: userErr } = await admin.auth.getUser(
      authHeader.replace('Bearer ', ''),
    );
    const user = userData?.user;
    if (userErr || !user) return json({ ok: false, error: 'unauthorized' }, 401);

    // 앱은 customerKey 로 auth.users.id 를 쓴다 (_tossPaymentsCtx 의 payment({customerKey: u.id})).
    // 다른 값이 오면 남의 카드를 붙이려는 시도다.
    if (customerKey !== user.id) {
      console.warn('[toss-billing-issue] customerKey 불일치', customerKey, user.id);
      return json({ ok: false, error: 'customer_mismatch' }, 403);
    }

    // 🔒 2026-09-14 회원당 시간당 10회 — 회원 JWT 하나로 토스 발급 API 를 무한정 대리 호출하던 길.
    //   taam_rate_hit 는 09-13 SQL 이 만든다(service_role 실행 가능). 없거나 오류면 통과.
    try {
      const { data: allowed, error: rlErr } = await admin.rpc('taam_rate_hit', {
        p_key: 'billing_issue:' + user.id, p_limit: 10, p_window: '1 hour',
      });
      if (!rlErr && allowed === false) return json({ ok: false, error: 'rate_limited' }, 429);
    } catch (_e) { /* 제한기 없음 → 통과 */ }

    // ── 빌링키 교환 ──
    const basic = btoa(`${secretKey}:`);
    const res = await fetch(TOSS_ISSUE_URL, {
      method: 'POST',
      headers: {
        'Authorization': `Basic ${basic}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ customerKey, authKey }),
    });
    const toss = await res.json().catch(() => ({}));

    if (!res.ok || !toss.billingKey) {
      const reason = toss?.message || toss?.code || `http_${res.status}`;
      console.warn('[toss-billing-issue] 발급 실패', String(reason).slice(0, 200));
      return json({ ok: false, error: 'issue_failed', reason: String(reason).slice(0, 200) });
    }

    // 카드 정보는 표시용만 취한다 (전체 번호·CVC 는 애초에 오지 않는다)
    const card = (toss.card || {}) as Record<string, unknown>;
    const cardCompany = String(toss.cardCompany || card.issuerCode || card.company || '') || null;
    const cardNumber = String(card.number || '') || null;      // 마스킹된 값
    const cardType = String(card.cardType || '') || null;

    // ── 저장 ──
    //   첫 카드는 자동으로 기본카드가 된다.
    //   🔧 2026-10-13 앞 두 조회의 오류를 더는 버리지 않는다 — 저장이 실패하면 그 오류까지 app_errors 에 함께 남긴다
    //     (서비스 키가 service_role 이 아니면 조회부터 조용히 비어 있었다 — 그걸 알 길이 없었다).
    const { count, error: countErr } = await admin.from('billing_keys')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', user.id).is('deleted_at', null);
    const isFirst = !count;

    // 같은 빌링키 재등록(카드 삭제 후 같은 카드 재등록 등) — 되살린다
    const { data: exist, error: existErr } = await admin.from('billing_keys')
      .select('id').eq('billing_key', toss.billingKey).maybeSingle();

    const restore = async (id: string) => {
      const { error: upErr } = await admin.from('billing_keys').update({
        user_id: user.id, customer_key: customerKey,
        card_company: cardCompany, card_number: cardNumber, card_type: cardType,
        deleted_at: null,
      }).eq('id', id);
      if (upErr) throw upErr;
      if (isFirst) await setDefault(admin, user.id, id);
      return json({ ok: true, restored: true, cardCompany, cardNumber });
    };
    if (exist) return await restore(exist.id);

    const { data: ins, error: insErr } = await admin.from('billing_keys').insert({
      user_id: user.id,
      customer_key: customerKey,
      billing_key: toss.billingKey,
      card_company: cardCompany,
      card_number: cardNumber,
      card_type: cardType,
      is_default: false,
    }).select('id').maybeSingle();

    if (insErr || !ins) {
      // 🔧 2026-10-13 같은 빌링키가 이미 있다(23505) — exist 조회가 비었거나 경주다. 되살리는 길로 보낸다.
      if (insErr && String((insErr as { code?: string }).code || '') === '23505') {
        const { data: again } = await admin.from('billing_keys')
          .select('id').eq('billing_key', toss.billingKey).maybeSingle();
        if (again) {
          try { return await restore(again.id); } catch (_re) { /* 아래로 — 원인을 남긴다 */ }
        }
      }
      // 발급은 됐는데 저장이 실패했다 — 회원 화면에 그대로 알린다.
      //   조용히 성공 처리하면 "등록했는데 목록에 없다"가 된다.
      //   🔧 2026-10-13 원인(코드·제약·컬럼)을 ① 응답 reason 으로 ② app_errors(kind billing_save, platform edge) 로 남긴다 —
      //     Edge 로그만 보고는 라이브에서 무엇이 거절했는지 아무도 알 수 없었다(「카드 저장 실패」만 떴다). 카드번호는 애초에 없다.
      const e = (insErr || {}) as { code?: string; message?: string; details?: string; hint?: string };
      const reason = (e.code ? e.code + ' ' : '') + String(e.message || (ins ? '' : 'no_row')).slice(0, 160);
      console.error('[toss-billing-issue] 저장 실패', insErr, { countErr, existErr });
      try {
        await admin.from('app_errors').insert({
          user_id: user.id, role: 'user', build: 'edge', platform: 'edge', kind: 'billing_save',
          message: 'toss-billing-issue 저장 실패: ' + reason,
          stack: null, url: '/toss-billing-issue',
          extra: {
            code: e.code || null, details: String(e.details || '').slice(0, 300), hint: String(e.hint || '').slice(0, 200),
            count_err: countErr ? String((countErr as { message?: string }).message || '').slice(0, 160) : null,
            exist_err: existErr ? String((existErr as { message?: string }).message || '').slice(0, 160) : null,
            is_first: isFirst, card_company: cardCompany,
          },
        });
      } catch (_ae) { /* 기록 실패는 결과를 바꾸지 않는다 */ }
      return json({ ok: false, error: 'save_failed', reason });
    }

    if (isFirst) await setDefault(admin, user.id, ins.id);

    return json({ ok: true, cardCompany, cardNumber, isDefault: isFirst });

  } catch (e) {
    console.error('[toss-billing-issue] 예외', e);
    return json({ ok: false, error: 'exception' });
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


// 기본카드 지정 — 부분 유니크 인덱스(회원당 1장) 때문에 기존 것을 먼저 내린다
async function setDefault(
  admin: ReturnType<typeof createClient>,
  userId: string,
  id: string,
): Promise<void> {
  await admin.from('billing_keys').update({ is_default: false })
    .eq('user_id', userId).eq('is_default', true);
  await admin.from('billing_keys').update({ is_default: true }).eq('id', id);
}
