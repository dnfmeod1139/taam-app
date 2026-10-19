#!/bin/bash
# 결제 링크 재구성 회귀 — 2026-10-18. 먼저: 로컬 pg. 실행: bash sql/_test/t_pay_link.sh
cd "$(dirname "$0")/../.."
DB=t_paylink; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a1000000-0000-4000-8000-000000000001; M2=a1000000-0000-4000-8000-000000000002; M3=a1000000-0000-4000-8000-000000000003; M4=a1000000-0000-4000-8000-000000000004; ADM=a1000000-0000-4000-8000-000000000005; M5=a1000000-0000-4000-8000-000000000006; M6=a1000000-0000-4000-8000-000000000007
$P <<SQL >/dev/null 2>&1
do \$\$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
          if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
          if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if; end \$\$;
alter default privileges in schema public grant execute on functions to anon, authenticated;
create schema auth; create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public._taam_uid_is_super() returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public.is_super_admin(u uuid) returns boolean language sql stable as \$\$ select coalesce(current_setting('taam.super', true),'') = '1' \$\$;
create or replace function public.taam_kashikiri_token() returns text language sql as \$\$ select md5(random()::text || clock_timestamp()::text) \$\$;
create table public.profiles(id uuid primary key, display_name text, role text, membership_tier text, deleted_at timestamptz);
create table public.admin_grants(user_id uuid, rest_id text, venue_id text);
create table public.restaurants(id uuid primary key, name text, name_en text, name_jp text);
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, total_pax int, meal_fee int, agency_fee int, wine_min int, type_class text);
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text, ticket_type text,
  reservation_date text, visit_time text, party_size int, price bigint, status text, purchase_id text, buyer_name text, buyer_phone text, extra_data jsonb, created_at timestamptz default now());
create table public.kashikiri_events(id uuid primary key default gen_random_uuid(), venue_id text not null, venue_name text, event_date date not null, event_time time, total_pax int default 0, escort boolean default true, status text default 'draft',
  fx_rate numeric(12,4), fx_usd numeric(12,4), fx_note text, ticket_product_id text, total_jpy int, total_krw int, created_by uuid, memo text, created_at timestamptz default now());
create table public.kashikiri_teams(id uuid primary key default gen_random_uuid(), event_id uuid, seq int, host_label text, pax int default 1);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid not null references public.kashikiri_events(id) on delete cascade, team_id uuid, guest_id uuid, label text not null, payer_phone text, user_id uuid references auth.users(id) on delete set null,
  amount_krw int not null check (amount_krw > 0), amount_jpy int, token text not null unique default public.taam_kashikiri_token(),
  status text not null default 'pending' check (status in ('pending','paid','cancelled','expired','failed','refunded')),
  order_id text unique, payment_key text, method text, receipt_url text, fail_reason text, payer_name text, approved_at timestamptz, expires_at timestamptz, created_at timestamptz default now(),
  pay_currency text not null default 'KRW', pay_amount numeric(14,2), pay_fx numeric(12,4), refund_krw int, refund_amount numeric(14,2), refunded_at timestamptz, cancel_reason text, link_invite boolean not null default false);
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text, url text, payload jsonb, created_at timestamptz default now());
create table public.membership_settings(k text primary key, v jsonb not null, note text, updated_at timestamptz default now(), updated_by uuid);
insert into public.membership_settings(k, v) values ('deposit_amount','10125000'), ('annual_fee_cash','1125000'), ('annual_fee_card','1270000');
create table public.membership_fees(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade, paid_at date not null, amount_krw int not null default 0,
  fx_currency text, fx_amount numeric(14,2), method text not null default 'transfer', period_from date, period_to date, tier text, note text, source text not null default 'manual', source_ref text, created_by uuid, created_at timestamptz default now(), updated_at timestamptz);
create table public.sync_calls(event_id uuid, at timestamptz default now());
create or replace function public.taam_kashikiri_charge_cancel(p_charge_id uuid) returns jsonb language plpgsql security definer as \$\$
declare c public.kashikiri_charges%rowtype; begin
  if not is_super_admin(auth.uid()) then raise exception '권한이 없습니다' using errcode = '42501'; end if;
  select * into c from public.kashikiri_charges where id = p_charge_id; if not found then raise exception '청구를 찾을 수 없습니다'; end if;
  if c.status = 'paid' then raise exception '이미 결제된 건은 끊을 수 없습니다 — 환불로 처리하세요' using errcode = '55000'; end if;
  update public.kashikiri_charges set status = 'cancelled' where id = c.id; return jsonb_build_object('ok', true, 'label', c.label); end \$\$;
create or replace function public._taam_ksk_seat_sync(p uuid) returns json language plpgsql as \$\$ begin insert into public.sync_calls(event_id) values (p); return '{"ok":true,"short":[]}'::json; end \$\$;
create or replace function public.taam_ticket_price_krw(p text, n int) returns bigint language sql stable as \$\$
  select (coalesce(meal_fee,0)+coalesce(agency_fee,0)+coalesce(wine_min,0))*greatest(coalesce(n,1),1) from public.ticket_products where id = p \$\$;
create or replace function public._cap() returns trigger language plpgsql as \$\$
declare v int; c int; begin
  select total_pax into c from public.ticket_products where id = new.ticket_product_id;
  select coalesce(sum(party_size),0) into v from public.tickets where ticket_product_id = new.ticket_product_id and coalesce(status,'')<>'cancelled';
  if c is not null and v + new.party_size > c then raise exception 'TICKET_SOLD_OUT'; end if; return new; end \$\$;
create trigger t_cap before insert on public.tickets for each row execute function public._cap();
insert into auth.users values ('$SU'),('$M2'),('$M3'),('$ADM'),('$M5'),('$M6');
insert into public.profiles(id, display_name, role, membership_tier) values ('$SU','슈퍼','superadmin','M'), ('$M2','김회원','user','M'), ('$M3','Eric Cheok','user','T'), ('$M4','유령','user','M'), ('$ADM','매장어드민','admin',null), ('$M5',null,'user','M'), ('$M6','가드맨','user','T');
insert into public.restaurants values ('b1000000-0000-4000-8000-000000000001','마츠카와','Matsukawa','松川');
insert into public.ticket_products values ('tp1','b1000000-0000-4000-8000-000000000001','마츠카와','05.01','18:00',4,750000,150000,350000,'Standard'),
  ('tp2','b1000000-0000-4000-8000-000000000001','마츠카와','05.01','19:30',4,500000,100000,0,'Standard'), ('tp3','b1000000-0000-4000-8000-000000000001','마츠카와','05.01','12:00',4,300000,50000,0,'Standard');
