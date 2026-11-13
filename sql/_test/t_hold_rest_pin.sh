#!/bin/bash
# 회원 구매 행(PAY*)의 매장 = 회차의 매장 — 2026-11-13. 먼저: 로컬 pg. 실행: bash sql/_test/t_hold_rest_pin.sh
#   회원이 홀드 INSERT 에 적은 restaurant_id·restaurant_name 은 회차 값으로 맞춘다(재구매 가드가 그 뒤에 본다) · 회차 없는 홀드 거절 · 운영 행 표시 지움 ·
#   매장 이름 UPDATE 되돌림 · 서버·슈퍼어드민·운영 행은 그대로 · 재실행.
cd "$(dirname "$0")/../.."
DB=t_holdrestpin; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
A=a1000000-0000-4000-8000-000000000011; SU=a1000000-0000-4000-8000-000000000001; PA=a1000000-0000-4000-8000-000000000022
R1=c1000000-0000-4000-8000-000000000001; R2=c1000000-0000-4000-8000-000000000002
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
insert into auth.users values ('$A'),('$SU'),('$PA');
create table public.profiles(id uuid primary key, display_name text, role text);
insert into public.profiles values ('$A','김회원','user'),('$SU','Super Admin','superadmin'),('$PA','파트너','user');
create or replace function public._taam_uid_is_super() returns boolean language sql stable security definer set search_path=public as
  \$\$ select exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('super_admin','superadmin')) \$\$;
-- 라이브 모양: ticket_products.id text · rest_id uuid · rest_name text / tickets.restaurant_id text
create table public.ticket_products(id text primary key, rest_id uuid, rest_name text, date text, time text, status text default 'active');
alter table public.ticket_products enable row level security;                      -- 회원은 못 읽는다(가드는 definer 로 읽는다)
insert into public.ticket_products values ('tp1','$R1','미타니','2026.12.15','18:00','active'), ('tp2','$R2','스시 사이토','2026.12.20','19:00','active'),
  ('tpNoName','$R1',null,'2026.12.22','19:00','active'), ('tpNoRest',null,null,'2026.12.23','19:00','active');
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_id text, restaurant_name text, ticket_product_id text,
  purchase_id text, status text default 'hold', price integer default 0, party_size integer default 2, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
-- 재구매 가드 자리 — 같은 이름의 트리거가 「그 시점에 본 매장 id」를 적는다(맞춘 뒤에 도는지 본다)
create table public.seen(purchase_id text, rest text, flagged boolean);
create or replace function public.taam_guard_repurchase() returns trigger language plpgsql security definer set search_path=public as
  \$\$ begin insert into public.seen values (new.purchase_id, new.restaurant_id,
         coalesce((new.extra_data->>'manualEntry')::boolean, false) or (new.extra_data ? 'inviteHold'));   -- 라이브 가드는 이 표시가 있으면 검사를 건너뛴다
       return new; end \$\$;
create trigger trg_taam_repurchase_guard before insert on public.tickets for each row execute function public.taam_guard_repurchase();
-- 행 가드 자리(확인 표 ⑤ 가 본문에서 restaurant_id 를 찾는다)
create or replace function public.taam_guard_ticket_row() returns trigger language plpgsql as
  \$\$ begin if new.restaurant_id is distinct from old.restaurant_id then raise exception 'x'; end if; return new; end \$\$;
