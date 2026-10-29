#!/bin/bash
# 파트너 권한 정리 (supabase/migrations/20261029_partner_grants.sql) — 로컬 postgres 픽스처. 실행: bash sql/_test/t_partner_grants.sh
#   실제 정책(tickets · ticket_products · reservation_invites · profiles) 위에서 set role authenticated 로 앱이 보내는 문장을 흉내 낸다.
cd "$(dirname "$0")/../.."
MIG=supabase/migrations/20261029_partner_grants.sql
FAIL=0
DB=t_partner_grants; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=b1000000-0000-4000-8000-000000000009; M1=b1000000-0000-4000-8000-000000000001; M2=b1000000-0000-4000-8000-000000000002
PT=b1000000-0000-4000-8000-000000000007; PT2=b1000000-0000-4000-8000-000000000006; P3=b1000000-0000-4000-8000-000000000005; RA=b1000000-0000-4000-8000-000000000008
R1=c1000000-0000-4000-8000-000000000001; R2=c1000000-0000-4000-8000-000000000002
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end \$\$;
create schema auth; grant usage on schema auth to authenticated, anon;
create table auth.users(id uuid primary key, email text);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create table public.profiles(id uuid primary key, display_name text, role text, phone text, email text, membership_tier text, nationality text, country text, display_name_en text, currency text,
  membership_deposit_balance bigint default 0, general_deposit_balance bigint default 0, deleted_at timestamptz, created_at timestamptz default now());
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable security definer set search_path = public as \$\$
  select coalesce((select role in ('super_admin','superadmin') from public.profiles where id = uid), false) \$\$;
create or replace function public.is_superadmin() returns boolean language sql stable security definer set search_path = public as \$\$ select public.is_super_admin(auth.uid()) \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer set search_path = public as \$\$ select public.is_super_admin(auth.uid()) \$\$;
create or replace function public._taam_fee_caller_ok() returns boolean language plpgsql stable security definer set search_path = public as \$\$
begin if auth.uid() is not null then return coalesce(public._taam_uid_is_super(), false); end if;
  return session_user = 'postgres' or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role';
exception when others then return false; end \$\$;
create or replace function public._taam_pu_visit_date(p_text text) returns date language plpgsql immutable as \$\$
declare m text[]; d date; begin
  if p_text is null then return null; end if;
  m := regexp_match(btrim(p_text), '^(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})'); if m is null then return null; end if;
  d := make_date(m[1]::int, m[2]::int, m[3]::int); if d < date '2020-01-01' or d > date '2100-01-01' then return null; end if; return d;
exception when others then return null; end \$\$;
create or replace function public._taam_sr_ts(p text) returns timestamptz language plpgsql stable as \$\$
begin if p is null or btrim(p) = '' then return null; end if; return p::timestamptz; exception when others then return null; end \$\$;
create table public.restaurants(id uuid primary key, name text);
create table public.admin_grants(id uuid primary key default gen_random_uuid(), user_id uuid not null, rest_id text, venue_id text, label text, granted_by uuid, created_at timestamptz not null default now());
create unique index uq_ag_user_rest on public.admin_grants(user_id, rest_id) where rest_id is not null;
alter table public.admin_grants enable row level security;
create policy "ag select" on public.admin_grants for select to authenticated using (public.is_super_admin(auth.uid()) or user_id = auth.uid());
create policy "ag write" on public.admin_grants for all to authenticated using (public.is_super_admin(auth.uid())) with check (public.is_super_admin(auth.uid()));
create table public.restaurant_admins(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, added_by uuid, added_at timestamptz default now());
create table public.venue_admins(id uuid primary key default gen_random_uuid(), admin_user_id uuid, venue_id text, granted_by uuid);
create table public.partner_accounts(login_id text primary key, user_id uuid, rest_id text, label text, issued_at timestamptz default now(), last_login_at timestamptz, disabled boolean default false);
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, status text, date text, time text, total_pax int, price int, meal_fee int, agency_fee int, wine_min int,
  ticket_type text, uploaded_by text, uploader_rest_id text, auto_soldout boolean default false, tile_photo text, repurchase_open boolean default false, updated_at timestamptz default now(),
  sale_state text, sale_open_at text, ticket_desc text, i18n_status_en text, i18n_status_jp text, slots jsonb, guest_price int, guest_opened_by uuid);
alter table public.ticket_products enable row level security;
create policy ticket_products_read on public.ticket_products for select to public using (true);
create policy ticket_products_superadmin_all on public.ticket_products for all to authenticated using (public.is_superadmin()) with check (public.is_superadmin());
create policy ticket_products_partner_insert on public.ticket_products for insert to public with check (false);
create policy ticket_products_partner_update on public.ticket_products for update to public using (false);
create policy ticket_products_partner_delete on public.ticket_products for delete to public using (false);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, reservation_date text, visit_time text, party_size int, status text,
  purchase_id text, price bigint, created_at timestamptz default now(), used_at timestamptz, cancelled_at timestamptz, ticket_product_id text, ticket_type text, buyer_name text, buyer_phone text,
  extra_data jsonb default '{}', visit_status text, visit_marked_at timestamptz);
alter table public.tickets enable row level security;
create policy tickets_select_own on public.tickets for select to authenticated using ((auth.uid() = user_id) or public.is_superadmin());
create policy tickets_insert_own on public.tickets for insert to authenticated with check ((auth.uid() = user_id) or public.is_superadmin());
create policy tickets_update_own on public.tickets for update to authenticated using ((auth.uid() = user_id) or public.is_superadmin()) with check ((auth.uid() = user_id) or public.is_superadmin());
-- 옛 판정 함수들(라이브 판 모양) — 마이그레이션이 덮어쓴다
create or replace function public.is_ticket_admin_of(p_rest_id text) returns boolean language sql stable security definer set search_path = public as \$\$
  select exists (select 1 from public.admin_grants where user_id = auth.uid() and rest_id = p_rest_id) \$\$;
create or replace function public.is_restaurant_admin_of(p_restaurant_id text) returns boolean language sql stable security definer set search_path = public as \$\$
  select exists (select 1 from public.admin_grants where user_id = auth.uid() and rest_id = p_restaurant_id)
      or exists (select 1 from public.restaurant_admins where user_id = auth.uid() and restaurant_id = p_restaurant_id) \$\$;
create or replace function public.is_venue_admin_of(p_venue_id text) returns boolean language sql stable security definer set search_path = public as \$\$
  select exists (select 1 from public.admin_grants where user_id = auth.uid() and venue_id = p_venue_id) \$\$;
create or replace function public.taam_is_rest_admin(p_rest_id text) returns boolean language sql stable security definer set search_path = public as \$\$
  select exists (select 1 from public.admin_grants where user_id = auth.uid() and (rest_id = p_rest_id or venue_id = p_rest_id)) \$\$;
create or replace function public.taam_can_mark_visit(p text) returns boolean language sql stable security definer as \$\$ select false \$\$;
create or replace function public.taam_can_manage_ticket_as(p_ticket_id text, p_user uuid) returns boolean language sql stable security definer as \$\$ select false \$\$;
create or replace function public._taam_rest_note_ok(p_rest_id text) returns boolean language sql stable security definer as \$\$ select false \$\$;
create or replace function public._taam_uid_role() returns text language sql stable security definer set search_path = public as \$\$ select coalesce((select role from public.profiles where id = auth.uid()), 'user') \$\$;
create policy "tickets select restaurant admin" on public.tickets for select to authenticated using (public.is_restaurant_admin_of(restaurant_id));
-- 라이브 INSERT 가드 원본(md5 7567d32f…)
create or replace function public.taam_guard_ticket_insert() returns trigger language plpgsql set search_path = public as \$\$
declare v_role text;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public._taam_uid_is_super() then
    return new;
  end if;

  if new.user_id is distinct from auth.uid() then
    raise exception '남의 이름으로 예약을 넣을 수 없습니다' using errcode = '42501';
  end if;

  v_role := public._taam_uid_role();
  if new.status = 'hold' then
    -- 🆕 2026-09-29 회원의 홀드는 PAYH- 뿐이다. 다른 접두어(MAN-·INV-·INVH-·KSK-·LINK-)는 서버·어드민 몫이라
    --   회원이 흉내 내면 등급 가드 면제를 타거나(접두어 면제) 5분 스윕에 안 잡히는 영구 홀드가 된다.
    if v_role <> 'admin' and coalesce(new.purchase_id, '') not like 'PAYH-%' then
      raise exception 'HOLD_PREFIX: 회원 좌석 홀드는 PAYH- 로만 만들 수 있습니다' using errcode = '42501';
    end if;
    return new;                               -- 좌석 홀드(5분) — 확정은 서버가 한다
  end if;

  if new.status = 'manual' and v_role = 'admin' then
    return new;                               -- 매장 어드민의 수동 연동 행(MAN-)
  end if;

  raise exception '예약은 서버가 확정합니다 — 직접 넣을 수 없는 상태: %', coalesce(new.status, '(없음)')
    using errcode = '42501';
end;
\$\$;
create trigger trg_taam_guard_ticket_insert before insert on public.tickets for each row execute function public.taam_guard_ticket_insert();
create table public.reservation_invites(id uuid primary key default gen_random_uuid(), host_user_id uuid, invitee_user_id uuid, restaurant_id text, restaurant_name text, visit_date text, visit_time text,
  pax int default 1, meal_fee int default 0, agency_fee int default 0, wine_min int default 0, total_amount int default 0, status text default 'sent', created_at timestamptz default now(), paid_at timestamptz, cancelled_at timestamptz, ticket_product_id text);
