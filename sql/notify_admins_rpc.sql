-- ═══════════════════════════════════════════════════════════════
-- TAAM — 슈퍼어드민 알림 이력 RPC (2026-08-27)
-- ═══════════════════════════════════════════════════════════════
-- 왜 필요한가
--   notifications 의 INSERT 정책은 이렇다:
--       is_super_admin(auth.uid()) or auth.uid() = user_id
--   즉 일반 회원은 슈퍼어드민에게 알림 행을 넣을 수 없다.
--
--   그래서 회원이 하는 행동(구매·취소·초대취소·충전)은 푸시는 가는데
--   — 푸시는 Edge Function 이 service_role 로 보내니까 —
--   슈퍼어드민의 벨(🔔) 에는 이력이 하나도 안 쌓였다.
--   푸시를 놓치면 그걸로 끝이고, 나중에 확인할 방법이 없었다.
--
--   이 RPC 는 로그인한 사용자면 누구나 '슈퍼어드민 전원에게' 알림 행을 남길 수
--   있게 한다. 대상은 서버가 정하므로(요청자가 지정 못 함) 아무 회원에게나
--   알림을 보내는 데는 쓸 수 없다.
--
-- 실행: Supabase SQL Editor 에 붙여넣고 RUN (idempotent)
-- ═══════════════════════════════════════════════════════════════

create or replace function public.taam_notify_admins(
  p_type    text,
  p_title   text,
  p_body    text  default null,
  p_url     text  default null,
  p_payload jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n     int := 0;
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception '로그인이 필요합니다';
  end if;
  if coalesce(p_title, '') = '' then
    raise exception '제목이 필요합니다';
  end if;

  insert into public.notifications (user_id, type, title, body, url, payload)
  select
    p.id,
    left(coalesce(p_type, 'system'), 60),
    left(p_title, 200),
    left(coalesce(p_body, ''), 1000),
    left(coalesce(p_url, '/'), 500),
    coalesce(p_payload, '{}'::jsonb)
      || jsonb_build_object('actor_id', v_actor, 'via', 'taam_notify_admins')
  from public.profiles p
  where p.role in ('superadmin', 'super_admin')
    and p.id <> v_actor;          -- 자기가 한 행동을 자기에게 다시 알리지 않는다

  get diagnostics v_n = row_count;
  return v_n;
end $$;

grant execute on function public.taam_notify_admins(text, text, text, text, jsonb) to authenticated;

comment on function public.taam_notify_admins(text, text, text, text, jsonb) is
  '회원 행동(구매·취소·충전 등)을 슈퍼어드민 알림 이력에 남긴다. 대상은 서버가 정한다.';


-- ═══════════════════════════════════════════════════════════════
-- 확인 — 슈퍼어드민이 몇 명인지 (0 이면 알림이 아무에게도 안 간다)
-- ═══════════════════════════════════════════════════════════════
select
  count(*) filter (where role = 'superadmin')  as "superadmin",
  count(*) filter (where role = 'super_admin') as "super_admin",
  count(*) filter (where role in ('superadmin','super_admin')) as "합계"
from public.profiles;
