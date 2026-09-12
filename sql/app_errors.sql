-- ═══════════════════════════════════════════════════════════════
-- TAAM — 회원 기기의 오류가 나에게 온다 (2026-09-12)
-- ═══════════════════════════════════════════════════════════════
-- 왜
--   안드로이드 검은 화면(2026-09-06)이 며칠이나 있었는지 아무도 모른다.
--   회원 기기에서 무슨 일이 나는지 알 길이 사장님 캡처뿐이었고, 토스트에서
--   서버 원문을 가린 뒤로는 그 통로도 좁아졌다. 이 표가 그 통로다.
--
-- 무엇을 적나
--   JS 오류 · 처리 안 된 Promise · 부팅 감시견 발동 · CDN 폴백 · 원장 폴백.
--   앱이 taam_report_error() 로만 넣는다 (표에 직접 INSERT 불가).
--   읽기는 슈퍼어드민만 — 대시보드 「오늘 오류」 카드가 taam_error_summary() 를 부른다.
--
-- 폭주 방지
--   한 사람(익명은 한 묶음) 한 시간 60건까지. 그 뒤는 조용히 버린다.
--   무한 루프에 걸린 기기 하나가 표를 채우면 안 된다.
--
-- 개인정보
--   message·stack 만 적는다. 이름·전화·이메일은 안 받는다.
--   ⚠ 앱이 message 에 그런 값을 실어 보내지 않게 앱 쪽에서 자른다 (500자).
--
-- 실행: Supabase SQL Editor 에 통째로. 여러 번 돌려도 안전.
--       ⚠ is_super_admin(uuid) 가 먼저 있어야 한다 (set_super_admin_dnfmeod.sql).
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.app_errors (
  id          bigserial primary key,
  created_at  timestamptz not null default now(),
  user_id     uuid,                       -- 비로그인이면 null
  role        text,
  build       text,
  platform    text,                       -- web / ios / android
  kind        text not null,              -- js · promise · boot_stuck · cdn_fallback · ledger_fallback · …
  message     text not null,
  stack       text,
  url         text,
  extra       jsonb not null default '{}'::jsonb
);
create index if not exists idx_app_errors_at   on public.app_errors (created_at desc);
create index if not exists idx_app_errors_kind on public.app_errors (kind, created_at desc);
create index if not exists idx_app_errors_user on public.app_errors (user_id, created_at desc);

alter table public.app_errors enable row level security;
revoke all on public.app_errors from anon, authenticated;
grant select on public.app_errors to authenticated;   -- 정책이 슈퍼어드민만 통과시킨다

drop policy if exists app_errors_read_super on public.app_errors;
create policy app_errors_read_super on public.app_errors
  for select to authenticated
  using (public.is_super_admin(auth.uid()));
-- INSERT/UPDATE/DELETE 정책은 두지 않는다 — 함수(definer)만 쓴다.

comment on table public.app_errors is
  '회원 기기에서 올라온 오류. 앱은 taam_report_error() 로만 쓰고, 슈퍼어드민만 읽는다. 30일 뒤 taam_error_prune() 로 지운다.';


-- ── 적기 — 누구나(익명 포함), 한 시간 60건까지 ─────────────────
create or replace function public.taam_report_error(
  p_kind     text,
  p_message  text,
  p_stack    text  default null,
  p_url      text  default null,
  p_build    text  default null,
  p_platform text  default null,
  p_extra    jsonb default '{}'::jsonb
)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_role text;
  v_n    int;
