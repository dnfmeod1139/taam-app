-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 가입·초대·프로필 연락처 강화 (2026-10-30)
-- ═══════════════════════════════════════════════════════════════════════════
-- 보안 점검(2026-10-29)이 「인증 담당」으로 넘긴 세 가지 + 라이브 본문을 읽다 나온 것. 라이브 모양(진단 20261030_diag_signup_*):
--   · 문지기 enforce · 초대장 41 = 번호만 23 · 이메일만 18 · 전부 사용됨 · 최근 90일 통과는 전부 invite_code(번호 11 · 이메일 1)
--   · 회원 38명 — 아래 「인증된 번호·이메일 정확 일치」로 바꿔도 로그인 대조가 바뀌는 회원 0 · 인증 안 된 auth 계정 0 ·
--     profiles 번호·이메일이 인증 값과 다른 회원 0 · 메타데이터에 phone 키를 가진 계정 0
--
-- 막는 것
--   ① 가입 문지기(taam_guard_signup) — 초대장이 묶은 채널과 **실제 가입 채널**이 맞아야 한다.
--      종전: 번호에 묶인 코드를 이메일 OTP 로(또는 그 반대로) 쓰면 대조할 쪽이 비어 통과했다 · 번호는 회원이 적는
--      raw_user_meta_data.phone 도 믿었다(남의 초대 번호를 적으면 그 번호로 대조됐다) · 묶임 없는 코드는 아무 채널로나 ·
--      코드 없는 가입은 **이미 쓴·만료된** 초대장과도 맞으면 통과(소셜로 같은 사람의 두 번째 계정) · 파트너 도메인은 누구나 · 판정 오류는 통과.
--      → 번호 = auth.users.phone 만 · 이메일 = auth.users.email 만 · 묶임 없는 초대장 거절 ·
--        코드 없는 가입은 소셜(제공자가 확인한 이메일)이고 안 쓴·안 지난 초대장일 때만 ·
--        해외 결제 링크 손님 초대장(국내 휴대폰 아님 · 이메일 없음)은 코드가 자격 — 주인은 그 코드로 가입한 유일한 인증 계정 ·
--        파트너 도메인은 partner-account 가 직전에 적은 발급 예약(partner_signup_allow · 10분 · 한 번)이 있을 때만 ·
--        enforce 에서 판정 오류는 **거절**(SIGNUP_GUARD_ERROR — 급하면 app_config.signup_guard 를 log 로) ·
--        메타데이터 이름(display_name·name·full_name…)은 꺾쇠·javascript: 를 지우고 phone 키는 버린다(가입 뒤 updateUser 로 바꿀 때도).
--   ①-2 ⚠ 이 프로젝트는 「Confirm email」이 꺼져 있다(진단: 이메일 계정 18/18 이 가입 2초 안에 확인됨) — 이메일 확인 시각은 메일함 소유의 증거가 아니다.
--      그래서 ⓐ 이메일·번호 가입은 언제나 코드가 있어야 하고(비밀번호 가입이 남의 이메일로 바로 세션을 받는 길) ⓑ 로그인 이메일 변경을 막는다
--      (updateUser({email}) 가 확인 없이 바로 바뀌어 남의 초대장 주인이 되던 길 · 앱은 이메일을 바꾸지 않는다 · SQL Editor 는 set local taam.allow_email_change='1').
--      대시보드에서 Confirm email 을 켜면(「Confirm signup」 메일에 {{ .Token }}) 이메일 쪽도 번호처럼 강해진다.
--   ② 초대 소진(invite_codes used → true) — **누가 소진하든**(Edge consume-invite · RPC consume_invite_by_self · 그 밖)
--      초대장이 묶은 번호·이메일로 **인증된 계정**이 그 주인이어야 하고, member_id·used_by_* 는 그 계정 값으로 서버가 적는다.
--      종전: consume-invite 는 대조할 쪽이 비면 통과 + used_by_* 를 요청 본문에서 받았고, consume_invite_by_self 는
--      회원이 쓸 수 있는 profiles.phone 을 폴백으로 4자리 부분 일치(LIKE '%1234%')까지 봤다 → 게스트 초대장(결제 링크 손님)을
--      이메일 가입 회원이 소진하면 trg_taam_guest_attach_on_invite_used 가 결제된 LINK- 좌석을 그 회원에게 붙였다(재현 · 아래 회귀).
--   ③ invite_codes 읽기 — 로그인한 회원은 **자기 초대장만**(member_id · 인증된 번호·이메일 정확 일치). 종전 USING true(전원 명부).
--   ④ profiles 연락처 — 회원 세션이 직접 쓰는 profiles.phone · email 은 auth.users 의 인증된 값(또는 비움)만. 아니면 되돌림.
--      (앱은 phone_change OTP 뒤에만 그 번호를 적는다 · 게스트 티켓 붙이기·알림이 profiles 번호를 본다)
--   ⑤ 이름 — 가입 때 메타데이터에서 profiles 로 오는 표시 이름(sync_profile_email_from_auth · 서버 세션이라 K 글자 검사를 비켜 갔다) ·
--      서버가 쓰는 profiles 이름 칸 · invite_codes 이름 칸에서 꺾쇠·javascript: 를 지운다. 회원 세션은 종전대로 K 가 거절(BAD_INPUT).
--   ⑥ 로그인 대조 user_has_invite_match · 등급 taam_invited_tier — 인증된 값 정확 일치만(부분 일치·메타데이터·profiles 폴백 없음).
--   ⑦ 서버 전용 도우미의 anon·회원 실행 권한 회수(이메일 존재 조회 · 게스트 코드 생성).
--
-- 안 바꾸는 것: Edge(verify-invite · consume-invite)는 대시보드 판과 대조 전이라 손대지 않는다 — DB 가 지킨다.
-- 되돌리기: 함수는 저장소 sql/signup_guard.sql 등 옛 판 · 트리거는 drop trigger … (머리말 아래 각 절에 이름)
-- 회귀: bash sql/_test/t_auth_hardening.sh
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 0) 도우미 ──
create or replace function public._taam_phone_key(p_text text)
returns text language sql immutable as $$
  select regexp_replace(regexp_replace(regexp_replace(coalesce(p_text, ''), '[^0-9]', '', 'g'), '^82', ''), '^0+', '')
$$;

-- 이름 정리 — 제어 문자 → 공백 · 꺾쇠 삭제 · javascript: 삭제 · 공백 정리 · 80자. 그래도 수상하면 빈 글자.
create or replace function public._taam_clean_name(p text)
returns text language plpgsql immutable as $$
declare v text := coalesce(p, '');
begin
  v := regexp_replace(v, '[[:cntrl:]]', ' ', 'g');
  v := regexp_replace(v, '[<>]', '', 'g');
  for i in 1..5 loop
    exit when v !~* 'javascript\s*:';
    v := regexp_replace(v, 'javascript\s*:', '', 'gi');
  end loop;
  v := btrim(regexp_replace(v, '\s{2,}', ' ', 'g'));
  v := left(v, 80);
  if v ~ '[<>]' or v ~* 'javascript\s*:' then return ''; end if;
  return v;
end $$;
grant execute on function public._taam_clean_name(text) to anon, authenticated;

