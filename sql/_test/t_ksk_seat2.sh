#!/bin/bash
# 정산 좌석 연동 2차 회귀 — 2026-09-29. 실제 정원 트리거(v3)·티어 가드 원본을 픽스처에 올리고 2차 마이그레이션이
#   ① md5 가 맞아 교체되는지 ② 1인 한도·M 전용을 KSK- 가 넘는지 ③ 총 정원은 여전히 막는지
#   ④ 회원 구매는 종전 규칙 그대로인지 ⑤ 좌석 오류가 결제 확정을 깨지 않는지 본다.
#   먼저: 로컬 pg. 실행: bash sql/_test/t_ksk_seat2.sh
cd "$(dirname "$0")/../.."
DB=t_kskseat2; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a1000000-0000-4000-8000-000000000001; AD=a1000000-0000-4000-8000-000000000002; MB=a1000000-0000-4000-8000-000000000003
REST=b1000000-0000-4000-8000-000000000001
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public.taam_kashikiri_token() returns text language sql as \$\$ select md5(random()::text || clock_timestamp()::text) \$\$;
create table public.profiles(id uuid primary key, role text, membership_tier text, display_name text);
create table public.admin_grants(user_id uuid, rest_id text, venue_id text);
create table public.restaurants(id uuid primary key, guest_seat_allowed boolean default false);
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, total_pax int, slots jsonb,
  meal_fee int, agency_fee int, wine_min int, type_class text, min_tier text default '', guest_open boolean default false,
  guest_open_reason text, guest_seat_qty int default 0, guest_price int default 0);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, ticket_type text,
  reservation_date text, visit_time text, party_size int, price bigint, status text, purchase_id text, buyer_name text, buyer_phone text, extra_data jsonb, created_at timestamptz default now());
create table public.kashikiri_events(id uuid primary key default gen_random_uuid(), venue_id text, venue_name text, event_date date, event_time time, total_pax int, escort boolean, status text,
  fx_rate numeric, fx_usd numeric, ticket_product_id text, created_by uuid, memo text, created_at timestamptz default now());
create table public.kashikiri_teams(id uuid primary key default gen_random_uuid(), event_id uuid, seq int, host_label text, pax int);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid, team_id uuid, label text, payer_phone text, amount_krw int, amount_jpy int,
  token text default public.taam_kashikiri_token(), status text default 'pending' check (status in ('pending','paid','cancelled','expired','failed')),
  pay_currency text default 'KRW', pay_fx numeric, pay_amount numeric, expires_at timestamptz, payment_key text, payer_name text, approved_at timestamptz);
create or replace function public.taam_ticket_price_krw(p text, n int) returns bigint language sql stable as \$\$
  select (coalesce(meal_fee,0)+coalesce(agency_fee,0)+coalesce(wine_min,0))*greatest(coalesce(n,1),1) from public.ticket_products where id = p \$\$;
create or replace function public.taam_tier_rank(p text) returns int language sql immutable as \$\$ select case upper(coalesce(p,'')) when 'M' then 3 when 'T' then 2 when 'A' then 1 else 0 end \$\$;
create or replace function public.taam_tier_is_open(p text) returns boolean language sql immutable as \$\$ select upper(coalesce(p,'')) = 'A' \$\$;
create or replace function public.taam_user_tier(p uuid) returns text language sql stable as \$\$ select membership_tier from public.profiles where id = p \$\$;
insert into auth.users values ('$SU'),('$AD'),('$MB');
insert into public.profiles values ('$SU','super_admin','M','슈퍼'),('$AD','admin','','매장어드민'),('$MB','member','T','회원T');
insert into public.admin_grants values ('$AD','$REST',null);
insert into public.restaurants values ('$REST', false);
-- tp1: 정원 4 · 자유구성 1·2인 · 1인 한도 1 · M 전용
insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,slots,meal_fee,agency_fee,wine_min,type_class,min_tier)
  values ('tp1','$REST','타키야','03.20','20:30',4,'{"mode":"flex","allowed":[1,2],"solo":1,"strict":false}',550000,100000,250000,'Standard','M');