insert into public.admin_grants values ('$ADM','b1000000-0000-4000-8000-000000000001',null);
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
$P -f supabase/migrations/20260929_link_invite.sql 2>&1 | grep -E "^ERROR" | head -2
$P -f supabase/migrations/20261013_kashikiri_paid_notify.sql 2>&1 | grep -E "^ERROR" | head -2
$P -f supabase/migrations/20261014_purchase_uniqueness.sql 2>&1 | grep -E "^ERROR" | head -2   # 실제 중복 가드 — 선검사·소유자 이전 폴백을 흉내 트리거가 아니라 진짜 가드로 검증한다 (3차)
out=$($P -f supabase/migrations/20261018_pay_link.sql 2>&1)
ok "마이그레이션 오류 없음 · ✅ 9 · ❌ 0" "|9|0" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '✅')|$(echo "$out" | grep -c '❌')"
$P -c "create trigger trg_ksk_seat_on_charge after update of status on public.kashikiri_charges for each row execute function public.taam_ksk_seat_on_charge();" >/dev/null
S="set taam.uid='$SU'; set taam.super='1';"
# ── 금액 규칙 ──
ok "금액: 국내 M 가입 11,250,000 / 연회비 1,125,000 / 예치금 10,125,000" "11250000|1125000|10125000" "$($P -c "select (j->>'total')||'|'||(j->>'fee')||'|'||(j->>'deposit') from public.taam_membership_price('M','join','KRW') j")"
ok "금액: 국내 T 갱신 = 연회비 630,000 · 해외 M 가입 \$9,900/\$990/\$8,910 · 해외 T 갱신 \$300" "630000|0|9900|990|8910|300" "$($P -c "select (a->>'total')||'|'||(a->>'deposit')||'|'||(b->>'total')||'|'||(b->>'fee')||'|'||(b->>'deposit')||'|'||(c->>'total') from public.taam_membership_price('T','renew','KRW') a, public.taam_membership_price('M','join','USD') b, public.taam_membership_price('T','renew','USD') c")"
ok "금액: JPY 는 규정 없음 → NO_PRICE_RULE" "1" "$($P -c "select public.taam_membership_price('M','join','JPY')" 2>&1 | grep -c NO_PRICE_RULE)"
# ── 멤버십 링크 ──
r=$($P -c "$S select public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M2','tier','M','kind','join','currency','KRW'))::text")
C1=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "국내 M 가입 링크 · 11,250,000 · 회차 없음 · 제목 · 회원 연결" "membership|11250000|KRW|11250000.00||멤버십 M 가입|김회원|$M2|1125000|10125000" "$($P -c "select purpose||'|'||amount_krw||'|'||pay_currency||'|'||pay_amount||'|'||coalesce(event_id::text,'')||'|'||title||'|'||label||'|'||user_id||'|'||(payload->>'fee_krw')||'|'||(payload->>'deposit_krw') from public.kashikiri_charges where id='$C1'")"
ok "  → 만료 14일 · url /pay/?t= · 토큰 32자" "14|1|32" "$($P -c "select (expires_at::date - now()::date)||'|'||(select count(*) from public.kashikiri_charges where id='$C1' and token is not null)||'|'||length(token) from public.kashikiri_charges where id='$C1'")"
r=$($P -c "$S select public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M3','tier','T','kind','renew','currency','USD','fx',1342.315))::text")
C2=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "해외 T 갱신 \$300 · 원화 round(300×1342.315)=402,695 · 연회비 전액 · 예치금 0" "USD|300.00|402695|1342.3150|300.00|402695|0" "$($P -c "select pay_currency||'|'||pay_amount||'|'||amount_krw||'|'||pay_fx||'|'||(payload->>'fee')||'|'||(payload->>'fee_krw')||'|'||(payload->>'deposit_krw') from public.kashikiri_charges where id='$C2'")"
ok "금액을 바꾸는데 사유 메모가 없으면 OVERRIDE_NOTE_REQUIRED" "1" "$($P -c "$S select public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M2','tier','M','kind','join','currency','KRW','total',10000000))" 2>&1 | grep -c OVERRIDE_NOTE_REQUIRED)"
r=$($P -c "$S select public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M2','tier','M','kind','join','currency','KRW','total',10000000,'fee',1000000,'note','특별 약정'))::text")
C3=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "사유 메모와 함께면 수정 가능 · override true · 예치금 9,000,000 · 메모는 어드민 표에(회원이 읽는 행엔 없음) · created_by 도" "10000000|true||9000000|특별 약정|$SU|" "$($P -c "select amount_krw||'|'||(payload->>'override')||'|'||coalesce(payload->>'note','')||'|'||(payload->>'deposit_krw')||'|'||(select note from public.kashikiri_charge_admin where charge_id='$C3')||'|'||(select created_by from public.kashikiri_charge_admin where charge_id='$C3')||'|'||coalesce(created_by::text,'') from public.kashikiri_charges where id='$C3'")"
ok "이름 없는 회원도 링크 가능 — label 「회원 a1000000」" "회원 a1000000" "$($P -c "$S select j->>'subtitle' from public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M5','tier','M','kind','renew','currency','KRW')) j")"
ok "JPY 는 규정이 없어 금액·메모 없이는 NO_PRICE_RULE · 둘 다 주면 됨(¥ 정수)" "1|JPY|150000.00|1500000" "$($P -c "$S select public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M2','tier','M','kind','renew','currency','JPY','fx',10))" 2>&1 | grep -c NO_PRICE_RULE)|$($P -c "$S select (j->>'pay_currency')||'|'||(j->>'pay_amount')||'|'||(j->>'amount_krw') from public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M2','tier','M','kind','renew','currency','JPY','fx',10,'total',150000.4,'fee',150000.4,'note','엔화 약정')) j")"
ok "회원 없음 · 탈퇴 → MEMBER_NOT_FOUND" "1" "$($P -c "$S select public.taam_pay_link_create('membership', jsonb_build_object('user_id','a1000000-0000-4000-8000-0000000000ff','tier','M'))" 2>&1 | grep -c MEMBER_NOT_FOUND)"
ok "슈퍼어드민 아니면 거부 · 비로그인은 로그인 필요" "1|1" "$($P -c "set taam.uid='$M2'; set taam.super='0'; select public.taam_pay_link_create('custom', '{\"name\":\"x\",\"amount\":1000}')" 2>&1 | grep -c '권한이 없습니다')|$($P -c "set taam.uid=''; select public.taam_pay_link_create('custom', '{\"name\":\"x\",\"amount\":1000}')" 2>&1 | grep -c '로그인이 필요합니다')"
# ── 자유 금액 ──
r=$($P -c "$S select public.taam_pay_link_create('custom', jsonb_build_object('name','홍길동','phone','010-1234-5678','currency','KRW','amount',50000,'memo','와인 추가분'))::text")
C4=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "자유 금액 KRW 50,000 · 제목=메모 · 번호 숫자만 · 만료 7일" "custom|50000|와인 추가분|홍길동|01012345678|7" "$($P -c "select purpose||'|'||amount_krw||'|'||title||'|'||label||'|'||payer_phone||'|'||(expires_at::date - now()::date) from public.kashikiri_charges where id='$C4'")"
ok "자유 금액 USD 100 × 1300 = 130,000 · 이름 없음·0원은 거부" "100.00|130000|1|1" "$($P -c "$S select (j->>'pay_amount')||'|'||(j->>'amount_krw') from public.taam_pay_link_create('custom', jsonb_build_object('name','Ann','currency','USD','amount',100,'fx',1300)) j")|$($P -c "$S select public.taam_pay_link_create('custom', '{\"amount\":1000}')" 2>&1 | grep -c '이름이 필요')|$($P -c "$S select public.taam_pay_link_create('custom', '{\"name\":\"x\",\"amount\":0}')" 2>&1 | grep -c BAD_AMOUNT)"
# ── 티켓 좌석 (위임) ──
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp1','name','Joy','phone','+1 415 555 0100','pax',2,'currency','USD','fx',1380,'visit_date','2027.05.01','visit_time','18:00','user_id','$M3'))::text")
C5=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "티켓 링크: 금액 서버 (750000+150000+350000)×2 · \$1811.59 · purpose ticket · 제목 매장 · 부제 날짜 · 회원 연결 · LINK- 홀드" "ticket|2500000|1811.59|마츠카와|2027.05.01 18:00|$M3|true|1" "$($P -c "select purpose||'|'||amount_krw||'|'||pay_amount||'|'||title||'|'||subtitle||'|'||user_id||'|'||link_invite||'|'||(select count(*) from public.tickets where purchase_id like 'LINK-%' and status='hold') from public.kashikiri_charges where id='$C5'")"
ok "티켓 링크: 매장 어드민이 회원을 붙이면 거부 · 없는 uuid 여도 같은 거부(존재 여부 안 샘)" "1|1" "$($P -c "set taam.uid='$ADM'; set taam.super='0'; select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp1','name','Lee','pax',1,'currency','KRW','visit_date','2027.05.01','user_id','$M2'))" 2>&1 | grep -c '권한이 없습니다')|$($P -c "set taam.uid='$ADM'; set taam.super='0'; select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp1','name','Lee','pax',1,'currency','KRW','visit_date','2027.05.01','user_id','a1000000-0000-4000-8000-0000000000ff'))" 2>&1 | grep -c '권한이 없습니다')"
ok "티켓 링크는 매장 어드민도 만들 수 있다 (회원 없이)" "ticket|" "$($P -c "set taam.uid='$ADM'; set taam.super='0'; select (j->>'purpose')||'|'||coalesce(j->>'user_id','') from public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp1','name','Lee','pax',1,'currency','KRW','visit_date','2027.05.01')) j")"
# ── 결제 페이지 공개 RPC ──
T1=$($P -c "select token from public.kashikiri_charges where id='$C1'")
CD=$($P -c "$S select (public.taam_link_invite_create('tp3','Direct',null,1,'KRW',null,'2027.05.01','12:00'))->>'charge_id'")
ok "링크 초대 직접 경로(taam_link_invite_create)도 purpose 가 ticket 으로 들어온다" "ticket|true" "$($P -c "select purpose||'|'||link_invite from public.kashikiri_charges where id='$CD'")"
ok "운영 행 판정: LINK- 는 memberUid 가 있으면 운영 행이 아니다(그 회원의 예약으로 센다)" "true|false|true" "$($P -c "select public._taam_ticket_is_ops('LINK-x','{}')||'|'||public._taam_ticket_is_ops('LINK-x','{\"memberUid\":\"u\"}')||'|'||public._taam_ticket_is_ops('KSK-x','{\"memberUid\":\"u\"}')")"
ok "운영 행 판정: 회원 행(PAYH-/PAYC-)은 extra_data 운영 플래그가 있어도 회원 행 · 접두어 없는 옛 플래그 행은 종전대로 운영 행" "false|false|true|true" "$($P -c "select public._taam_ticket_is_ops('PAYH-x','{\"kashikiri\":true}')||'|'||public._taam_ticket_is_ops('PAYC-x','{\"linkInvite\":\"true\"}')||'|'||public._taam_ticket_is_ops('','{\"manualEntry\":true}')||'|'||public._taam_ticket_is_ops('MAN-x','{}')")"
ok "실제 가드: 회원이 자기 PAYH- 홀드에 kashikiri:true 를 넣어도 같은 회차 두 번째 홀드는 DUPLICATE_PURCHASE" "1" "$($P -c "set taam.uid='$M5'; set taam.super='0'; insert into public.tickets(id,user_id,ticket_product_id,restaurant_id,restaurant_name,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data) values (gen_random_uuid(),'$M5','tp2','b1000000-0000-4000-8000-000000000002','사이토','2027.05.01','19:30',1,100,'hold','PAYH-tp2_1','{\"kashikiri\":true}'); insert into public.tickets(id,user_id,ticket_product_id,restaurant_id,restaurant_name,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data) values (gen_random_uuid(),'$M5','tp2','b1000000-0000-4000-8000-000000000002','사이토','2027.05.01','19:30',1,100,'hold','PAYH-tp2_2','{\"kashikiri\":true}')" 2>&1 | grep -c DUPLICATE_PURCHASE)"
ok "charge_public(멤버십): purpose·title·mship.tier · venue_name=title · event_date 없음 · split 1" "membership|멤버십 M 가입|M|멤버십 M 가입||1" "$($P -c "select (j->>'purpose')||'|'||(j->>'title')||'|'||(j->'mship'->>'tier')||'|'||(j->>'venue_name')||'|'||coalesce(j->>'event_date','')||'|'||(j->>'split_count') from public.taam_kashikiri_charge_public('$T1') j")"
T5=$($P -c "select token from public.kashikiri_charges where id='$C5'")
ok "charge_public(티켓): 매장 EN·JA 표기 · 날짜 그대로" "Matsukawa|松川|2027-05-01|ticket" "$($P -c "select (j->>'venue_name_en')||'|'||(j->>'venue_name_jp')||'|'||(j->>'event_date')||'|'||(j->>'purpose') from public.taam_kashikiri_charge_public('$T5') j")"
ok "order_start(멤버십): 주문명 [TAAM] 멤버십 M 가입 · 금액 · 통화" "[TAAM] 멤버십 M 가입|11250000.00|KRW" "$($P -c "select (j->>'order_name')||'|'||(j->>'amount')||'|'||(j->>'currency') from public.taam_kashikiri_order_start('$T1','김회원') j")"
T4=$($P -c "select token from public.kashikiri_charges where id='$C4'")
ok "order_start(자유): 주문명 [TAAM] 와인 추가분" "[TAAM] 와인 추가분" "$($P -c "select j->>'order_name' from public.taam_kashikiri_order_start('$T4','홍길동') j")"
ok "order_start(티켓): 종전 주문명 [TAAM] 05/01 마츠카와" "[TAAM] 05/01 마츠카와" "$($P -c "select j->>'order_name' from public.taam_kashikiri_order_start('$T5','Joy') j")"
# ── 결제 → 연회비 자동 기록 · 알림 · 좌석 트리거 ──
$P -c "update public.kashikiri_charges set status='paid', approved_at='2026-10-18 10:00+09', payment_key='pk1', payer_name='김회원' where id='$C1'" >/dev/null
ok "멤버십 결제 → membership_fees 자동 1건 (연회비 1,125,000 · link · M · source pay_link · ref 청구 id · 메모에 예치금 부여 안내)" "1|1125000|link|M|pay_link|$C1|1|1" "$($P -c "select count(*)||'|'||min(amount_krw)||'|'||min(method)||'|'||min(tier)||'|'||min(source)||'|'||min(source_ref)||'|'||(select count(*) from public.membership_fees where user_id='$M2' and paid_at='2026-10-18' and note like '%예치금 부여 ₩10,125,000%')||'|'||(select count(*) from public.kashikiri_charges where id='$C1' and applied_at is not null and applied_note='fee_recorded') from public.membership_fees where source_ref='$C1'")"
ok "  → 슈퍼어드민 알림 「💳 멤버십 결제 완료」 · 예치금 부여 ₩10,125,000 필요 · url /?feedue=1" "💳 멤버십 결제 완료|1|/?feedue=1" "$($P -c "select title||'|'||(body like '%김회원 · 멤버십 M 가입 · ₩11,250,000 → 예치금 부여 ₩10,125,000 필요%')::int||'|'||url from public.notifications where type='kashikiri_paid' and payload->>'charge_id'='$C1' limit 1")"
ok "  → 회차 없는 청구는 좌석 동기화를 부르지 않는다" "0" "$($P -c "select count(*) from public.sync_calls")"
$P -c "update public.kashikiri_charges set status='paid', payer_name='다시' where id='$C1'" >/dev/null
ok "paid → paid 재갱신은 기록·알림이 늘지 않음" "1|1" "$($P -c "select (select count(*) from public.membership_fees where source_ref='$C1')||'|'||(select count(*) from public.notifications where payload->>'charge_id'='$C1')")"
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pk2' where id='$C2'" >/dev/null
ok "해외 T 갱신 결제 → 기록 fx USD 300 · 원화 402,695 · T · 알림엔 부여 문구 없음(갱신)" "USD|300.00|402695|T|1" "$($P -c "select fx_currency||'|'||fx_amount||'|'||amount_krw||'|'||tier from public.membership_fees where source_ref='$C2'")|$($P -c "select (body like '%\$300.00 (₩402,695) · 연회비 기록은 자동')::int from public.notifications where payload->>'charge_id'='$C2' limit 1")"
# ── 환불 → 기록 삭제 ──
ok "환불 견적(멤버십): 슈퍼어드민 판단 전액 admin_full" "admin_full|11250000" "$($P -c "select (j->>'policy')||'|'||(j->>'refund_krw') from public.taam_link_invite_refund_quote('$C1') j")"
$P -c "$S select public.taam_link_invite_mark_refunded('$C1', 11250000, 11250000, '테스트 환불')" >/dev/null
ok "환불 확정 → refunded · 자동 기록 삭제 · applied_note" "refunded|0|1" "$($P -c "select status||'|'||(select count(*) from public.membership_fees where source_ref='$C1')||'|'||(applied_note like '%refunded_fee_removed')::int from public.kashikiri_charges where id='$C1'")"
# ── 자유 금액 결제 알림 · 회차 있는 정산 청구는 좌석 동기화 ──
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pk4', payer_name='홍길동' where id='$C4'" >/dev/null
ok "자유 금액 결제 알림 「💳 결제 완료」 · 제목 · 이름 · 금액" "💳 결제 완료|와인 추가분 · 홍길동 · ₩50,000" "$($P -c "select title||'|'||body from public.notifications where payload->>'charge_id'='$C4' limit 1")"
EV=$($P -c "insert into public.kashikiri_events(venue_id, venue_name, event_date, status) values ('v1','대관매장','2027-06-01','open') returning id")
C6=$($P -c "insert into public.kashikiri_charges(event_id, label, amount_krw) values ('$EV','정산A',100000) returning id")
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pk6' where id='$C6'" >/dev/null
ok "회차 있는 정산 청구 결제 → 좌석 동기화 1회 · 알림은 종전 문구(매장 날짜)" "1|💳 정산 결제 완료|1" "$($P -c "select (select count(*) from public.sync_calls where event_id='$EV')||'|'||(select title from public.notifications where payload->>'charge_id'='$C6' limit 1)||'|'||(select (body like '대관매장 2027.06.01 · 정산A · ₩100,000%')::int from public.notifications where payload->>'charge_id'='$C6' limit 1)")"
# ── 티켓 링크 결제 → 회원 소유 ──
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pk5', payer_name='Joy Kim' where id='$C5'" >/dev/null
ok "티켓 링크 결제 → 홀드 active · 소유자 = 고른 회원 · 이름 = 회원 이름 · memberUid" "active|$M3|Eric Cheok|$M3" "$($P -c "select status||'|'||user_id||'|'||buyer_name||'|'||(extra_data->>'memberUid') from public.tickets where extra_data->>'chargeId'='$C5'")"
ok "  → 티켓 링크 환불 견적은 종전 규정(30분 안 전액)" "within_30min_full" "$($P -c "select j->>'policy' from public.taam_link_invite_refund_quote('$C5') j")"
# ── 기록 실패 경로 (라이브에서도 가능한 모양: membership_fees 표를 잠시 숨긴다) · auth.users 에 없는 회원은 링크 자체가 거절 ──
ok "auth.users 에 없는 회원(프로필만)에겐 링크를 못 만든다(FK)" "1" "$($P -c "$S select public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M4','tier','M','kind','join','currency','KRW'))" 2>&1 | grep -c 'violates foreign key')"
r=$($P -c "$S select public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M2','tier','M','kind','join','currency','KRW'))::text")
C7=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
$P -c "alter table public.membership_fees rename to membership_fees_hidden" >/dev/null
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pk7' where id='$C7'" 2>/dev/null >/dev/null
$P -c "alter table public.membership_fees_hidden rename to membership_fees" >/dev/null
ok "연회비 기록이 실패해도 결제는 유지 · applied_note 는 코드만 · 원문은 어드민 표 · ⚠ 알림 · 결제 완료 알림도 실패 문구" "paid|fee_record_failed|1|1|1" "$($P -c "select status||'|'||applied_note||'|'||(select count(*) from public.kashikiri_charge_admin where charge_id='$C7' and fail_note like '%membership_fees%')||'|'||(select count(*) from public.notifications where title='⚠ 연회비 자동 기록 실패' and payload->>'charge_id'='$C7')||'|'||(select count(*) from public.notifications where type='kashikiri_paid' and payload->>'charge_id'='$C7' and body like '%⚠ 연회비 자동 기록 실패%') from public.kashikiri_charges where id='$C7'")"
# ── 회원 지정 티켓 링크의 중복 선검사 · 소유자 이전이 가드에 막힐 때 ──
ok "같은 회차에 이미 소유 행이 있는 회원(M3 · 위에서 결제된 LINK-)을 또 붙이면 DUPLICATE_PURCHASE" "1" "$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp1','name','Again','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','18:00','user_id','$M3'))" 2>&1 | grep -c DUPLICATE_PURCHASE)"
ok "같은 날 같은 시간대(저녁 19:30)의 다른 회차는 TIME_CONFLICT · 점심(12:00)은 통과" "1|ticket" "$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp2','name','Eve','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','19:30','user_id','$M3'))" 2>&1 | grep -c TIME_CONFLICT)|$($P -c "$S select j->>'purpose' from public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp3','name','Noon','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','12:00','user_id','$M3')) j")"
# 선검사는 가드와 같은 식 — 기존 행의 visit_time 이 비어 있으면 회차 시간(tp3 12:00 점심)으로 보충한다 → 같은 날 저녁(tp1 18:00) 링크는 통과, 점심(tp3 자체는 같은 회차라 DUPLICATE)
$P -c "insert into public.tickets(id,user_id,ticket_product_id,restaurant_id,restaurant_name,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data) values (gen_random_uuid(),'$M6','tp3','b1000000-0000-4000-8000-000000000003','스시 사이토','2027.05.01','',1,100,'active','INV-m6','{\"inviteHold\":false,\"invitePaid\":true}')" >/dev/null
R1=$($P -c "$S select j->>'purpose' from public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp1','name','Dinner','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','18:00','user_id','$M6')) j")
$P -c "update public.kashikiri_charges set status='cancelled' where user_id='$M6' and status='pending'" >/dev/null   # 홀드를 풀어 다음 링크가 정원(tp1 4석)에 막히지 않게
R2=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp3','name','Same','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','12:00','user_id','$M6'))" 2>&1 | grep -c DUPLICATE_PURCHASE)
R3=$($P -c "$S select j->>'purpose' from public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp1','name','NoTime','pax',1,'currency','KRW','visit_date','2027.05.01','user_id','$M6')) j")
$P -c "update public.kashikiri_charges set status='cancelled' where user_id='$M6' and status='pending'" >/dev/null
R4=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp2','name','Lunch2','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','11:00','user_id','$M6'))" 2>&1 | grep -c TIME_CONFLICT)
ok "선검사 = 가드: 기존 INV- 행의 빈 visit_time 을 회차(12:00 점심)로 보충 → 같은 날 저녁(18:00) 링크 통과 · 같은 회차는 DUPLICATE_PURCHASE · 새 시각이 비면 회차(tp1 18:00)로 보충해도 통과 · 같은 날 점심(tp2 를 11:00 으로) 은 TIME_CONFLICT" "ticket|1|ticket|1" "$R1|$R2|$R3|$R4"
$P -c "delete from public.tickets where purchase_id='INV-m6'" >/dev/null
# 소유자 이전이 실제 가드에 막히는 경우 — 링크를 만든 뒤(선검사 통과) 결제 전에 그 회원이 같은 회차를 따로 확보했다
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp3','name','Guard','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','12:00','user_id','$M6'))::text")
C8=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
$P -c "insert into public.tickets(id,user_id,ticket_product_id,restaurant_id,restaurant_name,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data) values (gen_random_uuid(),'$M6','tp3','b1000000-0000-4000-8000-000000000003','스시 사이토','2027.05.01','12:00',1,100,'active','INV-m6b','{\"inviteHold\":false,\"invitePaid\":true}')" >/dev/null
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pk8', payer_name='Guard' where id='$C8'" 2>/dev/null >/dev/null
ok "소유자 이전이 **실제 가드**에 막혀도 결제·좌석은 확정 · 소유자는 어드민 그대로 · memberUidPending · ⚠ 알림 · extra_data 에는 코드만(거절 문구의 매장·구매 id 가 매장 어드민에게 새지 않게) · 원문은 어드민 표" "paid|active|$SU|$M6|1|DUPLICATE_PURCHASE|1" "$($P -c "select (select status from public.kashikiri_charges where id='$C8')||'|'||status||'|'||user_id||'|'||(extra_data->>'memberUidPending')||'|'||(select count(*) from public.notifications where title='⚠ 결제 링크 소유자 이전 실패' and payload->>'charge_id'='$C8')||'|'||(extra_data->>'ownerTransferError')||'|'||(select count(*) from public.kashikiri_charge_admin where charge_id='$C8' and fail_note like '소유자 이전 실패: DUPLICATE_PURCHASE%INV-m6b%') from public.tickets where extra_data->>'chargeId'='$C8'")"
# ── 목록 · 권한 ──
ok "목록: 슈퍼어드민 전부(최근순) · 회원 필터 · member_name · 어드민 메모 합침" "16|3|Eric Cheok|특별 약정" "$($P -c "$S select (select count(*) from public.taam_pay_link_list(60)) || '|' || (select count(*) from public.taam_pay_link_list(60, '$M3')) || '|' || (select j->>'member_name' from public.taam_pay_link_list(60, '$M3') j limit 1) || '|' || (select j->>'note' from public.taam_pay_link_list(60) j where (j->>'id')::uuid = '$C3')")"
ok "목록: 슈퍼어드민 아니면 거부" "1" "$($P -c "set taam.uid='$M2'; set taam.super='0'; select count(*) from public.taam_pay_link_list(10)" 2>&1 | grep -c '권한이 없습니다')"
ok "anon: 만들기·목록·금액 없음 · 공개 둘만" "false|false|false|true|true" "$($P -c "select has_function_privilege('anon','public.taam_pay_link_create(text,jsonb)','execute')||'|'||has_function_privilege('anon','public.taam_pay_link_list(integer,uuid,text)','execute')||'|'||has_function_privilege('anon','public.taam_membership_price(text,text,text)','execute')||'|'||has_function_privilege('anon','public.taam_kashikiri_charge_public(text)','execute')||'|'||has_function_privilege('anon','public.taam_kashikiri_order_start(text,text)','execute')")"
ok "끊기: 미결제 멤버십 링크 cancelled (paid 는 거부 그대로)" "cancelled|1" "$($P -c "$S select public.taam_kashikiri_charge_cancel('$C3')->>'ok'; select status from public.kashikiri_charges where id='$C3'" | tail -1)|$($P -c "$S select public.taam_kashikiri_charge_cancel('$C2')" 2>&1 | grep -c '환불로 처리')"
# ══ 2026-10-19 티켓 금액 수동 설정 · 미결제 링크 금액 변경 ══
$P -c "insert into public.ticket_products values ('tp4','b1000000-0000-4000-8000-000000000001','마츠카와','05.02','18:00',6,400000,100000,0,'Standard')" >/dev/null
$P -c "alter table public.ticket_products add column ovs_prices jsonb, add column overseas_agency_usd int" >/dev/null
outo=$($P -f supabase/migrations/20261019_link_invite_ovs_prices.sql 2>&1)
ok "확정 해외 정가 마이그레이션: 오류 없음 · ❌ 0 · 교체 ✅ · ②③④ ✅" "|0|1|3" "$(echo "$outo" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$outo" | grep -c '❌')|$(echo "$outo" | grep -c '✅ 교체')|$(echo "$outo" | grep -cE '^ *(②|③|④).*✅')"
out9=$($P -f supabase/migrations/20261019_pay_link_ticket_override.sql 2>&1)
ok "금액 수정 마이그레이션: 오류 없음 · ❌ 0 · 교체 ✅ · ②③④⑤ ✅" "|0|1|4" "$(echo "$out9" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out9" | grep -c '❌')|$(echo "$out9" | grep -c '✅ 교체')|$(echo "$out9" | grep -cE '^ *(②|③|④|⑤).*✅')"
outr=$($P -f supabase/migrations/20261019_link_invite_refund_agency.sql 2>&1)
ok "대행비 스냅샷 마이그레이션: 오류 없음 · ❌ 0 · 교체 ✅ 2 · ③④ ✅" "|0|2|2" "$(echo "$outr" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$outr" | grep -c '❌')|$(echo "$outr" | grep -c '✅ 교체')|$(echo "$outr" | grep -cE '^ *(③|④).*✅')"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp4','name','Ov','pax',2,'currency','KRW','visit_date','2027.05.02','visit_time','18:00','total',800000,'note','2인 특약가'))::text")
C9=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "금액 수정(KRW · 정가 1,000,000 → 800,000 · 사유): 청구 금액 · payload 플래그 · 응답 price_override · 어드민 메모에 정가→수정액·사유 · 홀드 price 는 정가 · payAmount 는 지움(매장 어드민이 읽는 행에 협의 금액 없음)" "800000|800000.00|true|true|[금액 수정] 정가 ₩1,000,000 → ₩800,000 · 2인 특약가|1000000|(없음)|true" \
   "$($P -c "select c.amount_krw||'|'||c.pay_amount||'|'||(c.payload->>'price_override') from public.kashikiri_charges c where c.id='$C9'")|$(echo "$r" | grep -oE '"price_override": [a-z]+' | grep -oE 'true|false')|$($P -c "select note from public.kashikiri_charge_admin where charge_id='$C9'")|$($P -c "select t.price||'|'||coalesce(t.extra_data->>'payAmount','(없음)')||'|'||(t.extra_data->>'priceOverride') from public.tickets t where t.extra_data->>'chargeId'='$C9'")"
