// ════════════════════════════════════════════════════════════
// toss-order — 티켓 부족분 결제 주문 생성 Edge Function
// ════════════════════════════════════════════════════════════
// 작성일: 2026-08
//
// 왜 서버에서 만드는가
//   지금까지 결제 금액은 브라우저가 계산한 window._pendingShortage 였다.
//   DevTools 콘솔에서 그 값을 바꾸면 ₩500,000 짜리 티켓을 ₩1,000 만 내고 살 수 있다.
//   payment_orders 를 브라우저가 INSERT 하는 구조로는 막을 수 없다 — 회원이 금액을 정하기 때문이다.
//   → 티켓 가격과 예치금 잔액을 서버가 다시 읽어 부족분을 계산하고, 그 금액으로만 주문을 만든다.
//
// 하는 일
//   ① 티켓 조회 · 판매 상태 확인
//   ② 이용 등급(min_tier) 검증
//   ③ 좌석(총 정원 · 인원석 슬롯) 검증
//   ④ 금액 계산  total = (meal_fee + agency_fee + wine_min) × pax
//   ⑤ 예치금 잔액 조회 → 부족분 = max(0, total - balance)
//   ⑥ payment_orders 에 pending 주문 생성 (service_role)
//
// 반환한 orderId / amount 로만 결제창을 열고, 승인은 toss-confirm 이 한다.
//
// 필요한 시크릿: 없음 (SUPABASE_SERVICE_ROLE_KEY 는 런타임이 자동 주입)
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

