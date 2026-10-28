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
  ticket_type text, uploaded_by text, uploader_rest_id text, auto_soldout boolean default false, tile_photo text, updated_at timestamptz default now());
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
create table public.reservation_requests(id uuid primary key default gen_random_uuid(), user_id uuid, venue_id text, reserve_date date, status text default 'pending', visit_status text);
alter table public.profiles enable row level security;
create policy profiles_select_own on public.profiles for select to authenticated using ((auth.uid() = id) or public.is_superadmin());
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
ok "파트너 — 승인된 회차 내용 수정 → 다시 승인 대기 · 도장 지움" "$(Q "select status || '/' || (approved_at is null)::text from public.ticket_products where id='tp4'")" "pending/true"
ok "재승인 알림(티켓 수정)" "$(Q "select count(*) from public.notifications where user_id='$SU' and title like '티켓 수정%' and payload->>'ticket_id'='tp4'")" "1"
r=$(AS "$PT" "insert into public.ticket_products(id,rest_id,rest_name,status,date,time,total_pax,price) values ('tp1','$R1','메이노','active','2026.11.03','19:00',8,850000) on conflict (id) do update set status=excluded.status, updated_at=now();"); ok "파트너 upsert(있는 행 · 값 같음) — 통과 · 상태 유지" "$(echo "$r" | grep -c ERROR)/$(Q "select status from public.ticket_products where id='tp1'")" "0/active"
r=$(AS "$PT" "update public.ticket_products set status='deleteRequest' where id='tp1';"); ok "파트너 — 삭제 신청 OK" "$(Q "select status from public.ticket_products where id='tp1'")" "deleteRequest"
AS "$PT" "update public.ticket_products set status='active' where id='tp1';" >/dev/null
ok "파트너 — 승인된 회차 DELETE 는 0행" "$(AS "$PT" "delete from public.ticket_products where id='tp1' returning id;" | grep -c tp1)" "0"
ok "파트너 — 자기 pending 회차 DELETE OK" "$(AS "$PT" "delete from public.ticket_products where id='tp3' returning id;" | grep -c tp3)" "1"
ok "회원 — 승인 대기 회차 안 보임(tp4 pending)" "$(AS "$M1" "select count(*) from public.ticket_products where id='tp4'")" "0"
ok "파트너 — 자기 매장 승인 대기 회차 보임" "$(AS "$PT" "select count(*) from public.ticket_products where id='tp4'")" "1"
ok "anon — 승인 대기 회차 안 보임" "$($P -c "set role anon; select count(*) from public.ticket_products where status='pending';" 2>&1 | tail -1)" "0"
AS "$SU" "delete from public.ticket_products where id='tp4';" >/dev/null
ok "슈퍼어드민 거절(삭제) → 파트너 알림" "$(Q "select count(*) from public.notifications where user_id='$PT' and type='ticket_rejected' and payload->>'ticket_id'='tp4'")" "1"
# E 초대
r=$(AS "$PT" "insert into public.reservation_invites(host_user_id,invitee_user_id,restaurant_id,visit_date,pax,total_amount,ticket_product_id) values ('$PT','$M1','$R1','2026.11.05',1,1,'tp2');"); has "초대 — 다른 매장 회차 연결 거절" "$r" "TICKET_REST_MISMATCH"
r=$(AS "$PT" "insert into public.reservation_invites(host_user_id,invitee_user_id,restaurant_id,visit_date,pax,total_amount,ticket_product_id) values ('$PT','$M1','$R1','2026.11.03',1,850000,'tp1');"); ok "초대 — 자기 매장 회차 OK" "$(echo "$r" | grep -c ERROR)" "0"
Q "insert into public.reservation_invites(id,host_user_id,invitee_user_id,restaurant_id,visit_date,pax,total_amount,ticket_product_id,status) values ('e1000000-0000-4000-8000-000000000001','$SU','$M1','$R1','2026.11.05',1,1,'tp2','sent');" >/dev/null
r=$(AS "$M1" "update public.reservation_invites set status='paid', paid_at=now() where id='e1000000-0000-4000-8000-000000000001';"); ok "옛 불일치 초대 — 회원의 결제 갱신은 막히지 않는다" "$(echo "$r" | grep -c ERROR)" "0"
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
has "회원 검색 — 이 매장 회원만(회원이 는 사이토만)" "$(AS "$PT" "select public.taam_partner_member_search('$R1','회원')")" '"display_name": "회원일"'
no "회원 검색 — 다른 매장 회원 안 나옴" "$(AS "$PT" "select public.taam_partner_member_search('$R1','회원')")" '회원이'
has "회원 검색 — 번호로" "$(AS "$PT" "select public.taam_partner_member_search('$R1','1111')")" '회원일'
ok "회원 검색 — 두 글자 미만은 빈 배열" "$(AS "$PT" "select public.taam_partner_member_search('$R1','회')")" "[]"
has "회원 검색 — 다른 매장 회원도 번호 전체(10자리)를 정확히 치면 나온다(단골 초대)" "$(AS "$PT" "select public.taam_partner_member_search('$R1','010-3333-4444')")" '회원이'
has "회원 검색 — +82 10 3333 4444 도 같은 번호" "$(AS "$PT" "select public.taam_partner_member_search('$R1','+82 10 3333 4444')")" '회원이'
ok "회원 검색 — 번호 일부(8자리)로는 다른 매장 회원이 안 나온다" "$(AS "$PT" "select public.taam_partner_member_search('$R1','10-3333-44')")" "[]"
nm=$(AS "$PT" "select public.taam_partner_names('$R1', array['$M1','$M2']::uuid[])")
has "이름 채우기 — 이 매장 회원 이름" "$nm" '"display_name": "회원일"'
no "이름 채우기 — 다른 매장 회원은 빠진다" "$nm" '회원이'
no "이름 채우기 — 잔액 없음" "$nm" 'balance'
has "이름 채우기 — pending 파트너 FORBIDDEN" "$(AS "$P3" "select public.taam_partner_names('$R1', array['$M1']::uuid[])")" "FORBIDDEN"
ok "이름 채우기 — 빈 배열" "$(AS "$PT" "select public.taam_partner_names('$R1', array[]::uuid[])")" "[]"
has "내 권한 — approved" "$(AS "$PT" "select public.taam_partner_my_grants()")" '"status": "approved"'
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
AS "$SU" "update public.admin_grants set approved_by='$M1', status='approved' where user_id='$P3';" >/dev/null
ok "도장은 트리거가 찍는다(보낸 approved_by 무시)" "$(Q "select (approved_by='$SU')::text from public.admin_grants where user_id='$P3'")" "true"
# I
ok "_taam_auth_email — 남의 것 null" "$(AS "$M1" "select coalesce(public._taam_auth_email('$M2'),'-')")" "-"
ok "_taam_auth_email — 본인" "$(AS "$M1" "select public._taam_auth_email('$M1')")" "m1@x.kr"
ok "_taam_auth_email — 슈퍼어드민" "$(AS "$SU" "select public._taam_auth_email('$M2')")" "m2@x.kr"
ok "taam_user_tier anon 회수" "$(Q "select has_function_privilege('anon','public.taam_user_tier(uuid)','execute')")" "f"
# 재실행
out2=$($P -f "$MIG" 2>&1); echo "$out2" | grep -q "❌\|ERROR" && { echo "❌ 재실행 확인 표에 ❌/ERROR"; echo "$out2" | grep "❌\|ERROR"; FAIL=1; } || echo "✅ 재실행"
ok "재실행 뒤 suspended 가 approved 로 안 돌아감(백필은 옛 줄만)" "$(Q "select status from public.admin_grants where user_id='$P3'")" "approved"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "── 전부 통과" || { echo "── 실패 있음"; exit 1; }
