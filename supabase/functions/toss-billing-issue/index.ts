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

serve(async (req) => {
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
    const { count } = await admin.from('billing_keys')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', user.id).is('deleted_at', null);
    const isFirst = !count;

    // 같은 빌링키 재등록(카드 삭제 후 같은 카드 재등록 등) — 되살린다
    const { data: exist } = await admin.from('billing_keys')
      .select('id').eq('billing_key', toss.billingKey).maybeSingle();

    if (exist) {
      await admin.from('billing_keys').update({
        user_id: user.id, customer_key: customerKey,
        card_company: cardCompany, card_number: cardNumber, card_type: cardType,
        deleted_at: null,
      }).eq('id', exist.id);
      if (isFirst) await setDefault(admin, user.id, exist.id);
      return json({ ok: true, restored: true, cardCompany, cardNumber });
    }

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
      // 발급은 됐는데 저장이 실패했다 — 회원 화면에 그대로 알린다.
      //   조용히 성공 처리하면 "등록했는데 목록에 없다"가 된다.
      console.error('[toss-billing-issue] 저장 실패', insErr);
      return json({ ok: false, error: 'save_failed', detail: String(insErr?.message || '').slice(0, 200) });
    }

    if (isFirst) await setDefault(admin, user.id, ins.id);

    return json({ ok: true, cardCompany, cardNumber, isDefault: isFirst });

  } catch (e) {
    console.error('[toss-billing-issue] 예외', e);
    return json({ ok: false, error: 'exception', detail: String(e).slice(0, 300) });
  }
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
