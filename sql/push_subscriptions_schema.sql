-- ═══════════════════════════════════════════════════════════════
-- TAAM Push Notifications — push_subscriptions 테이블
-- Supabase SQL Editor 에서 1회 실행
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.push_subscriptions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users(id) on delete cascade,
  endpoint        text not null,
  p256dh          text not null,
  auth            text not null,
  user_agent      text,
  device_label    text,           -- 사용자 친화 라벨 (예: 'iPhone 15', 'Chrome 데스크탑')
  role            text,           -- 'superadmin' | 'admin' | 'user' (구독 시점 기준)
  topics          text[] default array[]::text[],  -- 구독 토픽 (예: ['ticket','charge','refund'])
  created_at      timestamptz default now(),
  last_seen_at    timestamptz default now(),
  unique (endpoint)
);

-- 인덱스 (user_id 로 자주 조회됨)
create index if not exists push_subs_user_id_idx on public.push_subscriptions(user_id);
create index if not exists push_subs_role_idx on public.push_subscriptions(role);
create index if not exists push_subs_topics_idx on public.push_subscriptions using gin(topics);

-- RLS
alter table public.push_subscriptions enable row level security;

-- 본인 구독만 select/insert/update/delete 가능
create policy "own_subs_select" on public.push_subscriptions
  for select using (auth.uid() = user_id);
create policy "own_subs_insert" on public.push_subscriptions
  for insert with check (auth.uid() = user_id);
create policy "own_subs_update" on public.push_subscriptions
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own_subs_delete" on public.push_subscriptions
  for delete using (auth.uid() = user_id);

-- Edge Function (service role)은 RLS 우회해서 모든 구독 조회/발송 가능
-- → service_role 키로 호출하면 RLS bypass

comment on table public.push_subscriptions is 'TAAM 웹 푸시 알림 구독 — VAPID 기반 web-push 라이브러리로 전송';
comment on column public.push_subscriptions.endpoint is 'PushSubscription.endpoint (브라우저별 유니크 URL)';
comment on column public.push_subscriptions.p256dh is 'PushSubscription.getKey("p256dh") base64url';
comment on column public.push_subscriptions.auth is 'PushSubscription.getKey("auth") base64url';
comment on column public.push_subscriptions.topics is '구독 토픽 — 발송 시 토픽으로 필터 가능';