alter table public.reservation_invites enable row level security;
create policy resinv_select on public.reservation_invites for select using (auth.uid() = invitee_user_id or auth.uid() = host_user_id or public.is_super_admin(auth.uid()));
create policy resinv_insert on public.reservation_invites for insert with check (host_user_id = auth.uid() and (public.is_super_admin(auth.uid()) or public.taam_is_rest_admin(restaurant_id)));
create policy resinv_update on public.reservation_invites for update using (auth.uid() = invitee_user_id or auth.uid() = host_user_id or public.is_super_admin(auth.uid()));
create table public.daegwan_manual(id uuid primary key default gen_random_uuid(), rest_id text, name text, memo text);
create table public.reservation_requests(id uuid primary key default gen_random_uuid(), user_id uuid, venue_id text, reserve_date date, status text default 'pending', visit_status text);
alter table public.profiles enable row level security;
create policy profiles_select_own on public.profiles for select to authenticated using ((auth.uid() = id) or public.is_superadmin());
create policy profiles_update_own on public.profiles for update to authenticated using ((auth.uid() = id) or public.is_superadmin()) with check ((auth.uid() = id) or public.is_superadmin());   -- 라이브 「profiles update own」 모양
create policy "profiles read by venue admin for requesters" on public.profiles for select to authenticated using (exists (select 1 from public.reservation_requests rr where rr.user_id = profiles.id and (public.is_super_admin(auth.uid()) or public.is_venue_admin_of(rr.venue_id))));
create or replace function public.get_requester_info(p_user_id uuid, p_venue_id text)
returns table (display_name text, phone text, nationality text, membership_tier text, purchase_count integer, cancel_count integer, venue_visits integer, last_visit date)
language sql stable security definer as \$\$ select null::text, null::text, null::text, null::text, 0, 0, 0, null::date \$\$;
create table public.deposit_transactions(id uuid primary key default gen_random_uuid(), user_id uuid, deposit_type text, change_type text, amount bigint, metadata jsonb default '{}', created_at timestamptz default now());
alter table public.deposit_transactions enable row level security;
create policy dts on public.deposit_transactions for select to authenticated using (user_id = auth.uid() or public.is_superadmin());
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), refund_krw int);
create or replace function public._taam_auth_email(p_id uuid) returns text language sql stable security definer set search_path = public as \$\$ select u.email from auth.users u where u.id = p_id \$\$;
create or replace function public.taam_user_tier(p uuid) returns text language sql stable security definer as \$\$ select 'T' \$\$;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on public.ticket_products, public.restaurants to anon;
grant usage on schema public to authenticated, anon;
-- 픽스처 데이터 (마이그레이션 전 = 옛 규칙 · 줄 = 승인)
insert into auth.users values ('$SU','su@x.kr'),('$M1','m1@x.kr'),('$M2','m2@x.kr'),('$PT','pt@partner.taam.kr'),('$PT2','pt2@x.kr'),('$P3','p3@partner.taam.kr'),('$RA','ra@x.kr');
insert into public.profiles(id,display_name,role,phone,email,membership_tier,nationality) values
 ('$SU','운영','superadmin',null,'su@x.kr',null,null),('$M1','회원일','user','010-1111-2222','m1@x.kr','M','KR'),('$M2','회원이','user','010-3333-4444','m2@x.kr','T','JP'),
 ('$PT','파트너','user',null,'pt@partner.taam.kr',null,null),('$PT2','옛파트너','user',null,'pt2@x.kr',null,null),('$P3','새파트너','user',null,'p3@partner.taam.kr',null,null),('$RA','글자어드민','admin',null,'ra@x.kr',null,null);
update public.profiles set membership_deposit_balance = 5000000, general_deposit_balance = 700000 where id = '$M1';
insert into public.restaurants values ('$R1','메이노'),('$R2','사이토');
insert into public.admin_grants(user_id,rest_id,label,granted_by,created_at) values ('$PT','$R1','메이노','$SU','2026-10-01T00:00:00Z');
insert into public.restaurant_admins(user_id,restaurant_id,restaurant_name,added_by,added_at) values ('$PT2','$R2','사이토','$SU','2026-09-01T00:00:00Z');
insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price,ticket_type) values ('tp1','$R1','메이노','active','2026.11.03','19:00',8,850000,'Standard'),('tp2','$R2','사이토','active','2026.11.05','19:00',8,1000000,'Standard'),
 ('tp3','$R1','메이노','pending','2026.12.01','12:00',8,500000,'Standard');
insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,status,purchase_id,price,buyer_name,buyer_phone,extra_data,created_at,visit_status) values
 ('$M1','$R1','메이노','tp1','2026.11.03','19:00',2,'active','PAYH-tp1_1',1700000,'회원일','','{"paidBy":"deposit"}','2026-10-05T00:00:00Z',null),
 ('$M1','$R1','메이노','tp1','2026.09.03','19:00',1,'used','PAYH-tp1_old',850000,'회원일','','{}','2026-08-20T00:00:00Z','attended'),
 ('$M1','$R1','메이노','tp1','2026.10.01','19:00',1,'cancelled','PAYH-tp1_c',850000,'회원일','','{"cancel_reason":"회원 취소","cardPaid":300000,"card_refund_pending":{"status":"done","amount":300000,"refunded_amount":300000}}','2026-09-10T00:00:00Z',null),
 ('$M1','$R2','사이토','tp2','2026.11.05','19:00',2,'active','PAYH-tp2_1',2000000,'회원일','','{}','2026-10-06T00:00:00Z',null),
 ('$M2','$R2','사이토','tp2','2026.11.05','19:00',1,'active','PAYH-tp2_2',1000000,'회원이','','{}','2026-10-07T00:00:00Z',null),
 ('$PT','$R1','메이노','tp1','2026.11.03','19:00',2,'manual','MAN-1',0,'손님','010-9999-8888','{"manualEntry":true}','2026-10-08T00:00:00Z',null);
insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M1','general','ticket_refund',550000,'{"purchase_id":"PAYH-tp1_c","cancel_refund":true}'),('$M1','general','ticket_refund',99,'{"purchase_id":"PAYH-tp2_1"}');
-- 라이브 매진 동기화 모양(sql/seat_soldout_sync.sql 요지): tickets 가 바뀌면 그 회차의 점유를 세어 ticket_products.status 를 soldout/active 로 — **회원 세션 안에서 중첩으로 돈다**
create or replace function public.sync_ticket_soldout() returns trigger language plpgsql security definer set search_path = public as \$\$
declare v_pid text; v_cap int; v_occ int; v_st text;
begin
  v_pid := coalesce(new.ticket_product_id, old.ticket_product_id); if v_pid is null then return null; end if;
  select total_pax, status into v_cap, v_st from public.ticket_products where id = v_pid;
  if v_cap is null then return null; end if;
  select coalesce(sum(party_size), 0) into v_occ from public.tickets where ticket_product_id = v_pid and lower(coalesce(status,'')) in ('hold','active','manual','used','pending_confirm');
  if v_occ >= v_cap and coalesce(v_st,'') <> 'soldout' then update public.ticket_products set status = 'soldout' where id = v_pid;   -- 라이브 sql/seat_soldout_sync.sql: pending 도 soldout 으로 밀린다
  elsif v_occ < v_cap and v_st = 'soldout' then update public.ticket_products set status = 'active' where id = v_pid; end if;
  return null;
end \$\$;
create trigger trg_sync_ticket_soldout after insert or update or delete on public.tickets for each row execute function public.sync_ticket_soldout();
create table public._rl(k text); create or replace function public.taam_rate_hit(p_key text, p_limit integer, p_window interval) returns boolean language plpgsql as \$\$
begin insert into public._rl(k) values (p_key); return (select count(*) from public._rl where k = p_key) <= p_limit; end \$\$;
-- J 대상 — 라이브 본문과 같은 모양의 직접 조회를 품은 함수 둘(가짜 · 매장 id 만 받는다)
create or replace function public.taam_ksk_seat_rows(p_rest text) returns text language plpgsql security definer set search_path = public as \$\$
declare v_uid uuid := auth.uid(); v_ev record;
begin
  select p_rest as venue_id into v_ev;
  if not (public._taam_uid_is_super() or exists (
        select 1 from public.admin_grants g where g.user_id = v_uid
           and (g.rest_id::text = v_ev.venue_id or g.venue_id::text = v_ev.venue_id))) then
    raise exception '이 매장의 어드민만 볼 수 있습니다' using errcode = '42501';
  end if;
  return 'ok';
end \$\$;
create or replace function public.taam_link_invite_create(p_ticket_id text) returns text language plpgsql security definer set search_path = public as \$\$
declare v_uid uuid := auth.uid(); v_super boolean := public._taam_uid_is_super(); v_tp record;
begin
  select * into v_tp from public.ticket_products where id::text = p_ticket_id;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  if not v_super and not exists (
       select 1 from public.admin_grants g where g.user_id = v_uid
          and (g.rest_id::text = v_tp.rest_id::text or g.venue_id::text = v_tp.rest_id::text)) then
    raise exception '권한이 없습니다' using errcode = '42501';
  end if;
  return 'ok';
