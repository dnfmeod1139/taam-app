-- ═══════════════════════════════════════════════════════════════
-- TAAM 멤버십 — 추천권 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 무엇
--   M회원이 연 2매(설정값) 발급한다. 유효 14일(설정값).
--   추천은 **심사 기회**이지 가입 보장이 아니다 — 문구에도 그렇게 적는다.
--
-- 코드 상태: issued → opened → applied → expired
--   회원 마이페이지에서 각 장이 어디까지 갔는지 보인다. 「보냈는데 아무
--   소식이 없다」와 「열어는 봤다」는 회원에게 전혀 다른 정보다.
--
-- 왜 매수를 서버가 세나
--   앱에서 세면 앱을 안 거치고 RPC 를 두 번 부르면 그만이다.
--   발급 함수가 **그 해 발급분을 세어** 초과를 막는다.
--
-- ⚠ 초대장 페이지는 추천인의 **성만** 본다. 이름·번호를 주지 않는다.
--
-- 실행: Supabase SQL Editor. ⚠ membership_settings.sql 다음.
--   읽는 법: 맨 아래가 전부 ✅ 여야 정상.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.membership_referrals (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  year         int  not null,
  status       text not null default 'issued',   -- issued|opened|applied|expired|revoked
  expires_at   timestamptz not null,
  opened_at    timestamptz,
  applied_at   timestamptz,
  application_id uuid references public.membership_applications(id) on delete set null,
  created_at   timestamptz not null default now()
);

create index if not exists idx_mship_ref_owner on public.membership_referrals (owner_id, year);
create unique index if not exists idx_mship_ref_code on public.membership_referrals (upper(code));

alter table public.membership_referrals enable row level security;
revoke all on public.membership_referrals from anon, authenticated;
grant select on public.membership_referrals to authenticated;

-- 회원은 **자기가 발급한 것만** 본다. 남이 몇 장 썼는지 볼 이유가 없다.
drop policy if exists mship_ref_own on public.membership_referrals;
create policy mship_ref_own on public.membership_referrals
  for select to authenticated
  using (owner_id = auth.uid() or is_super_admin(auth.uid()));

comment on table public.membership_referrals is
  '추천권. 연 N매(설정값)·유효 14일. 발급·조회는 RPC 로만. 추천 = 심사 기회이지 가입 보장이 아니다.';


-- ── ① 발급 ────────────────────────────────────────────────────
create or replace function public.taam_ref_issue()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  p public.profiles%rowtype;
  r public.membership_referrals%rowtype;
  v_max int; v_days int; v_year int := extract(year from now())::int;
  v_used int; v_code text; i int := 0;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  select * into p from public.profiles where id = auth.uid();
  if not found then raise exception '회원을 찾을 수 없습니다' using errcode = 'P0002'; end if;

  -- 유료 회원만. 게스트가 추천권을 쓰면 초대제가 무너진다.
  if upper(coalesce(p.membership_tier,'')) not in ('M','T') then
    raise exception '추천권은 멤버십 회원만 발급할 수 있습니다' using errcode = '42501';
  end if;

  select (s.v#>>'{}')::int into v_max  from public.membership_settings s where s.k = 'referral_per_year';
  select (s.v#>>'{}')::int into v_days from public.membership_settings s where s.k = 'referral_days';

  -- ⚠ 그 해 발급분을 **서버가** 센다. 만료·미사용도 한 장으로 센다 —
  --   안 그러면 발급하고 버리기를 반복해 무한이 된다.
  select count(*) into v_used
    from public.membership_referrals
   where owner_id = p.id and year = v_year and status <> 'revoked';
  if v_used >= coalesce(v_max, 2) then
    raise exception '올해 추천권을 모두 쓰셨습니다 (%/%)', v_used, coalesce(v_max,2)
      using errcode = '22023';
  end if;

  -- 사람이 부르는 코드. 헷갈리는 글자(0·O·1·I)는 뺀다.
  loop
    i := i + 1;
    v_code := 'TAAM-' || v_year::text || '-' ||
      (select string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ',
                                (floor(random()*32)+1)::int, 1), '')
         from generate_series(1,4));
    exit when not exists (select 1 from public.membership_referrals where upper(code) = upper(v_code));
    if i > 20 then raise exception '코드를 만들지 못했습니다' using errcode = '55000'; end if;
  end loop;

  insert into public.membership_referrals (code, owner_id, year, expires_at)
  values (v_code, p.id, v_year, now() + (coalesce(v_days, 14) || ' day')::interval)
  returning * into r;

  return jsonb_build_object('ok', true, 'code', r.code, 'expires_at', r.expires_at,
                            'used', v_used + 1, 'max', coalesce(v_max, 2));
