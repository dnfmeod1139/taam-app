-- ═══════════════════════════════════════════════════════════════
-- 테스트 계정 숨김 — profiles.is_test (2026-10-19 운영 결정: 김우 · 테스트1 · 김우종은)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: Supabase SQL Editor 에 통째로 RUN (또는 Supabase 자동 배포 워크플로가 돌린다). 마지막 표에 ❌ 가 한 줄도 없어야 정상 — ⚠ 는 손으로 처리할 것.
-- 왜: 운영자 본인 계정·테스트용 계정이 회원 목록(회원 관리 · 명부 · 만료일 관리 · 원장 검색 · 예치금 부여/초대/결제 링크의 회원 고르기 · 연회비 납부 시기)에
--     진짜 회원과 섞여 보였다. 탈퇴 처리는 로그인까지 막으니 쓸 수 없다 — 「숨김」 스위치를 따로 둔다.
-- 무엇: profiles.is_test(boolean · 기본 false) + 누가·언제(is_test_set_by/at · 트리거만 적는다). 앱은 이 칸이 true 인 uid 집합을 한 번 읽어 목록에서 거른다 —
--     「테스트 계정 보기」를 켜거나 검색어가 이름·번호·이메일과 **정확히** 같으면 보인다(테스트 계정에 예치금을 부여하거나 초대할 때). 컬럼이 없는 서버에서는 앱이 그대로 돈다(숨김만 없다).
--     켜면 연회비 대상에서도 뺀다(fee_exempt=true · 메모 「테스트 계정」 — 이미 메모가 있으면 그대로). 끌 때 fee_exempt 는 건드리지 않는다(면제는 따로 판단).
-- 가드: 회원 세션은 이 칸을 못 바꾼다(되돌림 · 예외 아님 · 전 칸 트리거 — fee_exempt 가드와 같은 방식). 숨김은 보기 문제라 악용 여지는 작지만, 감사 칸(set_by/at) 위조를 막는다.
-- 시드: 아래 세 이름은 공백을 뺀 display_name 이 **정확히 한 명**일 때만 적는다(탈퇴 안 한 회원 우선). 0명·2명 이상이면 ⚠ 로 두고 회원 관리 모달의 「테스트 계정 (숨김)」으로 손으로.
--     ⚠ 「김우」는 「김우종은」의 앞글자라 like 가 아니라 = 로 비교한다.
-- 의존: public._taam_uid_is_super() · profiles.fee_exempt(20261017_membership_fee_exempt.sql · 라이브 ✅). 여러 번 RUN 해도 안전하다(이미 숨긴 계정은 「이미 숨김」).
-- 회귀: bash sql/_test/t_test_accounts.sh · 스크래치 testhide.js
-- ═══════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists is_test        boolean not null default false,
  add column if not exists is_test_set_at timestamptz,
  add column if not exists is_test_set_by uuid;
comment on column public.profiles.is_test is '테스트·운영자 개인 계정 — 앱이 회원 목록·원장 검색·회원 고르기에서 숨긴다. 슈퍼어드민만 바꾼다(trg_taam_guard_is_test). 2026-10-19';

-- ── 가드 — 회원 세션은 되돌린다 · 바뀌면 누가·언제를 적는다 (fee_exempt 가드와 같은 모양 · OF 목록 없이 전 칸) ──
create or replace function public.taam_guard_is_test()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_member boolean := (current_user in ('authenticated', 'anon') and not coalesce(public._taam_uid_is_super(), false));
begin
  if tg_op = 'INSERT' then
    if coalesce(new.is_test, false) = false then
      new.is_test := false; new.is_test_set_at := null; new.is_test_set_by := null;
      return new;
    end if;
    if v_member then
      raise warning '[guard] is_test 는 슈퍼어드민만 바꿉니다 (insert · uid=%)', auth.uid();
      new.is_test := false; new.is_test_set_at := null; new.is_test_set_by := null;
      return new;
    end if;
    new.is_test_set_at := now(); new.is_test_set_by := auth.uid();
    return new;
  end if;
  if new.is_test is not distinct from old.is_test then
    new.is_test_set_at := old.is_test_set_at; new.is_test_set_by := old.is_test_set_by;   -- 그대로면 기록도 그대로(감사 칸만 보낸 UPDATE 도 되돌린다)
    return new;
  end if;
  if v_member then
    raise warning '[guard] is_test 변경 차단: % → % (uid=%)', old.is_test, new.is_test, auth.uid();
    new.is_test := old.is_test; new.is_test_set_at := old.is_test_set_at; new.is_test_set_by := old.is_test_set_by;
    return new;
  end if;
  new.is_test_set_at := now(); new.is_test_set_by := auth.uid();
  return new;
end $$;
drop trigger if exists trg_taam_guard_is_test on public.profiles;
create trigger trg_taam_guard_is_test
  before insert or update on public.profiles
  for each row execute function public.taam_guard_is_test();

-- ── 시드 — 세 이름 (정확히 한 명일 때만) ──
drop table if exists _ta; create temp table _ta(name text, status text);
do $do$
declare r record; v_id uuid; v_n int;
begin
  for r in select unnest(array['김우', '테스트1', '김우종은']) as nm loop
    select count(*) into v_n from public.profiles p where btrim(coalesce(p.display_name, '')) = r.nm and p.deleted_at is null;
    if v_n = 0 then
      select count(*) into v_n from public.profiles p where btrim(coalesce(p.display_name, '')) = r.nm;   -- 탈퇴한 계정뿐이면 그것
    end if;
    if v_n = 0 then insert into _ta values (r.nm, '⚠ 없음 — 이름을 확인하고 회원 관리 모달에서 손으로'); continue; end if;
    if v_n > 1 then insert into _ta values (r.nm, '⚠ ' || v_n || '명 일치 — 회원 관리 모달에서 손으로'); continue; end if;
    select p.id into v_id from public.profiles p where btrim(coalesce(p.display_name, '')) = r.nm order by (p.deleted_at is null) desc limit 1;
    update public.profiles
       set is_test = true, fee_exempt = true, fee_exempt_note = coalesce(fee_exempt_note, '테스트 계정')
     where id = v_id and (is_test = false or coalesce(fee_exempt, false) = false);
    if found then insert into _ta values (r.nm, '✅ 숨김 + 연회비 제외');
    else insert into _ta values (r.nm, '✅ 이미 숨김'); end if;
  end loop;
end $do$;

-- ── 확인 — 한 표 ──
select '① 컬럼 is_test · is_test_set_at · is_test_set_by' as 항목,
       case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name in ('is_test', 'is_test_set_at', 'is_test_set_by')) = 3 then '✅' else '❌' end as 결과
union all select '② 가드 trg_taam_guard_is_test (before insert or update · 전 칸)',
       case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid where t.tgname = 'trg_taam_guard_is_test' and c.relname = 'profiles' and not t.tgisinternal) then '✅' else '❌' end
union all select '③ 시드 · ' || name, status from _ta
union all select '④ 의존 — _taam_uid_is_super · profiles.fee_exempt',
       case when to_regproc('public._taam_uid_is_super') is not null and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'fee_exempt') then '✅' else '❌ 20261017_membership_fee_exempt.sql 먼저' end
union all select '⑤ 지금 숨긴 계정 (정보)',
       coalesce((select string_agg(coalesce(nullif(btrim(p.display_name), ''), '(이름 없음)') || case when p.deleted_at is not null then '(탈퇴)' else '' end || case when coalesce(p.fee_exempt, false) then '' else ' ⚠연회비 대상' end, ' · ' order by btrim(p.display_name)) from public.profiles p where p.is_test), '없음')
order by 1;
