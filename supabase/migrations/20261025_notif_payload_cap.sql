-- ═══════════════════════════════════════════════════════════════
-- 회원이 만든 알림의 payload 크기 제한 (2026-10-25)
--
-- 왜: 슈퍼어드민 알림 시트가 누르면 그 내역 화면으로 가도록 payload 의 몇 키를 읽게 됐다(index.html _anRoute).
--   그런데 taam_notify_admins 는 로그인한 회원 누구나 부를 수 있고(시간당 30건) type·title·body·url 은 잘라 넣지만
--   payload 는 그대로 넣는다 → 회원이 수 MB 짜리 payload 를 슈퍼어드민 알림함마다 꽂을 수 있었다(적대 리뷰).
--   앱은 이제 payload 통째가 아니라 키 몇 개만 읽지만, 그 키의 값 하나도 수 MB 일 수 있어 서버에서 자른다.
--
-- 무엇: notifications BEFORE INSERT/UPDATE OF payload 트리거.
--   회원 세션(auth.uid() 가 있고 슈퍼어드민이 아님)이 쓰는 행만 본다 — 서버(크론·트리거·service_role)와 슈퍼어드민은 그대로.
--   ① 맨 위 문자열 값은 500자까지  ② 그래도 전체가 16KB 를 넘으면 짧은 스칼라 키만 남기고 payload_truncated 에 원래 크기
--   알림 자체는 막지 않는다(예외는 삼킨다).
-- ═══════════════════════════════════════════════════════════════

create or replace function public._taam_notif_payload_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_len  int;
  v_sup  boolean := false;
  v_out  jsonb;
begin
  begin
    if new.payload is null or jsonb_typeof(new.payload) <> 'object' then return new; end if;
    if auth.uid() is null then return new; end if;               -- 서버 경로
    begin v_sup := public._taam_uid_is_super(); exception when others then v_sup := false; end;
    if v_sup then return new; end if;
    -- ① 긴 문자열 값 자르기
    select coalesce(jsonb_object_agg(k,
             case when jsonb_typeof(v) = 'string' and length(v #>> '{}') > 500
                  then to_jsonb(left(v #>> '{}', 500)) else v end), '{}'::jsonb)
      into v_out
      from jsonb_each(new.payload) e(k, v);
    -- ② 전체 크기
    v_len := octet_length(v_out::text);
    if v_len > 16384 then
      select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
        into v_out
        from jsonb_each(v_out) e(k, v)
       where jsonb_typeof(v) in ('string', 'number', 'boolean')
         and octet_length(v::text) <= 300;
      v_out := v_out || jsonb_build_object('payload_truncated', v_len);
    end if;
    new.payload := v_out;
  exception when others then
    raise warning '[notif payload cap] %', sqlerrm;   -- 알림을 막지 않는다
  end;
  return new;
end $$;

revoke all on function public._taam_notif_payload_cap() from public, anon, authenticated;

drop trigger if exists trg_taam_notif_payload_cap on public.notifications;
create trigger trg_taam_notif_payload_cap
  before insert or update of payload on public.notifications
  for each row execute function public._taam_notif_payload_cap();

-- 확인 (하나로 합친 표)
select '①' as 항목, '트리거 설치' as 내용,
       case when exists (select 1 from pg_trigger where tgname = 'trg_taam_notif_payload_cap' and not tgisinternal) then '✅' else '❌' end as 결과
union all
select '②', '함수', case when to_regproc('public._taam_notif_payload_cap') is not null then '✅' else '❌' end
union all
select '③', '의존 함수 _taam_uid_is_super', case when to_regproc('public._taam_uid_is_super') is not null then '✅' else '⚠ 없음 — 회원/슈퍼어드민을 못 가려 전부 회원으로 본다' end
union all
select '④', '지금 16KB 넘는 payload 알림 수(정보)', (select count(*)::text from public.notifications where octet_length(coalesce(payload, '{}'::jsonb)::text) > 16384);
