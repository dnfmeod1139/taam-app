-- ═══════════════════════════════════════════════════════════════
-- 연회비 갱신일 → 종료일(member_until) 동기화 · 실제 가입일은 앱 출시 전 날짜만 (2026-10-19 운영 결정)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). 마지막 표에 ❌ 가 한 줄도 없어야 정상.
-- 왜: ① 10-16 실제 가입일 시드(sql/membership_joined_seed_2026-10-15.sql)가 운영자 목록을 그대로 적어, **앱 출시 뒤 가입한 7명**(최정우·강지헌·권한진·장동진·김세민·안가람·김민혁)에게
--       가입일과 같은 날이 「실제 가입일」로 들어갔다 → 전원 「앱 이전 계약 회원」(①부류)으로 보이고 연회비 기준도 그 날로 잡혔다. 규칙은 「앱 출시(2026-08-25) 전에 계약한 회원만 ①」이다.
--     ② 「회원 멤버십 만료일 관리」의 종료일(member_until)은 전원 프로모션 2027-12-31 이라 갱신일을 알 수 없었다. 운영 결정:
--        ①부류 = 실제 가입일 기준 갱신일 · ②부류(앱 이후)에서 첫 구매·초대 결제가 있으면 **첫 구매 1년 뒤** · 아직 없으면 **프로모션 2027-12-31 유지(갱신일 미정)**.
-- 무엇:
--   A. _taam_app_launch_date() = 2026-08-25 (iOS 출시). 실제 가입일 가드(trg_taam_guard_membership_joined)에 「출시일 이후 날짜 거절(JOINED_AFTER_LAUNCH)」을 더한다(md5 가드 교체).
--   B. 출시일 이후로 적힌 실제 가입일을 지운다(이름은 확인 표 ②에 남긴다 · 되돌리려면 원장 헤더에서 다시 적는다 — 가드가 막으니 ①부류가 아니면 적을 수 없다).
--   C. taam_member_until_sync(p_uid, p_apply) — 연회비 보고(taam_membership_fee_due · 제외 회원 제외)의 기준일을 종료일로 맞춘다.
--        joined/start → 기준일(due_date) 23:59:59 KST · none(시작 전) → 2027-12-31 23:59:59 KST · is_test 는 건너뜀. p_apply=false 면 미리보기만(기본).
--        바꾼 것은 member_until_sync_log 에 옛값과 함께 남는다(되돌리기용). 슈퍼어드민·서버만(_taam_fee_caller_ok).
--   D. membership_fees 에 기록이 생기거나 지워지면(연회비 납부 기록 · 예치금 차감 기록 · 결제 링크 자동 기록) 그 회원의 종료일을 자동으로 다시 맞춘다(AFTER 트리거 · 실패는 warning).
--   ⚠ 이 파일은 종료일을 **바꾸지 않는다** — 확인 표 ④에 「바뀔 회원 수」만 보여 준다. 실제 적용은 앱 「📅 회원 멤버십 만료일 관리」의 「연회비 기준일로 종료일 맞추기」(미리보기 → 확인) 또는
--      SQL Editor 에서 `select * from public.taam_member_until_sync(null, true)`.
--   ⚠ membership_expires_at(M 등급 유효 판정)은 건드리지 않는다 — 종료일(member_until)은 표시·운영용 날짜다. ①부류 중 연회비가 밀린 회원은 종료일이 **과거**로 잡힌다(마이페이지에도 보인다) — 그게 「갱신할 때」라는 신호다.
-- 의존: taam_membership_fee_due(uuid,date,boolean) 두 부류 판(20261019_fee_due_anchor.sql) · _taam_fee_caller_ok · trg_taam_guard_membership_joined(20261015 판 · md5 d88551009d6604aec6595efb9cd9cb3a).
-- 회귀: bash sql/_test/t_member_until_sync.sh · 스크래치 musync.js
-- ═══════════════════════════════════════════════════════════════

-- ── A. 출시일 · 가드 교체 ──
create or replace function public._taam_app_launch_date() returns date language sql immutable as $$ select date '2026-08-25' $$;
comment on function public._taam_app_launch_date() is 'TAAM iOS 출시일. 실제 가입일(membership_joined_at)은 이 날 전 계약자에게만 — 그 뒤 가입자는 첫 구매·초대 결제일이 연회비 기준. 2026-10-19';

drop table if exists _mus; create temp table _mus(name text primary key, status text);
do $do$
declare v_live text; v_src text;
begin
  select md5(p.prosrc), p.prosrc into v_live, v_src from pg_proc p where p.oid = to_regproc('public.taam_guard_membership_joined');
  if v_live is null then
    insert into _mus values ('taam_guard_membership_joined', '❌ 라이브에 함수가 없다 — 20261015_membership_joined.sql 먼저');
  elsif v_src like '%JOINED_AFTER_LAUNCH%' then
    insert into _mus values ('taam_guard_membership_joined', '✅ 이미 새 판(JOINED_AFTER_LAUNCH)');
  elsif v_live <> 'd88551009d6604aec6595efb9cd9cb3a' then
    insert into _mus values ('taam_guard_membership_joined', '❌ 라이브 본문이 저장소 원본(20261015 판)과 다르다 — 건너뜀 (md5 ' || v_live || ')');
  else
    execute $fn$