ok "사유 없이 다른 금액 → OVERRIDE_NOTE_REQUIRED · 홀드도 안 남는다(롤백 · tp4 홀드 1건 그대로)" "1|1" "$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp4','name','NoNote','pax',1,'currency','KRW','visit_date','2027.05.02','total',300000))" 2>&1 | grep -c OVERRIDE_NOTE_REQUIRED)|$($P -c "select count(*) from public.tickets where ticket_product_id='tp4' and status='hold'")"
ok "매장 어드민이 total 을 보내면 PRICE_OVERRIDE_FORBIDDEN(홀드 없음)" "1|1" "$($P -c "set taam.uid='$ADM'; set taam.super='0'; select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp4','name','Adm','pax',1,'currency','KRW','visit_date','2027.05.02','total',100000,'note','x'))" 2>&1 | grep -c PRICE_OVERRIDE_FORBIDDEN)|$($P -c "select count(*) from public.tickets where ticket_product_id='tp4' and status='hold'")"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp4','name','Same','pax',1,'currency','KRW','visit_date','2027.05.02','total',500000))::text")
C10=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "정가와 같은 total(500,000)은 수정이 아니다 — 사유 없이 통과 · 플래그 없음" "500000|false|" "$($P -c "select c.amount_krw||'|'||coalesce(c.payload->>'price_override','false')||'|'||coalesce((select note from public.kashikiri_charge_admin a where a.charge_id=c.id),'') from public.kashikiri_charges c where c.id='$C10'")"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp4','name','Usd','pax',1,'currency','USD','fx',1400,'visit_date','2027.05.02','total',300,'note','해외 특약'))::text")
C11=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "외화 수정(USD 300 × 1400): pay_amount 300.00 · amount_krw 420,000 · 메모에 \$357.14 → \$300.00" "300.00|420000|1" "$($P -c "select c.pay_amount||'|'||c.amount_krw from public.kashikiri_charges c where c.id='$C11'")|$($P -c "select count(*) from public.kashikiri_charge_admin where charge_id='$C11' and note like '[금액 수정] 정가 \$357.14 → \$300.00 · 해외 특약'")"
ok "0 이하 금액은 BAD_AMOUNT" "1" "$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp4','name','Zero','pax',1,'currency','KRW','visit_date','2027.05.02','total',0,'note','x'))" 2>&1 | grep -c BAD_AMOUNT)"
# 결제 뒤 환불 견적은 수정액 기준
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pk9', payer_name='Ov' where id='$C9'" >/dev/null
ok "결제된 수정 링크의 환불 견적(30분 안) = 수정액 800,000" "800000|within_30min_full" "$($P -c "select (q->>'refund_krw')||'|'||(q->>'policy') from public.taam_link_invite_refund_quote('$C9') q")"
# ── 미결제 링크 금액 변경 ──
ok "금액 변경: 미결제 티켓 링크(C10 500,000 → 450,000 · 사유) changed · 청구 금액 · 홀드 payAmount 지움 · 어드민 메모 [금액 변경]" "true|450000|450000.00|true|(없음)|1" \
   "$($P -c "$S select (j->>'changed')||'|'||(j->>'amount_krw') from public.taam_pay_link_set_amount('$C10', 450000, '오픈 기념') j")|$($P -c "select c.pay_amount||'|'||(c.payload->>'price_override') from public.kashikiri_charges c where c.id='$C10'")|$($P -c "select coalesce(t.extra_data->>'payAmount','(없음)') from public.tickets t where t.extra_data->>'chargeId'='$C10'")|$($P -c "select count(*) from public.kashikiri_charge_admin where charge_id='$C10' and note like '[금액 변경 %] ₩500,000 → ₩450,000 · 오픈 기념'")"
