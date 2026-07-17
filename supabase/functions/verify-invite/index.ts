// ════════════════════════════════════════════════════════════
// verify-invite — TAAM 초대코드 검증 Edge Function
// ════════════════════════════════════════════════════════════
// 작성일: 2026-05-20
// 두 가지 모드:
//   1) mode = 'welcome' — 코드 + 사용여부 + 만료만 검증 (codeScreen 입장 단계)
//      응답: { ok, invitee_name, country }
//   2) mode 없음 — 코드 + 이름 + (휴대폰 또는 이메일) 매칭 (phoneScreen OTP 후)
//      응답: { ok, invitee_name, country } 또는 { ok: false, error }
// ════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// 정규화 헬퍼: 공백 제거 + 소문자 (이름 / 이메일 매칭용)
function norm(s: string): string {
  return (s || '').toString().replace(/\s+/g, '').toLowerCase();
}

// 휴대폰 정규화 — 숫자만 추출 + 국가코드/선행0 제거
function normPhone(p: string): string {
  const d = (p || '').replace(/[^0-9]/g, '');
  // +82 → 82..., 한국번호는 그대로 비교 가능하게 맞춤
  return d.replace(/^82/, '').replace(/^0+/, '');
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: cors });
  }

  try {
    const body = await req.json().catch(() => ({}));
    const code = (body.code || '').toString().trim().toUpperCase();
    const mode = (body.mode || '').toString();
    const name = (body.name || '').toString().trim();
    const phone = (body.phone || '').toString().trim();
    const email = (body.email || '').toString().trim().toLowerCase();
    const country = (body.country || 'EN').toString().toUpperCase();

    if (!code) {
      return new Response(
        JSON.stringify({ ok: false, error: '초대코드가 없습니다' }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }

    // Service Role Key 로 RLS 우회 — invite_codes 전체 조회 권한
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    // ── 1) 코드 조회 ──
    const { data: row, error: qErr } = await supabase
      .from('invite_codes')
      .select('*')
      .eq('code', code)
      .maybeSingle();

    if (qErr) {
      return new Response(
        JSON.stringify({ ok: false, error: 'DB 조회 실패: ' + qErr.message }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }
    if (!row) {
      return new Response(
        JSON.stringify({ ok: false, error: '유효하지 않은 초대코드' }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }

    // ── 2) 사용 여부 체크 ──
    if (row.used === true) {
      return new Response(
        JSON.stringify({ ok: false, error: '이미 사용된 초대코드' }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }

    // ── 3) 만료 체크 ──
    if (row.expires_at) {
      const expires = new Date(row.expires_at);
      if (!isNaN(expires.getTime()) && expires < new Date()) {
        return new Response(
          JSON.stringify({ ok: false, error: '만료된 초대코드' }),
          { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ── 4) welcome 모드 — 여기서 종료, 추가 정보 반환 ──
    if (mode === 'welcome') {
      // 🔧 2026.07: '이미 가입' 사전 차단 제거.
      //   원인 1) signInWithOtp(shouldCreateUser:true) 가 OTP "발송 시점"에 미인증
      //     유령 계정을 만들어, 가입을 완료 못 한 사람이 재시도하면 자기 유령에게
      //     막혔음 ("이미 가입된 회원입니다" 반복 발생 버그).
      //   원인 2) OTP 를 입력한 순간 계정이 '인증 완료'가 되므로, 어떤 판정을 써도
      //     중단-재개 가입자를 기존 회원과 구분할 수 없음.
      //   → welcome 단계는 코드 유효성(존재/미사용/미만료)만 본다.
      //     · 진짜 기존 회원의 옛 코드 재입력은 위 used=true 검사가 이미 차단.
      //     · 기존 회원이 새 코드를 받은 경우: 플로우가 OTP 로그인→코드 소진으로
      //       자연 수렴 (부작용 없음).
      return new Response(
        JSON.stringify({
          ok: true,
          invitee_name: row.invitee_name || '',
          country: row.country || 'EN',
        }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }

    // ── 5) 가입 검증 모드 — 이름 + (휴대폰 또는 이메일) 매칭 ──
    const inviteeName = (row.invitee_name || '').trim();
    const inviteePhone = (row.invitee_phone || '').trim();
    const inviteeEmail = (row.invitee_email || '').trim().toLowerCase();

    // 🔧 2026.07: 가입 검증 단계 '이미 가입' 체크 — 본인 제외(self-exclusion)로 수정.
    //   이 단계는 OTP 인증 "직후"에 호출되므로 호출자 본인의 계정이 방금 인증 완료
    //   상태가 됨 → 종전 검사(email_exists_in_auth)는 자기 자신을 '이미 가입'으로
    //   차단해 이메일 가입이 마지막 단계에서 실패하던 버그.
    //   → 호출자 JWT 의 user id 를 제외하고, '다른' 인증완료 계정이 그 이메일을
    //     쓰는 경우만 차단 (email_exists_in_auth_other RPC).
    if (email) {
      try {
        let callerId: string | null = null;
        try {
          const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
          if (jwt) {
            const { data: caller } = await supabase.auth.getUser(jwt);
            callerId = caller?.user?.id || null;
          }
        } catch (_) { /* JWT 없음/무효 — callerId null 로 진행 */ }
        const { data: takenByOther } = await supabase.rpc('email_exists_in_auth_other', {
          email_to_check: email,
          exclude_id: callerId,
        });
        if (takenByOther === true) {
          return new Response(
            JSON.stringify({
              ok: false,
              error: '이미 가입된 이메일입니다. 로그인 화면을 이용해주세요.',
              already_member: true,
            }),
            { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
          );
        }
      } catch (e) {
        // RPC 실패는 치명적이지 않음 (이름+이메일 매칭으로 fall-through)
        console.warn('email_exists_in_auth_other check skipped:', (e as Error).message);
      }
    }

    // 이름이 invite_codes 에 등록돼 있으면 반드시 일치해야 함
    if (inviteeName && norm(inviteeName) !== norm(name)) {
      return new Response(
        JSON.stringify({
          ok: false,
          error: '이름이 초대 정보와 일치하지 않습니다. 초대받으신 이름을 정확히 입력해주세요.',
        }),
        { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
      );
    }

    // 국가별 분기: 한국=휴대폰 / 해외=이메일
    if (country === 'KR') {
      if (inviteePhone && normPhone(inviteePhone) !== normPhone(phone)) {
        return new Response(
          JSON.stringify({
            ok: false,
            error: '휴대폰 번호가 초대 정보와 일치하지 않습니다.',
          }),
          { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
        );
      }
    } else {
      if (inviteeEmail && inviteeEmail !== email) {
        return new Response(
          JSON.stringify({
            ok: false,
            error: '이메일이 초대 정보와 일치하지 않습니다. / Email mismatch.',
          }),
          { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
        );
      }
    }

    // 모든 검증 통과
    return new Response(
      JSON.stringify({
        ok: true,
        invitee_name: inviteeName,
        country: row.country || 'EN',
      }),
      { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ ok: false, error: (e as Error).message || 'server error' }),
      { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } }
    );
  }
});