SQL
# 실제 정원 트리거 v3 (파일 통째로) + 티어 가드 원본(함수 블록만) + 트리거 바인딩
# ⚠ 라이브에 2차가 들어가기 **전** 판을 재현해야 md5 교체 경로가 검증된다. 저장소 원본은 4차 때 같은 규칙을 넣어 바뀌었으므로
#   그 전 커밋(2b56a8f · 2026-09-29 오전)의 파일을 git 에서 꺼내 쓴다.
git show 2b56a8f:sql/ticket_capacity_guard.sql | $P >/dev/null 2>&1
git show 2b56a8f:sql/general_open_to_guest.sql > /tmp/_tier_orig.sql
S=$(grep -n "create or replace function public.taam_guard_ticket_tier" /tmp/_tier_orig.sql | head -1 | cut -d: -f1)
E=$(awk -v s=$S 'NR>s && /^\$tier\$;/ {print NR; exit}' /tmp/_tier_orig.sql)
sed -n "${S},${E}p" /tmp/_tier_orig.sql | $P >/dev/null 2>&1
$P -c "create trigger trg_taam_guard_ticket_tier before insert on public.tickets for each row execute function public.taam_guard_ticket_tier();" >/dev/null
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
SUP="select set_config('taam.uid','$SU',false); select set_config('taam.super','1',false);"
EDGE="select set_config('taam.uid','',false); select set_config('taam.super','',false);"
MEM="select set_config('taam.uid','$MB',false); select set_config('taam.super','',false);"
LIVE="select coalesce(sum(party_size),0)||'|'||count(*) from public.tickets where purchase_id like 'KSK-%' and coalesce(status,'')<>'cancelled'"

echo "── 0. 전제: 원본 규칙이 산다 — 회원 1인 구매가 이미 1건이면 SOLO_LIMIT · T 회원은 M 전용에 TIER_BLOCKED"
$P -c "$SUP insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','$REST','tp1',1,900000,'manual','MAN-1')" >/dev/null
r=$($P -c "$SUP insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','$REST','tp1',1,900000,'active','PAY-x')" 2>&1)
ok "두 번째 1인 → SOLO_LIMIT" "1" "$(echo "$r" | grep -c SOLO_LIMIT)"
r=$($P -c "$MEM insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$MB','$REST','tp1',2,1800000,'active','PAY-y')" 2>&1)
ok "T 회원 2인 → TIER_BLOCKED" "1" "$(echo "$r" | grep -c TIER_BLOCKED)"

echo "── 1. 마이그레이션 1차 → 2차 (md5 일치 → 교체)"
$P -f supabase/migrations/20260929_link_invite.sql 2>&1 | grep -E "❌|ERROR"
$P -f supabase/migrations/20260929_kashikiri_seat_sync.sql 2>&1 | grep -E "❌|ERROR"
out=$($P -f supabase/migrations/20260929_kashikiri_seat_sync2.sql 2>&1)
ok "2차 오류 없음" "" "$(echo "$out" | grep -E "ERROR" | head -1)"
ok "2차 확인 표 ❌ 없음 · ✅ 7줄(표 5 + 교체 notice 2)" "0|7" "$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅')"
ok "교체 notice 2건 (티어·정원)" "2" "$(echo "$out" | grep -c '교체')"

EV=e1000000-0000-4000-8000-000000000001; C1=c1000000-0000-4000-8000-000000000001; C2=c1000000-0000-4000-8000-000000000002; C3=c1000000-0000-4000-8000-000000000003
$P <<SQL >/dev/null
insert into public.kashikiri_events(id, venue_id, venue_name, event_date, event_time, total_pax, escort, status, created_by, ticket_product_id)
  values ('$EV','$REST','Takiya','2027-03-20','20:30',5,false,'open',null,'tp1');
insert into public.kashikiri_charges(id, event_id, team_id, label, amount_krw, status, payer_name, pay_currency, pay_amount, approved_at)
  values ('$C1','$EV',null,'Trina',2321555,'pending','Trina Chin','USD',1679.85, null),
         ('$C2','$EV',null,'Second',900000,'pending','Second','KRW',900000, null),
         ('$C3','$EV',null,'Third',900000,'pending','Third','KRW',900000, null);
