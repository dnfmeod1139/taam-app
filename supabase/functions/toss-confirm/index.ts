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
//   TOSS_SECRET_KEY     = live_sk_...   국내 MID(playtauif6)
//   TOSS_SECRET_KEY_USD = live_sk_...   해외 MID(playtaamusd) — USD 승인 · KRW 정산
//   TOSS_SECRET_KEY_JPY = live_sk_...   해외 MID(playtaamjpy) — JPY 승인 · KRW 정산
//   ⚠ 코드·커밋에 절대 넣지 말 것
//
// 외화 주문(USD/JPY)의 원칙 — docs/TOSS_GOLIVE.md
//   승인은 주문의 통화·금액(amount·currency) 그대로, 원화 쪽 정산(예치금 차감·티켓
//   확정·기록)은 주문 생성 때 서버가 얼려둔 settle_krw 로 한다. 둘을 섞지 않는다.
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
    // 기본(국내) 시크릿. 외화 주문이면 주문 조회 후 통화별 시크릿으로 바꾼다 —
    // 토스는 MID 마다 키가 달라서, 국내 키로 외화 승인 호출하면 무조건 거절된다.
    let secretKey = Deno.env.get('TOSS_SECRET_KEY');
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

    // ── 외화 주문 → 통화별 시크릿 키 선택 ──
    const orderCur = String(order.currency || 'KRW').toUpperCase();
    if (orderCur !== 'KRW') {
      const fxSecret = Deno.env.get('TOSS_SECRET_KEY_' + orderCur);
      if (!fxSecret) {
        console.error('[toss-confirm] TOSS_SECRET_KEY_' + orderCur + ' 미설정');
        return json({ ok: false, error: 'server_not_configured', currency: orderCur });
      }
      secretKey = fxSecret;
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

    // ── 티켓 부족분 카드 결제 → 티켓 직접 구매 ──
    //   정책: 카드로 들어온 돈은 예치금을 거치지 않고 그 자리에서 티켓을 산다.
    //   총액 = 예치금 사용분(deposit_used) + 카드 결제분(shortage).
    //   좌석은 "결제하기" 시점에 이미 홀드로 잡혀 있으므로, 여기서는 그 홀드를
    //   실제 구매(status='active')로 전환하기만 하면 된다 — 좌석이 비지 않는다.
    if (order.purpose === 'ticket_topup') {
      const meta = (order.metadata || {}) as Record<string, unknown>;
      const total = Number(meta.total || 0);
      const depositUsed = Math.max(0, Number(meta.deposit_used || 0));
      const holdId = String(meta.hold_purchase_id || '');
      // 원화 쪽 정산 금액 — 외화 주문은 승인액(expected)이 $·¥ 라서 그대로 쓰면
      // 원장이 통째로 어긋난다. 주문 생성 때 얼려둔 settle_krw 를 쓴다.
      const cardPaid = (orderCur === 'KRW') ? expected : (Number(order.settle_krw) || 0);

      // ① 예치금 사용분 차감 (있으면). 결제 진행 중 잔액이 줄었을 수 있으니
      //   실제 잔액을 다시 읽어 그만큼만 뺀다 (음수 방지 · 회원 불리 방지).
      let deductedDeposit = 0;
      if (depositUsed > 0) {
        const ded = await deductDeposit(admin, user.id, depositUsed, {
          purchase_id: holdId, ticket_id: meta.ticket_id, restaurant_name: meta.restaurant_name,
          party_size: meta.pax, order_id: orderId,
        });
        deductedDeposit = ded.deducted;
        if (ded.deducted < depositUsed) {
          console.warn('[toss-confirm] 예치금 부족(결제 중 변동) — 뺀 금액', ded.deducted, '/', depositUsed, orderId);
        }
      }

      // ② 좌석 홀드를 실제 구매로 전환
      const conv = await convertHoldToActive(admin, user.id, holdId, order, total, cardPaid, deductedDeposit);

      if (!conv.ok) {
        // 좌석이 사라졌다(홀드 만료 등). 돈을 그냥 삼킬 수 없으므로:
        //   차감한 예치금을 되돌리고 · 카드 결제를 취소하고 · 회원에게 알린다.
        if (deductedDeposit > 0) {
          await refundDeposit(admin, user.id, deductedDeposit, orderId).catch(() => {});
        }
        const canceled = await cancelTossPayment(secretKey, paymentKey, '좌석 만료로 구매 불가');
        await admin.from('payment_orders')
          .update({ status: canceled ? 'canceled' : 'paid',
                    fail_reason: 'seat_lost' + (canceled ? '_refunded' : '_refund_failed') })
          .eq('order_id', orderId);
        console.error('[toss-confirm] 승인 후 좌석 상실', orderId, conv.reason, 'card_cancel=', canceled);
        return json({ ok: false, error: 'seat_lost', refunded: canceled, orderId });
      }

      // 🆕 구매 성공 → 슈퍼어드민 푸시.
      //   예치금 결제는 클라이언트(completePurchase)가 보내지만, 카드 결제는
      //   승인이 서버에서 끝나므로 여기서 보내야 한다 — 안 보내면 카드 구매만
      //   조용히 지나간다 (실제로 그랬다).
      notifyAdmins(admin, user.id, {
        rest: String(meta.restaurant_name || '티켓'),
        pax: Number(meta.pax || 0),
        amount: cardPaid,
        purchaseId: conv.purchaseId,
      }).catch((e) => console.warn('[toss-confirm] 관리자 푸시 실패(구매는 정상):', e));

      return json({
        ok: true, orderId, amount: expected, purpose: 'ticket_topup',
        total, depositUsed: deductedDeposit, cardPaid,
        purchaseId: conv.purchaseId,
        ticket: meta,
      });
    }

    // deposit_charge (예치금 카드 충전) 는 현재 정책에서 쓰지 않는다.
    //   예치금 충전은 계좌이체 전용. 남겨두되 도달하면 안내만 한다.
    if (order.purpose === 'deposit_charge') {
      await admin.from('payment_orders')
        .update({ fail_reason: 'deposit_charge_disabled' }).eq('order_id', orderId);
      return json({ ok: false, error: 'deposit_charge_disabled', paid: true, orderId });
    }

    return json({ ok: true, orderId, amount: expected, purpose: order.purpose });

  } catch (e) {
    console.error('[toss-confirm] 예외', e);
    return json({ ok: false, error: 'exception', detail: String(e).slice(0, 300) });
  }
});

