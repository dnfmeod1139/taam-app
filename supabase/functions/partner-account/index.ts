// ════════════════════════════════════════════════════════════
// partner-account — 파트너 레스토랑 계정 발급 (2026-09-03)
// ════════════════════════════════════════════════════════════
// 왜 Edge Function 인가
//   auth 유저를 만들려면 service_role 이 필요하다. service_role 은 절대
//   앱에 둘 수 없다 — 그 키 하나로 모든 표를 RLS 없이 읽고 쓴다.
//   그래서 「만들기」만 서버에 두고, 앱은 결과만 받는다.
//
// ⚠ 호출자가 슈퍼어드민인지 **서버가** 확인한다.
//   앱에서 버튼을 감추는 것은 방어가 아니다. 이 함수 URL 만 알면
//   누구나 부를 수 있다 — anon key 는 앱 안에 있으니까.
//
// ⚠ 비밀번호는 만들 때 한 번만 돌려준다. 어디에도 저장하지 않는다.
//   잊으면 재설정(reset)이지 조회가 아니다.
//
// 배포: Supabase 대시보드 → Edge Functions → partner-account
// 필요 시크릿: SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY (기본 제공)
// ════════════════════════════════════════════════════════════

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });

// 아이디는 이메일로 바뀌어 Auth 에 저장된다. 매장은 앞부분만 입력한다.
//   ⚠ 이 도메인으로 메일이 가는 일은 없다 (email_confirm 을 켜서 만든다).
//     실재하는 주소일 필요도 없고, 실재해서도 안 된다.
const PARTNER_DOMAIN = 'partner.taam.kr';

// 헷갈리는 글자를 뺀 알파벳 — 0/O, 1/l/I 가 없다.
//   비밀번호는 전화로 불러 주거나 종이에 적어 건넨다. 「영문 엘이야 숫자 일이야」를
//   한 번이라도 겪으면 이게 왜 필요한지 안다.
const SAFE = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
function makePassword(): string {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  const s = Array.from(bytes, (b) => SAFE[b % SAFE.length]).join('');
  return `${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}`;
}