SQL

echo "── 2. Edge 경로(auth.uid 없음)에서 1인 청구 paid → 1인 한도·M 전용을 넘어 좌석이 잡힌다"
r=$($P -c "$EDGE update public.kashikiri_charges set status='paid', approved_at=now() where id='$C1'" 2>&1)
ok "청구 갱신 오류 없음" "" "$(echo "$r" | grep -i error)"
ok "Trina 1석 · user_id 는 슈퍼어드민(작성자·호출자 없음 → 폴백)" "1|1|$SU" "$($P -c "$LIVE")|$($P -c "select user_id from public.tickets where extra_data->>'chargeId'='$C1'")"
ok "청구는 paid" "paid" "$($P -c "select status from public.kashikiri_charges where id='$C1'")"

echo "── 3. 총 정원은 여전히 막는다 (정원 4 = MAN 1 + Trina 1 + Second 1 → Third 는 short)"
$P -c "$EDGE update public.kashikiri_charges set status='paid', approved_at=now() where id='$C2'" >/dev/null
$P -c "update public.ticket_products set total_pax=3 where id='tp1'" >/dev/null   # 정원을 3 으로 줄여 Third 가 못 들어가게
r=$($P -c "$EDGE update public.kashikiri_charges set status='paid', approved_at=now() where id='$C3'" 2>&1)
ok "Third paid 갱신은 성공(예외 없음)" "paid|" "$($P -c "select status from public.kashikiri_charges where id='$C3'")|$(echo "$r" | grep -i error)"
ok "Third 좌석 없음 · 살아 있는 KSK 2석" "0|2|2" "$($P -c "select count(*) from public.tickets where extra_data->>'chargeId'='$C3'")|$($P -c "$LIVE")"
r=$($P -c "$SUP select (public.taam_kashikiri_link_ticket('$EV','tp1'))::text" 2>&1)
ok "RPC 결과 short: Third · kind capacity · TICKET_SOLD_OUT" "1|1|1" "$(echo "$r" | grep -c '"label": "Third"')|$(echo "$r" | grep -c '"kind": "capacity"')|$(echo "$r" | grep -c 'TICKET_SOLD_OUT')"

echo "── 4. bypass 플래그가 새지 않는다 — 회원 1인 구매는 여전히 SOLO_LIMIT"
$P -c "update public.ticket_products set total_pax=9 where id='tp1'" >/dev/null   # ⚠ 따로 — 같은 -c 에 넣으면 insert 예외와 함께 롤백된다
r=$($P -c "$SUP insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','$REST','tp1',1,900000,'active','PAY-z')" 2>&1)
ok "SOLO_LIMIT 그대로" "1" "$(echo "$r" | grep -c SOLO_LIMIT)"
r=$($P -c "$MEM insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$MB','$REST','tp1',2,1800000,'active','PAY-w')" 2>&1)
ok "T 회원 M 전용 → TIER_BLOCKED 그대로" "1" "$(echo "$r" | grep -c TIER_BLOCKED)"

