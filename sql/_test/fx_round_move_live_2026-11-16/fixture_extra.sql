-- 회차 날짜 이동 픽스처 — fx_repurchase_live_2026-11-15 위에 칸·표를 더한다(라이브 칸 이름 그대로 · 2026-11-16 조회)
alter table public.profiles add column if not exists phone text, add column if not exists notif_prefs jsonb default '{}'::jsonb;
alter table public.ticket_products add column if not exists total_pax int, add column if not exists auto_soldout boolean not null default false,
  add column if not exists updated_at timestamptz default now(), add column if not exists created_at timestamptz default now(),
  add column if not exists deadline_date text, add column if not exists m_open_date text, add column if not exists sale_open_at text,
  add column if not exists type_class text, add column if not exists slots jsonb, add column if not exists approved_at timestamptz;
alter table public.tickets add column if not exists visit_status text, add column if not exists buyer_phone text,
  add column if not exists reservation_time text, add column if not exists used_at timestamptz, add column if not exists cancelled_at timestamptz;
alter table public.restaurants add column if not exists name_en text, add column if not exists name_jp text;
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), host_user_id uuid not null, invitee_user_id uuid not null,
  restaurant_id text, restaurant_name text, visit_date text, visit_time text, pax int not null default 1, meal_fee int not null default 0,
  agency_fee int not null default 0, wine_min int not null default 0, total_amount int not null default 0, status text not null default 'sent',
  created_at timestamptz not null default now(), paid_at timestamptz, cancelled_at timestamptz, invitee_seen boolean not null default false, ticket_product_id text);
create table public.kashikiri_events(id uuid primary key default gen_random_uuid(), venue_id text not null, venue_name text, event_date date not null,
  event_time time, total_pax int not null default 0, status text not null default 'draft', created_by uuid, created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), ticket_product_id text);
create table public.kashikiri_teams(id uuid primary key default gen_random_uuid(), event_id uuid not null, seq int not null default 1, pax int not null default 1);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid, team_id uuid, label text not null, user_id uuid,
  amount_krw int not null default 0, status text not null default 'pending', payer_name text, payer_phone text, pay_currency text not null default 'KRW',
  pay_amount numeric, approved_at timestamptz, link_invite boolean not null default false, purpose text not null default 'custom', title text, subtitle text,
  payload jsonb not null default '{}'::jsonb, created_at timestamptz not null default now());
create table public.daegwan_manual(id uuid primary key default gen_random_uuid(), venue_id text not null, ymd date not null, name text, pax int not null default 1,
  memo text, created_by uuid, created_at timestamptz not null default now(), amount int not null default 0, ttype text not null default '오프라인', venue_name text);
create table public.guest_remind_log(ticket_id uuid not null, d int not null, phone_key text, result text, sent_at timestamptz not null default now(), primary key(ticket_id, d));
create table public.notifications(id uuid primary key default gen_random_uuid(), purchase_id uuid, user_id uuid not null, kind text, title text, message text,
  created_at timestamptz default now(), type text default 'system', body text, url text, payload jsonb default '{}'::jsonb, seen boolean not null default false);
create table public.ticket_package_rounds(ticket_product_id text primary key, package_id text not null, sort int not null default 0);
create table public.ticket_date_year_log(id bigserial primary key, tbl text not null, row_id text not null, old_date text, new_date text, source text, batch text,
  at timestamptz not null default now());
alter table public.purchase_rule_exceptions add column if not exists note text, add column if not exists created_by uuid;
-- 푸시 호출 기록(라이브 _taam_member_push 는 pg_net 으로 send-push 를 부른다 — 여기선 부른 것만 적는다)
create table public._push_calls(id bigserial primary key, uid uuid, title text, body text, url text, tag text, category text, i18n jsonb, at timestamptz default now());