begin
  -- 폭주 방지. 같은 사람이 한 시간에 60건을 넘기면 그 뒤는 버린다.
  --   익명은 구분할 열쇠가 없어 한 묶음으로 센다 — 익명 폭주도 60건에서 선다.
  if v_uid is not null then
    select count(*) into v_n from public.app_errors
     where user_id = v_uid and created_at > now() - interval '1 hour';
  else
    select count(*) into v_n from public.app_errors
     where user_id is null and created_at > now() - interval '1 hour';
  end if;
  if v_n >= 60 then return; end if;

  if v_uid is not null then
    select p.role into v_role from public.profiles p where p.id = v_uid;
  end if;

  insert into public.app_errors (user_id, role, build, platform, kind, message, stack, url, extra)
  values (
    v_uid, v_role,
    left(p_build, 40), left(p_platform, 20),
    left(coalesce(nullif(btrim(p_kind), ''), 'js'), 40),
    left(coalesce(p_message, ''), 500),
    left(p_stack, 2000),
    left(p_url, 300),
    case when jsonb_typeof(p_extra) = 'object' then p_extra else '{}'::jsonb end
  );
exception when others then
  -- 오류를 적다가 난 오류로 앱을 죽이지 않는다
  return;
end;
$$;
revoke all on function public.taam_report_error(text,text,text,text,text,text,jsonb) from public;
grant execute on function public.taam_report_error(text,text,text,text,text,text,jsonb) to anon, authenticated;


-- ── 요약 — 슈퍼어드민만. 대시보드 카드가 부른다 ─────────────────
create or replace function public.taam_error_summary(p_hours int default 24)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v     jsonb;
  since timestamptz := now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 720)));
begin
  if not public.is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'hours',  extract(epoch from (now() - since))::int / 3600,
    'total',  (select count(*) from public.app_errors where created_at > since),
    'users',  (select count(distinct user_id) from public.app_errors where created_at > since and user_id is not null),
    'anon',   (select count(*) from public.app_errors where created_at > since and user_id is null),
    'by_kind',(select coalesce(jsonb_object_agg(kind, n), '{}'::jsonb)
                 from (select kind, count(*) n from public.app_errors
                        where created_at > since group by kind) k),
    'top',    (select coalesce(jsonb_agg(jsonb_build_object(
                 'kind', kind, 'message', message, 'n', n, 'last', last, 'platforms', platforms)), '[]'::jsonb)
                 from (select kind, message, count(*) n, max(created_at) last,
                              array_agg(distinct coalesce(platform,'?')) platforms
                         from public.app_errors where created_at > since
                        group by kind, message order by n desc, last desc limit 8) t)
  ) into v;
  return v;
end;
$$;
revoke all on function public.taam_error_summary(int) from public;
grant execute on function public.taam_error_summary(int) to authenticated;


-- ── 정리 — 30일 지난 것. 자동으로 걸지 않는다(필요하면 대시보드 Cron) ──
create or replace function public.taam_error_prune()
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare n int;
begin
  if not public.is_super_admin(auth.uid()) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  delete from public.app_errors where created_at < now() - interval '30 day';
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.taam_error_prune() from public;
grant execute on function public.taam_error_prune() to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 하나만 돌린다 (SQL Editor 는 마지막 결과만 보여준다)
-- ═══════════════════════════════════════════════════════════════
select '① 표가 있나' as "구분",
       case when to_regclass('public.app_errors') is not null then '✅' else '❌' end as "상태",
       'app_errors' as "메모"
union all
select '② RLS 가 켜져 있나 ⭐',
       case when (select relrowsecurity from pg_class where oid = 'public.app_errors'::regclass) then '✅' else '❌ 회원이 남의 오류를 읽는다' end,
       '읽기는 슈퍼어드민만'
union all
select '③ 회원 직접 INSERT 정책이 없나 ⭐',
       case when not exists (select 1 from pg_policies where tablename='app_errors' and cmd='INSERT') then '✅ 없음' else '❌ 있음 — 함수로만 써야 한다' end,
       '쓰기는 taam_report_error() 만'
union all
select '④ 함수 셋이 있나',
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname in ('taam_report_error','taam_error_summary','taam_error_prune')) || ' / 3',
       '3 이어야 정상'
union all
select '⑤ is_super_admin 이 있나 (선행)',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='is_super_admin') then '✅' else '❌ set_super_admin_dnfmeod.sql 먼저' end,
       ''
 order by 1;