echo "── 5. 좌석 오류가 결제 확정을 깨지 않는다"
$P -c "create or replace function public._boom() returns trigger language plpgsql as \$\$ begin if new.purchase_id like 'KSK-%' and new.extra_data->>'chargeId' = '$C3' then raise exception 'BOOM: 테스트 폭탄'; end if; return new; end \$\$; create trigger t_boom before insert on public.tickets for each row execute function public._boom();" >/dev/null
r=$($P -c "$SUP select (public.taam_kashikiri_link_ticket('$EV','tp1'))::text" 2>&1)
ok "5a RPC: Third short kind=error · reason BOOM · 다른 둘은 유지" "1|1|2|2" "$(echo "$r" | grep -c '"kind": "error"')|$(echo "$r" | grep -c 'BOOM')|$($P -c "$LIVE")"
$P -c "update public.kashikiri_charges set status='pending' where id='$C3'" >/dev/null
r=$($P -c "$EDGE update public.kashikiri_charges set status='paid', approved_at=now() where id='$C3'" 2>&1)
ok "5b 트리거 경로: insert 폭탄은 short 로 삼켜져 paid 갱신 성공 · warning 없음" "paid|0" "$($P -c "select status from public.kashikiri_charges where id='$C3'")|$(echo "$r" | grep -c 'WARNING')"
$P -c "drop trigger t_boom on public.tickets" >/dev/null
# insert 바깥(취소 update)에서 터지는 오류 → 트리거 래퍼가 삼킨다
$P -c "create or replace function public._boom2() returns trigger language plpgsql as \$\$ begin if new.purchase_id like 'KSK-%' and new.status='cancelled' then raise exception 'BOOM2: 취소 폭탄'; end if; return new; end \$\$; create trigger t_boom2 before update on public.tickets for each row execute function public._boom2();" >/dev/null
r=$($P -c "$EDGE update public.kashikiri_charges set status='cancelled' where id='$C2'" 2>&1)
ok "5c 취소 update 폭탄 → 청구는 cancelled 로 갱신됨 · WARNING 1 · 좌석은 아직 살아 있음" "cancelled|1|2|2" "$($P -c "select status from public.kashikiri_charges where id='$C2'")|$(echo "$r" | grep -c 'WARNING')|$($P -c "$LIVE")"
$P -c "drop trigger t_boom2 on public.tickets" >/dev/null
r=$($P -c "$SUP select (public.taam_kashikiri_link_ticket('$EV','tp1'))::text" 2>&1)
ok "5d 폭탄 제거 후 다시 연결 → Second 좌석 접힘(cancelled 1) · 정원 9 라 Third 도 들어와 2석 2행" "1|2|2" "$(echo "$r" | grep -c '"cancelled" : 1')|$($P -c "$LIVE")"

echo "── 6. 링크 초대(LINK-)도 티어 가드 면제 — 등급 없는 매장 어드민이 M 전용 티켓에 링크 초대"
r=$($P -c "select set_config('taam.uid','$AD',false); select set_config('taam.super','',false); select (public.taam_link_invite_create('tp1','Joy','+1 415 555 0100',2,'USD',1380,'2027.03.20','20:30'))::text" 2>&1)
ok "LINK- 홀드 생성 (종전엔 TIER_BLOCKED)" "hold|2" "$($P -c "select status||'|'||party_size from public.tickets where purchase_id like 'LINK-%'")"

echo "── 7. 2차를 한 번 더 돌려도 안전 (이미 안다 → 건너뜀 · 표 ✅)"
out=$($P -f supabase/migrations/20260929_kashikiri_seat_sync2.sql 2>&1)
ok "재실행: ❌ 0 · '이미' 2건" "0|2" "$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '이미')"

echo "── 8. 라이브 본문이 다르면 건너뛰고 ❌ 로 알린다"
$P -c "create or replace function public.enforce_ticket_capacity() returns trigger language plpgsql as \$\$ begin return new; end \$\$;" >/dev/null
out=$($P -f supabase/migrations/20260929_kashikiri_seat_sync2.sql 2>&1)
ok "정원 트리거 ⚠ 건너뜀 + warning" "1|1" "$(echo "$out" | grep -c "④ 정원 트리거 KSK- 총 정원만|⚠")|$(echo "$out" | grep -c 'WARNING.*정원 트리거')"

