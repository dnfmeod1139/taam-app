-- ═══════════════════════════════════════════════════════════════
-- TAAM — push_subscriptions 저장 RPC (RLS 우회) (2026-06-18)
-- ═══════════════════════════════════════════════════════════════
-- 배경: 정책을 재생성해도 앱의 upsert(onConflict:'endpoint') 가
--   "new row violates row-level security policy (USING expression)" 로
--   계속 실패 → upsert × RLS 상호작용 문제.
-- 해결: SECURITY DEFINER 함수로 저장(소유자 권한 → RLS 우회). user_id 는
--   클라이언트 입력이 아니라 서버에서 auth.uid() 로 강제 → 안전.
-- Supabase SQL Editor 에 통째로 붙여넣고 RUN.
-- ═══════════════════════════════════════════════════════════════

-- 0) endpoint UNIQUE 제약 보장 (on conflict 동작에 필수)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.push_subscriptions'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) ilike '%(endpoint)%'
  ) then
    delete from public.push_subscriptions a
      using public.push_subscriptions b
      where a.endpoint = b.endpoint and a.ctid < b.ctid;
    alter table public.push_subscriptions
      add constraint push_subscriptions_endpoint_key unique (endpoint);
  end if;
end $$;

-- 1) 저장 RPC — 로그인 사용자가 본인 구독을 저장/갱신 (RLS 우회)
create or replace function public.save_push_subscription(
  p_endpoint     text,
  p_p256dh       text,
  p_auth         text,
  p_user_agent   text   default null,
  p_device_label text   default null,
  p_role         text   default null,
  p_topics       text[] default '{}'
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  insert into public.push_subscriptions
    (user_id, endpoint, p256dh, auth, user_agent, device_label, role, topics, last_seen_at)
  values
    (auth.uid(), p_endpoint, p_p256dh, p_auth, p_user_agent, p_device_label, p_role, coalesce(p_topics, '{}'), now())
  on conflict (endpoint) do update set
    user_id      = excluded.user_id,
    p256dh       = excluded.p256dh,
    auth         = excluded.auth,
    user_agent   = excluded.user_agent,
    device_label = excluded.device_label,
    role         = excluded.role,
    topics       = excluded.topics,
    last_seen_at = now();
end;
$$;

-- 2) 로그인 사용자에게 실행 권한 부여
revoke all on function public.save_push_subscription(text,text,text,text,text,text,text[]) from public;
grant execute on function public.save_push_subscription(text,text,text,text,text,text,text[]) to authenticated;

-- 3) 검증
select proname, prosecdef as security_definer
  from pg_proc where proname = 'save_push_subscription';

do $$ begin raise notice '✅ save_push_subscription RPC 생성 완료 — 앱에서 "재구독" 누르면 RLS 우회 저장됨'; end $$;
