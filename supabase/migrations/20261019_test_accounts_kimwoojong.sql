-- ═══════════════════════════════════════════════════════════════
-- 테스트 계정 숨김 — 세 번째 이름 정정: 「김우종은」이 아니라 「김우종」 (2026-10-19 운영 확인)
-- ═══════════════════════════════════════════════════════════════
-- 어디서: 자동 배포 워크플로가 main 푸시 때 돌린다(또는 SQL Editor 에 통째로 RUN). ② 줄에 세 이름이 다 보이면 정상.
-- 왜: 20261019_test_accounts.sql 의 시드가 「김우종은」을 찾아 ⚠ 없음 으로 끝났다 — 실제 계정 이름은 「김우종」이다(운영자 정정).
-- 무엇: 같은 규칙(공백 뺀 display_name 이 **정확히 한 명** · 탈퇴 안 한 회원 우선 · 0명·2명 이상은 ⚠ 로 두고 회원 관리 모달에서 손으로)으로
--       is_test=true + fee_exempt=true(메모 「테스트 계정」 · 이미 있으면 그대로). 여러 번 RUN 해도 안전(「이미 숨김」). 가드 trg_taam_guard_is_test 는 그대로.
-- 회귀: bash sql/_test/t_test_accounts.sh
-- ═══════════════════════════════════════════════════════════════

drop table if exists _ta2; create temp table _ta2(name text, status text);
do $do$
declare r record; v_id uuid; v_n int;
begin
  for r in select unnest(array['김우종']) as nm loop
    select count(*) into v_n from public.profiles p where btrim(coalesce(p.display_name, '')) = r.nm and p.deleted_at is null;
    if v_n = 0 then
      select count(*) into v_n from public.profiles p where btrim(coalesce(p.display_name, '')) = r.nm;   -- 탈퇴한 계정뿐이면 그것
    end if;
    if v_n = 0 then insert into _ta2 values (r.nm, '⚠ 없음 — 이름을 확인하고 회원 관리 모달에서 손으로'); continue; end if;
    if v_n > 1 then insert into _ta2 values (r.nm, '⚠ ' || v_n || '명 일치 — 회원 관리 모달에서 손으로'); continue; end if;
    select p.id into v_id from public.profiles p where btrim(coalesce(p.display_name, '')) = r.nm order by (p.deleted_at is null) desc limit 1;
    update public.profiles
       set is_test = true, fee_exempt = true, fee_exempt_note = coalesce(fee_exempt_note, '테스트 계정')
     where id = v_id and (is_test = false or coalesce(fee_exempt, false) = false);
    if found then insert into _ta2 values (r.nm, '✅ 숨김 + 연회비 제외');
    else insert into _ta2 values (r.nm, '✅ 이미 숨김'); end if;
  end loop;
end $do$;

-- ── 확인 — 한 표 ──
select '① 시드 · ' || name as 항목, status as 결과 from _ta2
union all select '② 지금 숨긴 테스트 계정', coalesce((select string_agg(btrim(coalesce(display_name, '')) || case when coalesce(fee_exempt, false) then '' else '(연회비 제외 아님)' end, ' · ' order by btrim(coalesce(display_name, ''))) from public.profiles where is_test = true), '(없음)')
union all select '③ 가드 trg_taam_guard_is_test', case when exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid where t.tgname = 'trg_taam_guard_is_test' and c.relname = 'profiles' and not t.tgisinternal) then '✅' else '❌ 20261019_test_accounts.sql 먼저' end
order by 1;