end;
$$;
revoke all on function public.taam_ref_issue() from public;
grant execute on function public.taam_ref_issue() to authenticated;


-- ── ② 내 추천권 ───────────────────────────────────────────────
create or replace function public.taam_ref_mine()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_out jsonb; v_max int; v_year int := extract(year from now())::int; v_used int;
begin
  if auth.uid() is null then raise exception '로그인이 필요합니다' using errcode = '42501'; end if;
  select (s.v#>>'{}')::int into v_max from public.membership_settings s where s.k = 'referral_per_year';
  select count(*) into v_used
    from public.membership_referrals
   where owner_id = auth.uid() and year = v_year and status <> 'revoked';

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into v_out
    from (select r.id, r.code, r.status, r.expires_at, r.opened_at, r.applied_at, r.created_at,
                 (r.expires_at <= now() and r.status in ('issued','opened')) as expired
            from public.membership_referrals r
           where r.owner_id = auth.uid() and r.year = v_year
           order by r.created_at desc) x;

  return jsonb_build_object('year', v_year, 'max', coalesce(v_max,2),
                            'used', v_used, 'left', greatest(0, coalesce(v_max,2) - v_used),
                            'items', v_out);
end;
$$;
revoke all on function public.taam_ref_mine() from public;
grant execute on function public.taam_ref_mine() to authenticated;


-- ── ③ 공개 — 초대장 열기 ──────────────────────────────────────
--   ⚠ 추천인의 **성만** 준다. 이름도 번호도 주지 않는다.
create or replace function public.taam_ref_public(p_code text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare r public.membership_referrals%rowtype; v_name text;
begin
  select * into r from public.membership_referrals where upper(code) = upper(btrim(p_code));
  if not found then return jsonb_build_object('found', false); end if;
  if r.status = 'revoked' then return jsonb_build_object('found', true, 'blocked', 'revoked'); end if;
  if r.expires_at <= now() and r.status in ('issued','opened') then
    return jsonb_build_object('found', true, 'blocked', 'expired', 'expires_at', r.expires_at);
  end if;
  if r.status = 'applied' then
    return jsonb_build_object('found', true, 'blocked', 'applied');
  end if;

  if r.status = 'issued' then
    update public.membership_referrals set status = 'opened', opened_at = now() where id = r.id;
  end if;

  select nullif(left(btrim(coalesce(display_name,'')), 1), '')
    into v_name from public.profiles where id = r.owner_id;

  return jsonb_build_object('found', true, 'blocked', null,
                            'code', r.code, 'surname', v_name, 'expires_at', r.expires_at);
end;
$$;
revoke all on function public.taam_ref_public(text) from public;
grant execute on function public.taam_ref_public(text) to anon, authenticated;


-- ── ④ 신청서에 추천 코드가 붙으면 그 장을 「썼다」로 ───────────
--   taam_mship_apply 가 referral_code 를 받으면 여기서 이어 준다.
create or replace function public.taam_ref_consume(p_code text, p_application_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare r public.membership_referrals%rowtype;
begin
  select * into r from public.membership_referrals where upper(code) = upper(btrim(coalesce(p_code,'')));
  if not found then return jsonb_build_object('ok', false, 'why', 'not_found'); end if;
  if r.status = 'applied' then return jsonb_build_object('ok', false, 'why', 'used'); end if;
  if r.expires_at <= now() then return jsonb_build_object('ok', false, 'why', 'expired'); end if;
  update public.membership_referrals
     set status = 'applied', applied_at = now(), application_id = p_application_id
   where id = r.id;
  return jsonb_build_object('ok', true, 'owner_id', r.owner_id);
end;
$$;
revoke all on function public.taam_ref_consume(text, uuid) from public;
grant execute on function public.taam_ref_consume(text, uuid) to anon, authenticated;

-- 신청이 들어올 때 코드가 붙어 있으면 자동으로 잇는다.
--   ⚠ 코드가 틀렸다고 **신청을 거절하지 않는다.** 추천 코드는 부가 정보이고,
--     여기서 막으면 오타 하나로 신청 자체가 사라진다.
create or replace function public.taam_mship_apply(
  p_name     text,
  p_phone    text,
  p_answers  jsonb,
  p_lang     text default 'ko',
  p_referral text default null,
  p_source   text default 'app'
)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_phone text;
  v_uid   uuid := auth.uid();
  v_row   public.membership_applications%rowtype;
  v_ref   text;
begin
  v_phone := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), '');
  if v_phone is null or length(v_phone) < 8 then
    raise exception '연락처를 확인해 주세요' using errcode = '22023';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception '이름을 적어 주세요' using errcode = '22023';
  end if;

  select * into v_row
    from public.membership_applications
   where phone = v_phone and status in ('applied','screening')
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'already', true, 'id', v_row.id,
                              'status', v_row.status, 'created_at', v_row.created_at);
  end if;

  v_ref := nullif(btrim(upper(coalesce(p_referral,''))), '');

  insert into public.membership_applications
    (user_id, name, phone, answers, referral_code, lang, source)
  values
    (v_uid, btrim(p_name), v_phone,
     coalesce(p_answers, '{}'::jsonb), v_ref,
     lower(coalesce(nullif(btrim(p_lang),''), 'ko')),
     lower(coalesce(nullif(btrim(p_source),''), 'app')))
  returning * into v_row;

  -- 코드가 틀렸어도 신청은 그대로 남는다
  if v_ref is not null then
    perform public.taam_ref_consume(v_ref, v_row.id);
  end if;

  return jsonb_build_object('ok', true, 'already', false, 'id', v_row.id,
                            'status', v_row.status, 'created_at', v_row.created_at);