create or replace function public.taam_guard_membership_joined()
returns trigger
language plpgsql
set search_path = public
as $b$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  v_member boolean := (current_user in ('authenticated', 'anon') and not public._taam_uid_is_super());
begin
  if tg_op = 'INSERT' then
    if new.membership_joined_at is null then
      new.membership_joined_set_at := null; new.membership_joined_set_by := null;
      return new;
    end if;
    if v_member then
      raise warning '[guard] membership_joined_at 는 슈퍼어드민만 적습니다 (insert · uid=%)', auth.uid();
      new.membership_joined_at := null; new.membership_joined_set_at := null; new.membership_joined_set_by := null;
      return new;
    end if;
  else
    if new.membership_joined_at is not distinct from old.membership_joined_at then
      -- 날짜가 그대로면 누가·언제 칸도 그대로 — 앱이 실수로 비워 보내도 기록이 안 지워진다
      new.membership_joined_set_at := old.membership_joined_set_at;
      new.membership_joined_set_by := old.membership_joined_set_by;
      return new;
    end if;
    if v_member then
      raise warning '[guard] membership_joined_at 변경 차단: % → % (uid=%)', old.membership_joined_at, new.membership_joined_at, auth.uid();
      new.membership_joined_at     := old.membership_joined_at;
      new.membership_joined_set_at := old.membership_joined_set_at;
      new.membership_joined_set_by := old.membership_joined_set_by;
      return new;
    end if;
    if new.membership_joined_at is null then
      new.membership_joined_set_at := now(); new.membership_joined_set_by := auth.uid();   -- 지운 것도 기록
      return new;
    end if;
  end if;
  if new.membership_joined_at < date '2015-01-01' or new.membership_joined_at > v_today then
    raise exception 'BAD_JOINED_DATE: 실제 가입일은 2015-01-01 ~ 오늘(%) 사이여야 합니다', v_today using errcode = 'P0001';
  end if;
  -- 🆕 2026-10-19 실제 가입일은 「앱 출시(2026-08-25) 전에 계약한 회원」에게만 — 그 뒤 날짜는 ②부류(첫 구매·초대 결제일 기준)라 적지 않는다.
  --   10-16 시드가 10월 가입자 7명에게 가입일과 같은 날을 실제 가입일로 적어 전원 「앱 이전 계약 회원」으로 보였다(운영 신고).
  if new.membership_joined_at >= public._taam_app_launch_date() then
    raise exception 'JOINED_AFTER_LAUNCH: 실제 가입일은 앱 출시(%) 전 날짜만 적습니다 — 그 뒤 가입자는 첫 구매·초대 결제일이 연회비 기준입니다', public._taam_app_launch_date() using errcode = 'P0001';
  end if;
  new.membership_joined_set_at := now();
  new.membership_joined_set_by := auth.uid();     -- SQL Editor(postgres) 에서 적으면 null
  return new;
end;
$b$
    $fn$;
    insert into _mus values ('taam_guard_membership_joined', '✅ 교체 (출시일 이후 거절)');
  end if;
end $do$;

-- ── B. 출시일 이후로 적힌 실제 가입일 지우기 (②부류로 되돌린다) ──
drop table if exists _mus_cleared; create temp table _mus_cleared(display_name text, was date);
with c as (
  update public.profiles p
     set membership_joined_at = null
   where p.membership_joined_at is not null
     and p.membership_joined_at >= public._taam_app_launch_date()
  returning p.display_name, p.membership_joined_at
)
insert into _mus_cleared select display_name, null from c;
-- (returning 은 바뀐 뒤 값이라 null — 지운 날짜는 확인 표에 안 적고 이름만 남긴다 · 원 날짜는 가입일과 같았다)

-- ── C. 동기화 함수 · 로그 표 ──
create table if not exists public.member_until_sync_log (
  id bigserial primary key,
  user_id uuid not null,
  old_until timestamptz,
  new_until timestamptz,
  reason text,
  applied_at timestamptz not null default now(),
  applied_by uuid
);
comment on table public.member_until_sync_log is '연회비 기준일 → 종료일(member_until) 동기화 기록 — 되돌리기용. 2026-10-19';
alter table public.member_until_sync_log enable row level security;
revoke all on public.member_until_sync_log from anon, authenticated;
drop policy if exists musl_super_read on public.member_until_sync_log;
create policy musl_super_read on public.member_until_sync_log for select to authenticated using (public.is_super_admin(auth.uid()));
grant select on public.member_until_sync_log to authenticated;