echo "── 9. 3차(라이브 판 + 우회) — 더미로 바뀐 정원 트리거 위에 얹어 KSK 는 1인 한도를 넘고 회원은 못 넘는지"
out=$($P -f supabase/migrations/20260929_kashikiri_seat_sync3.sql 2>&1)
ok "3차 확인 표 ✅ 2 · ❌ 0" "2|0" "$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -c '❌')"
$P -c "update public.ticket_products set total_pax=9, slots='{\"mode\":\"flex\",\"allowed\":[1,2],\"solo\":1,\"strict\":false}' where id='tp1'" >/dev/null
r=$($P -c "$SUP insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$SU','$REST','tp1',1,900000,'active','PAY-solo2')" 2>&1)
ok "회원 1인 → SOLO_LIMIT (원 규칙 유지)" "1" "$(echo "$r" | grep -c SOLO_LIMIT)"
C4=c1000000-0000-4000-8000-000000000004
$P -c "insert into public.kashikiri_charges(id, event_id, team_id, label, amount_krw, status, payer_name) values ('$C4','$EV',null,'Fourth',900000,'pending','Fourth')" >/dev/null
$P -c "$EDGE update public.kashikiri_charges set status='paid', approved_at=now() where id='$C4'" >/dev/null
ok "KSK 1인 → 1인 한도 우회해 좌석 생성" "1" "$($P -c "select count(*) from public.tickets where extra_data->>'chargeId'='$C4' and status='active'")"
echo "── 10. 4차: 잠금→읽기 · 인원 늘림 정원 검사 · 접두어 위조 차단 · 리마인드 제외"
# 픽스처 보강: INSERT 가드(invoker) + 회원 role · notifications · 리마인드 헬퍼 · tp2(등급 제한 없음·정원 없음)
$P <<SQL >/dev/null 2>&1
create or replace function public._taam_uid_role() returns text language sql stable as \$\$ select coalesce(current_setting('taam.role', true),'') \$\$;
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
grant usage on schema public, auth to authenticated;
grant all on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
grant execute on all functions in schema auth to authenticated;
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, seen boolean default false, created_at timestamptz default now());
insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,slots,meal_fee,agency_fee,wine_min,type_class,min_tier)
  values ('tp2','$REST','리마인드매장','03.21','19:00',null,null,100000,0,0,'Standard','');
alter table public.profiles add column notif_prefs jsonb not null default '{}'::jsonb;
SQL
S0=$(grep -n "create or replace function public.taam_visit_date" sql/visit_reminder.sql | cut -d: -f1); E0=$(grep -n "create or replace function public.taam_visit_reminder_notify" sql/visit_reminder.sql | cut -d: -f1)
sed -n "${S0},$((E0-1))p" sql/visit_reminder.sql | $P >/dev/null 2>&1
S1=$(grep -n "create or replace function public.taam_guard_ticket_insert" sql/audit_hardening_2026-09-13.sql | cut -d: -f1); E1=$(awk -v s=$S1 'NR>s && /^\$\$;/ {print NR; exit}' sql/audit_hardening_2026-09-13.sql)
sed -n "${S1},${E1}p" sql/audit_hardening_2026-09-13.sql | $P >/dev/null 2>&1
$P -c "create trigger trg_taam_guard_ticket_insert before insert on public.tickets for each row execute function public.taam_guard_ticket_insert();" >/dev/null
out=$($P -f supabase/migrations/20260929_kashikiri_seat_sync4.sql 2>&1)
ok "4차 오류 없음 · 표 ✅ 6 ❌ 0" "|6|0" "$(echo "$out" | grep -E "^ERROR" | head -1)|$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -c '❌')"

echo "   ── 10a. 인원 늘림: 조 pax 로 좌석을 늘릴 때 총 정원을 넘으면 short (현재 정원 9 · 팔린 좌석 $($P -c "select coalesce(sum(party_size),0) from public.tickets where ticket_product_id='tp1' and coalesce(status,'')<>'cancelled'"))"
TB=f1000000-0000-4000-8000-00000000000b
$P -c "insert into public.kashikiri_teams(id, event_id, seq, host_label, pax) values ('$TB','$EV',2,'F様',2); update public.kashikiri_charges set team_id='$TB' where id='$C4'" >/dev/null
r=$($P -c "$SUP select (public.taam_kashikiri_link_ticket('$EV','tp1'))::text" 2>&1)
ok "조 2명으로 늘림 (resized 1 · Fourth 2명)" "1|2" "$(echo "$r" | grep -c '"resized" : 1')|$($P -c "select party_size from public.tickets where extra_data->>'chargeId'='$C4' and status='active'")"
r=$($P -c "$EDGE update public.kashikiri_teams set pax=5 where id='$TB'" 2>&1)
ok "조 5명 → 정원 초과: WARNING 1 · 2명 유지" "1|2" "$(echo "$r" | grep -c 'RESIZE_OVER_CAPACITY')|$($P -c "select party_size from public.tickets where extra_data->>'chargeId'='$C4' and status='active'")"
sold=$($P -c "select coalesce(sum(party_size),0) from public.tickets where ticket_product_id='tp1' and coalesce(status,'')<>'cancelled'")
fit=$((9 - sold + 2))
$P -c "$EDGE update public.kashikiri_teams set pax=$fit where id='$TB'" >/dev/null
ok "딱 맞는 인원($fit)으로 → 늘어남" "$fit" "$($P -c "select party_size from public.tickets where extra_data->>'chargeId'='$C4' and status='active'")"

