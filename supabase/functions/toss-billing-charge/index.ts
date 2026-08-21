// ════════════════════════════════════════════════════════════
// toss-billing-charge — 등록된 카드로 즉시 결제 Edge Function
// ════════════════════════════════════════════════════════════
// 작성일: 2026-08
//
// 결제창을 띄우지 않고, 회원이 미리 등록해 둔 빌링키로 바로 승인한다.
//   ① 브라우저가 toss-order 로 주문(payment_orders)을 만든다 — 금액은 서버가 정한다
//   ② 이 함수가 그 orderId 로 빌링 승인 + 티켓 확정까지 끝낸다  ← 왕복(리다이렉트) 없음
//
// 승인 후 처리(예치금 차감 · 좌석 홀드 → 구매 전환 · 실패 시 자동취소)는
// toss-confirm 과 완전히 같은 규칙이다. toss-confirm 이 기준 구현이며,
// 실결제로 검증된 함수를 건드리지 않으려고 여기서는 같은 로직을 복제했다.
// ⚠ 한쪽만 고치면 두 결제 경로의 정산이 어긋난다 — 반드시 함께 고칠 것.
//
// 이 함수가 지키는 것 (toss-confirm 과 동일)
//   · 금액 위변조 차단 — 브라우저 금액이 아니라 payment_orders.amount 를 신뢰
//   · 소유권 확인      — 주문·빌링키 모두 호출자 본인 것이어야 한다
//   · 멱등성           — 이미 paid 인 주문은 다시 적립하지 않는다
//   · 좌석 상실 대응   — 승인 후 좌석이 없으면 예치금 환원 + 카드 승인취소
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
      console.error('[toss-billing-charge] TOSS_BILLING_SECRET_KEY / TOSS_SECRET_KEY 둘 다 미설정');
      return json({ ok: false, error: 'server_not_configured' });
    }

    const body = await req.json().catch(() => ({}));
    const orderId = String(body.orderId || '').trim();
    const orderName = String(body.orderName || '티켓 구매').slice(0, 100);
    if (!orderId) return json({ ok: false, error: 'missing_params' });

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

    // ── 주문 ──
    const { data: order, error: orderErr } = await admin
      .from('payment_orders').select('*').eq('order_id', orderId).maybeSingle();
    if (orderErr) {
      console.error('[toss-billing-charge] 주문 조회 실패', orderErr);
      return json({ ok: false, error: 'order_lookup_failed' });
    }
    if (!order) return json({ ok: false, error: 'order_not_found' });
    if (order.user_id !== user.id) {
      console.warn('[toss-billing-charge] 주문 소유자 불일치', orderId);
      return json({ ok: false, error: 'order_forbidden' }, 403);
    }
    if (order.status === 'paid') {
      return json({ ok: true, already: true, orderId, amount: Number(order.amount), purpose: order.purpose });
    }
    if (order.status !== 'pending') {
      return json({ ok: false, error: 'order_not_pending', status: order.status });
    }

    const expected = Number(order.amount);
    if (!(expected > 0)) return json({ ok: false, error: 'amount_invalid' });

    // ── 결제수단(빌링키) ──
    //   기본카드 우선, 없으면 가장 최근 등록 카드.
    const { data: cards, error: ckErr } = await admin
      .from('billing_keys')
      .select('id, billing_key, customer_key, card_company, card_number, is_default')
      .eq('user_id', user.id).is('deleted_at', null)
      .order('is_default', { ascending: false })
      .order('created_at', { ascending: false })
      .limit(1);
    if (ckErr) {
      console.error('[toss-billing-charge] 카드 조회 실패', ckErr);
      return json({ ok: false, error: 'card_lookup_failed' });
    }
    const card = cards && cards[0];
    if (!card) return json({ ok: false, error: 'no_billing_key' });

    // ── 빌링 승인 ──
    //   Idempotency-Key 를 orderId 로 고정해 재시도해도 두 번 결제되지 않게 한다.
    const basic = btoa(`${secretKey}:`);
    const tossRes = await fetch(
      `https://api.tosspayments.com/v1/billing/${encodeURIComponent(card.billing_key)}`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${basic}`,
          'Content-Type': 'application/json',
          'Idempotency-Key': `taam-billing-${orderId}`,
        },
        body: JSON.stringify({
          customerKey: card.customer_key || user.id,
          amount: expected,
          orderId,
          orderName,
          customerEmail: user.email || undefined,
        }),
      },
    );
    const toss = await tossRes.json().catch(() => ({}));

    if (!tossRes.ok || toss.status !== 'DONE') {
      const reason = toss?.message || toss?.code || `http_${tossRes.status}`;
      console.warn('[toss-billing-charge] 승인 실패', orderId, String(reason).slice(0, 200));
      await admin.from('payment_orders')
        .update({ status: 'failed', fail_reason: String(reason).slice(0, 300), metadata: { toss } })
        .eq('order_id', orderId).eq('status', 'pending');
      return json({ ok: false, error: 'charge_failed', reason: String(reason).slice(0, 200) });
    }

    const paymentKey = String(toss.paymentKey || '');
    const approved = Number(toss.totalAmount ?? toss.balanceAmount ?? 0);
    if (approved !== expected) {
      console.error('[toss-billing-charge] 승인 금액 불일치', orderId, approved, expected);
      await cancelTossPayment(secretKey, paymentKey, '금액 불일치');
      await admin.from('payment_orders')
        .update({ status: 'failed', fail_reason: `amount_mismatch_toss:${approved}`, metadata: { toss } })
        .eq('order_id', orderId).eq('status', 'pending');
      return json({ ok: false, error: 'amount_mismatch_toss' });
    }

    // ── 주문 확정 (동시 요청 중 하나만 통과) ──
    const { data: claimed, error: claimErr } = await admin
      .from('payment_orders')
      .update({
        status: 'paid',
        payment_key: paymentKey,
        method: toss.method || 'billing',
        receipt_url: toss.receipt?.url || null,
        approved_at: toss.approvedAt || new Date().toISOString(),
        metadata: { ...(order.metadata || {}), toss, paid_via: 'billing_key', billing_key_id: card.id },
      })
      .eq('order_id', orderId).eq('status', 'pending')
      .select('order_id').maybeSingle();

    if (claimErr) {
      console.error('[toss-billing-charge] 주문 확정 실패', orderId, claimErr);
      return json({ ok: false, error: 'order_update_failed', paid: true });
    }
    if (!claimed) {
      return json({ ok: true, already: true, orderId, amount: expected, purpose: order.purpose });
    }

    // ── 티켓 확정 (toss-confirm 과 동일 규칙) ──
    if (order.purpose === 'ticket_topup') {
      const meta = (order.metadata || {}) as Record<string, unknown>;
      const total = Number(meta.total || 0);
      const depositUsed = Math.max(0, Number(meta.deposit_used || 0));
      const holdId = String(meta.hold_purchase_id || '');
      const cardPaid = expected;

      let deductedDeposit = 0;
      if (depositUsed > 0) {
        const ded = await deductDeposit(admin, user.id, depositUsed, {
          purchase_id: holdId, ticket_id: meta.ticket_id, restaurant_name: meta.restaurant_name,
          party_size: meta.pax, order_id: orderId,
        });
        deductedDeposit = ded.deducted;
        if (ded.deducted < depositUsed) {
          console.warn('[toss-billing-charge] 예치금 부족(결제 중 변동)', ded.deducted, '/', depositUsed, orderId);
        }
      }

      const conv = await convertHoldToActive(admin, user.id, holdId, order, total, cardPaid, deductedDeposit);

      if (!conv.ok) {
        if (deductedDeposit > 0) {
          await refundDeposit(admin, user.id, deductedDeposit, orderId).catch(() => {});
        }
        const canceled = await cancelTossPayment(secretKey, paymentKey, '좌석 만료로 구매 불가');
        await admin.from('payment_orders')
          .update({ status: canceled ? 'canceled' : 'paid',
                    fail_reason: 'seat_lost' + (canceled ? '_refunded' : '_refund_failed') })
          .eq('order_id', orderId);
        console.error('[toss-billing-charge] 승인 후 좌석 상실', orderId, conv.reason, 'card_cancel=', canceled);
        return json({ ok: false, error: 'seat_lost', refunded: canceled, orderId });
      }

      // 🆕 구매 성공 → 슈퍼어드민 푸시 (toss-confirm 과 같은 규칙 — 카드 경로는
      //   승인이 서버에서 끝나므로 서버가 보내야 한다)
      notifyAdmins(admin, user.id, {
        rest: String(meta.restaurant_name || '티켓'),
        pax: Number(meta.pax || 0),
        amount: cardPaid,
        purchaseId: conv.purchaseId,
      }).catch((e) => console.warn('[toss-billing-charge] 관리자 푸시 실패(구매는 정상):', e));

      return json({
        ok: true, orderId, amount: expected, purpose: 'ticket_topup',
        total, depositUsed: deductedDeposit, cardPaid,
        purchaseId: conv.purchaseId,
        card: { company: card.card_company, number: card.card_number },
      });
    }

    return json({ ok: true, orderId, amount: expected, purpose: order.purpose });

  } catch (e) {
    console.error('[toss-billing-charge] 예외', e);
    return json({ ok: false, error: 'exception', detail: String(e).slice(0, 300) });
  }
});

// ────────────────────────────────────────────────────────────
// 아래 네 함수는 toss-confirm/index.ts 와 동일하다.
// 검증된 함수를 건드리지 않으려고 복제했다 — 한쪽만 고치지 말 것.
// ────────────────────────────────────────────────────────────

// 예치금 차감 (멤버십 먼저, 부족분 일반)
async function deductDeposit(
  admin: ReturnType<typeof createClient>,
  userId: string,
  want: number,
  meta: Record<string, unknown>,
): Promise<{ deducted: number }> {
  const { data: prof } = await admin.from('profiles')
    .select('membership_deposit_balance, general_deposit_balance, deposit_balance')
    .eq('id', userId).maybeSingle();
  if (!prof) return { deducted: 0 };

  const mem = Number(prof.membership_deposit_balance || 0);
  const gen = Number(prof.general_deposit_balance || 0);
  const totalBal = Number(prof.deposit_balance ?? (mem + gen));
  const deduct = Math.min(want, totalBal);
  if (deduct <= 0) return { deducted: 0 };

  const fromMem = Math.min(mem, deduct);
  const fromGen = deduct - fromMem;

  await admin.from('profiles').update({
    membership_deposit_balance: mem - fromMem,
    general_deposit_balance: gen - fromGen,
    deposit_balance: totalBal - deduct,
  }).eq('id', userId);

  const rows: Record<string, unknown>[] = [];
  let after = totalBal;
  if (fromMem > 0) {
    after -= fromMem;
    rows.push({ user_id: userId, deposit_type: 'membership', change_type: 'ticket_purchase',
      amount: -fromMem, balance_after: after,
      description: (meta.restaurant_name || '티켓') + ' 카드결제 · 멤버십 예치금 차감',
      metadata: { ...meta, portion: 'membership' } });
  }
  if (fromGen > 0) {
    after -= fromGen;
    rows.push({ user_id: userId, deposit_type: 'general', change_type: 'ticket_purchase',
      amount: -fromGen, balance_after: after,
      description: (meta.restaurant_name || '티켓') + ' 카드결제 · 일반 예치금 차감',
      metadata: { ...meta, portion: 'general' } });
  }
  if (rows.length) await admin.from('deposit_transactions').insert(rows);
  return { deducted: deduct };
}

// 좌석 상실 시 차감한 예치금을 되돌린다 (일반 예치금으로 환원)
async function refundDeposit(
  admin: ReturnType<typeof createClient>,
  userId: string,
  amount: number,
  orderId: string,
): Promise<void> {
  const { data: prof } = await admin.from('profiles')
    .select('general_deposit_balance, deposit_balance').eq('id', userId).maybeSingle();
  if (!prof) return;
  const gen = Number(prof.general_deposit_balance || 0) + amount;
  const bal = Number(prof.deposit_balance || 0) + amount;
  await admin.from('profiles').update({ general_deposit_balance: gen, deposit_balance: bal }).eq('id', userId);
  await admin.from('deposit_transactions').insert({
    user_id: userId, deposit_type: 'general', change_type: 'ticket_refund',
    amount: amount, balance_after: bal,
    description: '좌석 만료 취소 · 예치금 환원', metadata: { order_id: orderId },
  });
}

// 좌석 홀드 → 실제 구매
async function convertHoldToActive(
  admin: ReturnType<typeof createClient>,
  userId: string,
  holdId: string,
  order: Record<string, unknown>,
  total: number,
  cardPaid: number,
  depositUsed: number,
): Promise<{ ok: true; purchaseId: string } | { ok: false; reason: string }> {
  const meta = (order.metadata || {}) as Record<string, unknown>;
  const extra = {
    seatHold: false, cardPaid, depositUsed,
    buyerRole: 'user',
    agencyFee: Number(meta.agency_fee || 0),
    paidBy: 'card+deposit', order_id: order.order_id,
  };

  if (holdId) {
    const { data: up } = await admin.from('tickets')
      .update({ status: 'active', price: total, extra_data: extra })
      .eq('purchase_id', holdId).eq('user_id', userId).eq('status', 'hold')
      .select('purchase_id');
    if (up && up.length) return { ok: true, purchaseId: holdId };
  }

  const pid = holdId || ('PAYC-' + String(meta.ticket_id || '') + '_' + Date.now());
  const { error: insErr } = await admin.from('tickets').insert({
    user_id: userId,
    restaurant_id: String(meta.restaurant_id || ''),
    restaurant_name: meta.restaurant_name || '',
    ticket_product_id: String(meta.ticket_id || ''),
    reservation_date: null,
    party_size: Number(meta.pax || 0),
    price: total,
    status: 'active',
    purchase_id: pid,
    extra_data: extra,
    created_at: new Date().toISOString(),
  });
  if (insErr) return { ok: false, reason: String(insErr.message || insErr).slice(0, 200) };
  return { ok: true, purchaseId: pid };
}

// 토스 결제 취소
async function cancelTossPayment(secretKey: string, paymentKey: string, reason: string): Promise<boolean> {
  if (!paymentKey) return false;
  try {
    const basic = btoa(`${secretKey}:`);
    const res = await fetch(`https://api.tosspayments.com/v1/payments/${paymentKey}/cancel`, {
      method: 'POST',
      headers: {
        'Authorization': `Basic ${basic}`,
        'Content-Type': 'application/json',
        'Idempotency-Key': `taam-cancel-${paymentKey}`,
      },
      body: JSON.stringify({ cancelReason: reason }),
    });
    return res.ok;
  } catch (e) {
    console.error('[toss-billing-charge] 결제 취소 실패', e);
    return false;
  }
}

