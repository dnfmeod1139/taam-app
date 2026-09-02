-- ═══════════════════════════════════════════════════════════════
-- TAAM 멤버십 — 설정값 + 게스트 제도 (2026-09-02)
-- ═══════════════════════════════════════════════════════════════
-- 통합 스펙(FINAL) 반영. 두 가지가 핵심이다.
--
-- ① 금액·기간을 코드에 박지 않는다
--   연회비는 **아직 정해지지 않았다**(과세 127만 / 영세율 115만 대기).
--   번역 문구에 숫자를 박아 두면 정하는 날 KO·EN·JA 세 곳을 고치고
--   배포까지 해야 한다. 설정값으로 두면 어드민에서 바꾸면 끝이다.
--   90일·7일·14일·12/28 도 같은 이유로 여기 둔다.
--
-- ② 게스트는 90일 한정 초대다
--   무료지만 무기한이 아니다. 만료되면 휴면으로 내려가고 로그인이 풀린다.
--   ⚠ **삭제가 아니다.** 결제 이력·회원 정보는 그대로 둔다 —
--     취소·환불 대응이 남아 있고, 다시 초대하면 그대로 살아나야 한다.
--   연장은 자동 규칙이 없다. 슈퍼어드민의 [+90일] 이 유일한 수단이다.
--
--   ⚠ 등급값은 'A' 를 그대로 쓴다. 화면에만 「게스트」라고 적는다.
--     'G' 로 바꾸면 invite_codes 제약·티켓 가드·기존 회원 데이터까지
--     같이 옮겨야 하는데, 얻는 게 이름뿐이라 그 위험을 지지 않는다.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN.
--   ⚠ sql/membership_apply.sql 다음에.
--   읽는 법: 맨 아래가 전부 ✅ 여야 정상.
-- ═══════════════════════════════════════════════════════════════