-- 요청 JWT 의 role (service_role · authenticated · anon · 없음 '')
create or replace function public._taam_req_role()
returns text language sql stable as $$
  select coalesce(nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', ''),
                  nullif(current_setting('request.jwt.claim.role', true), ''), '')
$$;
grant execute on function public._taam_req_role() to anon, authenticated;

-- 초대장의 묶인 채널(번호 키 8자리 이상 · 이메일 소문자) — 없으면 null
create or replace function public._taam_invite_bind_phone(p text)
returns text language sql immutable as $$
  select case when length(public._taam_phone_key(p)) >= 8 then public._taam_phone_key(p) end
$$;
create or replace function public._taam_invite_bind_email(p text)
returns text language sql immutable as $$
  select case when lower(btrim(coalesce(p, ''))) ~ '^[^@\s]+@[^@\s]+$' then lower(btrim(p)) end
$$;
grant execute on function public._taam_invite_bind_phone(text), public._taam_invite_bind_email(text) to anon, authenticated;

-- 묶인 채널 대조 — null = 통과 · 아니면 거절 사유
--   가입 채널(번호·이메일)이 초대장이 묶은 채널 중 하나와 같아야 하고, 둘 다 있는 쪽은 서로 어긋나면 안 된다.
create or replace function public._taam_invite_bind_reason(p_inv_phone text, p_inv_email text, p_phone_key text, p_email text)
returns text language plpgsql immutable as $$
declare ip text := public._taam_invite_bind_phone(p_inv_phone); ie text := public._taam_invite_bind_email(p_inv_email);
        vp text := nullif(p_phone_key, ''); ve text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  if ip is null and ie is null then return 'invite_unbound'; end if;
  if ip is not null and vp is not null and vp <> ip then return 'phone_mismatch'; end if;
  if ie is not null and ve is not null and ve <> ie then return 'email_mismatch'; end if;
  if not coalesce(ip is not null and vp = ip, false) and not coalesce(ie is not null and ve = ie, false) then return 'channel_mismatch'; end if;
  return null;
end $$;

-- 국내 휴대폰 번호인가(엄격) — 010·011·016~019 + 7~8자리, 또는 82 + 10·11·16~19 + 7~8자리.
--   20261019 결제 링크 초대장의 판정(^(0?1[016789]|821[016789]))은 앞자리만 봐서 +1 617… 같은 북미 번호를 국내로 쳤다.
create or replace function public._taam_kr_mobile(p text)
returns boolean language sql immutable as $$
  select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') ~ '^(0?1[016789][0-9]{7,8}|821[016789][0-9]{7,8})$'
$$;
grant execute on function public._taam_kr_mobile(text) to anon, authenticated;

-- 코드만으로 묶이는 초대장 — 해외 결제 링크 손님(pay_link · 국내 휴대폰 번호 아님 · 이메일 없음).
--   앱은 해외 번호 OTP 를 못 하고(국내는 +82 고정) 손님 이메일은 초대장에 없다 → 코드(결제 완료 화면에만 보인다)가 자격이다.
--   주인은 그 코드로 가입이 허락된 **단 하나의** 인증 계정(_taam_code_owner).
--   (p_country 는 옛 호출 모양을 위해 받기만 한다 — 판정은 번호로)
create or replace function public._taam_invite_code_only(p_invited_by text, p_country text, p_iph text, p_iem text)
returns boolean language sql immutable as $$
  select coalesce(p_invited_by, '') = 'pay_link'
     and public._taam_invite_bind_email(p_iem) is null and public._taam_invite_bind_phone(p_iph) is not null
     and not public._taam_kr_mobile(p_iph)
$$;
grant execute on function public._taam_invite_code_only(text, text, text, text) to anon, authenticated;

-- 이 코드로 가입이 허락된(문지기 allow) 계정
create index if not exists signup_guard_log_user_idx on public.signup_guard_log(user_id);
create index if not exists signup_guard_log_code_idx on public.signup_guard_log(upper(btrim(coalesce(invite_code, '')))) where verdict = 'allow';

-- 이 코드로 가입이 허락된 인증 계정이 **정확히 하나**면 그 계정 · 0개·2개 이상이면 null(슈퍼어드민이 정한다)
--   ⚠ signup_guard_log 의 allow 줄이 이 판정의 근거다 — 지우거나 정리하는 작업을 두지 말 것(해외 손님이 주인을 잃는다)
--   코드로만 묶인 초대장(해외 결제 링크 손님)일 때만 답한다 — 번호·이메일에 묶인 초대장은 그 채널의 인증 값으로만 주인을 정한다
create or replace function public._taam_code_owner(p_code text)
returns uuid language sql stable security definer set search_path = public, auth as $$
  select case when count(distinct au.id) = 1 then (array_agg(au.id))[1] end
    from public.signup_guard_log l join auth.users au on au.id = l.user_id
   where nullif(btrim(coalesce(p_code, '')), '') is not null
     and exists (select 1 from public.invite_codes ic where upper(btrim(ic.code)) = upper(btrim(p_code))
                   and public._taam_invite_code_only(ic.invited_by, ic.country, ic.invitee_phone, ic.invitee_email))
     and l.verdict = 'allow' and upper(btrim(coalesce(l.invite_code, ''))) = upper(btrim(p_code))
     and (au.phone_confirmed_at is not null or au.email_confirmed_at is not null)
$$;
revoke all on function public._taam_code_owner(text) from public, anon, authenticated;

-- 이 초대장이 지금 로그인한 회원의 것인가 — member_id · 인증된 번호·이메일 정확 일치(invitee_* · used_by_*) · 이 코드로 가입이 허락된 인증 계정
do $$ begin
  if to_regclass('public.invite_codes') is not null then execute 'drop policy if exists invite_codes_read_own on public.invite_codes'; end if;
end $$;
drop function if exists public._taam_invite_mine(text, text, text, text, text);
create or replace function public._taam_invite_mine(p_member text, p_iph text, p_iem text, p_uph text, p_uem text, p_code text)
returns boolean language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from auth.users u
     where u.id = auth.uid()
       and (   (nullif(btrim(coalesce(p_member, '')), '') is not null and btrim(p_member) = u.id::text)
            or (u.phone_confirmed_at is not null and length(public._taam_phone_key(u.phone)) >= 8
                and (public._taam_phone_key(p_iph) = public._taam_phone_key(u.phone) or public._taam_phone_key(p_uph) = public._taam_phone_key(u.phone)))
            or (u.email_confirmed_at is not null and nullif(lower(btrim(coalesce(u.email, ''))), '') is not null
                and (lower(btrim(coalesce(p_iem, ''))) = lower(btrim(u.email)) or lower(btrim(coalesce(p_uem, ''))) = lower(btrim(u.email))))
            -- 아직 주인이 안 적힌 초대장: 이 코드로 가입이 허락된 유일한 인증 계정
            or (nullif(btrim(coalesce(p_member, '')), '') is null and public._taam_code_owner(p_code) = u.id))
  )
$$;
revoke all on function public._taam_invite_mine(text, text, text, text, text, text) from public, anon;
grant execute on function public._taam_invite_mine(text, text, text, text, text, text) to authenticated;   -- RLS 정책식이 부른다 · 자기 것만 답한다

