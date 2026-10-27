-- ═══════════════════════════════════════════════════════════════
-- 게스트 만료 알림 — 중복 검사를 글자 비교로 (2026-10-27 · 적대 리뷰)
--
-- 왜: taam_guest_expiry_notify(매일 10:00 KST · Edge notify-guest-expiry)의 중복 검사 두 곳이
--   (n.payload ->> 'days')::int = k.d 였다. 회원은 자기 알림 줄을 쓰고 고칠 수 있고(notif_insert · notif_update_own),
--   taam_notify_admins 로 슈퍼어드민 알림함에 아무 type·payload 나 꽂을 수 있어(시간당 30건) — days 에 'x' 를 넣으면
--   ::int 가 터져 그날 게스트 만료 알림 전체(슈퍼어드민 ①·게스트 본인 ② — 한 트랜잭션)가 멈췄다. 방문 리마인드도 같은 모양이었다
--   (20261027_visit_reminder_format.sql 이 고침).
-- 무엇: 라이브 본문(pg_get_functiondef)에서 그 비교만 n.payload ->> 'days' = k.d::text 로 바꿔 다시 만든다 — 진짜 줄(days 는 서버가 숫자로 적는다)에는
--   같은 결과. 라이브가 어느 판(sql/low_batch_2026-09-14.sql · sql/guest_expiry_notice.sql)이든 그 비교 모양만 보고 바꾼다.
--   이미 바뀌었으면 ✅ 그대로 · 함수가 없으면 ⚠(게스트 만료 알림을 안 쓰는 DB) · 비교 모양을 못 찾으면 ❌ 로 건너뛴다(덮어쓰지 않는다).
-- 회귀: bash sql/_test/t_visit_reminder_format.sh (끝부분 · 게스트 만료 위조 줄)
-- ═══════════════════════════════════════════════════════════════

drop table if exists _gedt;
create temp table _gedt(name text primary key, status text);

do $do$
declare v_def text; v_new text; v_n int; v_re text := '\(\s*n\.payload\s*->>\s*''days''\s*\)\s*::\s*int(eger)?\s*=\s*k\.d\M';
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.oid = to_regproc('public.taam_guest_expiry_notify');
  if v_def is null then
    insert into _gedt values ('taam_guest_expiry_notify', '⚠ 라이브에 함수가 없다 — 게스트 만료 알림을 안 쓰는 DB(건너뜀)');
    return;
  end if;
  -- 부르는 곳은 Edge(service_role)·크론뿐 — sql/low_batch_2026-09-14.sql 과 같은 권한으로 맞춘다(옛 판 guest_expiry_notice.sql 은 public 만 막았다)
  execute 'revoke all on function public.taam_guest_expiry_notify() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on function public.taam_guest_expiry_notify() from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on function public.taam_guest_expiry_notify() from authenticated'; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute 'grant execute on function public.taam_guest_expiry_notify() to service_role'; end if;
  select count(*) into v_n from regexp_matches(v_def, v_re, 'g');
  if v_n = 0 then
    if v_def ~ 'n\.payload\s*->>\s*''days''\s*=\s*k\.d::text' then
      insert into _gedt values ('taam_guest_expiry_notify', '✅ 이미 글자 비교');
    else
      insert into _gedt values ('taam_guest_expiry_notify', '❌ 중복 검사 모양을 못 찾음 — 건너뜀(덮어쓰지 않음) · md5 ' || md5(v_def));
    end if;
    return;
  end if;
  v_new := regexp_replace(v_def, v_re, 'n.payload ->> ''days'' = k.d::text', 'g');
  execute v_new;
  insert into _gedt values ('taam_guest_expiry_notify', '✅ 교체(중복 검사 ' || v_n || '곳 글자 비교)');
end $do$;

select '①' as 항목, status as 내용, case when status like '❌%' then '❌' when status like '⚠%' then '⚠' else '✅' end as 결과 from _gedt
union all
select '②', '남은 ::int 비교', case when exists (select 1 from pg_proc p where p.oid = to_regproc('public.taam_guest_expiry_notify')
                                         and pg_get_functiondef(p.oid) ~ '\(\s*n\.payload\s*->>\s*''days''\s*\)\s*::\s*int') then '❌' else '✅' end
union all
select '③', '권한(회원·anon 실행 불가)', case when to_regproc('public.taam_guest_expiry_notify') is null then '⚠'
                    when has_function_privilege('anon', 'public.taam_guest_expiry_notify()', 'execute')
                      or has_function_privilege('authenticated', 'public.taam_guest_expiry_notify()', 'execute') then '❌' else '✅' end;