ok "같은 금액으로 다시 → changed false · 사유 없으면 OVERRIDE_NOTE_REQUIRED · 0원 BAD_AMOUNT" "false|1|1" "$($P -c "$S select j->>'changed' from public.taam_pay_link_set_amount('$C10', 450000, '다시') j")|$($P -c "$S select public.taam_pay_link_set_amount('$C10', 400000, '')" 2>&1 | grep -c OVERRIDE_NOTE_REQUIRED)|$($P -c "$S select public.taam_pay_link_set_amount('$C10', 0, 'x')" 2>&1 | grep -c BAD_AMOUNT)"
C12=$($P -c "$S select j->>'charge_id' from public.taam_pay_link_create('membership', jsonb_build_object('user_id','$M2','tier','T','kind','renew','currency','KRW')) j")
ok "결제된 링크(C9)는 NOT_PENDING · 미결제 멤버십 링크(C12)는 BAD_PURPOSE · 회원 세션은 권한 없음" "1|1|1" "$($P -c "$S select public.taam_pay_link_set_amount('$C9', 1, 'x')" 2>&1 | grep -c NOT_PENDING)|$($P -c "$S select public.taam_pay_link_set_amount('$C12', 1, 'x')" 2>&1 | grep -c BAD_PURPOSE)|$($P -c "set taam.uid='$M2'; set taam.super='0'; select public.taam_pay_link_set_amount('$C10', 1, 'x')" 2>&1 | grep -c '권한이 없습니다')"
$P -c "update public.kashikiri_charges set order_id='KSK-started' where id='$C10'" >/dev/null
ok "손님이 결제를 시작한 링크(order_id 있음)는 PAYMENT_STARTED — 확정 경주를 피한다" "1" "$($P -c "$S select public.taam_pay_link_set_amount('$C10', 440000, '늦은 변경')" 2>&1 | grep -c PAYMENT_STARTED)"
ok "외화 링크 금액 변경(C11 \$300 → \$250): amount_krw = 250 × 1400 = 350,000 · 메모 두 줄째 이어 붙음" "250.00|350000|2" "$($P -c "$S select (j->>'pay_amount')||'|'||(j->>'amount_krw') from public.taam_pay_link_set_amount('$C11', 250, '추가 할인') j")|$($P -c "select array_length(string_to_array(note, E'\n'),1) from public.kashikiri_charge_admin where charge_id='$C11'")"
# ══ 2026-10-19 외화 링크 = 티켓 업로드의 확정 해외 정가(ovs_prices) 우선 ══
$P <<'SQL' >/dev/null
insert into public.ticket_products values ('tp5','b1000000-0000-4000-8000-000000000001','마츠카와','05.03','18:00',6,400000,100000,0,'Standard');
update public.ticket_products set ovs_prices = '{"usd":{"meal":300,"agency":120,"wine":""},"jpy":{"meal":45000,"agency":"","wine":null}}'::jsonb where id = 'tp5';
insert into public.ticket_products values ('tp6','b1000000-0000-4000-8000-000000000001','마츠카와','05.03','12:00',6,400000,100000,200000,'Standard');
update public.ticket_products set overseas_agency_usd = 150 where id = 'tp6';
SQL
ok "계산 함수: KRW 는 정가 그대로 · 환율 없는 외화는 null · 모르는 통화 null" "1000000|1000000|0|true|true" "$($P -c "select (j->>'pay')||'|'||(j->>'krw')||'|'||(j->>'fixed_count') from public.taam_ticket_price_fx('tp5',2,'KRW',null) j")|$($P -c "select (public.taam_ticket_price_fx('tp5',1,'USD',0) is null)||'|'||(public.taam_ticket_price_fx('tp5',1,'EUR',1500) is null)")"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp5','name','Fixed','pax',2,'currency','USD','fx',1400,'visit_date','2027.05.03','visit_time','18:00'))::text")
C13=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "USD 전항목 확정(식사 \$300 + 대행 \$120 · 주류 0원) × 2인 = \$840.00 · amount_krw = round(840×1400) = 1,176,000 · 홀드 price 는 원화 정가 1,000,000 · payAmount 840 · ovsFixed 2 · 수정 아님 · agencyPay 120 · agencyFee 168,000" "840.00|1176000|false|1000000|840.00|2|120|168000" \
   "$($P -c "select c.pay_amount||'|'||c.amount_krw||'|'||coalesce(c.payload->>'price_override','false') from public.kashikiri_charges c where c.id='$C13'")|$($P -c "select t.price||'|'||(t.extra_data->>'payAmount')||'|'||(t.extra_data->>'ovsFixed')||'|'||(t.extra_data->>'agencyPay')||'|'||(t.extra_data->>'agencyFee') from public.tickets t where t.extra_data->>'chargeId'='$C13'")"