const TIER_RANK: Record<string, number> = { M: 3, T: 2, A: 1 };
function tierRank(g: unknown): number {
  return TIER_RANK[String(g || '').toUpperCase()] || 0;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const body = await req.json().catch(() => ({}));
    const ticketId = String(body.ticketId || '').trim();
    const pax = parseInt(String(body.pax || '0'), 10) || 0;
    const currency = String(body.currency || 'KRW').toUpperCase();

    if (!ticketId || pax <= 0) return json({ ok: false, error: 'missing_params' });
    if (currency !== 'KRW') {
      // 외화 MID 는 토스 승인 대기 중이다. 열 때 fx 환산을 여기 추가한다.
      return json({ ok: false, error: 'currency_not_open', currency });
    }

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

    // ── ① 티켓 조회 ──
    const { data: ticket, error: tErr } = await admin
      .from('ticket_products')
      // ⚠ 컬럼명은 restaurant_id 가 아니라 rest_id 다. 틀리면 SELECT 자체가 실패해
      //   ticket_lookup_failed 로 떨어진다 (실제로 그렇게 막혔다).
      .select('id, rest_id, rest_name, meal_fee, agency_fee, wine_min, total_pax, slots, min_tier, status, type_class')
      .eq('id', ticketId)
      .maybeSingle();

    if (tErr) {
      console.error('[toss-order] 티켓 조회 실패', tErr);
      return json({ ok: false, error: 'ticket_lookup_failed', detail: String(tErr.message || tErr).slice(0, 300) });
    }
    if (!ticket) return json({ ok: false, error: 'ticket_not_found' });
    if (ticket.status === 'soldout') return json({ ok: false, error: 'sold_out' });
    if (ticket.status === 'closed' || ticket.status === 'expired') {
      return json({ ok: false, error: 'sales_closed' });
    }

    // ── ② 이용 등급 검증 ──
    //   등급은 profiles.membership_tier + membership_expires_at 로 결정한다
    //   (클라이언트 _refreshUserGrade 와 같은 규칙: M 은 만료일이 지나면 등급 없음).
    const { data: prof, error: pErr } = await admin
      .from('profiles')
      .select('membership_tier, membership_expires_at, membership_deposit_balance, general_deposit_balance')
      .eq('id', user.id)
      .maybeSingle();

    if (pErr || !prof) return json({ ok: false, error: 'profile_not_found' });

    const mActive = prof.membership_tier === 'M'
      && prof.membership_expires_at
      && new Date(prof.membership_expires_at) > new Date();
    const userTier = mActive ? 'M'
      : (prof.membership_tier === 'T' ? 'T' : (prof.membership_tier === 'A' ? 'A' : null));

    const need = String(ticket.min_tier || '').toUpperCase();
    if (TIER_RANK[need] && tierRank(userTier) < TIER_RANK[need]) {
      return json({ ok: false, error: 'tier_not_allowed', required: need, mine: userTier });
    }

    // ── ③ 좌석 검증 ──
    //   taam_ticket_sold_slots RPC 는 전 회원 합산 판매 좌석을 돌려준다
    //   (ticket_capacity_guard.sql). 미설치면 여기서 막지 않고 통과시킨다 —
    //   실제 오버셀은 구매 시점의 서버 트리거가 다시 막는다.
    const capTotal = parseInt(String(ticket.total_pax || '0'), 10) || 0;
    const slots = (ticket.slots && typeof ticket.slots === 'object')
      ? ticket.slots as Record<string, unknown> : {};

    if (capTotal > 0) {
      const { data: sold, error: sErr } = await admin
        .rpc('taam_ticket_sold_slots', { p_ticket_id: String(ticketId) });

      if (!sErr && sold) {
        const soldTotal = parseInt(String((sold as Record<string, unknown>).total ?? '-1'), 10);
        if (soldTotal >= 0) {
          const left = Math.max(0, capTotal - soldTotal);
          if (left <= 0) return json({ ok: false, error: 'sold_out' });
          if (pax > left) return json({ ok: false, error: 'not_enough_seats', left });
        }
        // 인원석 슬롯 소진 (고정 구성: 2인석 2개 → 2인 구매 2건이면 마감)
        const slotCap = parseInt(String(slots['s' + pax] ?? '0'), 10) || 0;
        const slotSold = parseInt(String((sold as Record<string, unknown>)['s' + pax] ?? '-1'), 10);
        const isFlex = String(slots.mode || '') === 'flex';
        if (!isFlex && slotCap > 0 && slotSold >= 0 && slotSold >= slotCap) {
          return json({ ok: false, error: 'slot_sold_out', pax });
        }
      } else if (sErr) {
        console.warn('[toss-order] taam_ticket_sold_slots 미설치/실패 — 좌석 검증 생략', sErr.message);
      }
    }

    // ── ④ 금액 계산 (서버 단독) ──
    const meal = parseInt(String(ticket.meal_fee || '0'), 10) || 0;
    const agency = parseInt(String(ticket.agency_fee || '0'), 10) || 0;
    const wine = parseInt(String(ticket.wine_min || '0'), 10) || 0;
    const total = (meal + agency + wine) * pax;
    if (total <= 0) return json({ ok: false, error: 'price_not_set' });

    // ── ⑤ 부족분 ──
    const balance = (Number(prof.membership_deposit_balance) || 0)
      + (Number(prof.general_deposit_balance) || 0);
    const shortage = Math.max(0, total - balance);

    if (shortage <= 0) {
      // 예치금만으로 살 수 있다 — 카드 결제가 필요 없다
      return json({ ok: true, needPayment: false, total, balance });
    }

    // ── ⑥ 주문 생성 ──
    const orderId = 'taamtkt_' + Date.now() + '_' + Math.floor(Math.random() * 100000);
    const { error: oErr } = await admin.from('payment_orders').insert({
      order_id: orderId,
      user_id: user.id,
      purpose: 'ticket_topup',
      amount: shortage,
      currency: 'KRW',
      settle_krw: shortage,
      status: 'pending',
      metadata: {
        ticket_id: ticketId,
        restaurant_id: ticket.rest_id || null,
        restaurant_name: ticket.rest_name || null,
        pax,
        total,
        balance_at_order: balance,
        meal_fee: meal, agency_fee: agency, wine_min: wine,
      },
    });

    if (oErr) {
      console.error('[toss-order] 주문 생성 실패', oErr);
      return json({ ok: false, error: 'order_create_failed' });
    }

    return json({
      ok: true,
      needPayment: true,
      orderId,
      amount: shortage,
      currency: 'KRW',
      total,
      balance,
    });

  } catch (e) {
    console.error('[toss-order] 예외', e);
    return json({ ok: false, error: 'exception', detail: String(e).slice(0, 300) });
  }
});