// 아이디 규칙 — 소문자·숫자·하이픈, 3~32자. 이메일 앞부분으로 쓰이므로 좁게 잡는다.
const ID_RE = /^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$/;

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin = createClient(url, svc, { auth: { persistSession: false } });

    // ── 호출자 확인 ────────────────────────────────────────────
    //   ⚠ 앱이 보낸 「나 슈퍼어드민이야」를 믿지 않는다. 토큰에서 직접 읽는다.
    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!jwt) return json({ ok: false, error: '로그인이 필요합니다' }, 401);

    const { data: who, error: whoErr } = await admin.auth.getUser(jwt);
    const caller = who?.user;
    if (whoErr || !caller) return json({ ok: false, error: '로그인이 필요합니다' }, 401);

    const { data: isSuper } = await admin.rpc('is_super_admin', { uid: caller.id });
    if (isSuper !== true) return json({ ok: false, error: '권한이 없습니다' }, 403);

    const body = await req.json().catch(() => ({}));
    const action = String(body.action || '').trim();
    const loginId = String(body.login_id || '').trim().toLowerCase();

    if (!ID_RE.test(loginId)) {
      return json({
        ok: false,
        error: '아이디는 소문자·숫자·하이픈 3~32자입니다 (예: sushi-arai)',
      });
    }
    const email = `${loginId}@${PARTNER_DOMAIN}`;

    // ── 발급 ───────────────────────────────────────────────────
    if (action === 'create') {
      const restId = String(body.rest_id || '').trim();
      const label = String(body.label || '').trim();
      if (!restId) return json({ ok: false, error: '매장을 골라주세요' });

      const { data: dup } = await admin
        .from('partner_accounts').select('login_id').eq('login_id', loginId).maybeSingle();
      if (dup) return json({ ok: false, error: '이미 쓰고 있는 아이디입니다' });

      const password = makePassword();
      const { data: made, error: mkErr } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,   // 확인 메일을 보내지 않는다. 갈 곳도 없다.
        user_metadata: { taam_partner: true, rest_id: restId, label },
      });
      if (mkErr || !made?.user) {
        return json({ ok: false, error: '계정을 만들지 못했습니다: ' + (mkErr?.message || '') });
      }
      const uid = made.user.id;

      // ⚠ 여기서부터 실패하면 auth 유저만 떠돌게 된다. 그래서 실패하면 되돌린다.
      const undo = async (msg: string) => {
        await admin.auth.admin.deleteUser(uid).catch(() => {});
        return json({ ok: false, error: msg });
      };

      // 프로필 — 없으면 앱의 여러 화면이 빈손이 된다.
      //   ⚠ role 은 'user' 그대로 둔다. 어드민은 admin_grants 가 만든다 —
      //     권한 경로를 둘로 늘리지 않는다.
      const { error: pErr } = await admin.from('profiles').upsert({
        id: uid,
        display_name: label || loginId,
        role: 'user',
      }, { onConflict: 'id' });
      if (pErr) return await undo('프로필을 만들지 못했습니다: ' + pErr.message);

      // 여러 기기 허용 — 매장은 홀 태블릿과 사장 휴대폰을 같이 쓰는 일이 흔하다.
      //   단일 기기로 묶으면 서로를 쫓아내며 「자꾸 로그아웃되는 앱」이 된다.
      //   ⚠ 위 upsert 에 같이 넣지 않는다. single_device_exempt 컬럼이 없는 DB
      //     에서는 프로필 생성이 통째로 실패해 계정이 반쪽으로 남는다.
      //     이 한 줄은 실패해도 계정은 멀쩡하다 — 나중에 켜 주면 된다.
      if (body.multi_device === true) {
        await admin.from('profiles')
          .update({ single_device_exempt: true }).eq('id', uid);
      }

      const { error: gErr } = await admin.from('admin_grants').insert({
        user_id: uid, rest_id: restId, label: label || null, granted_by: caller.id,
      });
      if (gErr) return await undo('권한을 주지 못했습니다: ' + gErr.message);

      const { error: aErr } = await admin.from('partner_accounts').insert({
        login_id: loginId, user_id: uid, rest_id: restId,
        label: label || null, issued_by: caller.id,
      });
      if (aErr) return await undo('장부에 적지 못했습니다: ' + aErr.message);

      // 비밀번호가 나가는 유일한 순간이다.
      return json({ ok: true, login_id: loginId, password, domain: PARTNER_DOMAIN });
    }

    // ── 비밀번호 재설정 ────────────────────────────────────────
    if (action === 'reset') {
      const { data: row } = await admin
        .from('partner_accounts').select('user_id').eq('login_id', loginId).maybeSingle();
      if (!row) return json({ ok: false, error: '그런 아이디가 없습니다' });

      const password = makePassword();
      const { error } = await admin.auth.admin.updateUserById(row.user_id, { password });
      if (error) return json({ ok: false, error: '바꾸지 못했습니다: ' + error.message });

      // 쓰던 기기를 전부 끊는다. 「비번 바꾸면 침해당할 일 없다」가 성립하려면
      // 옛 비밀번호로 이미 들어와 있던 세션도 같이 죽어야 한다.
      await admin.auth.admin.signOut(row.user_id, 'global').catch(() => {});
      await admin.from('partner_accounts')
        .update({ disabled: false }).eq('login_id', loginId);

      return json({ ok: true, login_id: loginId, password, domain: PARTNER_DOMAIN });
    }

    // ── 해지 / 되살리기 ────────────────────────────────────────
    //   ⚠ 계정을 지우지 않는다. 지우면 그 매장에 뭘 발급했었는지가 사라진다.
    //     권한만 떼고 잠근다 — 되살릴 때 다시 붙인다.
    if (action === 'revoke' || action === 'restore') {
      const off = action === 'revoke';
      const { data: row } = await admin
        .from('partner_accounts').select('user_id, rest_id, label')
        .eq('login_id', loginId).maybeSingle();
      if (!row) return json({ ok: false, error: '그런 아이디가 없습니다' });

      if (off) {
        await admin.from('admin_grants').delete().eq('user_id', row.user_id);
        await admin.auth.admin.signOut(row.user_id, 'global').catch(() => {});
      } else {
        await admin.from('admin_grants').insert({
          user_id: row.user_id, rest_id: row.rest_id,
          label: row.label, granted_by: caller.id,
        }).select().maybeSingle();
      }
      await admin.from('partner_accounts')
        .update({ disabled: off }).eq('login_id', loginId);
      return json({ ok: true, login_id: loginId, disabled: off });
    }

    return json({ ok: false, error: '알 수 없는 요청입니다' });
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