-- 지금 로그인한 회원의 인증된 번호 키 · 이메일 (프로필 연락처 가드가 부른다)
create or replace function public._taam_my_verified_phone_key()
returns text language sql stable security definer set search_path = public, auth as $$
  select case when u.phone_confirmed_at is not null then nullif(public._taam_phone_key(u.phone), '') end from auth.users u where u.id = auth.uid()
$$;
create or replace function public._taam_my_verified_email()
returns text language sql stable security definer set search_path = public, auth as $$
  select case when u.email_confirmed_at is not null then nullif(lower(btrim(coalesce(u.email, ''))), '') end from auth.users u where u.id = auth.uid()
$$;
revoke all on function public._taam_my_verified_phone_key(), public._taam_my_verified_email() from public, anon;
grant execute on function public._taam_my_verified_phone_key(), public._taam_my_verified_email() to authenticated;

-- ── ① 가입 문지기 ──
-- 매장 계정 발급 예약 — partner-account 가 createUser 직전에 적고 문지기가 지운다(10분)
create table if not exists public.partner_signup_allow (
  email      text primary key,
  created_at timestamptz not null default now(),
  created_by uuid
);
alter table public.partner_signup_allow enable row level security;
revoke all on public.partner_signup_allow from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select, insert, update, delete on public.partner_signup_allow to service_role';   -- partner-account(Edge)가 적고 지운다
  end if;
end $$;

create or replace function public.taam_guard_signup()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_mode    text := 'log';
  v_email   text;
  v_phone   text;
  v_code    text;
  v_prov    text;
  v_verdict text := 'reject';
  v_reason  text := 'no_invite';
  v_meta    jsonb;
  k         text;
  r         record;
begin
  begin
    v_mode  := public.taam_signup_guard_mode();
    -- 메타데이터는 가입자가 마음대로 적는다 — 이름은 정리하고 번호는 버린다(어디서도 믿지 않는다)
    v_meta := case when jsonb_typeof(new.raw_user_meta_data) = 'object' then new.raw_user_meta_data else '{}'::jsonb end;
    v_meta := v_meta - 'phone';
    foreach k in array array['display_name', 'name', 'full_name', 'user_name', 'nickname'] loop
      if jsonb_typeof(v_meta -> k) = 'string' then
        v_meta := jsonb_set(v_meta, array[k], to_jsonb(public._taam_clean_name(v_meta ->> k)));
      end if;
    end loop;
    if new.raw_user_meta_data is distinct from v_meta then new.raw_user_meta_data := v_meta; end if;

    v_email := lower(nullif(btrim(coalesce(new.email, '')), ''));
    v_phone := nullif(public._taam_phone_key(new.phone), '');          -- 실제 가입 채널만 (메타데이터 번호 없음)
    v_code  := upper(nullif(btrim(coalesce(v_meta->>'invite_code', '')), ''));
    v_prov  := coalesce(case when jsonb_typeof(new.raw_app_meta_data) = 'object' then new.raw_app_meta_data->>'provider' end, '');

    if v_email is not null and v_email in ('dnfmeod@playtaam.com') then
      v_verdict := 'allow'; v_reason := 'super_whitelist';

    elsif v_email is not null and v_email like '%@partner.taam.kr' then
      -- 매장 계정은 partner-account(슈퍼어드민 · service_role)가 만들기 직전에 partner_signup_allow 에 적는다 — 그 줄이 있어야(10분 · 한 번)
      --   종전엔 도메인만 보고 통과 → 누구나 OTP·비밀번호 가입으로 x@partner.taam.kr 계정 줄을 만들 수 있었다
      --   (⚠ GoTrue 는 OTP 새 가입도 임시 비밀번호로 만든다 — encrypted_password 로 가입 방식을 가를 수 없다)
      delete from public.partner_signup_allow a where a.email = v_email and a.created_at > now() - interval '10 minutes';
      if found then v_verdict := 'allow'; v_reason := 'partner_domain';
      else v_reason := 'partner_not_registered'; end if;


    elsif v_code is not null then
      select ic.used, ic.expires_at::text as expires_txt, ic.invitee_phone, ic.invitee_email, ic.invited_by, ic.country
        into r
        from public.invite_codes ic
       where upper(btrim(ic.code)) = v_code
       order by ic.used asc nulls first, ic.invited_at desc nulls last
       limit 1;
      if not found then
        v_reason := 'code_not_found';
      elsif coalesce(r.used, false) then
        v_reason := 'code_used';
      elsif public._taam_ts_safe(r.expires_txt) is not null and public._taam_ts_safe(r.expires_txt) < now() then
        v_reason := 'code_expired';
      elsif public._taam_invite_code_only(r.invited_by, r.country, r.invitee_phone, r.invitee_email) then
        -- 해외 결제 링크 손님 — 코드가 자격(번호 OTP 불가 · 이메일 모름). 주인은 이 코드로 가입한 유일한 인증 계정
        if v_phone is null and v_email is null then v_reason := 'channel_mismatch';
        elsif public._taam_code_owner(v_code) is not null then v_reason := 'code_claimed';   -- 이미 다른 계정이 이 코드로 가입·인증했다
        else v_verdict := 'allow'; v_reason := 'invite_code_only'; end if;
      else
        v_reason := coalesce(public._taam_invite_bind_reason(r.invitee_phone, r.invitee_email, v_phone, v_email), 'invite_code');
        if v_reason = 'invite_code' then v_verdict := 'allow'; end if;
      end if;

    else
      -- 코드가 안 실린 가입(소셜 첫 로그인 등): 안 쓴·안 지난 초대장이 이 채널에 묶여 있을 때만
      --   소셜(OAuth)만 — 제공자가 이메일을 확인했다고 할 때(메타데이터 email_verified 는 제공자가 채운다 · OAuth 가입은 data 를 못 싣는다).
      --   이메일·번호 가입은 언제나 코드를 싣는다(앱 _vpSignupMeta). 코드 없이 들이면 「Confirm email」이 꺼진 이 프로젝트에선
      --   비밀번호 가입(/auth/v1/signup)이 메일함 확인 없이 바로 세션을 받아 남의 이메일에 묶인 초대장을 가져갔다(2026-10-30 진단 ① 18/18 즉시 확인).
      if v_prov in ('', 'email', 'phone') or coalesce(v_meta->>'email_verified', '') <> 'true' then
        v_email := null; v_phone := null;
      end if;
      if (v_email is not null or v_phone is not null) and exists (
        select 1 from public.invite_codes ic
         where not coalesce(ic.used, false)
           and (public._taam_ts_safe(ic.expires_at::text) is null or public._taam_ts_safe(ic.expires_at::text) >= now())
           and public._taam_invite_bind_reason(ic.invitee_phone, ic.invitee_email, v_phone, v_email) is null
      ) then
        v_verdict := 'allow'; v_reason := 'invitee_match';
      end if;
    end if;
  exception when others then
    v_verdict := 'error'; v_reason := left(sqlerrm, 200);
  end;

  begin
    insert into public.signup_guard_log(user_id, email, phone, provider, invite_code, verdict, reason, mode, enforced)
    values (new.id, v_email, v_phone, v_prov, v_code, v_verdict, v_reason, v_mode,
            (v_mode = 'enforce' and v_verdict in ('reject', 'error')));
  exception when others then
    -- 기록 실패로 판정을 바꾸지 않는다 — 단 코드로만 묶인 가입은 이 기록이 주인 근거라 남기지 못하면 들이지 않는다
    if v_verdict = 'allow' and v_reason = 'invite_code_only' then v_verdict := 'error'; v_reason := 'log_failed'; end if;
  end;

  if v_mode = 'enforce' and v_verdict = 'reject' then
    raise warning 'taam_guard_signup reject: % email=% phone=% code=%', v_reason, v_email, v_phone, v_code;
    raise exception 'SIGNUP_NOT_INVITED: %', v_reason using errcode = 'P0001';
  elsif v_mode = 'enforce' and v_verdict = 'error' then
    -- 판정이 깨졌으면 들이지 않는다(2026-10-30 · 종전엔 통과). 급하면 app_config.signup_guard 를 log 로.
    raise warning 'taam_guard_signup error: % email=% phone=% code=%', v_reason, v_email, v_phone, v_code;
    raise exception 'SIGNUP_GUARD_ERROR' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_signup() from public, anon, authenticated;

