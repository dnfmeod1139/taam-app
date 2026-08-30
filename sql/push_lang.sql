-- ═══════════════════════════════════════════════════════════════
-- TAAM — 푸시 알림을 회원 언어로 보내기 ① 데이터 (2026-08-30)
-- ═══════════════════════════════════════════════════════════════
-- 무엇이 문제인가
--   send-push 는 앱이 보낸 title/body 를 그대로 기기에 전달만 한다.
--   언어 처리가 한 줄도 없다. 그래서 지금은 일본에 계신 회원도,
--   해외 회원도 전부 한국어 푸시를 받는다.
--
--   ⚠ 핸드폰의 언어 설정으로는 바뀌지 않는다. OS 언어는 OS 가 만든
--     알림에만 적용되고, 우리가 보낸 문자열에는 아무 영향이 없다.
--
-- 왜 profiles 가 아니라 push_subscriptions 인가
--   언어는 사람이 아니라 「기기」의 성질이다. 한 사람이 폰은 일본어,
--   PC 는 한국어로 쓸 수 있고, 푸시는 사람이 아니라 기기로 간다.
--   그래서 구독 행에 붙인다.
--
-- 이 파일이 하는 일
--   ① push_subscriptions.lang 컬럼 추가 (ko / en / ja)
--   ② 저장 RPC 가 lang 을 같이 받게 확장 — 기본값이 있어 옛 호출도 그대로 산다
--   ③ 지금 있는 기기의 언어를 profiles.country 로 한 번 추정해 채운다
--
-- ⚠ 이 파일만으로는 푸시 언어가 바뀌지 않는다. Edge Function(send-push)을
--   대시보드에서 교체해야 실제로 갈린다. 순서는 SQL_RUN_GUIDE.md 참고.
--
-- 실행: Supabase SQL Editor 에 통째로 붙여넣고 RUN. 여러 번 돌려도 안전.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ① 컬럼 — 이 기기가 쓰는 언어
-- ═══════════════════════════════════════════════════════════════
--   null = 아직 모름. 모르면 send-push 가 한국어로 보낸다(지금과 같음).
--   값을 강제하지 않는다 — 나중에 언어가 늘어도 스키마를 안 건드린다.
alter table public.push_subscriptions
  add column if not exists lang text;

comment on column public.push_subscriptions.lang is
  '이 기기의 앱 언어 (ko|en|ja). null 이면 ko 로 보낸다.';

-- 조회 성능 — 언어별로 묶어 보낼 일이 생기면 쓴다
create index if not exists idx_push_subs_lang
  on public.push_subscriptions (lang);


-- ═══════════════════════════════════════════════════════════════
-- ② 저장 RPC — lang 을 같이 받는다
-- ═══════════════════════════════════════════════════════════════
--   p_lang 에 default 를 준다. 옛 앱(파라미터를 안 보내는 버전)이 그대로
--   돌아야 한다 — 배포 순서가 어긋나도 구독 저장이 깨지면 안 된다.
--
--   ⚠ 인자가 하나 늘면 Postgres 는 다른 함수로 본다. 옛 시그니처를 먼저
--     지우지 않으면 두 개가 공존해 어느 쪽이 불릴지 모르게 된다.
drop function if exists public.save_push_subscription(text,text,text,text,text,text,text[]);

create or replace function public.save_push_subscription(
  p_endpoint     text,
  p_p256dh       text,
  p_auth         text,
  p_user_agent   text   default null,
  p_device_label text   default null,
  p_role         text   default null,
  p_topics       text[] default '{}',
  p_lang         text   default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lang text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  -- 아는 값만 받는다. 오타나 'ko-KR' 같은 변형이 들어와도 앞 두 글자로 맞춘다
  v_lang := lower(coalesce(p_lang, ''));
  v_lang := case
              when v_lang like 'ja%' then 'ja'
              when v_lang like 'en%' then 'en'
              when v_lang like 'ko%' then 'ko'
              else null
            end;

  insert into public.push_subscriptions
    (user_id, endpoint, p256dh, auth, user_agent, device_label, role, topics, lang, last_seen_at)
  values
    (auth.uid(), p_endpoint, p_p256dh, p_auth, p_user_agent, p_device_label, p_role,
     coalesce(p_topics, '{}'), v_lang, now())
  on conflict (endpoint) do update set
    user_id      = excluded.user_id,
    p256dh       = excluded.p256dh,
    auth         = excluded.auth,
    user_agent   = excluded.user_agent,
    device_label = excluded.device_label,
    role         = excluded.role,
    topics       = excluded.topics,
    -- 새 값이 없으면 알던 값을 지우지 않는다. 옛 앱이 저장해도 언어가 안 날아간다
    lang         = coalesce(excluded.lang, public.push_subscriptions.lang),
    last_seen_at = now();
end;
$$;

revoke all on function public.save_push_subscription(text,text,text,text,text,text,text[],text) from public;
grant execute on function public.save_push_subscription(text,text,text,text,text,text,text[],text) to authenticated;

comment on function public.save_push_subscription(text,text,text,text,text,text,text[],text) is
  '본인 푸시 구독 저장/갱신 (RLS 우회). p_lang 은 ko|en|ja, 없으면 기존 값 유지.';


-- ═══════════════════════════════════════════════════════════════
-- ③ 지금 있는 기기 — 한 번 추정해 채운다
-- ═══════════════════════════════════════════════════════════════
--   앱이 언어를 쓰기 시작해도, 그 회원이 앱을 다시 열기 전까지는 lang 이
--   비어 있다. 그동안은 전부 한국어로 나간다.
--   profiles.country 로 한 번 메워두면 그 사이에도 해외 회원이 영어를 받는다.
--
--   country 는 KR/EN 둘뿐이라 일본어는 여기서 못 채운다. 일본어 쓰는 회원은
--   앱을 한 번 열면 그때 정확한 값으로 덮인다.
--
--   ⚠ 이미 lang 이 있는 기기는 건드리지 않는다 — 추정이 실제를 이기면 안 된다.
update public.push_subscriptions ps
   set lang = case when p.country = 'EN' then 'en' else 'ko' end
  from public.profiles p
 where p.id = ps.user_id
   and ps.lang is null;


-- ═══════════════════════════════════════════════════════════════
-- ④ 확인
-- ═══════════════════════════════════════════════════════════════
select
  coalesce(lang, '(모름 → 한국어로 나감)') as "언어",
  count(*)                                  as "기기",
  count(distinct user_id)                   as "회원"
from public.push_subscriptions
group by 1
order by 2 desc;

-- 함수가 새 시그니처로 올라갔는지
select proname as "함수",
       pg_get_function_identity_arguments(oid) as "인자"
from pg_proc
where proname = 'save_push_subscription';