// ── 구매 알림 → 슈퍼어드민 (toss-confirm 과 동일) ────────────
async function notifyAdmins(
  admin: ReturnType<typeof createClient>,
  buyerId: string,
  info: { rest: string; pax: number; amount: number; purchaseId: string },
) {
  const base = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!base || !key) return;
  let who = '회원';
  try {
    const { data } = await admin.from('profiles').select('display_name').eq('id', buyerId).maybeSingle();
    if (data && data.display_name) who = String(data.display_name);
  } catch (_e) { /* 이름은 장식 — 못 읽어도 보낸다 */ }
  const body = who + '님 · ' + info.rest + (info.pax ? ' · ' + info.pax + '인' : '')
             + ' · \u20A9' + Number(info.amount || 0).toLocaleString() + ' (카드)';
  for (const role of ['superadmin', 'super_admin']) {
    try {
      await fetch(base + '/functions/v1/send-push', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + key },
        body: JSON.stringify({
          to: 'role:' + role,
          payload: {
            title: '\uD83C\uDFAB ' + who + '님이 티켓을 구매했습니다',
            body,
            url: '/',
            category: 'ticket_purchased',
            tag: 'taam-tpurchase-' + info.purchaseId,
          },
        }),
      });
    } catch (_e) { /* 한쪽 실패해도 다른 쪽은 보낸다 */ }
  }
}