$P -c "update public.kashikiri_charges set status='paid', approved_at=now()-interval '2 hours', payment_key='pk13', payer_name='Fixed' where id='$C13'" >/dev/null
ok "확정 대행비 링크 D-31 환불 견적 = \$840 − \$120×2 = \$600.00 · 원화 840,000 (결제 통화 기준)" "600.00|840000|d31_minus_agency" "$($P -c "select (q->>'refund_amount')||'|'||(q->>'refund_krw')||'|'||(q->>'policy') from public.taam_link_invite_refund_quote('$C13') q")"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp5','name','Yen','pax',1,'currency','JPY','fx',9.5,'visit_date','2027.05.03'))::text")
C14=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "JPY 섞임(식사 ¥45,000 확정 + 대행 ₩100,000 ÷ 9.5 = ¥10,526) = ¥55,526 · amount_jpy 같음 · amount_krw = round(55526×9.5) = 527,497 · ovsFixed 1" "55526.00|55526|527497|1" \
   "$($P -c "select c.pay_amount||'|'||c.amount_jpy||'|'||c.amount_krw from public.kashikiri_charges c where c.id='$C14'")|$($P -c "select t.extra_data->>'ovsFixed' from public.tickets t where t.extra_data->>'chargeId'='$C14'")"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp6','name','Legacy','pax',1,'currency','USD','fx',1400,'visit_date','2027.05.03'))::text")
