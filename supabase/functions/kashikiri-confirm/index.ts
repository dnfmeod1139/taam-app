// ════════════════════════════════════════════════════════════
// kashikiri-confirm — 대관 분할 청구, 링크 결제 승인
// ════════════════════════════════════════════════════════════
// 작성일: 2026-09
//
// 왜 toss-confirm 을 안 쓰고 따로 두는가
//   ① toss-confirm 은 payment_orders 를 본다. payment_orders.user_id 는
//      NOT NULL 이라 **동행 비회원**의 결제를 담을 수 없다.
//   ② toss-confirm 은 로그인한 회원만 부를 수 있다(Bearer 토큰 → getUser).
//      링크로 오는 사람은 로그인이 없다.
//   ③ toss-confirm 은 승인 뒤에 예치금 적립·좌석 전환까지 한다.
//      대관 청구는 그중 아무것도 하면 안 된다.
//   실결제로 검증된 함수를 초대·대관용으로 고치면 두 경로의 정산이
//   어긋난다 — toss-billing-charge 주석이 이미 그렇게 못박아 뒀다.
//
// 로그인이 없는데 왜 안전한가
//   호출자는 링크 토큰과 paymentKey 를 낸다.
//   · 토큰이 그 주문의 것인지 서버가 대조한다 (남의 주문을 못 건드린다)
//   · paymentKey 는 토스가 **그 orderId·그 금액**으로만 발급한다.
//     승인은 우리 시크릿 키로 토스에 다시 물어 확정된다. 위조가 안 된다
//   · 확정은 taam_kashikiri_mark_paid 가 하고, 금액이 다르면 거절한다
//
// 통화 (2026-09-02)
//   해외 손님에게는 달러·엔으로 청구한다. 토스는 **MID 별로 키가 다르다** —
//   원화 키로 외화 승인을 부르면 거절된다. 통화에 맞는 시크릿을 고른다.
//   승인은 외화로, 우리 매출 기록(amount_krw)은 원화로. 둘을 섞지 않는다.
//
// 입력:  { token, orderId, paymentKey, amount?, currency? }
// 시크릿: TOSS_SECRET_KEY            (원화 · 일반결제 MID)
//         TOSS_SECRET_KEY_USD / _JPY (해외 MID. 그 통화를 쓸 때만 필요)
// 배포:  Supabase Dashboard → Edge Functions → kashikiri-confirm
//        ⚠ Verify JWT 를 **꺼야** 한다 (비회원이 부른다)
// ════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const TOSS_CONFIRM_URL = 'https://api.tosspayments.com/v1/payments/confirm';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const body = await req.json().catch(() => ({}));
    const token = String(body.token || '').trim();
    const orderId = String(body.orderId || '').trim();
    const paymentKey = String(body.paymentKey || '').trim();

    if (!token || !orderId || !paymentKey) {
      return json({ ok: false, error: 'missing_params' });
    }

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // ── 청구 조회 — 토큰과 주문번호가 **같은 행**을 가리켜야 한다 ──
    const { data: charge, error: cErr } = await admin
      .from('kashikiri_charges')
      .select('id, order_id, amount_krw, status, token, pay_currency, pay_amount')
      .eq('token', token)
      .maybeSingle();

    if (cErr) {
      console.error('[kashikiri-confirm] 청구 조회 실패', cErr);
      return json({ ok: false, error: 'lookup_failed' });
    }
    if (!charge) return json({ ok: false, error: 'not_found' });
    if (charge.order_id !== orderId) {
      console.warn('[kashikiri-confirm] 토큰·주문 불일치', token.slice(0, 8), orderId);
      return json({ ok: false, error: 'order_mismatch' }, 403);
    }

    // 멱등 — 복귀 URL 은 새로고침·뒤로가기로 여러 번 열린다
    if (charge.status === 'paid') {
      return json({ ok: true, already: true,
                    amount: Number(charge.pay_amount ?? charge.amount_krw),
                    currency: String(charge.pay_currency || 'KRW').toUpperCase() });
    }
    if (charge.status !== 'pending') {
      return json({ ok: false, error: 'not_pending', status: charge.status });
    }

    // 금액·통화는 언제나 DB 것을 쓴다. 브라우저가 주장하는 값은 대조에만 쓴다.
    const currency = String(charge.pay_currency || 'KRW').toUpperCase();
    const expected = Number(charge.pay_amount ?? charge.amount_krw);
    const clientAmount = Number(body.amount || 0);
    if (clientAmount && Math.round(clientAmount * 100) !== Math.round(expected * 100)) {
      console.warn('[kashikiri-confirm] 금액 불일치(클라)', orderId, clientAmount, expected);
      return json({ ok: false, error: 'amount_mismatch' });
    }

    // ⚠ 토스는 MID 별로 키가 다르다. 원화 키로 외화 승인을 부르면 거절된다.
    //   (앱에서도 같은 이유로 통화별 클라이언트 키를 라우팅한다)
    const secretKey = (currency === 'KRW')
      ? Deno.env.get('TOSS_SECRET_KEY')
      : (Deno.env.get('TOSS_SECRET_KEY_' + currency) || Deno.env.get('TOSS_SECRET_KEY'));
    if (!secretKey) {
      console.error('[kashikiri-confirm] 시크릿 미설정', currency);
      return json({ ok: false, error: 'server_not_configured', currency });
    }

    // ── 토스 승인 ──
    const basic = btoa(`${secretKey}:`);
    const tossRes = await fetch(TOSS_CONFIRM_URL, {
      method: 'POST',
      headers: {
        'Authorization': `Basic ${basic}`,
        'Content-Type': 'application/json',
        'Idempotency-Key': `taam-ksk-${orderId}`,
      },
      body: JSON.stringify({ paymentKey, orderId, amount: expected }),
    });
    const toss = await tossRes.json().catch(() => ({}));

    if (!tossRes.ok || toss.status !== 'DONE') {
      const reason = toss?.message || toss?.code || `http_${tossRes.status}`;
      console.warn('[kashikiri-confirm] 승인 실패', orderId, reason);
      await admin.from('kashikiri_charges')
        .update({ fail_reason: String(reason).slice(0, 300) })
        .eq('id', charge.id).eq('status', 'pending');
      return json({ ok: false, error: 'confirm_failed', reason: String(reason) });
    }

    // 토스가 실제로 승인한 금액을 한 번 더 대조한다 (방어적)
    //   ⚠ 달러는 센트가 있다. 정수 비교로는 0.01 차이를 못 잡는다.
    const approved = Number(toss.totalAmount ?? toss.balanceAmount ?? 0);
    if (Math.round(approved * 100) !== Math.round(expected * 100)) {
      console.error('[kashikiri-confirm] 승인 금액 불일치', orderId, approved, expected);
      await admin.from('kashikiri_charges')
        .update({ fail_reason: `amount_mismatch_toss:${approved}` })
        .eq('id', charge.id).eq('status', 'pending');
      return json({ ok: false, error: 'amount_mismatch_toss' });
    }

    // ── 확정 — 통화·금액 대조와 멱등은 RPC 가 다시 한 번 한다 ──
    //   v2 는 numeric 을 받아 달러 센트까지 본다. 아직 SQL 이 안 올라간 DB 를
    //   위해 옛 함수로 내려가는 길을 남긴다 — 단, 원화일 때만이다.
    //   외화인데 v2 가 없으면 확정하지 않는다. 잘못 찍느니 안 찍는 게 낫다.
    let marked: unknown = null;
    let mErr: { message?: string; code?: string } | null = null;
    {
      const r1 = await admin.rpc('taam_kashikiri_mark_paid_v2', {
        p_order_id: orderId,
        p_payment_key: paymentKey,
        p_amount: expected,
        p_currency: currency,
        p_method: toss.method || null,
        p_receipt: toss.receipt?.url || null,
      });
      if (!r1.error) {
        marked = r1.data;
      } else if (/does not exist|schema cache|PGRST202/i.test(String(r1.error.message || ''))
                 && currency === 'KRW') {
        console.warn('[kashikiri-confirm] v2 없음 — 옛 함수로 내려간다 (원화)');
        const r0 = await admin.rpc('taam_kashikiri_mark_paid', {
          p_order_id: orderId,
          p_payment_key: paymentKey,
          p_amount: expected,
          p_method: toss.method || null,
          p_receipt: toss.receipt?.url || null,
        });
        marked = r0.data; mErr = r0.error;
      } else {
        mErr = r1.error;
      }
    }

    if (mErr) {
      // 돈은 이미 승인됐다. 여기서 실패하면 사람이 손으로 맞춰야 하므로
      // 반드시 남긴다 — 조용히 넘기면 「돈은 빠지고 기록은 없는」 건이 된다.
      console.error('[kashikiri-confirm] 확정 실패(승인은 됨)', orderId, mErr);
      return json({ ok: false, error: 'mark_paid_failed', paid: true, orderId });
    }

    return json({
      ok: true,
      amount: expected,
      currency,
      settleKrw: Number(charge.amount_krw),
      receiptUrl: toss.receipt?.url || null,
      method: toss.method || null,
      marked,
    });
  } catch (e) {
    console.error('[kashikiri-confirm] 예외', e);
    return json({ ok: false, error: 'exception', message: (e as Error).message });
  }
});