-- ── ② 초대 소진 가드 ──
create or replace function public.taam_guard_invite_consume()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid     uuid := auth.uid();
  v_role    text := public._taam_req_role();
  v_trusted boolean;
  v_owner   uuid;
  v_n       int;
  v_codeonly boolean;
  ip        text;
  ie        text;
  u         record;
begin
  -- 이름 칸은 누가 쓰든 정리한다(슈퍼어드민 화면이 그린다)
  if tg_op = 'INSERT' or new.invitee_name is distinct from old.invitee_name then
    new.invitee_name := public._taam_clean_name(new.invitee_name);
  end if;
  if tg_op = 'INSERT' or new.used_by_name is distinct from old.used_by_name then
    new.used_by_name := nullif(public._taam_clean_name(new.used_by_name), '');
  end if;

  -- 믿는 세션: 슈퍼어드민 · SQL Editor·마이그레이션·크론(로그인도 service_role 도 아닌 호출)
  v_trusted := (v_uid is not null and public._taam_uid_is_super())
            or (v_uid is null and v_role not in ('service_role', 'authenticated', 'anon'));

  if tg_op = 'INSERT' then
    -- 묶임 없는 초대장은 아무도 쓸 수 없다(문지기가 거절) — 만들 때 막는다
    if public._taam_invite_bind_phone(new.invitee_phone) is null and public._taam_invite_bind_email(new.invitee_email) is null then
      raise exception 'INVITE_UNBOUND: 초대장에 휴대폰 번호(8자리 이상) 또는 이메일이 있어야 합니다' using errcode = '22023';
    end if;
    if not v_trusted then
      -- 새 초대장에 사용 기록을 미리 적어 둘 수 없다
      new.used := false; new.used_at := null; new.member_id := null;
      new.used_by_phone := null; new.used_by_email := null; new.used_by_name := null;
    end if;
    return new;
  end if;

  -- UPDATE — 믿는 세션이 아니면 초대장의 묶임·자격 칸은 그대로(소진과 함께 번호를 바꿔 주인을 갈아 끼우지 못하게)
  if not v_trusted then
    new.code := old.code; new.invitee_phone := old.invitee_phone; new.invitee_email := old.invitee_email;
    new.invitee_tier := old.invitee_tier; new.invited_by := old.invited_by; new.country := old.country;
    new.expires_at := old.expires_at; new.invitee_name := old.invitee_name;
  end if;
  if coalesce(old.used, false) then
    -- 이미 쓴 초대장의 주인·사용 기록은 믿는 세션만 바꾼다
    if not v_trusted then
      new.used := old.used; new.used_at := old.used_at; new.member_id := old.member_id;
      new.used_by_phone := old.used_by_phone; new.used_by_email := old.used_by_email; new.used_by_name := old.used_by_name;
    end if;
    return new;
  end if;

  if not coalesce(new.used, false) then
    -- 안 쓴 초대장에 주인을 미리 적어 둘 수 없다
    if not v_trusted then
      new.used_at := old.used_at; new.member_id := old.member_id;
      new.used_by_phone := old.used_by_phone; new.used_by_email := old.used_by_email; new.used_by_name := old.used_by_name;
    end if;
    return new;
  end if;

  -- 소진(false → true): 묶인 번호·이메일로 인증된 계정이 주인이다
  ip := public._taam_invite_bind_phone(new.invitee_phone);
  ie := public._taam_invite_bind_email(new.invitee_email);
  if ip is null and ie is null then
    if v_trusted then return new; end if;
    raise exception 'INVITE_UNBOUND: 묶인 번호·이메일이 없는 초대장은 소진할 수 없습니다' using errcode = '42501';
  end if;

  v_codeonly := public._taam_invite_code_only(new.invited_by, new.country, new.invitee_phone, new.invitee_email);
  if v_codeonly then
    -- 해외 결제 링크 손님: 이 코드로 가입이 허락된 유일한 인증 계정
    v_owner := public._taam_code_owner(new.code);
    v_n := case when v_owner is null then 0 else 1 end;
  else
    select count(*), (array_agg(au.id order by au.created_at))[1] into v_n, v_owner
      from auth.users au
     where (ip is not null and au.phone_confirmed_at is not null and public._taam_phone_key(au.phone) = ip)
        or (ie is not null and au.email_confirmed_at is not null and lower(btrim(coalesce(au.email, ''))) = ie);
  end if;

  if v_uid is not null and not v_trusted then
    -- 회원 세션(consume_invite_by_self 등): 그 회원이 묶인 채널의 인증된 주인이어야(코드만 묶인 초대장은 그 코드로 가입한 인증 계정)
    if (v_codeonly and public._taam_code_owner(new.code) is distinct from v_uid)
       or (not v_codeonly and not exists (select 1 from auth.users au where au.id = v_uid
                     and ((ip is not null and au.phone_confirmed_at is not null and public._taam_phone_key(au.phone) = ip)
                       or (ie is not null and au.email_confirmed_at is not null and lower(btrim(coalesce(au.email, ''))) = ie)))) then
      raise exception 'INVITE_NOT_YOURS: 이 초대장은 다른 번호·이메일에 묶여 있습니다' using errcode = '42501';
    end if;
    v_owner := v_uid;
  elsif not v_trusted then
    -- 서버(service_role — Edge consume-invite): 묶인 채널의 인증된 계정이 정확히 하나여야
    if v_n <> 1 then
      raise exception 'INVITE_OWNER_UNVERIFIED: 묶인 번호·이메일(또는 이 코드)의 주인을 정하지 못했습니다(인증 계정 % 개)', v_n using errcode = '42501';
    end if;
  elsif v_n <> 1 or (nullif(btrim(coalesce(new.member_id, '')), '') is not null and new.member_id is distinct from old.member_id) then
    v_owner := null;   -- 믿는 세션 · 주인을 못 정했거나 직접 적었으면 적힌 그대로
  end if;

  new.used_at := coalesce(new.used_at, now());
  if v_owner is not null then
    select au.id, au.phone, au.email, au.phone_confirmed_at, au.email_confirmed_at into u from auth.users au where au.id = v_owner;
    new.member_id := v_owner::text;
    -- 사용 기록은 그 계정의 인증된 값으로(요청 본문이 적은 다른 번호·이메일은 버린다 · 같은 번호면 적힌 모양 유지)
    if u.phone_confirmed_at is not null and nullif(public._taam_phone_key(u.phone), '') is not null then
      if public._taam_phone_key(new.used_by_phone) is distinct from public._taam_phone_key(u.phone) then new.used_by_phone := u.phone; end if;
    else
      new.used_by_phone := null;
    end if;
    if u.email_confirmed_at is not null and nullif(lower(btrim(coalesce(u.email, ''))), '') is not null then
      if lower(btrim(coalesce(new.used_by_email, ''))) is distinct from lower(btrim(u.email)) then new.used_by_email := lower(btrim(u.email)); end if;
    else
      new.used_by_email := null;
    end if;
  end if;
  return new;