C15=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "옛 해외 대행비 예외(overseas_agency_usd 150) 폴백: 식사·주류 ₩600,000 ÷ 1400 = \$428.57 + \$150 = \$578.57 · amount_krw 809,998" "578.57|809998" "$($P -c "select c.pay_amount||'|'||c.amount_krw from public.kashikiri_charges c where c.id='$C15'")"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp4','name','NoFix','pax',1,'currency','USD','fx',1400,'visit_date','2027.05.02'))::text")
C16=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "확정 정가 없는 회차(tp4)는 종전 식 그대로: \$357.14 · amount_krw 는 원화 정가 500,000 · ovsFixed 0" "357.14|500000|0" "$($P -c "select c.pay_amount||'|'||c.amount_krw from public.kashikiri_charges c where c.id='$C16'")|$($P -c "select t.extra_data->>'ovsFixed' from public.tickets t where t.extra_data->>'chargeId'='$C16'")"
ok "수정 비교 기준도 확정 정가: tp5 USD 1인 total 420(=\$300+\$120)은 수정 아님(사유 없이 통과) · total 400 은 사유 없으면 OVERRIDE_NOTE_REQUIRED" "false|1" \
   "$($P -c "$S select coalesce(j->>'price_override','false') from public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp5','name','Eq','pax',1,'currency','USD','fx',1400,'visit_date','2027.05.03','total',420)) j")|$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp5','name','Low','pax',1,'currency','USD','fx',1400,'visit_date','2027.05.03','total',400))" 2>&1 | grep -c OVERRIDE_NOTE_REQUIRED)"