echo "   ── 10b. 접두어 위조: 회원이 'KSK-' 홀드로 등급 가드를 피하지 못한다"
$P -c "update public.ticket_products set total_pax=20 where id='tp1'" >/dev/null   # 10a 뒤 정원이 꽉 차 있어 정원 트리거(이름순 먼저)가 먼저 막는다 — 정원을 열어 둔다
MEMQ="set role authenticated; select set_config('taam.uid','$MB',false); select set_config('taam.super','',false); select set_config('taam.role','user',false);"
r=$($P -c "$MEMQ insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$MB','$REST','tp1',2,1800000,'hold','KSK-forged-1')" 2>&1)
ok "회원 홀드 'KSK-…' → HOLD_PREFIX" "1" "$(echo "$r" | grep -c HOLD_PREFIX)"
r=$($P -c "$MEMQ insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$MB','$REST','tp1',2,1800000,'hold','MAN-forged-1')" 2>&1)
ok "회원 홀드 'MAN-…' → HOLD_PREFIX (옛 구멍도 막힘)" "1" "$(echo "$r" | grep -c HOLD_PREFIX)"
r=$($P -c "$MEMQ insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id) values ('$MB','$REST','tp1',2,1800000,'hold','PAYH-ok-1')" 2>&1)
ok "회원 PAYH- 홀드는 INSERT 가드를 지나 티어 가드에서 M 전용 → TIER_BLOCKED" "1" "$(echo "$r" | grep -c TIER_BLOCKED)"
r=$($P -c "select set_config('taam.uid','$MB',false); select set_config('taam.super','',false); insert into public.tickets(user_id,restaurant_id,ticket_product_id,party_size,price,status,purchase_id,extra_data) values ('$MB','$REST','tp1',2,1800000,'active','KSK-forged-2','{\"chargeId\":\"00000000-0000-0000-0000-000000000000\"}')" 2>&1)
ok "서버 컨텍스트라도 증명 없는 'KSK-' → 티어 검사 그대로 (TIER_BLOCKED)" "1" "$(echo "$r" | grep -c TIER_BLOCKED)"
r=$($P -c "select set_config('taam.uid','$AD',false); select set_config('taam.super','',false); select (public.taam_link_invite_create('tp2','Kim','+81 90 0000 0000',1,'JPY',9.1,'2027.03.21','19:00'))::text" 2>&1)
ok "진짜 링크 초대(청구 증명)는 그대로 통과" "1" "$($P -c "select count(*) from public.tickets where purchase_id like 'LINK-%' and ticket_product_id='tp2' and status='hold'")"

echo "   ── 10c. 리마인드: 어드민이 잡은 좌석은 빠지고, boolean 아닌 설정값에도 죽지 않는다"
TMR="to_char((now() at time zone 'Asia/Seoul')::date + 1, 'YYYY.MM.DD')"
$P <<SQL >/dev/null 2>&1
update public.profiles set notif_prefs = '{"remind1": "yes", "remind3": 1}'::jsonb where id = '$MB';
insert into public.tickets(user_id,restaurant_id,restaurant_name,ticket_product_id,party_size,price,status,purchase_id,reservation_date,visit_time,extra_data) values
  ('$MB','$REST','리마인드매장','tp2',2,200000,'active','PAY-rem-1', $TMR, '19:00', '{}'),
  ('$SU','$REST','리마인드매장','tp2',1,100000,'active','KSK-rem-1', $TMR, '19:00', '{"kashikiri":true}'),
  ('$SU','$REST','리마인드매장','tp2',1,100000,'active','LINK-rem-1', $TMR, '19:00', '{"linkInvite":true}'),
  ('$SU','$REST','리마인드매장','tp2',1,100000,'manual','MAN-rem-1', $TMR, '19:00', '{"manualEntry":true}');
