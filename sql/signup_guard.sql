-- ═══════════════════════════════════════════════════════════════════════════
-- TAAM — 초대제 서버화 1단계: 가입 문지기 (auth.users BEFORE INSERT)  2026-09-14
-- ═══════════════════════════════════════════════════════════════════════════
-- 실행: Supabase SQL Editor 에서 통째로 RUN.  결과: 맨 아래 확인 표에 ❌ 가 없어야 정상.
--
-- 왜: 지금 초대제는 앱이 지킨다. verify-invite 로 코드를 확인한 뒤에야 OTP 를 보내지만,
--     그 순서는 앱이 정한 것이라 anon key 로 /auth/v1/otp 를 직접 부르면 초대 없이도
--     auth.users 에 계정이 생긴다. (대시보드 "Allow new users to sign up" 을 끄면 초대 가입
--     자체가 막히므로 그 스위치로는 못 조인다.)
--
-- 무엇: auth.users 에 행이 생기기 직전에 「초대받은 사람인가」를 DB 가 판정한다.
--   허용 ①  슈퍼어드민 화이트리스트 이메일   (auto_promote_super_admin 과 같은 목록)
--   허용 ②  @partner.taam.kr                   (partner-account 가 관리자 API 로 만드는 매장 계정)
--   허용 ③  user_metadata.invite_code 가 살아 있는 초대코드 (미사용·미만료·초대장의 번호/이메일과 일치)
--   허용 ④  초대장에 이 이메일/번호가 적혀 있다 (코드를 못 싣는 소셜 첫 로그인 등)
--   거부    그 밖의 전부
--
-- 모드 (app_config.key='signup_guard' → value->>'mode'):
--   'log'     (1단계)       판정만 signup_guard_log 에 적고 막지 않는다.
--   'enforce' (2단계 · 2026-09-15 01:59 라이브 전환) 거부면 예외 → GoTrue 가 "Database error saving new user" 로 가입을 끊는다.
--   모드는 아래 ⑤ 의 한 줄로 바꾼다. 앱은 안 건드려도 된다.
--
-- 안전장치: 판정 코드 자체가 오류를 내면(컬럼 없음 등) 가입을 막지 않고 verdict='error' 로 남긴다.
--   초대 문지기가 자기 버그로 진짜 초대 회원을 막는 것이 가장 나쁜 모양이기 때문이다.
--
-- 되돌리기: drop trigger if exists trg_taam_guard_signup on auth.users;
-- ═══════════════════════════════════════════════════════════════════════════

-- ── ① 판정 기록 표 ──
create table if not exists public.signup_guard_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  user_id     uuid,
  email       text,
  phone       text,
  provider    text,
  invite_code text,
  verdict     text not null,          -- allow | reject | error
  reason      text not null,          -- super_whitelist | partner_domain | invite_code | invitee_match | code_not_found | code_used | code_expired | phone_mismatch | email_mismatch | no_invite | <오류문>
  mode        text not null,          -- log | enforce (판정 당시)
  enforced    boolean not null default false  -- 실제로 막았나
);
alter table public.signup_guard_log enable row level security;
revoke all on public.signup_guard_log from anon, authenticated;
-- 슈퍼어드민만 읽는다 (앱 화면은 아직 없음 — SQL Editor 로 본다)
drop policy if exists signup_guard_log_super_read on public.signup_guard_log;
create policy signup_guard_log_super_read on public.signup_guard_log
  for select to authenticated using (public._taam_uid_is_super());
grant select on public.signup_guard_log to authenticated;

-- ── ② 전화번호 키 (이미 있으면 같은 정의) ──
create or replace function public._taam_phone_key(p_text text)
returns text language sql immutable as $$
  select regexp_replace(regexp_replace(regexp_replace(coalesce(p_text, ''), '[^0-9]', '', 'g'), '^82', ''), '^0+', '')
$$;

-- 만료일 컬럼이 text 든 timestamptz 든 안전하게 읽는다 (잘못된 문자열이면 null = 만료 없음)
create or replace function public._taam_ts_safe(p_any text)
returns timestamptz language plpgsql immutable as $$
begin
  return nullif(btrim(p_any), '')::timestamptz;
exception when others then
  return null;
end $$;