end $$;
revoke all on function public.taam_guard_invite_consume() from public, anon, authenticated;

do $$ begin
  if to_regclass('public.invite_codes') is null then raise notice 'invite_codes 없음 — ② 건너뜀'; return; end if;
  execute 'drop trigger if exists trg_taam_guard_invite_consume on public.invite_codes';
  execute 'create trigger trg_taam_guard_invite_consume before insert or update on public.invite_codes
           for each row execute function public.taam_guard_invite_consume()';
end $$;

-- 게스트 티켓 붙이기 — 주인은 소진 가드가 적은 member_id(인증된 계정). profiles 번호·이메일(회원이 쓰던 칸)로 찾지 않는다.
create or replace function public.taam_guest_attach_on_invite_used()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid; ip text; ie text; v_n int;
begin
  if not coalesce(new.used, false) or coalesce(old.used, false) then return new; end if;
  if coalesce(new.invited_by, '') <> 'pay_link' or coalesce(new.invitee_tier, '') <> 'A' then return new; end if;
  begin
    if nullif(btrim(coalesce(new.member_id, '')), '') is not null then
      begin v_uid := btrim(new.member_id)::uuid; exception when others then v_uid := null; end;
      if v_uid is not null and not exists (select 1 from auth.users where id = v_uid) then v_uid := null; end if;
    end if;
    if v_uid is null then
      -- 믿는 세션이 주인 없이 소진한 경우: 묶인 채널로 인증된 계정이 정확히 하나일 때만
      ip := public._taam_invite_bind_phone(new.invitee_phone);
      ie := public._taam_invite_bind_email(new.invitee_email);
      if public._taam_invite_code_only(new.invited_by, new.country, new.invitee_phone, new.invitee_email) then
        v_uid := public._taam_code_owner(new.code);
        v_n := case when v_uid is null then 0 else 1 end;
      else
        select count(*), (array_agg(au.id))[1] into v_n, v_uid from auth.users au
         where (ip is not null and au.phone_confirmed_at is not null and public._taam_phone_key(au.phone) = ip)
            or (ie is not null and au.email_confirmed_at is not null and lower(btrim(coalesce(au.email, ''))) = ie);
      end if;
      if v_n <> 1 then v_uid := null; end if;
    end if;
    if v_uid is not null then
      perform public.taam_guest_attach_tickets(v_uid, new.code,
        (select case when au.phone_confirmed_at is not null then au.phone end from auth.users au where au.id = v_uid));
    end if;
  exception when others then
    raise warning '[guest_invite] 가입 뒤 티켓 붙이기 실패 (초대 사용 표시는 유지): % %', sqlstate, sqlerrm;
  end;
  return new;
end $$;

-- 가입 직후 붙이기 — 그 번호가 auth 에서 **인증된** 번호일 때만(가입 줄은 OTP 확인 전에 생긴다)
create or replace function public.taam_guest_attach_on_profile()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare v_phone text;
begin
  if nullif(new.phone, '') is null then return new; end if;
  select au.phone into v_phone from auth.users au
   where au.id = new.id and au.phone_confirmed_at is not null
     and length(public._taam_phone_key(au.phone)) >= 8 and public._taam_phone_key(au.phone) = public._taam_phone_key(new.phone);
  if v_phone is null then return new; end if;
  begin perform public.taam_guest_attach_tickets(new.id, null, v_phone);
  exception when others then raise warning '[guest_invite] 가입 직후 티켓 붙이기 실패 (가입은 유지): % %', sqlstate, sqlerrm; end;
  return new;
end $$;

-- ── ③ invite_codes 읽기 — 자기 것만 ──
do $$ begin
  if to_regclass('public.invite_codes') is null then raise notice 'invite_codes 없음 — ③ 건너뜀'; return; end if;
  execute 'alter table public.invite_codes enable row level security';
  execute 'drop policy if exists invite_codes_read on public.invite_codes';
  execute 'drop policy if exists invite_codes_read_own on public.invite_codes';
  execute 'create policy invite_codes_read_own on public.invite_codes for select to authenticated
           using (public._taam_invite_mine(member_id, invitee_phone, invitee_email, used_by_phone, used_by_email, code))';
  execute 'revoke all on public.invite_codes from anon';
end $$;

-- 앱이 자기 초대장을 읽는 길(이름·등급·국가) — 정책과 같은 판정 · 가장 알맞은 한 줄
create or replace function public.taam_my_invite()
returns jsonb language sql stable security definer set search_path = public, auth as $$
  select coalesce((
    select jsonb_build_object('code', ic.code, 'invitee_name', ic.invitee_name, 'invitee_tier', ic.invitee_tier, 'country', ic.country,
                              'used', coalesce(ic.used, false), 'used_at', ic.used_at, 'member_id', ic.member_id)
      from public.invite_codes ic
     where auth.uid() is not null
       and public._taam_invite_mine(ic.member_id, ic.invitee_phone, ic.invitee_email, ic.used_by_phone, ic.used_by_email, ic.code)
     order by (ic.member_id = auth.uid()::text) desc nulls last, coalesce(ic.used, false) desc, ic.used_at desc nulls last, ic.invited_at desc nulls last
     limit 1), 'null'::jsonb)
$$;
revoke all on function public.taam_my_invite() from public, anon;
grant execute on function public.taam_my_invite() to authenticated;

-- ── ⑥ 로그인 대조 · 자기 소진 · 등급 ──
create or replace function public.user_has_invite_match()
returns boolean language sql stable security definer set search_path = public, auth as $$
  select auth.uid() is not null and exists (
    select 1 from public.invite_codes ic
     where public._taam_invite_mine(ic.member_id, ic.invitee_phone, ic.invitee_email, ic.used_by_phone, ic.used_by_email, ic.code))
$$;
revoke all on function public.user_has_invite_match() from public, anon;
grant execute on function public.user_has_invite_match() to authenticated;

