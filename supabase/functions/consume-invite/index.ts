// ════════════════════════════════════════════════════════════
// consume-invite — TAAM 초대코드 사용 처리 Edge Function
// ════════════════════════════════════════════════════════════
// 작성일: 2026-05-20
// 가입 완료 직후 호출 → invite_codes 의 used=true, used_at, used_by_* 기록
// ════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: cors });
  }

  try {
    const body = await req.json().catch(() => ({}));
    const code = (body.code || '').toString().trim().toUpperCase();
    const name = (body.name || '').toString().trim();
    const phone = (body.phone || '').toString().trim();
    const email = (body.email || '').toString().trim().toLowerCase();

    if (!code) {
      return new Response(
        JSON.stringify({ ok: false, error: 'code missing' }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    // 🔒 2026-09-13: 가입을 마친 **그 사람**만 소진할 수 있다.
    //   종전에는 로그인만 돼 있으면 아는 코드를 남이 used 로 만들 수 있었다.
    const authHeader = req.headers.get('Authorization') || '';
    const token = authHeader.startsWith('Bearer ') ? authHeader.substring(7) : '';
    const { data: ud } = token ? await supabase.auth.getUser(token) : { data: null as any };
    const caller = ud?.user;
    if (!caller) {
      return new Response(
        JSON.stringify({ ok: false, error: 'login required' }),
        { status: 401, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }
    try {
      const ip = (req.headers.get('x-forwarded-for') || 'noip').split(',')[0].trim();
      const { data: allowed, error: rlErr } = await supabase.rpc('taam_rate_hit',
        { p_key: 'consume_invite:' + (caller.id || ip), p_limit: 10, p_window: '1 hour' });
      if (!rlErr && allowed === false) {
        return new Response(
          JSON.stringify({ ok: false, error: 'rate limited' }),
          { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
        );
      }
    } catch (_) { /* 제한기 미설치 — 통과 */ }

    // 코드 검증 (이미 used 인 경우 무시)
    const { data: row } = await supabase
      .from('invite_codes')
      .select('used, invitee_phone, invitee_email')
      .eq('code', code)
      .maybeSingle();

    if (!row) {
      return new Response(
        JSON.stringify({ ok: false, error: 'invite not found' }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }
    if (row.used === true) {
      // 이미 사용처리됨 — 멱등성 보장
      return new Response(
        JSON.stringify({ ok: true, already_used: true }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }

    // 초대장에 번호·이메일이 적혀 있으면 호출자의 인증된 번호·이메일과 맞아야 한다
    const normPhone = (p: string) => (p || '').replace(/[^0-9]/g, '').replace(/^82/, '').replace(/^0+/, '');
    const invPhone = normPhone(String(row.invitee_phone || ''));
    const invEmail = String(row.invitee_email || '').trim().toLowerCase();
    const myPhone = normPhone(String(caller.phone || ''));
    const myEmail = String(caller.email || '').trim().toLowerCase();
    const phoneMatch = !!invPhone && !!myPhone && invPhone === myPhone;
    const emailMatch = !!invEmail && !!myEmail && invEmail === myEmail;
    if ((invPhone || invEmail) && !phoneMatch && !emailMatch) {
      // 비교할 수 있는 항목이 하나라도 있는데 맞지 않으면 거부.
      //   (초대장은 번호만, 가입은 이메일로 — 처럼 비교할 항목이 없으면 통과: 가입을 막지 않는다)
      const comparable = (invPhone && myPhone) || (invEmail && myEmail);
      if (comparable) {
        return new Response(
          JSON.stringify({ ok: false, error: 'invite not for this account' }),
          { status: 403, headers: { ...cors, 'Content-Type': 'application/json' } }
        );
      }
    }

    const { error } = await supabase
      .from('invite_codes')
      .update({
        used: true,
        used_at: new Date().toISOString(),
        used_by_name: name,
        used_by_phone: phone || caller.phone || '',
        used_by_email: email || caller.email || '',
      })
      .eq('code', code)
      .eq('used', false);

    if (error) {
      return new Response(
        JSON.stringify({ ok: false, error: error.message }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ ok: true }),
      { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ ok: false, error: (e as Error).message || 'server error' }),
      { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
    );
  }
});
