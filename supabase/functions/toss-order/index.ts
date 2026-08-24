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
    // 🆕 결제하기 시점에 잡아둔 좌석 홀드. 있으면 좌석 재검증을 건너뛴다 —
    //   자기 홀드가 잔여석에 잡혀 있어 "매진" 으로 잘못 거절되기 때문이다.
    const holdPurchaseId = String(body.holdPurchaseId || '').trim();

    if (!ticketId || pax <= 0) return json({ ok: false, error: 'missing_params' });
    // ── 통화 검증 ──
    //   해외 MID(playtaamusd / playtaamjpy)는 승인 완료. 단, 해당 MID 의 시크릿 키가
    //   Secrets 에 등록돼 있어야 연다 — 키 없이 주문을 만들면 결제창 인증까지 마친 회원의
    //   승인(confirm)이 실패해 "결제했는데 아무것도 안 됨" 이 된다.
    if (currency !== 'KRW') {
      if (currency !== 'USD' && currency !== 'JPY') {
        return json({ ok: false, error: 'currency_not_open', currency });
      }
      if (!Deno.env.get('TOSS_SECRET_KEY_' + currency)) {
        console.warn('[toss-order] TOSS_SECRET_KEY_' + currency + ' 미등록 — 외화 주문 거부');
        return json({ ok: false, error: 'currency_not_open', currency });
      }
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
    //   ⚠ 컬럼명은 restaurant_id 가 아니라 rest_id 다. 틀리면 SELECT 자체가 실패해
    //     ticket_lookup_failed 로 떨어진다 (실제로 그렇게 막혔다).
    //   auto_soldout 은 "좌석이 차서 자동으로 걸린 매진"과 "슈퍼어드민 수동 매진"을
    //   구분하는 플래그다. 컬럼이 없는 환경도 있으므로 실패하면 없이 다시 조회한다.
    const BASE_COLS = 'id, rest_id, rest_name, meal_fee, agency_fee, wine_min, total_pax, slots, min_tier, status, type_class';
    // deno-lint-ignore no-explicit-any
    let ticket: any = null;
    // deno-lint-ignore no-explicit-any
    let tErr: any = null;
    {
      const r1 = await admin.from('ticket_products')
        .select(BASE_COLS + ', auto_soldout').eq('id', ticketId).maybeSingle();
      if (r1.error) {
        console.warn('[toss-order] auto_soldout 컬럼 없음 — 기본 컬럼으로 재조회', r1.error.message);
        const r2 = await admin.from('ticket_products')
          .select(BASE_COLS).eq('id', ticketId).maybeSingle();
        ticket = r2.data;
        tErr = r2.error;
      } else {
        ticket = r1.data;
      }
    }

    if (tErr) {
      console.error('[toss-order] 티켓 조회 실패', tErr);
      return json({ ok: false, error: 'ticket_lookup_failed', detail: String(tErr.message || tErr).slice(0, 300) });
    }
    if (!ticket) return json({ ok: false, error: 'ticket_not_found' });
    if (ticket.status === 'closed' || ticket.status === 'expired') {
      return json({ ok: false, error: 'sales_closed' });
    }

    // 🆕 판매 오픈 게이트 — 비공개(draft)·예약(scheduled, 시간 전)은 구매 불가.
    //   화면에서 안 보여도 REST 직접 호출로 살 수 있으면 게이트가 아니다.
    //   컬럼 미설치 DB 에서는 조용히 통과 (기존 동작 유지).
    try {
      const { data: saleRow, error: saleErr } = await admin.from('ticket_products')
        .select('sale_state, sale_open_at').eq('id', ticketId).maybeSingle();
      if (!saleErr && saleRow) {
        const ss = String(saleRow.sale_state || 'open');
        if (ss === 'draft') return json({ ok: false, error: 'sales_closed' });
        if (ss === 'scheduled') {
          const at = saleRow.sale_open_at ? new Date(String(saleRow.sale_open_at)) : null;
          if (!at || isNaN(at.getTime()) || at > new Date()) {
            return json({ ok: false, error: 'sales_closed' });
          }
        }
      }
    } catch (_se) { /* 컬럼 미설치 — 게이트 생략 */ }

    // ── 🆕 본인 좌석 홀드 확인 (매진 판정보다 먼저) ──
    //   "결제하기" 시점에 잡은 홀드는 그 자체로 좌석을 점유하므로, 마지막 1석을
    //   잡으면 자동 매진이 걸린다. 그 상태에서 매진을 먼저 보고 거절하면
    //   "자기 홀드 때문에 자기 결제가 거절되는" 자기차단이 된다 (정원 1석 티켓은 100% 발생).
    //   → 홀드를 먼저 확인하고, 홀드가 유효하면 '자동 매진'은 통과시킨다.
    //   ⚠ 단, 슈퍼어드민 수동 매진(auto_soldout=false)은 홀드가 있어도 절대 통과시키지 않는다.
    //     수동 매진은 웹/메신저/캘린더 등 외부 예약이 이미 잡혔다는 뜻이라 뚫으면 이중예약이 된다.
    let hasValidHold = false;
    if (holdPurchaseId) {
      const { data: hold } = await admin
        .from('tickets')
        .select('purchase_id, party_size, user_id, status')
        .eq('purchase_id', holdPurchaseId)
        .maybeSingle();
      hasValidHold = !!(hold && hold.user_id === user.id && hold.status === 'hold'
                        && Number(hold.party_size) === pax);
      if (!hasValidHold) {
        console.warn('[toss-order] 홀드 무효 — 좌석 재검증으로 진행', holdPurchaseId);
      }
    }

    if (ticket.status === 'soldout') {
      // auto_soldout 이 명시적으로 false = 수동 매진 → 무조건 거절.
      // 컬럼이 없거나(undefined) true = 좌석이 차서 걸린 자동 매진 → 본인 홀드가 있으면 통과.
      const isManualSoldout = ticket.auto_soldout === false;
      if (isManualSoldout || !hasValidHold) {
        return json({ ok: false, error: 'sold_out', manual: isManualSoldout });
      }
      console.log('[toss-order] 자동 매진이지만 본인 홀드 보유 — 통과', holdPurchaseId);
    }

    // ── ② 이용 등급 검증 ──
    //   등급은 profiles.membership_tier + membership_expires_at 로 결정한다
    //   (클라이언트 _refreshUserGrade 와 같은 규칙: M 은 만료일이 지나면 등급 없음).
    const { data: prof, error: pErr } = await admin
      .from('profiles')
      .select('*')
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

    // 홀드가 본인 것이고 살아 있으면 좌석은 이미 확보된 상태다 (hasValidHold 는 위에서 판정).
    if (capTotal > 0 && !hasValidHold) {
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
    let total = (meal + agency + wine) * pax;
    if (total <= 0) return json({ ok: false, error: 'price_not_set' });

    // ── ④-1 회원 통화 확정 ──
    //   profiles.currency 가 지정돼 있으면 클라이언트가 보낸 통화를 덮는다 —
    //   통화를 바꿔 보내 해외 정가를 피하는 우회를 서버가 막는다.
    //   지정 외화의 시크릿 키가 없으면 원화로 폴백 (결제가 막히면 안 된다).
    const profCur = String((prof as Record<string, unknown>).currency || '').toUpperCase();
    let effCur = (profCur === 'KRW' || profCur === 'USD' || profCur === 'JPY') ? profCur : currency;
    if (effCur !== 'KRW' && !Deno.env.get('TOSS_SECRET_KEY_' + effCur)) {
      console.warn('[toss-order] TOSS_SECRET_KEY_' + effCur + ' 미등록 — KRW 폴백');
      effCur = 'KRW';
    }

    // ── ④-2 환율 설정 (외화일 때만) ──
    let fxApplied = 0, fxBase = 0, fxMargin = 0;
    if (effCur !== 'KRW') {
      const { data: fxRow } = await admin.from('app_config')
        .select('value').eq('key', 'fx_settings').maybeSingle();
      const fx = (fxRow?.value || {}) as Record<string, unknown>;
      fxBase = effCur === 'USD' ? Number(fx.base_rate || 0) : Number(fx.rate_jpy || 0);
      fxMargin = Number(fx.margin_pct || 0);
      fxApplied = fxBase * (1 - fxMargin / 100);
      if (!(fxApplied > 0)) {
        console.warn('[toss-order] 환율 미설정 — KRW 폴백', effCur);
        effCur = 'KRW';
      }
    }

    // ── ④-3 확정 해외 정가 — 전 항목(0원 제외) 확정일 때만 외화 정가로 청구 ──
    //   화면($1,000)과 청구가 같은 근거를 가져야 한다. 하나라도 미확정이면 원화 정가.
    //   ovs_prices 컬럼이 없는 DB 에서도 죽지 않게 별도 조회 + 실패 무시.
    let fxFixed: { amount: number; agencyPer: number } | null = null;
    if (effCur !== 'KRW') {
      let side: Record<string, unknown> = {};
      let legacyAg = 0;
      try {
        const { data: ovsRow, error: ovsErr } = await admin.from('ticket_products')
          .select('ovs_prices, overseas_agency_usd').eq('id', ticketId).maybeSingle();
        if (!ovsErr && ovsRow) {
          const op = (ovsRow.ovs_prices || {}) as Record<string, Record<string, unknown>>;
          side = (effCur === 'JPY' ? op.jpy : op.usd) || {};
          legacyAg = Number(ovsRow.overseas_agency_usd || 0);
        }
      } catch (_oe) { /* 컬럼 미설치 — 환산 폴백 */ }
      const fixedOf = (comp: string, krw: number): number | null => {
        if (krw <= 0) return 0;                              // 0원 항목은 청구 없음
        const v = Number(side[comp] || 0);
        if (v > 0) return v;
        if (comp === 'agency' && effCur === 'USD' && legacyAg > 0) return legacyAg;
        return null;
      };
      const fm = fixedOf('meal', meal), fa = fixedOf('agency', agency), fw = fixedOf('wine', wine);
      if (fm != null && fa != null && fw != null && (fm + fa + fw) > 0) {
        fxFixed = { amount: (fm + fa + fw) * pax, agencyPer: fa };
        total = Math.round(fxFixed.amount * fxApplied);      // 원장 차감액 = 외화 정가 × 적용환율
      }
    }

    // ── ⑤ 부족분 ──
    const balance = (Number(prof.membership_deposit_balance) || 0)
      + (Number(prof.general_deposit_balance) || 0);
    const shortage = Math.max(0, total - balance);

    if (shortage <= 0) {
      // 예치금만으로 살 수 있다 — 카드 결제가 필요 없다
      return json({ ok: true, needPayment: false, total, balance });
    }

    // ── ⑤-2 외화 환산 (USD / JPY) ──
    //   설계(docs/TOSS_GOLIVE.md): 한 주문 안에 「얼마를 승인했나(amount·currency)」와
    //   「얼마를 적립했나(settle_krw)」를 각각 자기 통화로 고정한다. 주문 시점의
    //   적용환율을 metadata.fx 에 얼려두므로 이후 환율이 움직여도 이 주문은 변하지 않는다.
    //   환산은 반드시 서버가 한다 — 브라우저 값을 믿으면 $1 결제하고 수백만 원 적립이 가능하다.
    //   올림(ceil)으로 외화 정수 금액을 만든다 — 회원이 정가보다 덜 내는 일이 없게.
    let payAmount = shortage;
    let fxMeta: Record<string, unknown> | null = null;
    if (effCur !== 'KRW') {
      if (fxFixed && shortage >= total) {
        // 예치금 0 → 카드가 전액: 확정 정가 그대로 청구 ($1,000 · ¥74,000 딱 떨어짐)
        payAmount = fxFixed.amount;
      } else {
        payAmount = Math.ceil(shortage / fxApplied);
      }
      if (payAmount < 1) payAmount = 1;
      fxMeta = {
        base_rate: fxBase, margin_pct: fxMargin, applied_rate: fxApplied, shortage_krw: shortage,
        ...(fxFixed ? { fixed_price: true, price_fx: fxFixed.amount, agency_fx_per: fxFixed.agencyPer } : {}),
      };
    }

    // ── ⑥ 주문 생성 ──
    const orderId = 'taamtkt_' + Date.now() + '_' + Math.floor(Math.random() * 100000);
    const { error: oErr } = await admin.from('payment_orders').insert({
      order_id: orderId,
      user_id: user.id,
      purpose: 'ticket_topup',
      amount: payAmount,
      currency: effCur,
      settle_krw: shortage,
      status: 'pending',
      metadata: {
        ticket_id: ticketId,
        restaurant_id: ticket.rest_id || null,
        restaurant_name: ticket.rest_name || null,
        pax,
        total,
        balance_at_order: balance,
        // 대행비 스냅샷 — 외화 정가 구매는 정가 × 환율(원화 환산)로 얼린다 (반환 차감의 근거)
        meal_fee: meal,
        agency_fee: fxFixed ? Math.round(fxFixed.agencyPer * fxApplied) : agency,
        wine_min: wine,
        // 승인 후 이 홀드를 실제 구매로 전환한다
        hold_purchase_id: holdPurchaseId || null,
        deposit_used: Math.max(0, total - shortage),
        ...(fxMeta ? { fx: fxMeta } : {}),
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
      amount: payAmount,
      currency: effCur,
      settleKrw: shortage,
      total,
      balance,
    });

  } catch (e) {
    console.error('[toss-order] 예외', e);
    return json({ ok: false, error: 'exception', detail: String(e).slice(0, 300) });
  }
});
