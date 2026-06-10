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

    // 코드 검증 (이미 used 인 경우 무시)
    const { data: row } = await supabase
      .from('invite_codes')
      .select('used')
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

    const { error } = await supabase
      .from('invite_codes')
      .update({
        used: true,
        used_at: new Date().toISOString(),
        used_by_name: name,
        used_by_phone: phone,
        used_by_email: email,
      })
      .eq('code', code);

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