create or replace function public.consume_invite_by_self()
returns integer language plpgsql volatile security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid(); v_ph text; v_em text; v_n integer := 0;
begin
  if v_uid is null then return 0; end if;
  select case when u.phone_confirmed_at is not null then nullif(public._taam_phone_key(u.phone), '') end,
         case when u.email_confirmed_at is not null then nullif(lower(btrim(coalesce(u.email, ''))), '') end
    into v_ph, v_em from auth.users u where u.id = v_uid;
  if v_ph is null and v_em is null then return 0; end if;
  -- 묶인 채널이 내 인증된 번호·이메일과 정확히 같은 안 쓴 초대장만 · 주인·사용 기록은 소진 가드가 적는다
  update public.invite_codes ic
     set used = true, used_at = coalesce(ic.used_at, now())
   where not coalesce(ic.used, false)
     and (   (    ((v_ph is not null and public._taam_invite_bind_phone(ic.invitee_phone) = v_ph)
                or (v_em is not null and public._taam_invite_bind_email(ic.invitee_email) = v_em))
              and not public._taam_invite_code_only(ic.invited_by, ic.country, ic.invitee_phone, ic.invitee_email)
              and public._taam_invite_bind_reason(ic.invitee_phone, ic.invitee_email, v_ph, v_em) is null)
          -- 해외 결제 링크 손님 초대장: 내가 그 코드로 가입했을 때
          or (    public._taam_invite_code_only(ic.invited_by, ic.country, ic.invitee_phone, ic.invitee_email)
              and public._taam_code_owner(ic.code) = v_uid));
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.consume_invite_by_self() from public, anon;
grant execute on function public.consume_invite_by_self() to authenticated;

create or replace function public.taam_invited_tier(p_user_id uuid, p_email text, p_phone text)
returns text
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_email text := '';
  v_pkey  text := '';
  v_tier  text;
begin
  if p_user_id is null then return null; end if;
  -- 남의 등급은 묻지 못한다(본인 · 슈퍼어드민 · 서버만)
  if auth.uid() is not null and auth.uid() <> p_user_id and not public._taam_uid_is_super() then return null; end if;
  begin
    -- 인증된 값만(메타데이터 번호·인자 무시)
    select case when u.email_confirmed_at is not null then lower(btrim(coalesce(u.email, ''))) else '' end,
           case when u.phone_confirmed_at is not null then public._taam_phone_key(u.phone) else '' end
      into v_email, v_pkey
      from auth.users u where u.id = p_user_id;
  exception when others then
    v_email := ''; v_pkey := '';
  end;
  v_email := coalesce(v_email, ''); v_pkey := coalesce(v_pkey, '');

  select upper(btrim(ic.invitee_tier))
    into v_tier
    from public.invite_codes ic
   where upper(btrim(coalesce(ic.invitee_tier,''))) in ('M','T','A')
     and (
          ic.member_id::text = p_user_id::text
       or (v_email <> '' and lower(btrim(coalesce(ic.used_by_email,''))) = v_email)
       or (v_email <> '' and lower(btrim(coalesce(ic.invitee_email,''))) = v_email)
       or (length(v_pkey) >= 8 and public._taam_phone_key(ic.used_by_phone) = v_pkey)
       or (length(v_pkey) >= 8 and public._taam_phone_key(ic.invitee_phone) = v_pkey)
       -- 해외 결제 링크 손님: 소진(member_id) 전에도 그 코드로 가입한 유일한 인증 계정
       or (nullif(btrim(coalesce(ic.member_id, '')), '') is null and public._taam_code_owner(ic.code) = p_user_id)
     )
   order by (ic.member_id::text = p_user_id::text) desc nulls last, ic.used_at desc nulls last
   limit 1;
  return v_tier;
end;
$$;
comment on function public.taam_invited_tier(uuid, text, text) is
  '이 회원의 초대코드가 지정한 등급. 인자 email/phone 은 무시하고 auth.users 의 인증된 값만 쓴다(2026-10-30 · 메타데이터 번호 제외).';
revoke all on function public.taam_invited_tier(uuid, text, text) from public, anon;
grant execute on function public.taam_invited_tier(uuid, text, text) to authenticated;

-- ── ⑤ 가입 때 auth → profiles 동기화: 이름 정리 · 메타데이터 번호 안 씀 ──
create or replace function public.sync_profile_email_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  -- 새 사용자가 생성됐을 때 또는 이메일이 변경됐을 때 (표시 이름은 가입자가 적은 메타데이터 — 정리해서)
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, public._taam_clean_name(new.raw_user_meta_data->>'display_name'))
  on conflict (id) do update
    set email = excluded.email
    where public.profiles.email is distinct from excluded.email;
  return new;
end;
$$;

create or replace function public.sync_profile_contact_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  update public.profiles
  set
    email = coalesce(nullif(public.profiles.email,''), new.email),
    phone = coalesce(nullif(public.profiles.phone,''), new.phone)    -- 메타데이터 번호는 쓰지 않는다(2026-10-30)
  where id = new.id;
  return new;
end;
$$;

-- ── ④ profiles 연락처 가드(회원 세션) · ⑤ 서버가 쓰는 이름 정리 ──
create or replace function public.taam_guard_profile_contact()
returns trigger language plpgsql set search_path = public as $$
declare v_ph text; v_em text;
begin
  -- 회원이 앱으로 직접 쓰는 문장만(서버 함수·Edge·SQL Editor 는 그대로) · 슈퍼어드민은 통과
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if public._taam_uid_is_super() then return new; end if;
  if tg_op = 'INSERT' or new.phone is distinct from old.phone then
    if nullif(btrim(coalesce(new.phone, '')), '') is not null then
      v_ph := public._taam_my_verified_phone_key();
      if v_ph is null or public._taam_phone_key(new.phone) <> v_ph then
        new.phone := case when tg_op = 'INSERT' then null else old.phone end;   -- 인증 안 된 번호는 되돌림(같은 UPDATE 의 다른 칸은 그대로)
      end if;
    end if;
  end if;
  if tg_op = 'INSERT' or new.email is distinct from old.email then
    if nullif(btrim(coalesce(new.email, '')), '') is not null then
      v_em := public._taam_my_verified_email();
      if v_em is null or lower(btrim(new.email)) <> v_em then
        new.email := case when tg_op = 'INSERT' then null else old.email end;
      end if;
    end if;
  end if;
  return new;
end $$;

-- 이름 정리 함수 — 본문은 아래 ⑤-2 에서 채운다(트리거를 먼저 걸 수 있게 빈 판을 둔다)
create or replace function public.taam_profile_name_clean()
returns trigger language plpgsql set search_path = public as $$ begin return new; end $$;
do $$ begin
  if to_regclass('public.profiles') is null then raise notice 'profiles 없음 — ④⑤ 건너뜀'; return; end if;
  execute 'drop trigger if exists trg_taam_guard_profile_contact on public.profiles';
  execute 'create trigger trg_taam_guard_profile_contact before insert or update on public.profiles
           for each row execute function public.taam_guard_profile_contact()';
  -- 이름 정리는 K 글자 검사(trg_taam_guard_text_input · 회원 세션은 거절) 뒤 · 잔액 동기화(trg_taam_sync_…) 앞
  execute 'drop trigger if exists trg_taam_profile_name_clean on public.profiles';
  execute 'create trigger trg_taam_profile_name_clean before insert or update on public.profiles
           for each row execute function public.taam_profile_name_clean()';
end $$;