-- ── ① 설정값 ──────────────────────────────────────────────────
create table if not exists public.membership_settings (
  k          text primary key,
  v          jsonb not null,
  note       text,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

alter table public.membership_settings enable row level security;
-- 금액·기간은 화면에 적히는 값이라 누구나 읽는다. 쓰기는 RPC 로만.
drop policy if exists mship_set_read on public.membership_settings;
create policy mship_set_read on public.membership_settings
  for select to anon, authenticated using (true);
revoke all on public.membership_settings from anon, authenticated;
grant select on public.membership_settings to anon, authenticated;

-- 기본값. ⚠ annual_fee 는 **아직 정해지지 않은 값**이다 —
--   지금 값은 실수령 기준(112.5만)일 뿐, 과세 구분이 확정되면 바뀐다.
insert into public.membership_settings (k, v, note) values
  ('deposit_amount', '10125000'::jsonb, '다이닝 예치금 (원). M회원 전용'),
  ('annual_fee',     '1125000'::jsonb,  '연회비 (원). ⚠ 미확정 — 과세 127만 / 영세율 115만 결정 대기'),
  ('annual_fee_note','"금액 확정 전"'::jsonb, '연회비 옆에 붙일 한 줄. 비우면 안 붙는다'),
  ('guest_days',     '90'::jsonb,       '게스트 초대 기간 (일)'),
  ('guest_extend_days','90'::jsonb,     '[+90일] 한 번에 늘리는 일수'),
  ('guest_warn_days','7'::jsonb,        '만료 며칠 전에 알리나'),
  ('offer_days',     '7'::jsonb,        '오퍼 링크 유효 기간 (일)'),
  ('referral_days',  '14'::jsonb,       '추천권 유효 기간 (일)'),
  ('referral_per_year','2'::jsonb,      '회원당 연간 추천권 매수'),
  ('renewal_mmdd',   '"12-28"'::jsonb,  '갱신 일괄 확인일'),
  ('corp_deposit_ratio','85'::jsonb,    '법인 예치금 비율 (%)'),
  ('corp_slots',     '5'::jsonb,        '법인 슬롯 수')
on conflict (k) do nothing;

create or replace function public.taam_mship_settings()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from public.membership_settings
$$;
revoke all on function public.taam_mship_settings() from public;
grant execute on function public.taam_mship_settings() to anon, authenticated;

create or replace function public.taam_mship_settings_set(p_k text, p_v jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v public.membership_settings%rowtype;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  -- 없는 열쇠는 만들지 않는다. 오타로 새 설정이 생기면 화면은 옛 값을 계속 읽는다.
  update public.membership_settings
     set v = p_v, updated_at = now(), updated_by = auth.uid()
   where k = p_k returning * into v;
  if not found then
    raise exception '설정 「%」 은 없습니다', p_k using errcode = 'P0002';
  end if;
  return jsonb_build_object('ok', true, 'k', v.k, 'v', v.v);
end;
$$;
revoke all on function public.taam_mship_settings_set(text, jsonb) from public;
grant execute on function public.taam_mship_settings_set(text, jsonb) to authenticated;


-- ── ② 게스트 — 90일 한정 초대 ─────────────────────────────────
alter table public.profiles add column if not exists guest_expires_at   timestamptz;
alter table public.profiles add column if not exists guest_status       text;   -- active | dormant
alter table public.profiles add column if not exists guest_extended_cnt int not null default 0;
alter table public.profiles add column if not exists guest_extended_at  timestamptz;

create index if not exists idx_profiles_guest_exp
  on public.profiles (guest_expires_at)
  where guest_expires_at is not null;

comment on column public.profiles.guest_expires_at is
  '게스트 초대 만료. M회원에게는 null. 판정은 언제나 서버 시각으로 한다 — 클라이언트 시계를 믿지 않는다.';

-- 지금 살아 있는 게스트에게 만료일을 채운다.
--   ⚠ 가입일 + 90일로 계산하면 **이미 만료된 사람이 무더기로 생긴다.**
--     제도를 새로 켜는 것이므로 「오늘부터 90일」로 시작한다.
update public.profiles
   set guest_expires_at = now() + (
         (select (v#>>'{}')::int from public.membership_settings where k = 'guest_days') || ' day')::interval,
       guest_status = 'active'
 where upper(coalesce(membership_tier,'')) = 'A'
   and guest_expires_at is null;

-- ── ③ 지금 이 사람은 만료됐나 — 서버가 판정한다 ────────────────
create or replace function public.taam_guest_state(p_uid uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare u uuid := coalesce(p_uid, auth.uid()); p public.profiles%rowtype; v_warn int;
begin
  if u is null then return null; end if;
  -- 남의 상태는 슈퍼어드민만 본다
  if u <> auth.uid() and not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = u;
  if not found then return null; end if;
  if upper(coalesce(p.membership_tier,'')) <> 'A' then
    return jsonb_build_object('is_guest', false);
  end if;
  select (s.v#>>'{}')::int into v_warn
    from public.membership_settings s where s.k = 'guest_warn_days';
  return jsonb_build_object(
    'is_guest',   true,
    'expires_at', p.guest_expires_at,
    'status',     coalesce(p.guest_status, 'active'),
    -- 만료 판정은 여기서만 한다. 앱이 자기 시계로 세면 시계를 돌려 놓으면 그만이다.
    'expired',    (p.guest_expires_at is not null and p.guest_expires_at <= now()),
    'days_left',  case when p.guest_expires_at is null then null
                       else greatest(0, ceil(extract(epoch from (p.guest_expires_at - now())) / 86400))::int end,
    'warn',       (p.guest_expires_at is not null
                   and p.guest_expires_at > now()
                   and p.guest_expires_at <= now() + (coalesce(v_warn,7) || ' day')::interval)
  );
end;
$$;
revoke all on function public.taam_guest_state(uuid) from public;
grant execute on function public.taam_guest_state(uuid) to authenticated;

-- ── ④ 어드민 — 게스트 목록 (만료 임박순) ──────────────────────
create or replace function public.taam_guest_list(
  p_filter text default 'all',   -- all | active | dormant | warn
  p_limit  int  default 200
)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
-- ⚠ 변수 이름을 v 로 두면 membership_settings.v 컬럼을 가린다.
--   (column reference "v" is ambiguous) — 실제로 목록이 통째로 안 나왔다.
declare v_out jsonb; v_warn int;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select (s.v#>>'{}')::int into v_warn
    from public.membership_settings s where s.k = 'guest_warn_days';

  select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_key), '[]'::jsonb) into v_out
    from (
      select p.id, p.display_name, p.phone, p.created_at,
             p.guest_expires_at, coalesce(p.guest_status,'active') as guest_status,
             p.guest_extended_cnt, p.guest_extended_at,
             (p.guest_expires_at is not null and p.guest_expires_at <= now()) as expired,
             -- 어드민이 [+90일] 을 누를지 판단하는 재료
             exists (select 1 from public.tickets t
                      where t.user_id = p.id and coalesce(t.status,'') = 'active') as has_purchased,
             exists (select 1 from public.membership_applications a
                      where a.user_id = p.id) as has_applied,
             coalesce(p.guest_expires_at, 'infinity'::timestamptz) as sort_key
        from public.profiles p
       where upper(coalesce(p.membership_tier,'')) = 'A'
         and (p_filter = 'all'
              or (p_filter = 'dormant' and coalesce(p.guest_status,'active') = 'dormant')
              or (p_filter = 'active'  and coalesce(p.guest_status,'active') = 'active')
              or (p_filter = 'warn'    and p.guest_expires_at is not null
                  and p.guest_expires_at > now()
                  and p.guest_expires_at <= now() + (coalesce(v_warn,7) || ' day')::interval))
       order by sort_key
       limit greatest(1, least(coalesce(p_limit,200), 1000))) x;
  return v_out;
end;
$$;
revoke all on function public.taam_guest_list(text, int) from public;
grant execute on function public.taam_guest_list(text, int) to authenticated;

-- ── ⑤ 어드민 — [+90일] ────────────────────────────────────────
--   이미 만료된 사람에게 누르면 「지금부터 90일」로 되살린다.
--   아직 남아 있으면 남은 기한 **뒤에** 붙인다 — 눌렀는데 기한이 줄면 안 된다.
create or replace function public.taam_guest_extend(p_uid uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare p public.profiles%rowtype; v_days int; v_base timestamptz;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = p_uid;
  if not found then raise exception '회원을 찾을 수 없습니다' using errcode = 'P0002'; end if;
  if upper(coalesce(p.membership_tier,'')) <> 'A' then
    raise exception '게스트가 아닙니다' using errcode = '22023';
  end if;

  select (s.v#>>'{}')::int into v_days
    from public.membership_settings s where s.k = 'guest_extend_days';
  v_base := greatest(coalesce(p.guest_expires_at, now()), now());

  update public.profiles
     set guest_expires_at   = v_base + (coalesce(v_days,90) || ' day')::interval,
         guest_status       = 'active',
         guest_extended_cnt = coalesce(guest_extended_cnt,0) + 1,
         guest_extended_at  = now()
   where id = p_uid
   returning * into p;

  return jsonb_build_object('ok', true, 'expires_at', p.guest_expires_at,
                            'count', p.guest_extended_cnt, 'days', coalesce(v_days,90));
end;
$$;
revoke all on function public.taam_guest_extend(uuid) from public;
grant execute on function public.taam_guest_extend(uuid) to authenticated;

-- ── ⑥ 만료된 게스트를 휴면으로 ────────────────────────────────
--   ⚠ 삭제가 아니다. 등급도 이력도 그대로 두고 status 만 내린다.
--     로그인·API 시점에 판정하므로 크론이 없어도 되지만, 어드민 목록을
--     깔끔히 보려고 한 번에 정리할 수 있게 해 둔다.
create or replace function public.taam_guest_sweep()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if not is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  update public.profiles
     set guest_status = 'dormant'
   where upper(coalesce(membership_tier,'')) = 'A'
     and guest_expires_at is not null
     and guest_expires_at <= now()
     and coalesce(guest_status,'active') <> 'dormant';
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'dormant', n);
end;
$$;
revoke all on function public.taam_guest_sweep() from public;
grant execute on function public.taam_guest_sweep() to authenticated;

commit;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다
-- ═══════════════════════════════════════════════════════════════
select '① 설정값' as "구분",
       case when count(*) >= 12 then '✅ ' || count(*)::text || '개'
            else '❌ ' || count(*)::text || '개뿐' end as "상태",
       coalesce((select v#>>'{}' from public.membership_settings where k='annual_fee'), '—')
         || '원 (연회비 · 미확정)' as "메모"
  from public.membership_settings

union all
select '② 게스트 칸',
       case when count(*) = 4 then '✅' else '❌ ' || count(*)::text || '/4' end,
       coalesce(string_agg(column_name, ' · ' order by column_name), '—')
  from information_schema.columns
 where table_schema='public' and table_name='profiles'
   and column_name in ('guest_expires_at','guest_status','guest_extended_cnt','guest_extended_at')

union all
select '③ 함수 5개',
       case when count(*) = 5 then '✅' else '❌ ' || count(*)::text || '/5' end,
       coalesce(string_agg(proname, ' · ' order by proname), '—')
  from pg_proc
 where pronamespace='public'::regnamespace
   and proname in ('taam_mship_settings','taam_mship_settings_set',
                   'taam_guest_state','taam_guest_list','taam_guest_extend')

union all
select '④ 만료일이 채워진 게스트',
       case when count(*) filter (where guest_expires_at is null) = 0 then '✅' else '❌ 빈 사람 있음' end,
       count(*)::text || '명'
  from public.profiles where upper(coalesce(membership_tier,'')) = 'A'

union all
select '⑤ 설정값을 누구나 읽나 (화면에 적힌다)',
       case when exists (select 1 from pg_policies
                          where tablename='membership_settings' and 'anon' = any(roles))
            then '✅' else '❌' end, ''

 order by 1;