-- ── ③ 모드 읽기 ──
create or replace function public.taam_signup_guard_mode()
returns text language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  if to_regclass('public.app_config') is null then return 'log'; end if;
  select value->>'mode' into v from public.app_config where key = 'signup_guard';
  return case when v in ('log','enforce') then v else 'log' end;
end $$;
revoke all on function public.taam_signup_guard_mode() from public, anon, authenticated;

-- ── ④ 문지기 ──
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
  r         record;
begin
  begin
    v_mode  := public.taam_signup_guard_mode();
    v_email := lower(nullif(btrim(coalesce(new.email, '')), ''));
    v_phone := public._taam_phone_key(coalesce(nullif(new.phone, ''), new.raw_user_meta_data->>'phone'));
    v_code  := upper(nullif(btrim(coalesce(new.raw_user_meta_data->>'invite_code', '')), ''));
    v_prov  := coalesce(new.raw_app_meta_data->>'provider', '');

    if v_email is not null and v_email in ('dnfmeod@playtaam.com') then
      v_verdict := 'allow'; v_reason := 'super_whitelist';

    elsif v_email is not null and v_email like '%@partner.taam.kr' then
      v_verdict := 'allow'; v_reason := 'partner_domain';

    elsif v_code is not null then
      select ic.used, ic.expires_at::text as expires_txt, ic.invitee_phone, ic.invitee_email
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
      elsif length(public._taam_phone_key(r.invitee_phone)) >= 8
            and length(coalesce(v_phone, '')) >= 8
            and public._taam_phone_key(r.invitee_phone) <> v_phone then
        v_reason := 'phone_mismatch';
      elsif nullif(lower(btrim(coalesce(r.invitee_email, ''))), '') is not null
            and v_email is not null
            and lower(btrim(r.invitee_email)) <> v_email then
        v_reason := 'email_mismatch';
      else
        v_verdict := 'allow'; v_reason := 'invite_code';
      end if;

    else
      -- 코드가 안 실린 가입(소셜 첫 로그인 등): 초대장에 이 사람이 적혀 있으면 통과
      if exists (
        select 1 from public.invite_codes ic
         where (v_email is not null and lower(btrim(coalesce(ic.invitee_email, ''))) = v_email)
            or (length(coalesce(v_phone, '')) >= 8 and public._taam_phone_key(ic.invitee_phone) = v_phone)
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
            (v_mode = 'enforce' and v_verdict = 'reject'));
  exception when others then
    null; -- 기록 실패로 가입을 막지 않는다
  end;

  if v_mode = 'enforce' and v_verdict = 'reject' then
    -- 예외로 끝나면 위의 로그 행도 같은 트랜잭션이라 함께 롤백된다.
    -- 그래서 Postgres 로그(Supabase → Logs → Postgres)에도 한 줄 남긴다.
    raise warning 'taam_guard_signup reject: % email=% phone=% code=%', v_reason, v_email, v_phone, v_code;
    raise exception 'SIGNUP_NOT_INVITED: %', v_reason using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists trg_taam_guard_signup on auth.users;
create trigger trg_taam_guard_signup
  before insert on auth.users
  for each row execute function public.taam_guard_signup();

-- ── ⑤ 모드 — 1단계는 log. 2단계에서 아래 값을 'enforce' 로 바꿔 이 블록만 다시 RUN ──
do $$ begin
  if to_regclass('public.app_config') is not null then
    insert into public.app_config(key, value, updated_at)
    values ('signup_guard', jsonb_build_object('mode', 'log'), now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
end $$;

-- ── 확인 (한 표) ──
select '① 로그 표' as item, case when to_regclass('public.signup_guard_log') is not null then '✅' else '❌' end as ok
union all select '② 트리거 auth.users', case when exists (select 1 from pg_trigger where tgname='trg_taam_guard_signup') then '✅' else '❌' end
union all select '③ 모드', case when public.taam_signup_guard_mode() = 'log' then '✅ log (판정만 기록)' else '❌ ' || public.taam_signup_guard_mode() end
union all select '④ 로그 회원 직접 못 씀', case when not has_table_privilege('authenticated','public.signup_guard_log','insert') then '✅' else '❌' end
union all select '⑤ 기존 sync 트리거 유지', case when exists (select 1 from pg_trigger where tgname='trg_sync_profile_email') then '✅' else '⚠ trg_sync_profile_email 없음' end;