grant usage on schema public to authenticated; grant usage on schema auth to authenticated;
grant select, insert, update on public.tickets to authenticated; grant select on public.profiles to authenticated;
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
out=$($P -f supabase/migrations/20261113_ticket_hold_rest_pin.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0 · ④ 0 · ⑤ ✅" "|0|0|✅" "$(echo "$out" | grep -E "ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep '④' | awk -F'|' '{print $NF}' | tr -d ' ')|$(echo "$out" | grep '⑤' | awk -F'|' '{print $NF}' | tr -d ' ')"
asm(){ $P -c "set role authenticated; set taam.uid='$1'; $2; reset role;" 2>&1; }
row(){ $P -c "select coalesce(restaurant_id,'-')||'|'||coalesce(restaurant_name,'-') from public.tickets where purchase_id='$1'"; }
seen(){ $P -c "select coalesce(rest,'-') from public.seen where purchase_id='$1'"; }
# ── 회원 세션 ──
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','$R1','미타니','tp1','PAYH-tp1_1')")
ok "정상 홀드(회차와 같은 값) → 그대로 · 오류 없음" "$R1|미타니|" "$(row PAYH-tp1_1)|$(echo "$r" | grep -c ERROR | sed 's/^0$//')"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','$R2','다른 매장','tp1','PAYH-tp1_2')")
ok "⭐ 다른 매장 id 로 넣은 홀드 → 회차의 매장으로 맞춘다(재구매 제한 비켜 가기)" "$R1|미타니" "$(row PAYH-tp1_2)"
ok "⭐ 재구매 가드는 맞춘 뒤의 매장 id 를 본다(이름 순서)" "$R1" "$(seen PAYH-tp1_2)"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','constructor','미타니','tp1','PAYH-tp1_3')")
ok "매장 id 'constructor' → 회차 값" "$R1|미타니" "$(row PAYH-tp1_3)"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A', \$q\$x');window.__xss=8;//\$q\$, \$q\$x\" onanimationstart=\"y\$q\$, 'tp2', 'PAYH-tp2_1')")
ok "따옴표가 든 매장 id·이름 → 회차 값" "$R2|스시 사이토" "$(row PAYH-tp2_1)"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A', null, null, 'tp1', 'PAYH-tp1_4')")
ok "매장 칸을 비워 보낸 홀드 → 회차 값으로 채운다" "$R1|미타니" "$(row PAYH-tp1_4)"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','$R2','보낸 이름','tpNoName','PAYH-nn_1')")
ok "회차에 이름이 비어 있으면 id 만 맞추고 이름은 보낸 값" "$R1|보낸 이름" "$(row PAYH-nn_1)"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','$R2','보낸 이름','tpNoRest','PAYH-nr_1')")
ok "회차에 매장이 비어 있으면 보낸 값 그대로" "$R2|보낸 이름" "$(row PAYH-nr_1)"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','$R2','보낸 이름','없는회차','PAYH-zz_1')")
ok "⭐ 없는 회차의 홀드 → 거절(TICKET_NOT_FOUND) · 행 없음" "1|0" "$(echo "$r" | grep -c 'TICKET_NOT_FOUND')|$($P -c "select count(*) from public.tickets where purchase_id='PAYH-zz_1'")"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','$R2','보낸 이름',null,'PAYH-none_1')")
ok "⭐ 회차를 비운 홀드 → 거절(TICKET_NOT_FOUND) · 행 없음" "1|0" "$(echo "$r" | grep -c 'TICKET_NOT_FOUND')|$($P -c "select count(*) from public.tickets where purchase_id='PAYH-none_1'")"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','$R1','미타니','tp1 ','PAYH-sp_1')")
ok "회차 id 뒤에 공백 → 없는 회차 → 거절" "1" "$(echo "$r" | grep -c 'TICKET_NOT_FOUND')"
# ── 운영 행 표시 ──
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id, extra_data) values ('$A','$R1','미타니','tp1','PAYH-tp1_f1','{\"seatHold\":true,\"heldAt\":\"x\",\"pkg\":\"pk1\",\"manualEntry\":true,\"inviteHold\":\"1\",\"kashikiri\":true,\"linkInvite\":true,\"memberUid\":\"u\"}'::jsonb)")
ok "⭐ 회원 홀드의 운영 행 표시 다섯 → 지운다 · 앱이 쓰는 칸(seatHold·heldAt·pkg)은 그대로" "heldAt,pkg,seatHold" "$($P -c "select string_agg(k, ',' order by k) from public.tickets t, jsonb_object_keys(t.extra_data) k where t.purchase_id='PAYH-tp1_f1'")"
ok "⭐ 재구매 가드는 표시가 지워진 행을 본다(건너뛰지 않는다)" "f" "$($P -c "select flagged from public.seen where purchase_id='PAYH-tp1_f1'")"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id, extra_data) values ('$A','$R1','미타니','tp1','PAYH-tp1_f2','[1,2]'::jsonb)")
ok "extra_data 가 객체가 아니어도 오류 없이 들어간다" "1|" "$($P -c "select count(*) from public.tickets where purchase_id='PAYH-tp1_f2'")|$(echo "$r" | grep -c ERROR | sed 's/^0$//')"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id, status) values ('$A','$R2','다른 매장','tp1','PAYC-o1','active')")
ok "PAYC- 도 회원 구매 행 — 맞춘다" "$R1|미타니" "$(row PAYC-o1)"
# ── 운영 행 · 파트너 ──
r=$(asm $PA "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id, status) values ('$PA','$R2','수동 입력 매장','tp1','MAN-1','manual')")
ok "운영 행(MAN-)은 손대지 않는다(INSERT 가드가 매장 권한을 본다)" "$R2|수동 입력 매장" "$(row MAN-1)"
r=$(asm $PA "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id, status, extra_data) values ('$PA','$R1','미타니',null,'MAN-2','manual','{\"manualEntry\":true}'::jsonb)")
ok "운영 행은 회차가 없어도 · 표시가 있어도 그대로" "$R1|미타니|true" "$(row MAN-2)|$($P -c "select extra_data->>'manualEntry' from public.tickets where purchase_id='MAN-2'")"
r=$(asm $PA "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$PA','$R2','초대 홀드','tp1','INVH-abcd1234-1')")
ok "초대 홀드(INVH-)도 그대로" "$R2|초대 홀드" "$(row INVH-abcd1234-1)"
r=$(asm $PA "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$PA','$R2','다른 매장','tp1','PAYH-tp1_pa')")
ok "파트너가 회원처럼 넣은 PAYH- 는 맞춘다" "$R1|미타니" "$(row PAYH-tp1_pa)"
# ── 슈퍼어드민 · 서버 ──
r=$(asm $SU "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$SU','$R2','슈퍼 입력','tp1','PAYH-tp1_su')")
ok "슈퍼어드민 → 그대로" "$R2|슈퍼 입력" "$(row PAYH-tp1_su)"
r=$(asm $SU "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$SU','$R2','슈퍼 입력',null,'PAYH-su_none')")
ok "슈퍼어드민은 회차 없는 행도 넣는다" "1" "$($P -c "select count(*) from public.tickets where purchase_id='PAYH-su_none'")"
r=$($P -c "set taam.uid=''; insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id, status) values ('$A','$R2','서버 입력','tp1','PAYC-srv','active')" 2>&1)
ok "서버(uid 없음 — Edge 카드 확정 폴백) → 그대로" "$R2|서버 입력" "$(row PAYC-srv)"
r=$($P -c "set taam.uid=''; insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id, status) values ('$A','$R2','서버 입력',null,'PAYC-srv2','active')" 2>&1)
ok "서버는 회차 없는 행도 넣는다" "1" "$($P -c "select count(*) from public.tickets where purchase_id='PAYC-srv2'")"
# ── 매장 이름 UPDATE ──
r=$(asm $A "update public.tickets set restaurant_name = '미타니 (위조 · x\" onmouseover=\"y)' where purchase_id='PAYH-tp1_1'")
ok "⭐ 회원이 자기 홀드의 매장 이름을 바꾸면 되돌린다 · 오류 없음" "$R1|미타니|" "$(row PAYH-tp1_1)|$(echo "$r" | grep -c ERROR | sed 's/^0$//')"
r=$(asm $A "update public.tickets set restaurant_name = '위조', status = 'cancelled' where purchase_id='PAYH-tp1_1'")
ok "이름 변경 + 취소를 한 문장으로 → 이름만 되돌리고 취소는 반영" "미타니|cancelled" "$($P -c "select restaurant_name||'|'||status from public.tickets where purchase_id='PAYH-tp1_1'")"
r=$(asm $PA "update public.tickets set restaurant_name = '고친 이름' where purchase_id='MAN-1'")
ok "운영 행(MAN-)의 이름은 넣은 어드민이 고칠 수 있다" "고친 이름" "$($P -c "select restaurant_name from public.tickets where purchase_id='MAN-1'")"
r=$(asm $SU "update public.tickets set restaurant_name = '슈퍼가 고침' where purchase_id='PAYH-tp1_2'")
ok "슈퍼어드민은 회원 구매 행의 이름도 고친다" "슈퍼가 고침" "$($P -c "select restaurant_name from public.tickets where purchase_id='PAYH-tp1_2'")"
r=$($P -c "set taam.uid=''; update public.tickets set restaurant_name = '서버가 고침' where purchase_id='PAYH-tp1_3'" 2>&1)
ok "서버(uid 없음)도 고친다" "서버가 고침" "$($P -c "select restaurant_name from public.tickets where purchase_id='PAYH-tp1_3'")"
$P -c "create or replace function public.fix_name(p text) returns void language sql security definer set search_path=public as \$f\$ update public.tickets set restaurant_name = '함수가 고침' where purchase_id = p \$f\$; grant execute on function public.fix_name(text) to authenticated;" >/dev/null
r=$(asm $A "select public.fix_name('PAYH-tp1_4')")
ok "회원이 부른 security definer 함수의 갱신은 그대로(앱이 직접 보낸 문장만 본다)" "함수가 고침" "$($P -c "select restaurant_name from public.tickets where purchase_id='PAYH-tp1_4'")"
# ── 모양 ──
ok "이름 트리거: BEFORE UPDATE OF restaurant_name · invoker" "1|t|f" "$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_ticket_rest_name' and not tgisinternal")|$($P -c "select (tgtype::int & 2) = 2 and (tgtype::int & 16) = 16 and (tgtype::int & 4) = 0 from pg_trigger where tgname='trg_taam_guard_ticket_rest_name'")|$($P -c "select prosecdef from pg_proc where oid=to_regproc('public.taam_guard_ticket_rest_name')")"
ok "트리거 하나 · BEFORE INSERT 만 · definer · 회원 실행 권한 없음" "1|t|f|t|f" "$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_ticket_rest_pin' and not tgisinternal")|$($P -c "select (tgtype::int & 2) = 2 and (tgtype::int & 4) = 4 from pg_trigger where tgname='trg_taam_guard_ticket_rest_pin'")|$($P -c "select (tgtype::int & 16) = 16 from pg_trigger where tgname='trg_taam_guard_ticket_rest_pin'")|$($P -c "select prosecdef from pg_proc where oid=to_regproc('public.taam_guard_ticket_rest_pin')")|$($P -c "select has_function_privilege('authenticated','public.taam_guard_ticket_rest_pin()','execute')")"
# ── ④ 정보: 가드 전에 들어간 어긋난 행을 센다 ──
$P -c "alter table public.tickets disable trigger trg_taam_guard_ticket_rest_pin; insert into public.tickets(user_id, restaurant_id, ticket_product_id, purchase_id) values ('$A','$R2','tp1','PAYH-old_bad'); alter table public.tickets enable trigger trg_taam_guard_ticket_rest_pin;" >/dev/null
# (슈퍼어드민·서버가 넣은 두 행 + 방금 한 행 = 3)
out2=$($P -f supabase/migrations/20261113_ticket_hold_rest_pin.sql 2>&1)
ok "재실행 안전 · ❌ 0 · ④ 정보 3(슈퍼어드민·서버·옛 행)" "0|3" "$(echo "$out2" | grep -c '❌')|$(echo "$out2" | grep '④' | awk -F'|' '{print $NF}' | tr -d ' ')"
r=$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','$R2','다른 매장','tp1','PAYH-tp1_9')")
ok "재실행 뒤에도 맞춘다 · 트리거 하나" "$R1|미타니|1" "$(row PAYH-tp1_9)|$($P -c "select count(*) from pg_trigger where tgname='trg_taam_guard_ticket_rest_pin' and not tgisinternal")"
# ── _taam_uid_is_super 가 없으면 ② ❌ ──
$P -c "drop function public._taam_uid_is_super() cascade" >/dev/null 2>&1
out3=$($P -f supabase/migrations/20261113_ticket_hold_rest_pin.sql 2>&1)
ok "_taam_uid_is_super 없음 → 트리거 둘 다 안 건다 · ①②⑥ ❌ 3 · 회원 홀드는 그대로 들어간다(막지 않는다)" "0|3|$R2" "$($P -c "select count(*) from pg_trigger where tgname in ('trg_taam_guard_ticket_rest_pin','trg_taam_guard_ticket_rest_name') and not tgisinternal")|$(echo "$out3" | grep -c '❌')|$(asm $A "insert into public.tickets(user_id, restaurant_id, restaurant_name, ticket_product_id, purchase_id) values ('$A','$R2','다른 매장','tp1','PAYH-tp1_nofn') returning restaurant_id" | head -1)"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
if [ $FAIL = 0 ]; then echo "=== 전부 통과 ==="; else echo "=== 실패 있음 ==="; exit 1; fi