// ── 예치금 차감 (멤버십 먼저, 부족분 일반) ──
//   클라이언트 completePurchase 의 차감 로직을 그대로 미러링한다.
//   main 컬럼(membership/general/deposit_balance)을 직접 갱신하고,
//   deposit_transactions INSERT 는 split 트리거가 charged_* 를 맞추게 한다.
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
  const newMem = mem - fromMem;
  const newGen = gen - fromGen;

  await admin.from('profiles').update({
    membership_deposit_balance: newMem,
    general_deposit_balance: newGen,
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

// 좌석 홀드 → 실제 구매. 홀드가 있으면 UPDATE, 없으면(만료) 새로 INSERT 하며
//   좌석 트리거가 재검증한다. 트리거가 거부하면 좌석이 없는 것이다.
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
  const orderCur = String(order.currency || 'KRW').toUpperCase();
  const extra = {
    seatHold: false, cardPaid, depositUsed,
    buyerRole: 'user',
    agencyFee: Number(meta.agency_fee || 0),
    paidBy: 'card+deposit', order_id: order.order_id,
    // 외화 결제 흔적 — 환불(카드 원거래 취소)은 이 통화·이 금액 그대로 한다.
    //   cardPaid 는 원화 정산액(settle_krw)이고, 실제 카드 승인은 card_amount_fx 였다.
    ...(orderCur !== 'KRW' ? { card_currency: orderCur, card_amount_fx: Number(order.amount) || 0 } : {}),
  };

  if (holdId) {
    const { data: up } = await admin.from('tickets')
      .update({ status: 'active', price: total, extra_data: extra })
      .eq('purchase_id', holdId).eq('user_id', userId).eq('status', 'hold')
      .select('purchase_id');
    if (up && up.length) return { ok: true, purchaseId: holdId };
    // 홀드가 이미 만료/취소됨 → 아래에서 새로 INSERT 시도
  }

  // 홀드 없음(만료) → 좌석 트리거로 재검증하며 INSERT
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
  if (insErr) {
    return { ok: false, reason: String(insErr.message || insErr).slice(0, 200) };
  }
  return { ok: true, purchaseId: pid };
}

// 토스 결제 취소 (좌석 상실 시 환불)
async function cancelTossPayment(secretKey: string, paymentKey: string, reason: string): Promise<boolean> {
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
    console.error('[toss-confirm] 결제 취소 실패', e);
    return false;
  }
}

// ── 구매 알림 → 슈퍼어드민 ─────────────────────────────────
//   send-push 를 서버에서 서버로 부른다(service role). 실패해도 구매에는 영향 없다.
//   role 문자열이 환경마다 'superadmin'/'super_admin' 으로 갈려 양쪽에 보낸다
//   (클라이언트의 예치금 경로와 같은 규칙).
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
    // 이름을 못 찾으면 「회원님이 구매했습니다」로 나가 누가 샀는지 알 수 없다.
    //   실제로 display_name 이 빈 회원이 여럿이라 그 알림이 계속 나갔다.
    //   ① 프로필 이름 → ② 이 구매에 적힌 이름 → ③ 번호 뒷자리 순으로 찾는다.
    const { data } = await admin.from('profiles')
      .select('display_name, phone').eq('id', buyerId).maybeSingle();
    if (data && data.display_name && String(data.display_name).trim()) {
      who = String(data.display_name).trim();
    } else {
      const { data: tk } = await admin.from('tickets')
        .select('buyer_name, buyer_phone').eq('purchase_id', info.purchaseId).maybeSingle();
      if (tk && tk.buyer_name && String(tk.buyer_name).trim()) {
        who = String(tk.buyer_name).trim();
      } else {
        const tail = String((data && data.phone) || (tk && tk.buyer_phone) || '')
          .replace(/[^0-9]/g, '').slice(-4);
        if (tail) who = '회원 ' + tail;
      }
    }
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