SQL
r=$($P -c "select (public.taam_visit_reminder_notify())::text" 2>&1)
ok "made 1 (회원 것만) · 오류 없음" "1|" "$(echo "$r" | grep -c '"made": 1')|$(echo "$r" | grep -E "^ERROR")"
ok "알림 수신자는 회원 · 제목 「내일 방문 예정입니다」" "$MB|내일 방문 예정입니다" "$($P -c "select user_id||'|'||title from public.notifications where type='visit_reminder'")"

echo "── 11. 인원 바꾸기 RPC (조 없는 청구 → 조 생성 · 정원 초과 → short · 권한)"
out=$($P -f supabase/migrations/20260929_kashikiri_seat_pax.sql 2>&1); ok "5차 오류 없음 · ✅ 1" "|1" "$(echo "$out" | grep -E "^ERROR" | head -1)|$(echo "$out" | grep -c '✅')"
$P -c "update public.ticket_products set total_pax=20 where id='tp1'" >/dev/null
PID3=$($P -c "select purchase_id from public.tickets where extra_data->>'chargeId'='$C3' and status='active' order by created_at desc limit 1")
ok "Third 좌석 현재 1명 · 조 없음" "1|" "$($P -c "select party_size from public.tickets where purchase_id='$PID3'")|$($P -c "select coalesce(team_id::text,'') from public.kashikiri_charges where id='$C3'")"
r=$($P -c "$SUP select (public.taam_ksk_seat_set_pax('$PID3', 2))::text" 2>&1)
ok "2명으로: 조 생성·연결 · 좌석 2명 · resized 1 · short 없음" "2|2|1|1" "$($P -c "select party_size from public.tickets where purchase_id='$PID3'")|$($P -c "select t.pax from public.kashikiri_charges c join public.kashikiri_teams t on t.id=c.team_id where c.id='$C3'")|$(echo "$r" | grep -c '"resized" : 1')|$(echo "$r" | grep -c '"short" : \[\]')"
sold=$($P -c "select coalesce(sum(party_size),0) from public.tickets where ticket_product_id='tp1' and coalesce(status,'')<>'cancelled'")
r=$($P -c "$SUP select (public.taam_ksk_seat_set_pax('$PID3', 40))::text" 2>&1)
ok "40명(정원 초과): short RESIZE_OVER_CAPACITY(트리거 warning + RPC short) · 좌석 2명 유지" "1|2" "$(( $(echo "$r" | grep -c 'RESIZE_OVER_CAPACITY') > 0 ))|$($P -c "select party_size from public.tickets where purchase_id='$PID3'")"
r=$($P -c "$SUP select (public.taam_ksk_seat_set_pax('$PID3', 1))::text" 2>&1)
ok "다시 1명" "1" "$($P -c "select party_size from public.tickets where purchase_id='$PID3'")"
# (권한 거부 경로는 픽스처가 postgres 로 접속해 session_user 가 늘 postgres 라 재현할 수 없다 — 함수 본문의 v_srv 참고)
r=$($P -c "$SUP select (public.taam_ksk_seat_set_pax('KSK-없는행', 2))::text" 2>&1)
ok "없는 좌석 → SEAT_NOT_FOUND" "1" "$(echo "$r" | grep -c 'SEAT_NOT_FOUND')"
r=$($P -c "$EDGE select (public.taam_ksk_seat_set_pax('$PID3', 2))::text" 2>&1)
ok "SQL Editor(postgres) 경로는 통과 → 2명" "2" "$($P -c "select party_size from public.tickets where purchase_id='$PID3'")"

[ $FAIL = 0 ] && echo "=== 5차 포함 전부 통과 ===" || echo "=== 실패 있음 ==="
exit $FAIL