-- ── ①-2 auth.users 갱신 가드: 로그인 이메일 변경 막음 · 메타데이터 정리 ──
create or replace function public.taam_guard_auth_user_update()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare v_meta jsonb; k text;
begin
  -- Confirm email 이 꺼진 프로젝트에선 updateUser({email}) 가 확인 없이 바로 바뀐다 — 남의 초대 이메일로 바꿔 그 초대장의 주인이 되던 길.
  --   앱은 이메일을 바꾸지 않는다. 운영자가 바꿔야 하면 SQL Editor 에서 set local taam.allow_email_change = '1' 뒤에.
  if lower(nullif(btrim(coalesce(new.email, '')), '')) is distinct from lower(nullif(btrim(coalesce(old.email, '')), ''))
     and coalesce(current_setting('taam.allow_email_change', true), '') <> '1' then
    raise exception 'EMAIL_CHANGE_BLOCKED: 로그인 이메일은 바꿀 수 없습니다 — TAAM 에 문의해 주세요' using errcode = '42501';
  end if;
  -- 메타데이터(가입자가 updateUser({data}) 로 언제든 쓴다): 이름 정리 · 번호 키 버림. 실패해도 로그인·갱신을 막지 않는다.
  begin
    if new.raw_user_meta_data is distinct from old.raw_user_meta_data and jsonb_typeof(new.raw_user_meta_data) = 'object' then
      v_meta := new.raw_user_meta_data - 'phone';
      foreach k in array array['display_name', 'name', 'full_name', 'user_name', 'nickname'] loop
        if jsonb_typeof(v_meta -> k) = 'string' then
          v_meta := jsonb_set(v_meta, array[k], to_jsonb(public._taam_clean_name(v_meta ->> k)));
        end if;
      end loop;
      if v_meta is distinct from new.raw_user_meta_data then new.raw_user_meta_data := v_meta; end if;
    end if;
  exception when others then
    raise warning '[auth_update] 메타데이터 정리 실패(갱신은 진행): % %', sqlstate, sqlerrm;
  end;
  return new;
end $$;
revoke all on function public.taam_guard_auth_user_update() from public, anon, authenticated;
drop trigger if exists trg_taam_guard_auth_update on auth.users;
create trigger trg_taam_guard_auth_update before update on auth.users
  for each row execute function public.taam_guard_auth_user_update();

-- ── ②-2 게스트 좌석 — 번호가 인증되는 순간 붙인다(가입 줄은 OTP 확인 전에 생기므로 가입 직후 붙이기는 이제 거의 안 탄다) ──
create or replace function public.taam_guest_attach_on_verify()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  if to_regprocedure('public.taam_guest_attach_tickets(uuid,text,text)') is null then return new; end if;
  begin
    perform public.taam_guest_attach_tickets(new.id, null, new.phone);
  exception when others then
    raise warning '[guest_invite] 번호 인증 뒤 티켓 붙이기 실패(인증은 유지): % %', sqlstate, sqlerrm;
  end;
  return new;
end $$;
revoke all on function public.taam_guest_attach_on_verify() from public, anon, authenticated;
drop trigger if exists trg_taam_guest_attach_on_verify on auth.users;
create trigger trg_taam_guest_attach_on_verify after update on auth.users
  for each row
  when (new.phone_confirmed_at is not null and length(regexp_replace(coalesce(new.phone, ''), '[^0-9]', '', 'g')) >= 9
        and (old.phone_confirmed_at is null or old.phone is distinct from new.phone))
  execute function public.taam_guest_attach_on_verify();

-- ── ②-3 결제 링크 손님 초대장의 국내/해외 판정 — 앞자리만 보던 정규식을 엄격하게(+1 617… 이 국내로 분류돼 가입이 막혔다) ──
do $$
declare v_def text; v_new text; v_old text := 'v_kr  := v_digits ~ ''^(0?1[016789]|821[016789])'';';
        v_rep text := 'v_kr  := public._taam_kr_mobile(v_digits);';
begin
  if to_regprocedure('public.taam_guest_invite_on_paid()') is null then raise notice '[②-3] taam_guest_invite_on_paid 없음 — 건너뜀'; return; end if;
  v_def := pg_get_functiondef('public.taam_guest_invite_on_paid()'::regprocedure);
  if position(v_rep in v_def) > 0 then raise notice '[②-3] 이미 엄격 판정'; return; end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise notice '[②-3] 판정 줄을 정확히 하나 찾지 못함 — 건너뜀(⚠ 확인 표)'; return;
  end if;
  v_new := replace(v_def, v_old, v_rep);
  execute v_new;
  raise notice '[②-3] 국내 판정 교체';
end $$;

-- ── ⑤-2 서버가 쓰는 profiles 글자 — 이름은 정리, 그 밖의 글자 칸은 태그 모양 꺾쇠 제거 · 이메일은 이상하면 비움 · 번호는 번호 글자만 ──
create or replace function public.taam_profile_name_clean()
returns trigger language plpgsql set search_path = public as $$
declare j jsonb := to_jsonb(new); o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end; k text; v text; ch jsonb := '{}'::jsonb;
begin
  for k, v in select e.key, e.value #>> '{}' from jsonb_each(j) e where jsonb_typeof(e.value) = 'string' loop
    continue when o is not null and (o -> k) is not distinct from (j -> k);
    if k in ('display_name', 'display_name_en', 'display_name_jp', 'display_name_ja') then
      if v ~ '[<>[:cntrl:]]' or v ~* 'javascript\s*:' then ch := ch || jsonb_build_object(k, public._taam_clean_name(v)); end if;
    elsif k = 'email' then
      if v ~ '[<>"''[:space:]]' then ch := ch || jsonb_build_object(k, null); end if;
    elsif k = 'phone' then
      if v ~ '[^0-9+()\- .]' then ch := ch || jsonb_build_object(k, nullif(btrim(regexp_replace(v, '[^0-9+()\- .]', '', 'g')), '')); end if;
    elsif v ~* '<\s*[a-z/!?]' or v ~* 'javascript\s*:' then
      ch := ch || jsonb_build_object(k, regexp_replace(regexp_replace(v, '[<>]', '', 'g'), 'javascript\s*:', '', 'gi'));
    end if;
  end loop;
  if ch <> '{}'::jsonb then new := jsonb_populate_record(new, ch); end if;
  return new;
end $$;

-- ── ⑦ 서버 전용 도우미 권한 ──
do $$ begin
  if to_regprocedure('public.email_exists_in_auth(text)') is not null then
    execute 'revoke all on function public.email_exists_in_auth(text) from public, anon, authenticated'; end if;
  if to_regprocedure('public.email_exists_in_auth_other(text, uuid)') is not null then
    execute 'revoke all on function public.email_exists_in_auth_other(text, uuid) from public, anon, authenticated'; end if;
  if to_regprocedure('public._taam_guest_invite_code()') is not null then
    execute 'revoke all on function public._taam_guest_invite_code() from public, anon, authenticated'; end if;
  if to_regprocedure('public.taam_signup_guard_mode()') is not null then
    execute 'revoke all on function public.taam_signup_guard_mode() from public, anon, authenticated'; end if;
end $$;

