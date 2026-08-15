// ════════════════════════════════════════════════════════════
// toss-confirm — 토스페이먼츠 결제 승인 Edge Function
// ════════════════════════════════════════════════════════════
// 작성일: 2026-08
//
// 토스 V2 결제는 2단계다.
//   ① 브라우저에서 결제창 인증 (클라이언트 키) → paymentKey 발급
//   ② 서버에서 승인 confirm (시크릿 키)  ← 이 함수
// ②가 없으면 회원이 카드 인증을 마쳐도 실제 승인이 일어나지 않고
// 미승인 건으로 자동 취소된다. 회원에게는 "결제했는데 아무것도 안 됨"이 된다.
//
// 이 함수가 지키는 것
//   · 금액 위변조 차단 — 브라우저가 보낸 금액이 아니라 payment_orders.amount 를 신뢰한다
//   · 소유권 확인    — 주문의 user_id 와 호출자 JWT 의 uid 가 같아야 한다
//   · 멱등성         — 이미 paid 인 주문은 다시 적립하지 않는다 (새로고침·뒤로가기 대비)
//   · 부분 실패 방지 — 승인 성공 후 적립에 실패하면 그 사실을 주문에 남긴다
//
// 필요한 시크릿 (Supabase Dashboard → Edge Functions → Secrets)
//   TOSS_SECRET_KEY = live_sk_...   ⚠ 코드·커밋에 절대 넣지 말 것
// ════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const TOSS_CONFIRM_URL = 'https://api.tosspayments.com/v1/payments/confirm';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const secretKey = Deno.env.get('TOSS_SECRET_KEY');
    if (!secretKey) {
      console.error('[toss-confirm] TOSS_SECRET_KEY 미설정');
      return json({ ok: false, error: 'server_not_configured' });
    }

    const body = await req.json().catch(() => ({}));
    const orderId = String(body.orderId || '').trim();
    const paymentKey = String(body.paymentKey || '').trim();
    // 클라이언트가 보낸 금액은 참고만 한다. 신뢰 기준은 DB 의 amount 다.
    const clientAmount = Number(body.amount || 0);

    if (!orderId || !paymentKey) {
      return json({ ok: false, error: 'missing_params' });
    }

    // ── 호출자 신원 확인 ──
    const authHeader = req.headers.get('Authorization') || '';
    if (!authHeader.startsWith('Bearer ')) {
      return json({ ok: false, error: 'unauthorized' }, 401);
    }

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { data: userData, error: userErr } = await admin.auth.getUser(
      authHeader.replace('Bearer ', ''),
    );
    const user = userData?.user;
    if (userErr || !user) {
      return json({ ok: false, error: 'unauthorized' }, 401);
    }

    // ── 주문 조회 ──
    const { data: order, error: orderErr } = await admin
      .from('payment_orders')
      .select('*')
      .eq('order_id', orderId)
      .maybeSingle();

    if (orderErr) {
      console.error('[toss-confirm] 주문 조회 실패', orderErr);
      return json({ ok: false, error: 'order_lookup_failed' });
    }
    if (!order) {
      return json({ ok: false, error: 'order_not_found' });
    }
    if (order.user_id !== user.id) {
      console.warn('[toss-confirm] 주문 소유자 불일치', orderId, order.user_id, user.id);
      return json({ ok: false, error: 'order_forbidden' }, 403);
    }

    // ── 멱등: 이미 승인된 주문 ──
    //   결제창 복귀 URL 은 새로고침·뒤로가기로 여러 번 열릴 수 있다.
    //   여기서 막지 않으면 예치금이 두 번 적립된다.
    if (order.status === 'paid') {
      return json({
        ok: true,
        already: true,
        orderId,
        amount: Number(order.amount),
        purpose: order.purpose,
      });
    }
    if (order.status !== 'pending') {
      return json({ ok: false, error: 'order_not_pending', status: order.status });
    }

    const expected = Number(order.amount);
    if (clientAmount && clientAmount !== expected) {
      // 브라우저가 다른 금액을 주장하고 있다. 승인을 시도하지 않는다.
      console.warn('[toss-confirm] 금액 불일치', orderId, clientAmount, expected);
      await admin.from('payment_orders')
        .update({ status: 'failed', fail_reason: 'amount_mismatch_client' })
        .eq('order_id', orderId).eq('status', 'pending');
      return json({ ok: false, error: 'amount_mismatch' });
    }

    // ── 토스 승인 ──
    //   Idempotency-Key 로 토스 쪽 중복 승인도 막는다.
    const basic = btoa(`${secretKey}:`);
    const tossRes = await fetch(TOSS_CONFIRM_URL, {
      method: 'POST',
      headers: {
        'Authorization': `Basic ${basic}`,
        'Content-Type': 'application/json',
        'Idempotency-Key': `taam-confirm-${orderId}`,
      },
      body: JSON.stringify({ paymentKey, orderId, amount: expected }),
    });

    const toss = await tossRes.json().catch(() => ({}));

    if (!tossRes.ok || toss.status !== 'DONE') {
      const reason = toss?.message || toss?.code || `http_${tossRes.status}`;
      console.warn('[toss-confirm] 승인 실패', orderId, reason, toss);
      await admin.from('payment_orders')
        .update({ status: 'failed', fail_reason: String(reason).slice(0, 300), metadata: { toss } })
        .eq('order_id', orderId).eq('status', 'pending');
      return json({ ok: false, error: 'confirm_failed', reason: String(reason) });
    }

    // 토스가 실제로 승인한 금액을 한 번 더 대조한다 (방어적)
    const approved = Number(toss.totalAmount ?? toss.balanceAmount ?? 0);
    if (approved !== expected) {
      console.error('[toss-confirm] 승인 금액 불일치', orderId, approved, expected);
      await admin.from('payment_orders')
        .update({ status: 'failed', fail_reason: `amount_mismatch_toss:${approved}`, metadata: { toss } })
        .eq('order_id', orderId).eq('status', 'pending');
      return json({ ok: false, error: 'amount_mismatch_toss' });
    }

    // ── 주문을 paid 로 확정 ──
    //   .eq('status','pending') 조건을 걸어, 동시에 두 요청이 들어와도
    //   한쪽만 성공하게 한다 (적립 이중 실행 방지).
    const { data: claimed, error: claimErr } = await admin
      .from('payment_orders')
      .update({
        status: 'paid',
        payment_key: paymentKey,
        method: toss.method || null,
        receipt_url: toss.receipt?.url || null,
        approved_at: toss.approvedAt || new Date().toISOString(),
        metadata: { toss },
      })
      .eq('order_id', orderId)
      .eq('status', 'pending')
      .select('order_id')
      .maybeSingle();

    if (claimErr) {
      console.error('[toss-confirm] 주문 확정 실패', orderId, claimErr);
      return json({ ok: false, error: 'order_update_failed', paid: true });
    }
    if (!claimed) {
      // 다른 요청이 먼저 확정했다 — 이미 적립됐으므로 성공으로 응답한다
      return json({ ok: true, already: true, orderId, amount: expected, purpose: order.purpose });
    }

    // ── 용도별 처리 ──
    if (order.purpose === 'deposit_charge') {
      const credited = await creditDeposit(admin, user.id, expected, orderId, toss);
      if (!credited.ok) {
        // 승인은 됐는데 적립에 실패한 상태. 돈은 받았으므로 주문을 되돌리지 않고
        // 흔적을 남겨 슈퍼어드민이 수동 보정할 수 있게 한다.
        await admin.from('payment_orders')
          .update({ fail_reason: 'credit_failed:' + credited.error })
          .eq('order_id', orderId);
        console.error('[toss-confirm] 승인 성공 · 적립 실패 — 수동 보정 필요', orderId, credited.error);
        return json({ ok: false, error: 'credit_failed', paid: true, orderId });
      }
      return json({ ok: true, orderId, amount: expected, purpose: order.purpose, balance: credited.balance });
    }

    // 그 외 용도는 아직 서버 처리가 없다 (1차 범위는 예치금 충전).
    return json({ ok: true, orderId, amount: expected, purpose: order.purpose });

  } catch (e) {
    console.error('[toss-confirm] 예외', e);
    return json({ ok: false, error: 'exception', detail: String(e).slice(0, 300) });
  }
});

