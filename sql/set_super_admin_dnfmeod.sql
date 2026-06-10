-- ═══════════════════════════════════════════════════════════════
-- TAAM — 슈퍼어드민 계정 지정 (dnfmeod@playtaam.com)
-- Supabase SQL Editor 에서 1회 실행
-- 작성일: 2026-05-20 (재작성: profiles.role 컬럼 자동 생성 포함)
-- 목적:
--   ① profiles.role 컬럼 없으면 추가
--   ② dnfmeod@playtaam.com 의 role = 'super_admin' 지정
--   ③ 향후 동일 이메일로 가입돼도 자동 슈퍼어드민 (트리거)
-- ═══════════════════════════════════════════════════════════════

-- ── 0. profiles 테이블 존재 여부 확인 ──
do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'public.profiles 테이블이 존재하지 않습니다. 먼저 profiles 테이블을 만들어주세요.';
  end if;
  raise notice '✓ profiles 테이블 확인';
end $$;

-- ── 1. profiles.role 컬럼 추가 (없을 때만) ──
alter table public.profiles
  add column if not exists role text default 'member';

comment on column public.profiles.role is
  '사용자 역할: member | admin | partner | super_admin';

-- ── 2. dnfmeod@playtaam.com 을 super_admin 으로 지정 ──
--   ⚠️ 사전에 PWA 에서 1회 가입돼 있어야 함 (auth.users 에 레코드 존재)
update public.profiles
set role = 'super_admin'
where id = (
  select id from auth.users
  where lower(email) = 'dnfmeod@playtaam.com'
  limit 1
);

-- ── 3. 결과 확인 ──
select
  u.email,
  p.id,
  p.role,
  p.display_name,
  p.created_at
from auth.users u
left join public.profiles p on p.id = u.id
where lower(u.email) = 'dnfmeod@playtaam.com';

-- 예상 결과 (가입돼 있으면):
--   email                 | role        | display_name
--   dnfmeod@playtaam.com  | super_admin | (이름)
--
-- 만약 0 row → 아직 PWA 에서 가입 안 됨:
--   1) https://taam-app.vercel.app 접속 → 초대코드로 dnfmeod@playtaam.com 가입
--   2) 이 SQL 다시 실행

-- ── 4. 자동 부여 트리거 (향후 가입 시 자동 super_admin) ──
create or replace function public.auto_promote_super_admin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  user_email text;
begin
  select lower(email) into user_email from auth.users where id = new.id;
  if user_email in ('dnfmeod@playtaam.com') then
    new.role := 'super_admin';
    raise notice '✓ % 슈퍼어드민 자동 지정', user_email;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_auto_promote_super_admin on public.profiles;
create trigger trg_auto_promote_super_admin
before insert on public.profiles
for each row execute function public.auto_promote_super_admin();

-- ── 5. is_super_admin 헬퍼 함수 (RLS 정책용) — 없으면 생성 ──
create or replace function public.is_super_admin(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select role in ('super_admin', 'superadmin') from public.profiles where id = uid),
    false
  );
$$;

comment on function public.is_super_admin(uuid) is
  '주어진 user_id 의 role 이 super_admin / superadmin 인지 검사. RLS 정책에서 사용.';

-- ── 완료 메시지 ──
do $$ begin raise notice '✅ profiles.role 컬럼 + 슈퍼어드민 지정 + 트리거 + is_super_admin() 설치 완료'; end $$;