-- ── 확인 (한 표) ──
select '① 문지기 — 메타데이터 번호 안 봄 · 채널 대조 · 오류 거절' as item,
       case when (select prosrc from pg_proc where oid = 'public.taam_guard_signup()'::regprocedure) like '%_taam_invite_bind_reason%'
             and (select prosrc from pg_proc where oid = 'public.taam_guard_signup()'::regprocedure) like '%SIGNUP_GUARD_ERROR%'
             and (select prosrc from pg_proc where oid = 'public.taam_guard_signup()'::regprocedure) not like '%raw_user_meta_data->>''phone''%'
            then '✅' else '❌' end as ok
union all select '① 매장 계정 발급 예약 표 — 회원·anon 접근 없음', case when to_regclass('public.partner_signup_allow') is not null and not has_table_privilege('authenticated', 'public.partner_signup_allow', 'select') and not has_table_privilege('anon', 'public.partner_signup_allow', 'insert') then '✅' else '❌' end
union all select '① 문지기 트리거 auth.users', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_signup' and tgrelid = 'auth.users'::regclass) then '✅' else '❌ 트리거 없음' end
union all select '① 모드', coalesce((select '✅ ' || public.taam_signup_guard_mode()), '⚠')
union all select '② 초대 소진 가드', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_invite_consume' and tgrelid = 'public.invite_codes'::regclass) then '✅' else '❌' end
union all select '② 게스트 붙이기 — profiles 번호로 안 찾음', case when (select prosrc from pg_proc where oid = 'public.taam_guest_attach_on_invite_used()'::regprocedure) not like '%from public.profiles%' then '✅' else '❌' end
union all select '③ invite_codes 읽기 — 자기 것만', case when not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'invite_codes' and cmd = 'SELECT' and qual = 'true')
                                                  and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'invite_codes' and policyname = 'invite_codes_read_own') then '✅' else '❌' end
union all select '③ invite_codes SELECT 정책(정보)', (select string_agg(policyname || ' ' || array_to_string(roles, ','), ' · ' order by policyname) from pg_policies where schemaname = 'public' and tablename = 'invite_codes' and cmd in ('SELECT', 'ALL'))
union all select '③ anon 읽기 없음', case when not has_table_privilege('anon', 'public.invite_codes', 'select') then '✅' else '❌' end
union all select '④ profiles 연락처 가드', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_profile_contact' and tgrelid = 'public.profiles'::regclass) then '✅' else '❌' end
union all select '⑤ 이름 정리(profiles · 동기화)', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_profile_name_clean' and tgrelid = 'public.profiles'::regclass)
                                                and (select prosrc from pg_proc where oid = 'public.sync_profile_email_from_auth()'::regprocedure) like '%_taam_clean_name%' then '✅' else '❌' end
union all select '⑤ 동기화 — 메타데이터 번호 안 씀', case when (select prosrc from pg_proc where oid = 'public.sync_profile_contact_from_auth()'::regprocedure) not like '%raw_user_meta_data%' then '✅' else '❌' end
union all select '⑥ 로그인 대조 · 자기 소진 · 등급 — 부분 일치·폴백 없음',
       case when (select prosrc from pg_proc where oid = 'public.user_has_invite_match()'::regprocedure) not like '%like%'
             and (select prosrc from pg_proc where oid = 'public.consume_invite_by_self()'::regprocedure) not like '%profiles%'
             and (select prosrc from pg_proc where oid = 'public.taam_invited_tier(uuid,text,text)'::regprocedure) not like '%raw_user_meta_data%' then '✅' else '❌' end
union all select '⑥ anon 실행 없음(대조·소진·등급·내 초대장)',
       case when not has_function_privilege('anon', 'public.user_has_invite_match()', 'execute') and not has_function_privilege('anon', 'public.consume_invite_by_self()', 'execute')
             and not has_function_privilege('anon', 'public.taam_invited_tier(uuid,text,text)', 'execute') and not has_function_privilege('anon', 'public.taam_my_invite()', 'execute') then '✅' else '❌' end
union all select '⑦ 이메일 존재 조회 — 회원·anon 실행 없음',
       case when to_regprocedure('public.email_exists_in_auth_other(text, uuid)') is null then '⚠ 함수 없음'
            when not has_function_privilege('authenticated', 'public.email_exists_in_auth_other(text, uuid)', 'execute') and not has_function_privilege('anon', 'public.email_exists_in_auth_other(text, uuid)', 'execute') then '✅' else '❌' end
union all select '⑧ 지금 초대장 — 묶임 없는 것(정보)', (select count(*)::text || '건' from public.invite_codes where public._taam_invite_bind_phone(invitee_phone) is null and public._taam_invite_bind_email(invitee_email) is null)
union all select '⑧ 지금 회원 — 로그인 대조', (select case when count(*) filter (where not ok) = 0 then '✅ ' else '⚠ 대조 실패 ' || count(*) filter (where not ok) || '명 — ' end
                                          || count(*) filter (where ok)::text || ' / ' || count(*)::text from (
         select exists (select 1 from public.invite_codes ic where ic.member_id = au.id::text
                           or (au.phone_confirmed_at is not null and length(public._taam_phone_key(au.phone)) >= 8 and (public._taam_phone_key(ic.invitee_phone) = public._taam_phone_key(au.phone) or public._taam_phone_key(ic.used_by_phone) = public._taam_phone_key(au.phone)))
                           or (au.email_confirmed_at is not null and nullif(lower(btrim(coalesce(au.email,''))),'') is not null and (lower(btrim(coalesce(ic.invitee_email,''))) = lower(btrim(au.email)) or lower(btrim(coalesce(ic.used_by_email,''))) = lower(btrim(au.email))))
                           or (nullif(btrim(coalesce(ic.member_id, '')), '') is null and public._taam_code_owner(ic.code) = au.id)) as ok
           from auth.users au join public.profiles p on p.id = au.id
          where coalesce(p.role, 'user') not in ('admin','super_admin','superadmin','staff') and p.deleted_at is null
            and not exists (select 1 from public.admin_grants g where g.user_id = au.id)) s)
union all select '①-2 auth.users 갱신 가드(이메일 변경 · 메타데이터)', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guard_auth_update' and tgrelid = 'auth.users'::regclass) then '✅' else '❌' end
union all select '②-2 번호 인증 뒤 게스트 좌석 붙이기', case when exists (select 1 from pg_trigger where tgname = 'trg_taam_guest_attach_on_verify' and tgrelid = 'auth.users'::regclass) then '✅' else '❌' end
union all select '②-3 결제 링크 손님 국내 판정(엄격)', case when to_regprocedure('public.taam_guest_invite_on_paid()') is null then '⚠ 함수 없음'
            when (select prosrc from pg_proc where oid = 'public.taam_guest_invite_on_paid()'::regprocedure) like '%_taam_kr_mobile%' then '✅' else '⚠ 옛 판정 그대로(모양이 달라 건너뜀)' end
union all select '③ 해외 손님 초대장 주인 — 유일한 인증 계정만(정보)', (select count(*)::text || '건 미사용 · 주인 정해짐 ' || count(*) filter (where public._taam_code_owner(code) is not null)
          from public.invite_codes where not coalesce(used, false) and public._taam_invite_code_only(invited_by, country, invitee_phone, invitee_email));
