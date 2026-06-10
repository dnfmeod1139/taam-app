-- ═══════════════════════════════════════════════════════════════
-- TAAM — profiles.email 컬럼 추가 + auth.users 자동 동기화
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-21
-- 목적:
--   ① profiles 테이블에 email 컬럼 추가 (auth.users 와 동기화)
--   ② 회원 검색 / 알림 / 통계에서 email 사용 가능
--   ③ invite_codes 의 invitee_name 으로 profiles.display_name 보강
-- 안전장치:
--   - 기존 display_name 이 있으면 덮어쓰지 않음
--   - email 동기화 트리거 = security definer
-- ═══════════════════════════════════════════════════════════════

-- ── 1. email 컬럼 추가 (idempotent) ──
alter table public.profiles
  add column if not exists email text;

comment on column public.profiles.email is
  'auth.users.email 의 미러본. 회원 검색·알림에 사용. 자동 동기화 트리거 적용.';

-- ── 2. 기존 회원 email 동기화 (auth.users → profiles) ──
update public.profiles p
set email = u.email
from auth.users u
where u.id = p.id
  and (p.email is null or p.email = '');

-- ── 3. 자동 동기화 트리거 함수 ──
-- auth.users 에 사용자 생성/이메일 변경 시 profiles 도 자동 업데이트
create or replace function public.sync_profile_email_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'display_name', '')
  )
  on conflict (id) do update
    set email = excluded.email
    where public.profiles.email is distinct from excluded.email;
  return new;
end;
$$;

comment on function public.sync_profile_email_from_auth() is
  'auth.users INSERT/UPDATE 시 profiles 테이블의 email 컬럼을 자동 동기화. profiles 가 없으면 새로 생성.';

-- ── 4. 트리거 등록 (idempotent) ──
drop trigger if exists trg_sync_profile_email on auth.users;
create trigger trg_sync_profile_email
after insert or update of email on auth.users
for each row execute function public.sync_profile_email_from_auth();

-- ── 5. invite_codes 의 invitee_name → profiles.display_name 보강 ──
-- 사용된(used=true) 초대코드의 invitee_name 을 profiles 의 display_name 으로 채움
-- (display_name 이 비어있을 때만 — 사용자가 직접 수정한 이름은 보존)
update public.profiles p
set display_name = ic.invitee_name
from public.invite_codes ic
where lower(ic.used_by_email) = lower(p.email)
  and ic.used = true
  and ic.invitee_name is not null
  and ic.invitee_name <> ''
  and (p.display_name is null or p.display_name = '');

-- ── 6. 검증 쿼리 ──
-- 동기화 결과 확인 (테스트 계정 + 슈퍼어드민)
select
  p.id,
  p.email,
  p.display_name,
  p.display_name_en,
  p.role,
  ic.invitee_name as invite_original_name,
  ic.code
from public.profiles p
left join public.invite_codes ic on lower(ic.used_by_email) = lower(p.email)
where p.email in (
  'ripe0315@naver.com',
  'tft315@naver.com',
  'dnfmeod@playtaam.com'
)
order by p.email;

-- ── 완료 메시지 ──
do $$ begin
  raise notice '✅ profiles.email 컬럼 + auto-sync 트리거 + invite_name 보강 완료';
  raise notice '   이제 회원 검색에서 email/display_name 모두 매칭 가능';
end $$;