// ── 예치금 적립 ──
//   기존 구조를 그대로 따른다:
//     ① profiles.general_deposit_balance 를 더한다 (합계 컬럼)
//     ② deposit_transactions 에 change_type='charge' 한 줄 넣는다
//        → trg_sync_split_balance 트리거가 charged_general_balance 를 맞춘다
async function creditDeposit(
  admin: ReturnType<typeof createClient>,
  userId: string,
  amount: number,
  orderId: string,
  toss: Record<string, unknown>,
): Promise<{ ok: true; balance: number } | { ok: false; error: string }> {
  const { data: prof, error: profErr } = await admin
    .from('profiles')
    .select('general_deposit_balance')
    .eq('id', userId)
    .maybeSingle();

  if (profErr || !prof) {
    return { ok: false, error: 'profile_not_found' };
  }

  const before = Number(prof.general_deposit_balance || 0);
  const after = before + amount;

  const { error: balErr } = await admin
    .from('profiles')
    .update({ general_deposit_balance: after })
    .eq('id', userId);

  if (balErr) return { ok: false, error: 'balance_update_failed' };

  const { error: trxErr } = await admin.from('deposit_transactions').insert({
    user_id: userId,
    deposit_type: 'general',
    change_type: 'charge',
    amount: amount,
    balance_after: after,
    description: '카드 충전 · 토스페이먼츠',
    metadata: {
      order_id: orderId,
      payment_key: toss.paymentKey || null,
      method: toss.method || null,
      approved_at: toss.approvedAt || null,
      receipt_url: (toss.receipt as Record<string, unknown> | undefined)?.url || null,
    },
  });

  if (trxErr) {
    // 잔액은 이미 올랐는데 거래기록이 없다 = 정합성 깨짐. 잔액을 되돌린다.
    await admin.from('profiles').update({ general_deposit_balance: before }).eq('id', userId);
    return { ok: false, error: 'transaction_insert_failed' };
  }

  return { ok: true, balance: after };
}