# ── 적대 리뷰 반영 ──
ok "매장 어드민이 정가와 같은 total 을 보내면 통과(수정 아님 · 종전엔 PRICE_OVERRIDE_FORBIDDEN)" "true" "$($P -c "set taam.uid='$ADM'; set taam.super='0'; select j->>'ok' from public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp4','name','AdmEq','pax',1,'currency','KRW','visit_date','2027.05.02','total',500000)) j")"
C17=$($P -c "$S select j->>'charge_id' from public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp6','name','Memo','pax',1,'currency','KRW','visit_date','2027.05.03','total',700000,'note','메모만 남김')) j")
ok "정가와 같은 total 이라도 메모는 어드민 표에 남는다 · 플래그 없음" "메모만 남김|false" "$($P -c "select (select note from public.kashikiri_charge_admin where charge_id='$C17')||'|'||coalesce(c.payload->>'price_override','false') from public.kashikiri_charges c where c.id='$C17'")"
CS=$($P -c "insert into public.kashikiri_charges(event_id, team_id, label, amount_krw, pay_currency, pay_fx, pay_amount, status, purpose) select event_id, team_id, 'Settle', 100000, 'KRW', 1, 100000, 'pending', 'custom' from public.kashikiri_charges where id='$C9' returning id")
ok "대관 정산 청구(회차 있음 · link_invite 아님)는 금액 변경 거부 SETTLEMENT_CHARGE" "1" "$($P -c "$S select public.taam_pay_link_set_amount('$CS', 90000, '시트 우회')" 2>&1 | grep -c SETTLEMENT_CHARGE)"
CF=$($P -c "insert into public.kashikiri_charges(event_id, team_id, label, amount_krw, pay_currency, pay_fx, pay_amount, status, purpose) values (null, null, 'NoFx', 140000, 'USD', null, 100, 'pending', 'custom') returning id")
ok "환율 없는 외화 행은 FX_MISSING(1 로 지어내지 않는다)" "1" "$($P -c "$S select public.taam_pay_link_set_amount('$CF', 90, '환율 없음')" 2>&1 | grep -c FX_MISSING)"
ok "목록 RPC: order_id · price_override 키 (C10 결제 시작 · 금액 수정)" "KSK-started|true|false" "$($P -c "$S select (j->>'order_id')||'|'||(j->>'price_override') from public.taam_pay_link_list(100) j where j->>'id'='$C10'")|$($P -c "$S select j->>'price_override' from public.taam_pay_link_list(100) j where j->>'id'='$C13'")"
outo2=$($P -f supabase/migrations/20261019_link_invite_ovs_prices.sql 2>&1)
ok "확정 해외 정가 마이그레이션 두 번째 RUN: ❌ 0 · 「이미 새 판」" "0|1" "$(echo "$outo2" | grep -c '❌')|$(echo "$outo2" | grep -c '이미 새 판')"
# ══ 2026-10-19 항목별 금액(식사·대행·주류 1인 × 인원) — payload.override_parts · 환불 견적이 그 대행비를 뺀다 ══
outp=$($P -f supabase/migrations/20261019_pay_link_override_parts.sql 2>&1)
ok "항목별 금액 마이그레이션: 오류 없음 · ❌ 0 · 교체 ✅ 2 · ③④ ✅" "|0|2|2" "$(echo "$outp" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$outp" | grep -c '❌')|$(echo "$outp" | grep -c '✅ 교체')|$(echo "$outp" | grep -cE '^ *(③|④).*✅')"
$P <<'SQL' >/dev/null
insert into public.ticket_products(id,rest_id,rest_name,date,time,total_pax,meal_fee,agency_fee,wine_min,type_class) values
  ('tp7','b1000000-0000-4000-8000-000000000001','마츠카와','05.04','18:00',20,500000,100000,200000,'Standard'),
  ('tp8','b1000000-0000-4000-8000-000000000001','마츠카와','05.05','18:00',20,750000,150000,350000,'Standard');
update public.ticket_products set ovs_prices = '{"usd":{"meal":350,"agency":70,"wine":140}}'::jsonb where id = 'tp7';
SQL
PJ="'ticket_id','tp7','pax',2,'visit_date','2027.05.04','visit_time','18:00'"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','PartsKrw','currency','KRW','parts',jsonb_build_object('meal',450000,'agency',80000,'wine',200000),'total',1460000,'note','식사 할인 · 대행비 조정'))::text")
CP1=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "KRW 항목별(식사 450,000 + 대행 80,000 + 주류 200,000) × 2 = 1,460,000 · price_override · override_parts 저장 · 좌석 행 payAmount 없음" "1460000|true|80000|2|KRW|(없음)" \
   "$($P -c "select c.amount_krw||'|'||(c.payload->>'price_override')||'|'||(c.payload->'override_parts'->>'agency')||'|'||(c.payload->'override_parts'->>'pax')||'|'||(c.payload->'override_parts'->>'currency') from public.kashikiri_charges c where c.id='$CP1'")|$($P -c "select coalesce(t.extra_data->>'payAmount','(없음)') from public.tickets t where t.extra_data->>'chargeId'='$CP1'")"