end;
$$;
revoke all on function public.taam_mship_apply(text, text, jsonb, text, text, text) from public;
grant execute on function public.taam_mship_apply(text, text, jsonb, text, text, text)
  to anon, authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 추천권 표' as "구분",
       case when to_regclass('public.membership_referrals') is not null then '✅' else '❌' end as "상태",
       '' as "메모"
union all
select '② 남의 추천권은 못 보나 ⭐',
       case when exists (select 1 from pg_policies
                          where tablename='membership_referrals'
                            and qual like '%owner_id = auth.uid()%')
            then '✅' else '❌' end, ''
union all
select '③ anon 은 표에 손도 못 대나',
       case when not has_table_privilege('anon','public.membership_referrals','select')
            then '✅' else '❌' end, ''
union all
select '④ 함수 4개',
       case when count(*) = 4 then '✅' else '❌ ' || count(*)::text || '/4' end,
       coalesce(string_agg(proname, ' · ' order by proname), '—')
  from pg_proc
 where pronamespace='public'::regnamespace
   and proname in ('taam_ref_issue','taam_ref_mine','taam_ref_public','taam_ref_consume')
union all
select '⑤ 신청이 추천 코드를 잇나',
       case when prosrc like '%taam_ref_consume%' then '✅' else '❌ 옛 버전' end, ''
  from pg_proc
 where pronamespace='public'::regnamespace and proname='taam_mship_apply'
union all
select '⑥ 연 매수 설정',
       coalesce((select v#>>'{}' from public.membership_settings where k='referral_per_year'), '❌') || '매',
       coalesce((select v#>>'{}' from public.membership_settings where k='referral_days'), '?') || '일 유효'
 order by 1;
