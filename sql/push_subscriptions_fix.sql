-- ═══════════════════════════════════════════════════════════════
-- TAAM — push_subscriptions 저장 실패 수정 (2026-06-18)
-- ═══════════════════════════════════════════════════════════════
-- 증상: 폰(브라우저)에는 구독이 활성(구독 ✓)인데, Supabase 의
--   push_subscriptions 에 row 가 0개. → 푸시 발송 대상이 없어 알림 안 옴.
-- 원인 후보(라이브 DB 가 스키마 파일과 불일치):
--   (a) endpoint UNIQUE 제약 없음 → 앱의 upsert(onConflict:'endpoint') 가
--       매번 실패 ("no unique or exclusion constraint matching ON CONFLICT").
--   (b) INSERT RLS 정책 없음/잘못됨 → 본인 구독 insert 가 차단.
-- 이 스크립트는 (a)(b) 모두 멱등하게 보강. Supabase SQL Editor 에서 1회 RUN.
-- ═══════════════════════════════════════════════════════════════

-- 1) 테이블 없으면 생성 (있으면 skip)
create table if not exists public.push_subscriptions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users(id) on delete cascade,
  endpoint        text not null,
  p256dh          text not null,
  auth            text not null,
  user_agent      text,
  device_label    text,
  role            text,
  topics          text[] default array[]::text[],
  created_at      timestamptz default now(),
  last_seen_at    timestamptz default now()
);

-- 2) 누락 컬럼 보강 (구버전 테이블 대비)
alter table public.push_subscriptions add column if not exists user_agent   text;
alter table public.push_subscriptions add column if not exists device_label text;
alter table public.push_subscriptions add column if not exists role         text;
alter table public.push_subscriptions add column if not exists topics       text[] default array[]::text[];
alter table public.push_subscriptions add column if not exists created_at   timestamptz default now();
alter table public.push_subscriptions add column if not exists last_seen_at timestamptz default now();

-- 3) endpoint UNIQUE 제약 보강 — onConflict:'endpoint' upsert 가 동작하려면 필수
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.push_subscriptions'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) ilike '%(endpoint)%'
  ) then
    -- 중복 endpoint 가 있으면 제약 추가가 실패 → 최신 1건만 남기고 정리
    delete from public.push_subscriptions a
      using public.push_subscriptions b
      where a.endpoint = b.endpoint and a.ctid < b.ctid;
    alter table public.push_subscriptions
      add constraint push_subscriptions_endpoint_key unique (endpoint);
    raise notice '✅ endpoint UNIQUE 제약 추가';
  else
    raise notice 'ℹ endpoint UNIQUE 제약 이미 존재';
  end if;
end $$;

-- 4) RLS + 본인 구독 CRUD 정책 (drop & recreate — 멱등)
alter table public.push_subscriptions enable row level security;

drop policy if exists "own_subs_select" on public.push_subscriptions;
drop policy if exists "own_subs_insert" on public.push_subscriptions;
drop policy if exists "own_subs_update" on public.push_subscriptions;
drop policy if exists "own_subs_delete" on public.push_subscriptions;

create policy "own_subs_select" on public.push_subscriptions
  for select using (auth.uid() = user_id);
create policy "own_subs_insert" on public.push_subscriptions
  for insert with check (auth.uid() = user_id);
create policy "own_subs_update" on public.push_subscriptions
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own_subs_delete" on public.push_subscriptions
  for delete using (auth.uid() = user_id);

-- 5) 검증 — 제약/정책 확인
select conname, pg_get_constraintdef(oid) as def
  from pg_constraint where conrelid='public.push_subscriptions'::regclass;
select policyname, cmd from pg_policies
  where schemaname='public' and tablename='push_subscriptions' order by policyname;

do $$ begin raise notice '✅ push_subscriptions 저장 수정 완료 — 앱에서 "재구독" 다시 누르면 DB row 1개로 저장됨'; end $$;