end \$\$;
grant execute on function public.taam_ksk_seat_rows(text), public.taam_link_invite_create(text) to authenticated;
create schema storage; create table storage.objects(bucket_id text, name text, owner uuid); alter table storage.objects enable row level security;
grant usage on schema storage to authenticated; grant insert, select on storage.objects to authenticated;
create policy restaurant_videos_partner_insert on storage.objects for insert to authenticated with check (bucket_id = 'restaurant-videos' and (public._taam_uid_is_super() or exists (select 1 from public.admin_grants g where g.user_id = auth.uid())));
SQL
out=$($P -f "$MIG" 2>&1)
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1 — 기대 [$3] 실제 [$2]"; FAIL=1; fi; }
has(){ if echo "$2" | grep -q -- "$3"; then echo "✅ $1"; else echo "❌ $1 — [$3] 없음: ${2:0:300}"; FAIL=1; fi; }
no(){ if echo "$2" | grep -q -- "$3"; then echo "❌ $1 — [$3] 있음: ${2:0:300}"; FAIL=1; else echo "✅ $1"; fi; }
AS(){ $P -c "set role authenticated; set taam.uid='$1'; $2" 2>&1; }
Q(){ $P -c "$1" 2>&1; }
echo "$out" | grep -q "❌" && { echo "❌ 설치 확인 표에 ❌"; echo "$out" | grep "❌"; FAIL=1; } || echo "✅ 설치 확인 표"
echo "$out" | grep -q "ERROR" && { echo "❌ 설치 중 ERROR"; echo "$out" | grep -A2 "ERROR" | head -20; FAIL=1; } || echo "✅ 설치 중 ERROR 없음"
echo "$out" | grep -E "^A |^B 교체|^C |^I " | sed 's/^/   /'
# A 상태
ok "옛 권한 → approved" "$(Q "select status from public.admin_grants where user_id='$PT'")" "approved"
ok "restaurant_admins 옮김 → approved" "$(Q "select status from public.admin_grants where user_id='$PT2' and rest_id='$R2'")" "approved"
# B 판정
ok "approved 파트너 — 자기 매장 true" "$(AS "$PT" "select public.taam_rest_admin_ok('$R1')")" "t"
ok "approved 파트너 — 남의 매장 false" "$(AS "$PT" "select public.taam_rest_admin_ok('$R2')")" "f"
ok "옛 is_restaurant_admin_of 도 같은 판정" "$(AS "$PT2" "select public.is_restaurant_admin_of('$R2')")" "t"
Q "select public.taam_partner_grant_set('$P3','$R1','pending','신규')" >/dev/null
ok "pending 권한 — false" "$(AS "$P3" "select public.taam_rest_admin_ok('$R1')")" "f"
ok "pending 파트너 — 매장 티켓 안 보임" "$(AS "$P3" "select count(*) from public.tickets")" "0"
ok "approved 파트너 — 자기 매장 티켓만(4) · 남의 매장 0" "$(AS "$PT" "select count(*) || '/' || count(*) filter (where restaurant_id='$R2') from public.tickets")" "4/0"
ok "글자 role admin 계정 — 권한 없으면 아무것도 안 보임" "$(AS "$RA" "select count(*) from public.tickets")" "0"
# C INSERT 가드
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price,buyer_name) values ('$PT','$R1','tp1','2026.11.03',1,'manual','MAN-new',0,'손님2');"); ok "approved 파트너 — 자기 매장 MAN- OK" "$(echo "$r" | grep -c ERROR)" "0"
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$PT','$R2','tp2','2026.11.05',1,'manual','MAN-x',0);"); has "파트너 — 남의 매장 MAN- 거절" "$r" "직접 넣을 수 없는"
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$PT','$R1','tp2','2026.11.05',1,'manual','MAN-y',0);"); has "파트너 — 자기 매장 이름에 남의 회차 → TICKET_REST_MISMATCH" "$r" "TICKET_REST_MISMATCH"
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price,extra_data) values ('$PT','$R1','tp1','2026.11.03',1,'hold','INVH-abcd1234-1',0,'{\"inviteHold\":true}');"); ok "파트너 — 자기 매장 INVH- 홀드 OK" "$(echo "$r" | grep -c ERROR)" "0"
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$PT','$R1','tp1','2026.11.03',1,'hold','MAN-hold',0);"); has "파트너 — 홀드는 INVH-/PAYH- 만" "$r" "HOLD_PREFIX"
r=$(AS "$RA" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$RA','$R2','tp2','2026.11.05',1,'manual','MAN-z',0);"); has "글자 role admin — 권한 없으면 MAN- 거절(종전엔 어느 매장이든 됐다)" "$r" "직접 넣을 수 없는"
r=$(AS "$M1" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$M1','$R1','tp1','2026.11.03',1,'hold','PAYH-tp1_h',0);"); ok "회원 PAYH- 홀드 그대로" "$(echo "$r" | grep -c ERROR)" "0"
r=$(AS "$P3" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$P3','$R1','tp1','2026.11.03',1,'manual','MAN-p3',0);"); has "pending 파트너 — MAN- 거절" "$r" "직접 넣을 수 없는"
# D ticket_products
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp4','$R1','메이노','pending','2026.12.10','19:00',6,900000);"); ok "파트너 — pending 업로드 OK" "$(echo "$r" | grep -c ERROR)" "0"
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp5','$R1','메이노','active','2026.12.11','19:00',6,900000);"); has "파트너 — active 로 올리기 거절" "$r" "ADMIN_MUST_UPLOAD_PENDING"
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp6','$R2','사이토','pending','2026.12.11','19:00',6,900000);"); ok "파트너 — 남의 매장 업로드 거절(정책)" "$(echo "$r" | grep -c "ERROR")" "1"
r=$(AS "$P3" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp7','$R1','메이노','pending','2026.12.12','19:00',6,900000);"); ok "pending 파트너 — 업로드 거절" "$(echo "$r" | grep -c "ERROR")" "1"
ok "슈퍼어드민 알림(업로드 신청) 1건" "$(Q "select count(*) from public.notifications where user_id='$SU' and type='ticket_upload_request' and payload->>'ticket_id'='tp4'")" "1"
r=$(AS "$PT" "update public.ticket_products set status='active' where id='tp4';"); has "파트너 — pending→active 거절" "$r" "ONLY_SUPERADMIN_APPROVES"
AS "$SU" "update public.ticket_products set status='active' where id='tp4';" >/dev/null
ok "슈퍼어드민 승인 → 도장 · 상태 active" "$(Q "select status || '/' || (approved_by='$SU')::text from public.ticket_products where id='tp4'")" "active/true"
ok "승인 알림 → 그 매장 approved 어드민에게만(PT 1 · P3 0)" "$(Q "select count(*) filter (where user_id='$PT') || '/' || count(*) filter (where user_id='$P3') from public.notifications where type='ticket_approved' and payload->>'ticket_id'='tp4'")" "1/0"
AS "$PT" "update public.ticket_products set status='soldout', auto_soldout=false, updated_at=now() where id='tp4';" >/dev/null
ok "파트너 — 매진 토글은 그대로(승인 유지)" "$(Q "select status || '/' || (approved_at is not null)::text from public.ticket_products where id='tp4'")" "soldout/true"
AS "$PT" "update public.ticket_products set status='active' where id='tp4';" >/dev/null
AS "$PT" "update public.ticket_products set price=950000, updated_at=now() where id='tp4';" >/dev/null
EQ(){ Q "select coalesce((select edit::text from public.ticket_product_edits where ticket_id='$1'),'-')"; }
ok "파트너 — 승인된 회차 내용 수정 → **status·값은 그대로** · 바뀐 칸은 수정 큐 표에 · 도장 유지" "$(Q "select status || '/' || price || '/' || (approved_at is not null)::text from public.ticket_products where id='tp4'")/$(EQ tp4)" "active/900000/true/{\"price\": 950000}"
ok "회원에게는 그 회차가 그대로 보인다(종전 판은 pending 이 되어 사라졌다)" "$(AS "$M1" "select count(*) from public.ticket_products where id='tp4'")" "1"
ok "회원은 수정 큐를 못 읽는다(0행) · anon 은 권한 없음 — 미승인 값이 회원 기기에 안 내려간다" "$(AS "$M1" "select count(*) from public.ticket_product_edits")/$($P -c "set role anon; select count(*) from public.ticket_product_edits;" 2>&1 | grep -c 'permission denied')" "0/1"
ok "파트너는 자기 매장 큐만(표 RLS · RPC)" "$(AS "$PT" "select count(*) from public.ticket_product_edits")/$(AS "$PT" "select public.taam_ticket_edits()->0->>'ticket_id'")/$(AS "$P3" "select public.taam_ticket_edits()")" "1/tp4/[]"
ok "수정 신청 알림 → 슈퍼어드민(payload edit=true)" "$(Q "select count(*) from public.notifications where user_id='$SU' and title like '티켓 수정 신청%' and payload->>'ticket_id'='tp4' and payload->>'edit'='true'")" "1"
AS "$PT" "update public.ticket_products set wine_min=50000, updated_at=now() where id='tp4';" >/dev/null
ok "두 번째 수정은 큐에 합쳐진다" "$(EQ tp4)" "{\"price\": 950000, \"wine_min\": 50000}"
ok "같은 회차의 10분 안 두 번째 수정은 알림을 또 쌓지 않는다" "$(Q "select count(*) from public.notifications where user_id='$SU' and payload->>'ticket_id'='tp4' and payload->>'edit'='true'")" "1"
r=$(AS "$PT" "update public.ticket_products set repurchase_open=true, review_note='lol', uploaded_by='x', uploader_rest_id='y' where id='tp4';"); ok "파트너 — 재구매 해제·검토 메모·업로더 칸은 되돌린다(큐도 아님)" "$(Q "select coalesce(repurchase_open,false)::text || '/' || coalesce(review_note,'-') || '/' || coalesce(uploaded_by,'-') || coalesce(uploader_rest_id,'-') from public.ticket_products where id='tp4'")/$(EQ tp4)" "false/-/--/{\"price\": 950000, \"wine_min\": 50000}"
r=$(AS "$PT" "update public.ticket_products set ticket_type=repeat('a',2001) where id='tp4';"); has "파트너 — 수정 큐 상한(글자 2,000자) → EDIT_TOO_LONG" "$r" "EDIT_TOO_LONG"
ok "상한에 걸린 수정은 큐도 값도 그대로" "$(Q "select coalesce(ticket_type,'-') from public.ticket_products where id='tp4'")/$(EQ tp4)" "-/{\"price\": 950000, \"wine_min\": 50000}"
ok "파트너 — 승인된 회차(큐 있음) DELETE 는 0행" "$(AS "$PT" "delete from public.ticket_products where id='tp4' returning id;" | grep -c tp4)" "0"
has "파트너 — 수정 승인 RPC 는 못 부른다" "$(AS "$PT" "select public.taam_ticket_edit_review('tp4', true)")" "FORBIDDEN"
AS "$SU" "select public.taam_ticket_edit_review('tp4', true, '확인');" >/dev/null
ok "슈퍼어드민 「수정 승인」 → 값 반영 · 큐 비움 · 도장 갱신" "$(Q "select price || '/' || wine_min || '/' || (approved_by='$SU')::text from public.ticket_products where id='tp4'")/$(EQ tp4)" "950000/50000/true/-"
ok "수정 승인 알림 → 파트너(fields)" "$(Q "select count(*) from public.notifications where user_id='$PT' and type='ticket_edit_approved' and payload->>'ticket_id'='tp4' and payload->'fields' ? 'price'")" "1"
has "큐가 비었을 때 승인 → applied false · nothing_pending" "$(AS "$SU" "select public.taam_ticket_edit_review('tp4', true)")" "nothing_pending"
AS "$PT" "update public.ticket_products set price=999000 where id='tp4';" >/dev/null
AS "$SU" "select public.taam_ticket_edit_review('tp4', false, '가격 근거 필요');" >/dev/null
ok "슈퍼어드민 「반려」 → 큐 비움 · 값 그대로 · 메모" "$(Q "select price || '/' || review_note from public.ticket_products where id='tp4'")/$(EQ tp4)" "950000/가격 근거 필요/-"
ok "반려 알림 → 파트너" "$(Q "select count(*) from public.notifications where user_id='$PT' and type='ticket_edit_rejected' and payload->>'ticket_id'='tp4'")" "1"
AS "$PT" "update public.ticket_products set price=1000000 where id='tp4';" >/dev/null
has "회원은 남의 신청을 못 거둔다" "$(AS "$M1" "select public.taam_ticket_edit_cancel('tp4')")" "FORBIDDEN"
ok "파트너가 자기 신청을 거둔다(RPC)" "$(AS "$PT" "select public.taam_ticket_edit_cancel('tp4')->>'removed'")/$(EQ tp4)/$(Q "select price from public.ticket_products where id='tp4'")" "1/-/950000"
AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price,meal_fee,agency_fee,wine_min) values ('tp4','$R1','메이노','active','2026.12.10','19:00',6,950000,0,0,50000) on conflict (id) do update set meal_fee=excluded.meal_fee, agency_fee=excluded.agency_fee, wine_min=excluded.wine_min, status=excluded.status, updated_at=now();" >/dev/null
ok "앱 모양의 전체 upsert(null → 0 · 같은 값) 는 수정으로 안 친다" "$(EQ tp4)" "-"
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp4','$R1','메이노','pending','2026.12.10','19:00',6,950000) on conflict (id) do update set status=excluded.status, price=excluded.price, updated_at=now();")
ok "옛 앱(수정에 'pending' 을 보냄) — 상태 변경 없음으로 읽어 통과 · active 유지 · 큐 없음" "$(echo "$r" | grep -c ERROR)/$(Q "select status from public.ticket_products where id='tp4'")/$(EQ tp4)" "0/active/-"
Q "update public.ticket_products set status='hidden' where id='tp4';" >/dev/null
r=$(AS "$PT" "update public.ticket_products set status='active' where id='tp4';"); has "슈퍼어드민이 숨긴(hidden) 회차의 상태는 파트너가 못 바꾼다" "$r" "BAD_STATUS_CHANGE"
r=$(AS "$PT" "update public.ticket_products set price=970000 where id='tp4';"); ok "숨긴 회차의 내용 수정은 큐로(상태 그대로)" "$(echo "$r" | grep -c ERROR)/$(Q "select status || '/' || price from public.ticket_products where id='tp4'")/$(EQ tp4)" "0/hidden/950000/{\"price\": 970000}"
Q "delete from public.ticket_product_edits where ticket_id='tp4'; update public.ticket_products set status='active' where id='tp4';" >/dev/null
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp1','$R1','메이노','active','2026.11.03','19:00',8,850000) on conflict (id) do update set status=excluded.status, updated_at=now();"); ok "파트너 upsert(있는 행 · 값 같음) — 통과 · 상태 유지" "$(echo "$r" | grep -c ERROR)/$(Q "select status from public.ticket_products where id='tp1'")" "0/active"
r=$(AS "$PT" "update public.ticket_products set status='deleteRequest' where id='tp1';"); ok "파트너 — 삭제 신청 OK" "$(Q "select status from public.ticket_products where id='tp1'")" "deleteRequest"
AS "$PT" "update public.ticket_products set status='active' where id='tp1';" >/dev/null
ok "파트너 — 승인된 회차 DELETE 는 0행" "$(AS "$PT" "delete from public.ticket_products where id='tp1' returning id;" | grep -c tp1)" "0"
ok "파트너 — 자기 pending 회차 DELETE OK" "$(AS "$PT" "delete from public.ticket_products where id='tp3' returning id;" | grep -c tp3)" "1"
AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp7p','$R1','메이노','pending','2026.12.21','19:00',6,900000);" >/dev/null
ok "회원 — 승인 대기 회차 안 보임(tp7p pending)" "$(AS "$M1" "select count(*) from public.ticket_products where id='tp7p'")" "0"
ok "파트너 — 자기 매장 승인 대기 회차 보임" "$(AS "$PT" "select count(*) from public.ticket_products where id='tp7p'")" "1"
ok "anon — 승인 대기 회차 안 보임" "$($P -c "set role anon; select count(*) from public.ticket_products where status='pending';" 2>&1 | tail -1)" "0"
Q "delete from public.ticket_products where id='tp7p';" >/dev/null
AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp8','$R1','메이노','pending','2026.12.20','19:00',6,900000);" >/dev/null
AS "$SU" "delete from public.ticket_products where id='tp8';" >/dev/null
ok "슈퍼어드민 거절(pending 삭제) → 파트너 알림" "$(Q "select count(*) from public.notifications where user_id='$PT' and type='ticket_rejected' and payload->>'ticket_id'='tp8'")" "1"
AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp9','$R1','메이노','pending','2026.12.22','19:00',1,900000);" >/dev/null
AS "$PT" "update public.ticket_products set price=910000 where id='tp9';" >/dev/null
ok "승인 전 회차의 내용은 바로 고쳐진다(큐 없음)" "$(Q "select price from public.ticket_products where id='tp9'")/$(EQ tp9)" "910000/-"
AS "$SU" "update public.ticket_products set status='soldout' where id='tp9';" >/dev/null
ok "pending → soldout 으로 승인(정원 찬 회차) — 도장 · 승인 알림" "$(Q "select (approved_by='$SU')::text from public.ticket_products where id='tp9'")/$(Q "select count(*) from public.notifications where user_id='$PT' and type='ticket_approved' and payload->>'ticket_id'='tp9'")" "true/1"
Q "delete from public.ticket_products where id='tp9';" >/dev/null
# ── 중첩 경로(매진 동기화) — 1차 판의 치명 회귀
Q "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tpS','$R1','메이노','active','2026.11.20','19:00',2,100000);" >/dev/null
r=$(AS "$M2" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$M2','$R1','tpS','2026.11.20',2,'hold','PAYH-tpS_1',200000);")
ok "회원 — 마지막 좌석 홀드가 들어가고 매진 동기화가 회차를 soldout 으로(중첩 UPDATE 통과)" "$(echo "$r" | grep -c ERROR)/$(Q "select status from public.ticket_products where id='tpS'")" "0/soldout"
Q "update public.tickets set status='active' where purchase_id='PAYH-tpS_1';" >/dev/null
r=$(AS "$M2" "update public.tickets set status='cancelled' where purchase_id='PAYH-tpS_1';")
ok "회원 — soldout 회차의 자기 티켓 취소 → 회차 active 로(중첩 UPDATE 통과)" "$(echo "$r" | grep -c ERROR)/$(Q "select status from public.ticket_products where id='tpS'")" "0/active"
Q "update public.ticket_products set status='pending', approved_at=null where id='tpS';" >/dev/null
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$PT','$R1','tpS','2026.11.20',2,'manual','MAN-tpS',0);"); has "파트너 — 승인 대기 회차에 수동 좌석 → TICKET_NOT_APPROVED(매진 동기화로 노출되던 길)" "$r" "TICKET_NOT_APPROVED"
r=$(AS "$PT" "insert into public.reservation_invites(host_user_id,invitee_user_id,restaurant_id,visit_date,pax,total_amount,ticket_product_id) values ('$PT','$M1','$R1','2026.11.20',1,100000,'tpS');"); has "파트너 — 승인 대기 회차에 초대 → TICKET_NOT_APPROVED" "$r" "TICKET_NOT_APPROVED"
r=$(AS "$SU" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$SU','$R1','tpS','2026.11.20',2,'manual','MAN-su',0);"); has "슈퍼어드민도 승인 대기 회차에 수동 좌석은 못 넣는다(좌석이 차면 동기화가 soldout 으로 공개)" "$r" "TICKET_NOT_APPROVED"
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$PT','$R1','nope','2026.11.20',1,'manual','MAN-nf',0);"); has "없는 회차에 수동 좌석 → 거절(없는 회차·다른 매장 회차는 같은 답)" "$r" "TICKET_REST_MISMATCH"
Q "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp6p','$R2','사이토','pending','2026.12.11','19:00',6,900000);" >/dev/null
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$PT','$R1','tp6p','2026.12.11',1,'manual','MAN-hid',0);"); has "다른 매장의 승인 대기 회차(RLS 로 안 보임)에도 못 넣는다(definer 조회 · 없는 회차와 같은 답)" "$r" "TICKET_REST_MISMATCH"
ok "회원은 회차 검사 도우미에서 답을 못 받는다(숨은 회차 오라클 · 3차 리뷰)" "$(AS "$M1" "select coalesce(public._taam_tp_seat_check('tp6p','$R2'),'null')")" "null"
ok "승인된 파트너도 남의 매장 회차는 「bad」(존재를 안 알린다)" "$(AS "$PT" "select public._taam_tp_seat_check('tp6p','$R1')")" "bad"
r=$(AS "$M1" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$M1','$R2','tp6p','2026.12.11',1,'hold','PAYH-tp6p_1',900000);"); has "회원 — 숨은 승인 대기 회차 id 로 홀드를 넣어 승인 전 회차를 사는 길 → TICKET_NOT_APPROVED" "$r" "TICKET_NOT_APPROVED"
r=$(AS "$SU" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$SU','$R2','tp6p','2026.12.11',1,'hold','PAYH-tp6p_su',900000);"); has "회원 결제 행(PAYH-)은 슈퍼어드민이 넣어도 승인 대기 회차엔 못 넣는다(4차)" "$r" "TICKET_NOT_APPROVED"
Q "delete from public.tickets where purchase_id='PAYH-tp6p_su';" >/dev/null
Q "delete from public.ticket_products where id='tp6p';" >/dev/null
Q "update public.tickets set status='active' where purchase_id='PAYH-tpS_1'; update public.ticket_products set status='pending' where id='tpS';" >/dev/null
Q "set taam.uid=''; select 1;" >/dev/null
r=$(AS "$M2" "update public.tickets set party_size=2 where purchase_id='PAYH-tpS_1';")
ok "승인 대기 회차는 중첩 동기화가 와도 pending 을 지킨다(soldout 으로 안 바뀜 · 회원 세션)" "$(Q "select status from public.ticket_products where id='tpS'")" "pending"
r=$(AS "$SU" "update public.tickets set party_size=2 where purchase_id='PAYH-tpS_1';")
ok "슈퍼어드민 세션의 중첩 동기화도 pending 을 지킨다" "$(Q "select status from public.ticket_products where id='tpS'")" "pending"
Q "update public.tickets set party_size=2 where purchase_id='PAYH-tpS_1';" >/dev/null
ok "서버 세션의 중첩 동기화도 pending 을 지킨다" "$(Q "select status from public.ticket_products where id='tpS'")" "pending"
Q "update public.ticket_products set status='active' where id='tpS';" >/dev/null
Q "delete from public.tickets where purchase_id='PAYH-tpS_1'; delete from public.ticket_products where id='tpS';" >/dev/null   # 뒤 검사(기간·관계)에 안 남게
# E 초대
r=$(AS "$PT" "insert into public.reservation_invites(host_user_id,invitee_user_id,restaurant_id,visit_date,pax,total_amount,ticket_product_id) values ('$PT','$M1','$R1','2026.11.05',1,1,'tp2');"); has "초대 — 다른 매장 회차 연결 거절" "$r" "TICKET_REST_MISMATCH"
r=$(AS "$PT" "insert into public.reservation_invites(host_user_id,invitee_user_id,restaurant_id,visit_date,pax,total_amount,ticket_product_id) values ('$PT','$M1','$R1','2026.11.03',1,850000,'tp1');"); ok "초대 — 자기 매장 회차 OK" "$(echo "$r" | grep -c ERROR)" "0"
Q "insert into public.reservation_invites(id,host_user_id,invitee_user_id,restaurant_id,visit_date,pax,total_amount,ticket_product_id,status) values ('e1000000-0000-4000-8000-000000000001','$SU','$M1','$R1','2026.11.05',1,1,'tp2','sent');" >/dev/null
r=$(AS "$M1" "update public.reservation_invites set status='paid', paid_at=now() where id='e1000000-0000-4000-8000-000000000001';"); ok "옛 불일치 초대 — 회원의 결제 갱신은 막히지 않는다" "$(echo "$r" | grep -c ERROR)" "0"
r=$(AS "$PT" "insert into public.reservation_invites(host_user_id,invitee_user_id,restaurant_id,visit_date,pax,total_amount,ticket_product_id,status,paid_at) values ('$PT','$M2','$R1','2026.11.03',1,850000,'tp1','paid',now()) returning id;")
hid=$(echo "$r" | grep -Eo '[0-9a-f]{8}-[0-9a-f-]{27}' | head -1)
ok "초대 — host 가 넣은 'paid' 는 'sent' 로(paid_at 없음)" "$(Q "select status || '/' || (paid_at is null)::text from public.reservation_invites where id='$hid'")" "sent/true"
r=$(AS "$PT" "update public.reservation_invites set status='paid', paid_at=now() where id='$hid';"); has "초대 — host 는 paid 로 못 바꾼다" "$r" "INVITE_HOST_PAID_FORBIDDEN"
AS "$PT" "update public.reservation_invites set paid_at=now() where id='$hid';" >/dev/null
ok "초대 — host 는 paid_at 도 못 적는다(되돌림)" "$(Q "select (paid_at is null)::text from public.reservation_invites where id='$hid'")" "true"
Q "update public.reservation_invites set status='paid', paid_at=now() where id='$hid';" >/dev/null
AS "$PT" "update public.reservation_invites set invitee_user_id='$M1', total_amount=1, pax=9, ticket_product_id='tp2', restaurant_id='$R2' where id='$hid';" >/dev/null
ok "초대 — paid 줄의 받는 회원·금액·인원·회차·매장은 host 가 못 바꾼다(되돌림)" "$(Q "select (invitee_user_id='$M2')::text || '/' || total_amount || '/' || pax || '/' || ticket_product_id || '/' || (restaurant_id='$R1')::text from public.reservation_invites where id='$hid'")" "true/850000/1/tp1/true"
AS "$PT" "update public.reservation_invites set status='sent' where id='$hid';" >/dev/null
ok "초대 — paid 줄을 host 가 sent 로 되돌리지 못한다" "$(Q "select status from public.reservation_invites where id='$hid'")" "paid"
AS "$PT" "update public.reservation_invites set visit_time='20:00' where id='$hid';" >/dev/null
ok "초대 — host 의 시각 변경은 그대로" "$(Q "select visit_time from public.reservation_invites where id='$hid'")" "20:00"
AS "$PT" "update public.reservation_invites set status='cancelled', cancelled_at=now() where id='$hid';" >/dev/null
ok "초대 — host 의 취소는 그대로" "$(Q "select status from public.reservation_invites where id='$hid'")" "cancelled"
# F profiles
ok "파트너 — profiles 는 자기 행만" "$(AS "$PT" "select count(*) from public.profiles")" "1"
ok "전 칸 읽기 정책 없음" "$(Q "select count(*) from pg_policies where tablename='profiles' and policyname='profiles read by venue admin for requesters'")" "0"
# G 파트너 RPC
rv=$(AS "$PT" "select public.taam_partner_reservations('$R1')")
has "예약 목록 — 회원 이름·전화" "$rv" '"buyer": "회원일"'
has "예약 목록 — 전화" "$rv" '"phone": "010-1111-2222"'
no "예약 목록 — 남의 매장 행 없음" "$rv" 'PAYH-tp2_'
no "예약 목록 — 예치금 잔액 없음" "$rv" 'deposit_balance'
has "예약 목록 — 취소 건의 환불(예치금 550,000)" "$rv" '"refund_dep": 550000'
has "예약 목록 — 카드 환불 완료 300,000" "$rv" '"refund_card": 300000'
has "예약 목록 — 수동 좌석(손님 번호)" "$rv" '"phone": "010-9999-8888"'
no "예약 목록 — 수동 좌석에 어드민 uid 없음" "$(echo "$rv" | python3 -c "import json,sys;d=json.load(sys.stdin);print([r.get('uid') for r in d['rows'] if r['pid']=='MAN-1'])")" "$PT"
ok "예약 목록 — 이름 검색" "$(AS "$PT" "select jsonb_array_length(public.taam_partner_reservations('$R1', null, null, '회원일')->'rows')")" "3"
ok "예약 목록 — 번호 검색(9999)" "$(AS "$PT" "select jsonb_array_length(public.taam_partner_reservations('$R1', null, null, '9999')->'rows')")" "1"
ok "예약 목록 — 취소만" "$(AS "$PT" "select jsonb_array_length(public.taam_partner_reservations('$R1', null, null, null, 'cancelled')->'rows')")" "1"
ok "예약 목록 — 기간(11월 · 홀드 제외 3)" "$(AS "$PT" "select jsonb_array_length(public.taam_partner_reservations('$R1', '2026-11-01', '2026-12-01')->'rows')")" "3"
has "pending 파트너 — FORBIDDEN" "$(AS "$P3" "select public.taam_partner_reservations('$R1')")" "FORBIDDEN"
has "approved 파트너 — 남의 매장 FORBIDDEN" "$(AS "$PT" "select public.taam_partner_reservations('$R2')")" "FORBIDDEN"
mb=$(AS "$PT" "select public.taam_partner_member('$R1','$M1')")
has "회원 — 이름·전화·이메일·등급·국적" "$mb" '"nationality": "KR"'
has "회원 — 이메일" "$mb" '"email": "m1@x.kr"'
no "회원 — 예치금 잔액 없음" "$mb" 'balance'
no "회원 — 다른 매장 구매 없음" "$mb" 'PAYH-tp2_1'
has "회원 — 이 매장 방문 1 · 취소 1" "$(echo "$mb" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['stats']['visits'],d['stats']['cancels'],d['stats']['upcoming'])")" "1 1 1"
has "회원 — 이 매장에 예약 없으면 NOT_RELATED" "$(AS "$PT" "select public.taam_partner_member('$R1','$M2')")" "NOT_RELATED"
Q "insert into public.reservation_invites(id,host_user_id,invitee_user_id,restaurant_id,visit_date,pax,total_amount,ticket_product_id,status) values ('e1000000-0000-4000-8000-000000000002','$PT','$M2','$R1','2026.11.03',1,850000,'tp1','sent');" >/dev/null
has "회원 — 파트너가 초대를 보낸 것만으로는 관계가 아니다(명부 훑기)" "$(AS "$PT" "select public.taam_partner_member('$R1','$M2')")" "NOT_RELATED"
no "이름 채우기도 보낸 초대만으로는 안 준다" "$(AS "$PT" "select public.taam_partner_names('$R1', array['$M2']::uuid[])")" "회원이"
Q "update public.reservation_invites set status='paid', paid_at=now() where id='e1000000-0000-4000-8000-000000000002';" >/dev/null
has "회원 — status 'paid' 만으로는 관계가 아니다(host 가 적을 수 있던 칸 · 2차 리뷰)" "$(AS "$PT" "select public.taam_partner_member('$R1','$M2')")" "NOT_RELATED"
Q "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M2','membership','ticket_purchase',-850000,'{\"invite_id\":\"e1000000-0000-4000-8000-000000000002\",\"purchase_id\":\"INV-e1000000-x\"}');" >/dev/null
has "회원 — 받는 회원의 원장 결제 줄(서버만 쓰는 표)이 있으면 관계" "$(AS "$PT" "select public.taam_partner_member('$R1','$M2')")" '"name": "회원이"'
Q "delete from public.deposit_transactions where user_id='$M2' and change_type='ticket_purchase';" >/dev/null
Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price,extra_data) values ('$M2','$R1','tp1','2026.11.03',1,'active','INV-e1000000-1',850000,'{\"inviteId\":\"e1000000-0000-4000-8000-000000000002\"}');" >/dev/null
has "회원 — 그 초대의 INV- 좌석 행(확정 RPC 가 만든다)이 있으면 관계" "$(AS "$PT" "select public.taam_partner_member('$R1','$M2')")" '"name": "회원이"'
Q "delete from public.tickets where purchase_id='INV-e1000000-1';" >/dev/null
has "회원 — 증거를 지우면 다시 NOT_RELATED" "$(AS "$PT" "select public.taam_partner_member('$R1','$M2')")" "NOT_RELATED"
Q "update public.reservation_invites set status='cancelled' where id='e1000000-0000-4000-8000-000000000002';" >/dev/null
has "회원 검색 — 이 매장 회원만(회원이 는 사이토만)" "$(AS "$PT" "select public.taam_partner_member_search('$R1','회원')")" '"display_name": "회원일"'
no "회원 검색 — 다른 매장 회원 안 나옴" "$(AS "$PT" "select public.taam_partner_member_search('$R1','회원')")" '회원이'
has "회원 검색 — 번호로" "$(AS "$PT" "select public.taam_partner_member_search('$R1','1111')")" '회원일'
ok "회원 검색 — 두 글자 미만은 빈 배열" "$(AS "$PT" "select public.taam_partner_member_search('$R1','회')")" "[]"
ex=$(AS "$PT" "select public.taam_partner_member_search('$R1','010-3333-4444')")
has "회원 검색 — 다른 매장 회원도 번호 전체(10자리)를 정확히 치면 나온다(단골 초대)" "$ex" '회원이'
no "회원 검색 — 번호로만 찾은 다른 매장 회원은 이메일·국적이 없다" "$ex" 'm2@x.kr'
has "회원 검색 — related:false 표시" "$ex" '"related": false'
has "회원 검색 — 이 매장 회원은 이메일·통화까지(related:true)" "$(AS "$PT" "select public.taam_partner_member_search('$R1','회원일')")" '"email": "m1@x.kr"'
has "회원 검색 — +82 10 3333 4444 도 같은 번호" "$(AS "$PT" "select public.taam_partner_member_search('$R1','+82 10 3333 4444')")" '회원이'
ok "회원 검색 — 번호 일부(8자리)로는 다른 매장 회원이 안 나온다" "$(AS "$PT" "select public.taam_partner_member_search('$R1','10-3333-44')")" "[]"
for i in $(seq 1 30); do AS "$PT" "select public.taam_partner_member_search('$R1','010-3333-4444')" >/dev/null; done
ok "회원 검색 — 번호 정확 일치는 파트너마다 시간당 30번(넘으면 빈 배열 · 번호 목록으로 회원인지 훑는 오라클)" "$(AS "$PT" "select public.taam_partner_member_search('$R1','010-3333-4444')")" "[]"
has "회원 검색 — 상한 뒤에도 이 매장 회원 검색은 그대로" "$(AS "$PT" "select public.taam_partner_member_search('$R1','회원일')")" '회원일'
has "회원 검색 — 상한 뒤 이 매장 회원은 번호 전체로도 그대로(관계 회원은 상한과 무관)" "$(AS "$PT" "select public.taam_partner_member_search('$R1','010-1111-2222')")" '회원일'
ok "회원 검색 — 10자리 이상 조회는 맞든 틀리든 센다(틀린 번호 훑기도 공짜가 아니다) · 짧은 조회는 안 센다" "$(Q "select count(*) from public._rl where k like 'partner_phone_lookup:%'")" "34"
ok "회원 검색은 volatile(상한을 적는다 · stable 이면 PostgREST READ ONLY 에서 INSERT 가 터진다)" "$(Q "select provolatile from pg_proc where oid = to_regprocedure('public.taam_partner_member_search(text, text)')")" "v"
r=$($P -c "begin isolation level read committed read only; set local role authenticated; set local taam.uid='$PT'; select public.taam_partner_member_search('$R1','회원일'); rollback;" 2>&1); has "읽기 전용 트랜잭션에서도 이름 검색은 된다" "$r" "회원일"
nm=$(AS "$PT" "select public.taam_partner_names('$R1', array['$M1','$M2']::uuid[])")
has "이름 채우기 — 이 매장 회원 이름" "$nm" '"display_name": "회원일"'
no "이름 채우기 — 다른 매장 회원은 빠진다" "$nm" '회원이'
no "이름 채우기 — 잔액 없음" "$nm" 'balance'
has "이름 채우기 — pending 파트너 FORBIDDEN" "$(AS "$P3" "select public.taam_partner_names('$R1', array['$M1']::uuid[])")" "FORBIDDEN"
ok "이름 채우기 — 빈 배열" "$(AS "$PT" "select public.taam_partner_names('$R1', array[]::uuid[])")" "[]"
has "내 권한 — approved" "$(AS "$PT" "select public.taam_partner_my_grants()")" '"status": "approved"'
has "내 권한 — rest_id 와 venue_id 를 따로(venue 전용 줄이 티켓 매장으로 올라가지 않게)" "$(AS "$PT" "select public.taam_partner_my_grants()")" "\"rest_id\": \"$R1\""
no "내 권한 — 운영 메모(note)는 안 준다" "$(AS "$P3" "select public.taam_partner_my_grants()")" 'note'
ok "taam_rest_admin_ok_for 는 회원이 못 부른다" "$(Q "select has_function_privilege('authenticated','public.taam_rest_admin_ok_for(uuid, text)','execute')")" "f"
has "내 권한 — pending 도 보인다(화면이 「승인 대기」를 말한다)" "$(AS "$P3" "select public.taam_partner_my_grants()")" '"status": "pending"'
# H
has "슈퍼어드민 목록 — pending 먼저" "$(AS "$SU" "select (public.taam_partner_grants_list()->0)->>'status'")" "pending"
has "파트너는 목록 FORBIDDEN" "$(AS "$PT" "select public.taam_partner_grants_list()")" "FORBIDDEN"
has "파트너는 상태 변경 FORBIDDEN" "$(AS "$PT" "select public.taam_partner_grant_set('$P3','$R1','approved')")" "FORBIDDEN"
AS "$SU" "select public.taam_partner_grant_set('$P3','$R1','approved','확인함');" >/dev/null
ok "승인 → approved · 도장" "$(Q "select status || '/' || (approved_by='$SU')::text from public.admin_grants where user_id='$P3'")" "approved/true"
ok "승인 알림 → 파트너" "$(Q "select count(*) from public.notifications where user_id='$P3' and type='partner_grant' and payload->>'status'='approved'")" "1"
ok "승인 뒤 — 판정 true" "$(AS "$P3" "select public.taam_rest_admin_ok('$R1')")" "t"
AS "$SU" "select public.taam_partner_grant_set('$P3','$R1','suspended','정지');" >/dev/null
ok "정지 → 판정 false · 티켓 안 보임" "$(AS "$P3" "select public.taam_rest_admin_ok('$R1')::text || '/' || (select count(*) from public.tickets)")" "false/0"
r=$(AS "$PT" "update public.admin_grants set status='approved' where user_id='$P3';"); ok "파트너가 남의 상태를 못 바꾼다(RLS 0행)" "$(Q "select status from public.admin_grants where user_id='$P3'")" "suspended"
ok "정지 때 prev_status 에 직전 상태(approved)" "$(Q "select prev_status from public.admin_grants where user_id='$P3'")" "approved"
ok "RPC 정지 → suspended_via 'rpc'(계정 되살리기가 안 건드린다)" "$(Q "select suspended_via from public.admin_grants where user_id='$P3'")" "rpc"
AS "$SU" "update public.admin_grants set approved_by='$M1', status='approved' where user_id='$P3';" >/dev/null
ok "도장은 트리거가 찍는다(로그인 호출은 보낸 approved_by 무시)" "$(Q "select (approved_by='$SU')::text || '/' || coalesce(prev_status,'-') from public.admin_grants where user_id='$P3'")" "true/-"
AS "$SU" "select public.taam_partner_grant_set('$P3','$R1','pending','철회');" >/dev/null
ok "「대기로」 = 승인 철회 — approved_at·by 비움" "$(Q "select status || '/' || (approved_at is null)::text || '/' || (approved_by is null)::text from public.admin_grants where user_id='$P3'")" "pending/true/true"
Q "update public.admin_grants set status='suspended', suspended_via='account' where user_id='$P3' and status <> 'suspended';" >/dev/null
ok "서버(Edge revoke 모양) 정지 → prev_status pending (되살리기는 pending 으로 돌아간다)" "$(Q "select prev_status from public.admin_grants where user_id='$P3'")" "pending"
ok "Edge 계정 해지는 suspended_via 'account' 를 같은 UPDATE 로 보낸다 — 받아 적힌다" "$(Q "select suspended_via from public.admin_grants where user_id='$P3'")" "account"
Q "update public.admin_grants set suspended_via='rpc' where user_id='$P3';" >/dev/null
ok "정지된 채 suspended_via 만 바꾸는 UPDATE 는 무시(도장은 상태가 바뀔 때만)" "$(Q "select suspended_via from public.admin_grants where user_id='$P3'")" "account"
Q "update public.admin_grants set status='approved', approved_by='$SU', status_set_by='$SU' where user_id='$P3';" >/dev/null
ok "서버 호출(auth.uid() null)은 보낸 approved_by·status_set_by 를 받는다(Edge 감사 칸)" "$(Q "select (approved_by='$SU')::text || '/' || (status_set_by='$SU')::text from public.admin_grants where user_id='$P3'")" "true/true"
ok "정지가 풀리면 suspended_via·prev_status 비움" "$(Q "select coalesce(suspended_via,'-') || '/' || coalesce(prev_status,'-') from public.admin_grants where user_id='$P3'")" "-/-"
# J — 직접 조회를 품은 라이브 함수 · storage 정책
AS "$SU" "select public.taam_partner_grant_set('$P3','$R1','suspended','정지');" >/dev/null
has "J — 정지된 파트너는 정산 좌석 RPC(직접 조회 판)도 FORBIDDEN 으로(본문 교체)" "$(AS "$P3" "select public.taam_ksk_seat_rows('$R1')")" "어드민만"
ok "J — 승인된 파트너는 그대로 통과" "$(AS "$PT" "select public.taam_ksk_seat_rows('$R1')")" "ok"
has "J — 결제 링크 만들기(직접 조회 판)도 정지 파트너는 거절" "$(AS "$P3" "select public.taam_link_invite_create('tp1')")" "권한이 없습니다"
ok "J — 승인된 파트너의 결제 링크 만들기 통과" "$(AS "$PT" "select public.taam_link_invite_create('tp1')")" "ok"
ok "J — 본문에 직접 조회가 남지 않았다" "$(Q "select count(*) from pg_proc where proname in ('taam_ksk_seat_rows','taam_link_invite_create') and prosrc like '%from public.admin_grants%'")" "0"
r=$(AS "$P3" "insert into storage.objects(bucket_id,name,owner) values ('restaurant-videos','x.mp4','$P3');"); ok "J — storage 정책: 정지 파트너 거절" "$(echo "$r" | grep -c "ERROR")" "1"
r=$(AS "$PT" "insert into storage.objects(bucket_id,name,owner) values ('restaurant-videos','y.mp4','$PT');"); ok "J — storage 정책: 승인 파트너 통과" "$(echo "$r" | grep -c "ERROR")" "0"
AS "$SU" "select public.taam_partner_grant_set('$P3','$R1','approved','복구');" >/dev/null
# 알림 속도 제한 — 파트너가 pending 을 지우고 다시 넣어 알림함을 채우는 길
before=$(Q "select count(*) from public.notifications where user_id='$SU' and type='ticket_upload_request'")
rl0=$(Q "select count(*) from public._rl where k='tp_approval_notify:$PT'")
for i in $(seq 1 35); do AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('spam$i','$R1','메이노','pending','2026.12.0$((i%9+1))','19:00',6,900000);" >/dev/null; done
after=$(Q "select count(*) from public.notifications where user_id='$SU' and type='ticket_upload_request'")
exp=$((30-rl0)); [ $exp -gt 35 ] && exp=35; [ $exp -lt 0 ] && exp=0
ok "업로드 알림은 파트너마다 시간당 30건까지(35건 올려도 알림은 상한만큼 · 업로드는 전부)" "$((after-before))/$(Q "select count(*) from public.ticket_products where id like 'spam%'")" "$exp/35"
ok "속도 제한 열쇠는 파트너별(호출 35번 기록)" "$(( $(Q "select count(*) from public._rl where k='tp_approval_notify:$PT'") - rl0 ))" "35"
# ── 3차 리뷰 반영(2026-10-29)
# 판매 오픈은 내용 칸 — 승인 전엔 바로 · 승인 뒤엔 큐
AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tpSS','$R1','메이노','pending','2026.12.24','19:00',6,900000);" >/dev/null
AS "$PT" "update public.ticket_products set sale_state='draft', sale_open_at=null where id='tpSS';" >/dev/null
ok "판매 오픈 — 승인 전 회차의 「비공개 보관」은 남는다(되돌리면 승인 순간 바로 판매됐다)" "$(Q "select coalesce(sale_state,'-') from public.ticket_products where id='tpSS'")" "draft"
AS "$SU" "update public.ticket_products set status='active' where id='tpSS';" >/dev/null
AS "$PT" "update public.ticket_products set sale_state='open' where id='tpSS';" >/dev/null
ok "판매 오픈 — 승인된 회차에선 큐로(바로 공개되지 않는다)" "$(Q "select coalesce(sale_state,'-') from public.ticket_products where id='tpSS'")/$(EQ tpSS)" "draft/{\"sale_state\": \"open\"}"
Q "delete from public.ticket_product_edits where ticket_id='tpSS';" >/dev/null
AS "$PT" "update public.ticket_products set sale_state='open', sale_open_at=null where id='tp4';" >/dev/null
ok "판매 오픈 — 서버 null 과 앱의 'open' 은 같다(매진 토글의 뒤따르는 저장이 수정 신청을 만들지 않는다)" "$(EQ tp4)" "-"
# 수정 신청 저장(교체) — 되돌리면 빠지고 · 차이가 없으면 지운다
r=$(AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 990000, \"wine_min\": 50000, \"status\": \"pending\", \"approved_by\": \"$PT\", \"repurchase_open\": true}'::jsonb)"); has "submit — 승인된 회차의 차이만 큐에" "$r" '"queued": true'
ok "submit — 큐 = 이번 폼의 차이(상태·도장·되돌림 칸은 버린다) · 행은 그대로" "$(EQ tp4)/$(Q "select status || '/' || price || '/' || coalesce(repurchase_open,false) from public.ticket_products where id='tp4'")" "{\"price\": 990000}/active/950000/false"
AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 990000, \"meal_fee\": 10}'::jsonb)" >/dev/null
ok "submit — 다시 저장하면 합치지 않고 교체" "$(EQ tp4)" "{\"price\": 990000, \"meal_fee\": 10}"
AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 950000, \"meal_fee\": 10}'::jsonb)" >/dev/null
ok "submit — 값을 원래대로 되돌리면 그 칸은 큐에서 빠진다(3차 리뷰 재현)" "$(EQ tp4)" "{\"meal_fee\": 10}"
has "submit — 바뀐 칸이 없으면 큐를 지운다(신청 거두기)" "$(AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": \"950000\", \"meal_fee\": null}'::jsonb)")" '"cleared": true'
ok "submit — 큐 없음(숫자 글자 '950000' 도 칸 타입으로 견준다)" "$(EQ tp4)" "-"
AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tpPP','$R1','메이노','pending','2026.12.25','19:00',6,900000);" >/dev/null
has "submit — 승인 전 회차는 ROUND_PENDING(바로 고친다)" "$(AS "$PT" "select public.taam_ticket_edit_submit('tpPP', '{\"price\": 1}'::jsonb)")" "ROUND_PENDING"
has "submit — 남의 매장 회차 NOT_YOUR_RESTAURANT" "$(AS "$PT" "select public.taam_ticket_edit_submit('tp2', '{\"price\": 1}'::jsonb)")" "NOT_YOUR_RESTAURANT"
has "submit — 회원 NOT_YOUR_RESTAURANT" "$(AS "$M1" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 1}'::jsonb)")" "NOT_YOUR_RESTAURANT"
has "submit — 매장을 바꾸려 하면 NOT_YOUR_RESTAURANT" "$(AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"rest_id\": \"$R2\", \"price\": 1}'::jsonb)")" "NOT_YOUR_RESTAURANT"
Q "select public.taam_partner_grant_set('$P3','$R1','suspended');" >/dev/null
has "submit — 정지된 파트너 NOT_YOUR_RESTAURANT" "$(AS "$P3" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 1}'::jsonb)")" "NOT_YOUR_RESTAURANT"
ok "submit — 정지된 파트너의 시도는 큐에 안 남는다" "$(EQ tp4)" "-"
has "submit — 상한(글자 2,000자) EDIT_TOO_LONG" "$(AS "$PT" "select public.taam_ticket_edit_submit('tp4', jsonb_build_object('ticket_type', repeat('a',2001)))")" "EDIT_TOO_LONG"
has "submit — 칸 타입에 안 맞는 값은 오류" "$(AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": \"abc\"}'::jsonb)")" "invalid input syntax"
# 수정 승인 — 낡은 화면 · 이미 같은 값 · 설명 번역 상태
AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 970000}'::jsonb)" >/dev/null
AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 970000, \"total_pax\": 80}'::jsonb)" >/dev/null
has "수정 승인 — 화면이 본 큐(p_expect)와 지금 큐가 다르면 STALE_EDIT(파트너가 그 사이 칸을 더했다 · 3차 리뷰 재현)" "$(AS "$SU" "select public.taam_ticket_edit_review('tp4', true, null, '{\"price\": 970000}'::jsonb)")" "STALE_EDIT"
ok "STALE 뒤 값·큐 그대로" "$(Q "select price || '/' || total_pax from public.ticket_products where id='tp4'")/$(EQ tp4)" "950000/6/{\"price\": 970000, \"total_pax\": 80}"
AS "$SU" "update public.ticket_products set price=970000 where id='tp4';" >/dev/null
r=$(AS "$SU" "select public.taam_ticket_edit_review('tp4', true, null, '{\"price\": 970000, \"total_pax\": 80}'::jsonb)")
has "수정 승인 — 지금 값과 같은 칸은 건너뛴다(applied_fields 는 total_pax 만)" "$r" '"applied_fields": \["total_pax"\]'
ok "수정 승인 — 값 반영 · 큐 비움" "$(Q "select price || '/' || total_pax from public.ticket_products where id='tp4'")/$(EQ tp4)" "970000/80/-"
Q "update public.ticket_products set ticket_desc='옛 설명', i18n_status_en='done', i18n_status_jp='done' where id='tp4';" >/dev/null
AS "$PT" "update public.ticket_products set ticket_desc='새 설명', i18n_status_en='pending', i18n_status_jp='pending' where id='tp4';" >/dev/null
ok "설명 수정이 큐로 가면 같은 저장의 번역 상태(pending)도 되돌린다(옛 설명을 번역하지 않게)" "$(Q "select ticket_desc || '/' || i18n_status_en || '/' || i18n_status_jp from public.ticket_products where id='tp4'")/$(EQ tp4)" "옛 설명/done/done/{\"ticket_desc\": \"새 설명\"}"
AS "$SU" "select public.taam_ticket_edit_review('tp4', true);" >/dev/null
ok "설명 수정 승인 → 번역 상태 pending(옛 번역이 새 설명 옆에 남지 않게)" "$(Q "select ticket_desc || '/' || i18n_status_en || '/' || i18n_status_jp from public.ticket_products where id='tp4'")" "새 설명/pending/pending"
# 운영 행으로는 관계가 안 된다 — 슈퍼어드민의 수동 좌석
Q "update public.profiles set phone='010-7777-0001' where id='$SU';" >/dev/null
Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price,buyer_name,buyer_phone,extra_data) values ('$SU','$R1','tp1','2026.11.03',1,'manual','MAN-su1',0,'손님삼','010-5555-0000','{\"manualEntry\":true}');" >/dev/null
has "운영 행(슈퍼어드민의 수동 좌석)으로는 「관계」가 안 된다 — 슈퍼어드민 연락처 안 줌(3차 리뷰 재현)" "$(AS "$PT" "select public.taam_partner_member('$R1','$SU')")" "NOT_RELATED"
no "이름 채우기 — 운영 행의 어드민은 빠진다" "$(AS "$PT" "select public.taam_partner_names('$R1', array['$SU']::uuid[])")" "010-7777-0001"
Q "select public.taam_partner_grant_set('$P3','$R1','approved');" >/dev/null
no "회원 검색 — 어드민 계정은 번호를 끝까지 쳐도 안 나온다" "$(AS "$P3" "select public.taam_partner_member_search('$R1','010-7777-0001')")" "운영"
rv2=$(AS "$PT" "select public.taam_partner_reservations('$R1')")
has "예약 목록 — 운영 행의 이름·번호는 손님 것" "$rv2" "010-5555-0000"
no "예약 목록 — 슈퍼어드민 번호 없음" "$rv2" "010-7777-0001"
ok "예약 목록 — 슈퍼어드민 이름(운영)으로 검색해도 운영 행이 안 걸린다 · 손님 이름으로는 걸린다" "$(AS "$PT" "select jsonb_array_length(public.taam_partner_reservations('$R1', null, null, '운영')->'rows')")/$(AS "$PT" "select jsonb_array_length(public.taam_partner_reservations('$R1', null, null, '손님삼')->'rows')")" "0/1"
Q "delete from public.tickets where purchase_id='MAN-su1';" >/dev/null
# 운영 메모(note) — 파트너는 표에서 직접 못 읽는다
has "파트너는 admin_grants.note 를 직접 못 읽는다(칸 권한 · 3차 리뷰 재현)" "$(AS "$PT" "select note from public.admin_grants")" "permission denied"
ok "파트너는 자기 줄의 매장·상태는 읽는다(앱 폴백 그대로)" "$(AS "$PT" "select status from public.admin_grants where user_id='$PT'")" "approved"
has "슈퍼어드민의 목록 RPC 는 note 를 준다(정의자 권한)" "$(AS "$SU" "select public.taam_partner_grants_list()")" '"note"'
# ── 4차 리뷰 반영(2026-10-29)
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tpX1','$R1','메이노','pending','2026.12.26','<img src=x onerror=alert(1)>',6,900000);"); has "입력 검사 — 시각 칸에 HTML(저장형 XSS · 4차 리뷰 재현) → BAD_INPUT" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('x''+alert(1)+''','$R1','메이노','pending','2026.12.26','19:00',6,900000);"); has "입력 검사 — id 에 따옴표(onclick 탈출) → BAD_INPUT" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price,ticket_desc) values ('tpX2','$R1','메이노','pending','2026.12.26','19:00',6,900000,'좋아요 <script>x</script>');"); has "입력 검사 — 설명에 태그 → BAD_INPUT" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price,ticket_desc,slots) values ('tpX3','$R1','메이노','pending','2026.12.26','19:00',6,900000,'<주의> 1인 2병 · 5<6','{\"s1\":2,\"note\":\"ok\"}');"); ok "입력 검사 — 한글 꺾쇠·부등호는 그대로" "$(echo "$r" | grep -c ERROR)" "0"
r=$(AS "$PT" "update public.ticket_products set slots='{\"s1\":2,\"note\":\"<svg/onload=x>\"}'::jsonb where id='tpX3';"); has "입력 검사 — jsonb 안쪽 글자도 본다" "$r" "BAD_INPUT"
AS "$PT" "update public.ticket_products set price=910000, updated_at='2020-01-01' where id='tpX3';" >/dev/null
ok "파트너 쓰기의 updated_at 은 서버가 적는다(옛 값을 보내 「그 사이 바뀌었나」 대조를 비켜 가던 길)" "$(Q "select (updated_at > now() - interval '1 minute')::text from public.ticket_products where id='tpX3'")" "true"
Q "update public.ticket_products set time='19시' where id='tpX3';" >/dev/null
r=$(AS "$PT" "update public.ticket_products set status='pending', price=920000 where id='tpX3';"); ok "입력 검사 — 바뀐 칸만 본다(옛 모양의 시각이 남은 행도 다른 칸은 고친다)" "$(echo "$r" | grep -c ERROR)/$(Q "select price from public.ticket_products where id='tpX3'")" "0/920000"
Q "delete from public.ticket_products where id='tpX3';" >/dev/null
# 수정 신청 저장 — 폼이 본 큐와 다르면 STALE
AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 990000}'::jsonb, '{}'::jsonb)" >/dev/null
ok "submit p_expect — 큐가 없을 때 {} 로 열린 폼은 저장된다" "$(EQ tp4)" "{\"price\": 990000}"
has "submit p_expect — 신청 값 없이 열린 폼({})이 앞 신청을 지우려 하면 STALE_EDIT(4차 리뷰 재현)" "$(AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"meal_fee\": 10}'::jsonb, '{}'::jsonb)")" "STALE_EDIT"
ok "STALE 뒤 큐 그대로" "$(EQ tp4)" "{\"price\": 990000}"
AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 990000, \"meal_fee\": 10}'::jsonb, '{\"price\": 990000}'::jsonb)" >/dev/null
ok "submit p_expect — 본 큐와 같으면 교체" "$(EQ tp4)" "{\"price\": 990000, \"meal_fee\": 10}"
has "submit — 칸에 태그 → BAD_INPUT" "$(AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"ticket_desc\": \"<img src=x>\"}'::jsonb)")" "BAD_INPUT"
AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"price\": 970000, \"guest_price\": 1, \"guest_opened_by\": \"$PT\"}'::jsonb)" >/dev/null
ok "submit — 게스트석·도장 칸은 버린다(파트너가 큐로 위조하던 길)" "$(EQ tp4)/$(Q "select coalesce(guest_price::text,'-') from public.ticket_products where id='tp4'")" "-/-"
AS "$PT" "update public.ticket_products set guest_price=1 where id='tp4';" >/dev/null
ok "직접 UPDATE 의 게스트가도 되돌린다" "$(Q "select coalesce(guest_price::text,'-') from public.ticket_products where id='tp4'")/$(EQ tp4)" "-/-"
Q "update public.ticket_products set slots='{\"mode\":\"flex\",\"s1\":2}' where id='tp4';" >/dev/null
AS "$PT" "select public.taam_ticket_edit_submit('tp4', '{\"slots\": {\"mode\":\"flex\",\"s1\":2,\"strict\":false,\"s4\":0}}'::jsonb)" >/dev/null
ok "submit — 객체의 빈 값 키(strict:false · 0)는 없는 것과 같다(바뀐 것 없는 저장이 수정 신청이 되던 것)" "$(EQ tp4)" "-"
# 권한 상태가 같으면 알림·메모를 안 건드린다
n0=$(Q "select count(*) from public.notifications where user_id='$P3' and type='partner_grant'")
r=$(AS "$SU" "select public.taam_partner_grant_set('$P3','$R1','approved','덮어쓰기')")
has "grant_set — 같은 상태면 changed:false" "$r" '"changed": false'
ok "grant_set — 같은 상태면 알림·메모 그대로" "$(( $(Q "select count(*) from public.notifications where user_id='$P3' and type='partner_grant'") - n0 ))/$(Q "select coalesce(note,'-') from public.admin_grants where user_id='$P3'")" "0/복구"
# 승인 대기 회차의 결제 행 — 서버 카드 확정 폴백(PAYC-)도 막는다 · 운영 행은 서버면 그대로 · UPDATE 로 옮기는 것도
r=$(Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$M1','$R1','tpPP','2026.12.25',1,'active','PAYC-x1',900000);"); has "서버(카드 확정 폴백)의 PAYC- 도 승인 대기 회차엔 못 넣는다(4차 리뷰 재현)" "$r" "TICKET_NOT_APPROVED"
r=$(Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$SU','$R1','tpPP','2026.12.25',1,'active','KSK-x1',0);"); ok "서버의 운영 행(KSK-)은 그대로" "$(echo "$r" | grep -c ERROR)" "0"
Q "delete from public.tickets where purchase_id='KSK-x1';" >/dev/null
AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$PT','$R1','tp1','2026.11.03',1,'manual','MAN-mv',0);" >/dev/null
r=$(AS "$PT" "update public.tickets set ticket_product_id='tpPP' where purchase_id='MAN-mv';"); has "UPDATE 로 승인 대기 회차로 옮기는 것도 막는다" "$r" "TICKET_NOT_APPROVED"
Q "update public.tickets set status='cancelled' where purchase_id='MAN-mv';" >/dev/null
r=$(AS "$PT" "update public.tickets set ticket_product_id='tpPP', status='manual' where purchase_id='MAN-mv';"); has "취소된 행을 승인 대기 회차로 되살리는 것도" "$r" "TICKET_NOT_APPROVED"
r=$(AS "$PT" "update public.tickets set buyer_name='메모만' where purchase_id='MAN-mv';"); ok "그 밖의 갱신(메모 등)은 그대로" "$(echo "$r" | grep -c ERROR)" "0"
Q "delete from public.tickets where purchase_id='MAN-mv'; delete from public.ticket_products where id='tpPP';" >/dev/null
# 예약 목록 — 어드민 계정의 시험 구매에 그 사람 연락처를 안 붙인다
Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price,buyer_name) values ('$SU','$R1','tp1','2026.11.03',1,'active','PAYH-sutest',850000,'시험');" >/dev/null
no "예약 목록 — 슈퍼어드민의 시험 구매에 슈퍼어드민 번호 없음(4차 리뷰)" "$(AS "$PT" "select public.taam_partner_reservations('$R1')")" "010-7777-0001"
Q "delete from public.tickets where purchase_id='PAYH-sutest';" >/dev/null
# ── 5차 리뷰 반영(2026-10-29) — 그 밖의 표 글자 검사 · 업로드 기본값 · 어드민 시험 구매
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,visit_time,party_size,status,purchase_id,price) values ('$PT','$R1','tp1','2026.11.03','<img src=x onerror=alert(1)>',1,'manual','MAN-xs1',0);"); has "수동 좌석 — 시각 칸 HTML(슈퍼어드민 캘린더 저장형 XSS · 5차 리뷰 재현) → BAD_INPUT" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price) values ('$PT','$R1','tp1','2026.11.03',1,'manual','MAN-x'');alert(1);//',0);"); has "수동 좌석 — 구매 id 따옴표(onclick 탈출) → BAD_INPUT" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price,buyer_name) values ('$PT','$R1','tp1','2026.11.03',1,'manual','MAN-xs2',0,'<svg onload=x>');"); has "수동 좌석 — 손님 이름 태그 → BAD_INPUT" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price,buyer_name,extra_data) values ('$PT','$R1','tp1','2026.11.03',1,'manual','MAN-xs3',0,'손님<주의>','{\"memo\":\"<b>굵게</b>\"}');"); has "수동 좌석 — extra_data 안쪽 태그 → BAD_INPUT" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.reservation_invites(host_user_id,invitee_user_id,restaurant_id,restaurant_name,visit_date,visit_time,pax,total_amount,ticket_product_id) values ('$PT','$M1','$R1','<img src=x onerror=alert(1)>','2026.11.03','19:00',1,850000,'tp1');"); has "초대 — 매장 이름 HTML(회원 초대 결제 팝업 저장형 XSS · 5차 리뷰 재현) → BAD_INPUT" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.daegwan_manual(rest_id,name,memo) values ('$R1','손님','<script>x</script>');"); has "수동 기록 — 메모 태그 → BAD_INPUT" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.daegwan_manual(rest_id,name,memo) values ('$R1','손님 <A코스>','창가 [VIP] 5<6');"); has "수동 기록 — 영문 꺾쇠는 막고" "$r" "BAD_INPUT"
r=$(AS "$PT" "insert into public.daegwan_manual(rest_id,name,memo) values ('$R1','손님','<주의> 창가 [A코스] 5<6');"); ok "수동 기록 — 한글 꺾쇠·대괄호·부등호는 그대로" "$(echo "$r" | grep -c ERROR)" "0"
r=$(AS "$SU" "insert into public.daegwan_manual(rest_id,name,memo) values ('$R1','운영','<b>슈퍼어드민</b>');"); ok "슈퍼어드민은 검사 밖" "$(echo "$r" | grep -c ERROR)" "0"
Q "update public.tickets set extra_data = extra_data || '{\"admin_memo\":\"<b>옛 메모</b>\"}'::jsonb where purchase_id='PAYH-tp1_1';" >/dev/null
r=$(AS "$M1" "update public.tickets set status='cancelled', extra_data = extra_data || '{\"cancel_reason\":\"회원 취소\"}'::jsonb where purchase_id='PAYH-tp1_1';"); ok "옛 글자(슈퍼어드민이 적은 태그)가 남은 행도 회원의 취소는 그대로(새로 생긴 글자만 본다)" "$(echo "$r" | grep -c ERROR)/$(Q "select status from public.tickets where purchase_id='PAYH-tp1_1'")" "0/cancelled"
Q "update public.tickets set status='active' where purchase_id='PAYH-tp1_1';" >/dev/null
r=$(AS "$M1" "update public.tickets set extra_data = extra_data || '{\"x\":\"<img src=x>\"}'::jsonb where purchase_id='PAYH-tp1_1';"); has "회원이 자기 행에 새 태그를 넣으면 BAD_INPUT" "$r" "BAD_INPUT"
# 업로드(INSERT) — 게스트석·도장 칸은 기본값으로
AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price,guest_price,guest_opened_by) values ('tpG1','$R1','메이노','pending','2026.12.27','19:00',6,900000,1,'$SU');" >/dev/null
ok "업로드 — 게스트가·연 사람 칸은 기본값으로(위조한 게스트석이 승인과 함께 열리던 길 · 5차 리뷰 재현)" "$(Q "select coalesce(guest_price::text,'-') || '/' || coalesce(guest_opened_by::text,'-') from public.ticket_products where id='tpG1'")" "-/-"
Q "delete from public.ticket_products where id='tpG1';" >/dev/null
# 어드민 계정의 회원 모양 구매 — 손님 칸(자기가 적은 연락처)도 안 준다
Q "insert into public.tickets(user_id,restaurant_id,ticket_product_id,reservation_date,party_size,status,purchase_id,price,buyer_name,buyer_phone) values ('$SU','$R1','tp1','2026.11.03',1,'active','PAYH-sutest2',850000,'운영자','010-7777-0001');" >/dev/null
rv3=$(AS "$PT" "select public.taam_partner_reservations('$R1')")
no "예약 목록 — 어드민 계정의 시험 구매는 손님 칸 번호도 안 준다(5차 리뷰)" "$rv3" "010-7777-0001"
has "예약 목록 — 그 줄은 「(운영 계정)」" "$rv3" "(운영 계정)"
ok "예약 목록 — 그 번호로 검색해도 안 걸린다" "$(AS "$PT" "select jsonb_array_length(public.taam_partner_reservations('$R1', null, null, '7777-0001')->'rows')")" "0"
Q "delete from public.tickets where purchase_id='PAYH-sutest2';" >/dev/null
# I
ok "_taam_auth_email — 남의 것 null" "$(AS "$M1" "select coalesce(public._taam_auth_email('$M2'),'-')")" "-"
ok "_taam_auth_email — 본인" "$(AS "$M1" "select public._taam_auth_email('$M1')")" "m1@x.kr"
ok "_taam_auth_email — 슈퍼어드민" "$(AS "$SU" "select public._taam_auth_email('$M2')")" "m2@x.kr"
ok "taam_user_tier anon 회수" "$(Q "select has_function_privilege('anon','public.taam_user_tier(uuid)','execute')")" "f"
# ── 보안 점검 반영(2026-10-29) — _taam_auth_email 비로그인 · 회원 이름 글자 검사
has "_taam_auth_email — 비로그인(anon) 실행 권한 없음(PostgREST 의 anon 도 auth.uid() 가 null 이라 「서버」로 읽히던 길)" "$($P -c "set role anon; select public._taam_auth_email('$M2');" 2>&1)" "permission denied"
ok "_taam_auth_email — JWT 역할이 anon 이면 서버로 안 본다(null)" "$(Q "select set_config('request.jwt.claims','{\"role\":\"anon\"}',false); select coalesce(public._taam_auth_email('$M2'),'-');" | tail -1)" "-"
ok "_taam_auth_email — 서버(JWT 없음 · SQL Editor)는 그대로" "$(Q "select public._taam_auth_email('$M2')")" "m2@x.kr"
has "회원 — 자기 이름에 태그 → BAD_INPUT(슈퍼어드민 화면 저장형 XSS · 보안 점검 재현)" "$(AS "$M1" "update public.profiles set display_name='회원일<img src=x onerror=alert(1)>' where id='$M1';")" "BAD_INPUT"
r=$(AS "$M1" "update public.profiles set display_name='회원일 <주의>' where id='$M1';"); ok "회원 — 한글 꺾쇠 이름은 그대로" "$(echo "$r" | grep -c ERROR)/$(Q "select display_name from public.profiles where id='$M1'")" "0/회원일 <주의>"
Q "update public.profiles set display_name='회원일' where id='$M1';" >/dev/null
r=$(AS "$SU" "update public.profiles set display_name='<b>운영</b>' where id='$SU';"); ok "슈퍼어드민은 검사 밖" "$(echo "$r" | grep -c ERROR)" "0"
Q "update public.profiles set display_name='운영' where id='$SU';" >/dev/null
# 재실행
out2=$($P -f "$MIG" 2>&1); echo "$out2" | grep -q "❌\|ERROR" && { echo "❌ 재실행 확인 표에 ❌/ERROR"; echo "$out2" | grep "❌\|ERROR"; FAIL=1; } || echo "✅ 재실행"
ok "재실행 뒤 suspended 가 approved 로 안 돌아감(백필은 옛 줄만)" "$(Q "select status from public.admin_grants where user_id='$P3'")" "approved"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