ok "어드민 메모에 항목 내역 「(1인 식사 ₩450,000 + 대행 ₩80,000 + 주류 ₩200,000 × 2인)」" "1" "$($P -c "select count(*) from public.kashikiri_charge_admin where charge_id='$CP1' and note like '[금액 수정] 정가 ₩1,600,000 → ₩1,460,000 (1인 식사 ₩450,000 + 대행 ₩80,000 + 주류 ₩200,000 × 2인) · 식사 할인 · 대행비 조정'")"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','PartsSame','currency','KRW','parts',jsonb_build_object('meal',500000,'agency',100000,'wine',200000)))::text")
CP2=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "정가 항목 그대로면 수정 아님 — 사유 없이 통과 · 정가 1,600,000 · override_parts 없음" "1600000|false|(없음)" "$($P -c "select c.amount_krw||'|'||coalesce(c.payload->>'price_override','false')||'|'||coalesce(c.payload->>'override_parts','(없음)') from public.kashikiri_charges c where c.id='$CP2'")"
ok "항목 합 × 인원과 다른 total → PARTS_TOTAL_MISMATCH(홀드 안 남음)" "1" "$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','Mis','currency','KRW','parts',jsonb_build_object('meal',450000,'agency',80000,'wine',200000),'total',1500000,'note','x'))" 2>&1 | grep -c PARTS_TOTAL_MISMATCH)"
ok "음수·숫자 아닌 항목 → BAD_PARTS · 합 0 → BAD_AMOUNT" "1|1|1" "$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','Neg','currency','KRW','parts',jsonb_build_object('meal',-1,'agency',0,'wine',0),'note','x'))" 2>&1 | grep -c BAD_PARTS)|$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','Abc','currency','KRW','parts',jsonb_build_object('meal','abc'),'note','x'))" 2>&1 | grep -c BAD_PARTS)|$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','Zero','currency','KRW','parts',jsonb_build_object('meal',0,'agency',0,'wine',0),'note','x'))" 2>&1 | grep -c BAD_AMOUNT)"
ok "항목이 다른데 사유 없으면 OVERRIDE_NOTE_REQUIRED · 매장 어드민은 PRICE_OVERRIDE_FORBIDDEN · 매장 어드민이 정가 항목 그대로 보내면 통과" "1|1|true" "$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','NoNote','currency','KRW','parts',jsonb_build_object('meal',450000,'agency',100000,'wine',200000)))" 2>&1 | grep -c OVERRIDE_NOTE_REQUIRED)|$($P -c "set taam.uid='$ADM'; set taam.super='0'; select public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','AdmP','currency','KRW','parts',jsonb_build_object('meal',450000,'agency',100000,'wine',200000),'note','x'))" 2>&1 | grep -c PRICE_OVERRIDE_FORBIDDEN)|$($P -c "set taam.uid='$ADM'; set taam.super='0'; select j->>'ok' from public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','AdmSame','currency','KRW','parts',jsonb_build_object('meal',500000,'agency',100000,'wine',200000))) j")"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object($PJ,'name','Shuffle','currency','KRW','parts',jsonb_build_object('meal',550000,'agency',50000,'wine',200000),'note','대행비를 식사로'))::text")
CP3=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "총액은 정가와 같아도 대행비가 다르면 항목 저장(환불 기준) · price_override 는 false · 금액 1,600,000" "1600000|false|50000" "$($P -c "select c.amount_krw||'|'||coalesce(c.payload->>'price_override','false')||'|'||(c.payload->'override_parts'->>'agency') from public.kashikiri_charges c where c.id='$CP3'")"
PU="'ticket_id','tp7','pax',2,'visit_date','2027.05.04','visit_time','18:00','currency','USD','fx',1400"
r=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object($PU,'name','PartsUsd','parts',jsonb_build_object('meal',300,'agency',50,'wine',140),'total',980,'note','해외 특약'))::text")
CP4=$(echo "$r" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
ok "USD 항목별(\$300 + \$50 + \$140) × 2 = \$980.00 · 원화 round(980×1400) = 1,372,000 · override_parts agency 50" "980.00|1372000|50.00|true" "$($P -c "select c.pay_amount||'|'||c.amount_krw||'|'||(c.payload->'override_parts'->>'agency')||'|'||(c.payload->>'price_override') from public.kashikiri_charges c where c.id='$CP4'")"
ok "USD 확정 정가 항목 그대로(\$350·\$70·\$140)면 수정 아님 · \$1,120.00" "1120.00|false" "$($P -c "$S select (j->>'pay_amount')||'|'||coalesce(j->>'price_override','false') from public.taam_pay_link_create('ticket', jsonb_build_object($PU,'name','UsdSame','parts',jsonb_build_object('meal',350,'agency',70,'wine',140))) j")"
ok "확정 없는 회차(tp8) 3인 USD — 1인 환산 항목(\$543.48·\$108.70·\$253.62) 그대로면 수정 아님 · 센트 차이 없이 정가 \$2,717.39" "2717.39|false" "$($P -c "$S select (j->>'pay_amount')||'|'||coalesce(j->>'price_override','false') from public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp8','pax',3,'visit_date','2027.05.05','visit_time','18:00','currency','USD','fx',1380,'name','Conv3','parts',jsonb_build_object('meal',543.48,'agency',108.70,'wine',253.62))) j")"
# 환불 견적 D-31 — 항목별로 적은 대행비를 뺀다
$P -c "update public.kashikiri_charges set status='paid', approved_at=now()-interval '2 hours', payment_key='pkp'||left(id::text,6) where id in ('$CP1','$CP4')" >/dev/null
ok "KRW 항목별 링크 D-31 환불 = 1,460,000 − 80,000×2 = 1,300,000 (정가 대행비 100,000 이 아니라)" "1300000|160000|d31_minus_agency" "$($P -c "select (q->>'refund_krw')||'|'||(q->>'agency_krw')||'|'||(q->>'policy') from public.taam_link_invite_refund_quote('$CP1') q")"
ok "USD 항목별 링크 D-31 환불 = \$980 − \$50×2 = \$880.00 · 원화 1,232,000 · agency_krw 140,000" "880.00|1232000|140000" "$($P -c "select (q->>'refund_amount')||'|'||(q->>'refund_krw')||'|'||(q->>'agency_krw') from public.taam_link_invite_refund_quote('$CP4') q")"
ok "항목 없는 링크는 종전대로 좌석 행 대행비(CP2 · 미결제라 not_paid)" "not_paid" "$($P -c "select q->>'policy' from public.taam_link_invite_refund_quote('$CP2') q")"
ok "미결제 링크 금액 변경 뒤에도 override_parts 는 남는다(대행비 기준 유지)" "true|50000" "$($P -c "$S select j->>'changed' from public.taam_pay_link_set_amount('$CP3', 1550000, '추가 할인') j")|$($P -c "select c.payload->'override_parts'->>'agency' from public.kashikiri_charges c where c.id='$CP3'")"
outp2=$($P -f supabase/migrations/20261019_pay_link_override_parts.sql 2>&1)
ok "항목별 금액 마이그레이션 두 번째 RUN: 「이미 새 판」 2 · ❌ 0" "2|0" "$(echo "$outp2" | grep -c '이미 새 판')|$(echo "$outp2" | grep -c '❌')"
out10=$($P -f supabase/migrations/20261019_pay_link_ticket_override.sql 2>&1)
ok "금액 수정 마이그레이션 두 번째 RUN: ❌ 0 · 「이미 새 판」" "0|1" "$(echo "$out10" | grep -c '❌')|$(echo "$out10" | grep -c '이미 새 판')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