create or replace function public.taam_member_until_sync(p_uid uuid default null, p_apply boolean default false)
returns table (user_id uuid, display_name text, tier text, anchor_kind text, anchor_date date, old_until timestamptz, new_until timestamptz, changed boolean, reason text)
language plpgsql volatile security definer set search_path = public
as $$
declare r record; v_new timestamptz; v_reason text; v_by uuid := auth.uid();
begin
  if not public._taam_fee_caller_ok() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  for r in
    select d.user_id, d.display_name, d.tier, d.anchor_kind, d.anchor_date, d.due_date, p.member_until, coalesce(p.is_test, false) as is_test
      from public.taam_membership_fee_due(p_uid, null, false) d
      join public.profiles p on p.id = d.user_id
     where p.deleted_at is null
     order by d.display_name
  loop
    if r.is_test then continue; end if;
    if r.anchor_kind in ('joined', 'start') and r.due_date is not null then
      v_new := (r.due_date::text || ' 23:59:59')::timestamp at time zone 'Asia/Seoul';
      v_reason := case when r.anchor_kind = 'joined' then '실제 가입일 기준 갱신일' else '첫 구매·초대 결제일 기준 갱신일' end;
    else
      v_new := timestamptz '2027-12-31 23:59:59+09';
      v_reason := '시작 전 — 프로모션 유지(갱신일 미정)';
    end if;
    user_id := r.user_id; display_name := r.display_name; tier := r.tier; anchor_kind := r.anchor_kind; anchor_date := r.anchor_date;
    old_until := r.member_until; new_until := v_new; changed := (r.member_until is distinct from v_new); reason := v_reason;
    if p_apply and changed then
      update public.profiles set member_until = v_new where id = r.user_id;
      insert into public.member_until_sync_log(user_id, old_until, new_until, reason, applied_by) values (r.user_id, r.member_until, v_new, v_reason, v_by);
    end if;
    return next;
  end loop;
  return;
end $$;
revoke all on function public.taam_member_until_sync(uuid, boolean) from public, anon;
grant execute on function public.taam_member_until_sync(uuid, boolean) to authenticated, service_role;   -- authenticated 는 함수 안에서 슈퍼어드민만 통과
comment on function public.taam_member_until_sync(uuid, boolean) is '연회비 기준일(taam_membership_fee_due)을 종료일(member_until)로 맞춘다. joined/start → 기준일 · none → 2027-12-31 · is_test 제외. p_apply=false 미리보기. 슈퍼어드민·서버만. 2026-10-19';

-- ── D. 납부 기록이 바뀌면 그 회원만 자동으로 ──
create or replace function public.taam_member_until_after_fee()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_uid uuid := coalesce(new.user_id, old.user_id);
begin
  begin
    perform public.taam_member_until_sync(v_uid, true);
  exception when others then
    raise warning '[member_until] 연회비 기록 뒤 종료일 동기화 실패 (기록은 유지): % %', sqlstate, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists trg_taam_member_until_after_fee on public.membership_fees;
create trigger trg_taam_member_until_after_fee
  after insert or update or delete on public.membership_fees
  for each row execute function public.taam_member_until_after_fee();

-- ── 확인 — 한 표 ──
select '① 실제 가입일 가드 교체' as 항목, status as 결과 from _mus
union all select '② 출시일 이후 실제 가입일을 지운 회원 (정보 · ②부류로 복귀)', coalesce((select string_agg(display_name, ' · ' order by display_name) from _mus_cleared), '없음')
union all select '③ 함수·표·트리거 (sync · log · after_fee)', case when to_regprocedure('public.taam_member_until_sync(uuid,boolean)') is not null and to_regclass('public.member_until_sync_log') is not null
       and exists (select 1 from pg_trigger where tgname = 'trg_taam_member_until_after_fee' and not tgisinternal) and to_regproc('public._taam_app_launch_date') is not null then '✅' else '❌' end
union all select '④ 미리보기 — 종료일이 바뀔 회원 수 / 대상 (정보 · 적용은 앱 버튼 또는 taam_member_until_sync(null,true))',
       coalesce((select count(*) filter (where s.changed) || ' / ' || count(*) || ' · ' || coalesce(string_agg(s.display_name || ' ' || to_char(s.old_until at time zone 'Asia/Seoul', 'YY-MM-DD') || '→' || to_char(s.new_until at time zone 'Asia/Seoul', 'YY-MM-DD'), ' · ' order by s.display_name) filter (where s.changed), '-')
                   from public.taam_member_until_sync(null, false) s), '-')
union all select '⑤ 의존 — fee_due 두 부류 판 · _taam_fee_caller_ok', case when exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.taam_membership_fee_due(uuid,date,boolean)') and p.prosrc like '%implicit_first%') and to_regproc('public._taam_fee_caller_ok') is not null then '✅' else '❌ 20261019_fee_due_anchor.sql 먼저' end
union all select '⑥ anon 은 못 부른다', case when has_function_privilege('anon', 'public.taam_member_until_sync(uuid,boolean)', 'execute') then '❌' else '✅' end
order by 1;
