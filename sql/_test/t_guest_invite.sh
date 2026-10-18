#!/bin/bash
# 비회원 결제 → 게스트 초대장 · 가입하면 티켓 붙이기 회귀 — 2026-10-19. 먼저: 로컬 pg. 실행: bash sql/_test/t_guest_invite.sh
cd "$(dirname "$0")/../.."
DB=t_ginv; psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; psql -h /tmp -U postgres -d postgres -q -c "create database $DB" >/dev/null
P="psql -h /tmp -U postgres -d $DB -q -At"
SU=a1000000-0000-4000-8000-000000000001; NEW=a1000000-0000-4000-8000-000000000021; NEW2=a1000000-0000-4000-8000-000000000022; M=a1000000-0000-4000-8000-000000000011
$P <<SQL >/dev/null 2>&1
create schema auth; create table auth.users(id uuid primary key);
do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if; end \$\$;
create or replace function auth.uid() returns uuid language sql stable as \$\$ select nullif(current_setting('taam.uid', true),'')::uuid \$\$;
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable as \$\$ select uid = '$SU'::uuid \$\$;
create or replace function public._taam_ts_safe(p_any text) returns timestamptz language plpgsql immutable as \$\$ begin return p_any::timestamptz; exception when others then return null; end \$\$;
insert into auth.users values ('$SU'),('$NEW'),('$NEW2'),('$M');
create table public.profiles(id uuid primary key, display_name text, phone text, created_at timestamptz default now(), role text);
insert into public.profiles values ('$SU','Super','010-0000-0000',now(),'superadmin'),('$M','기존회원','010-2222-3333',now(),'user');
create table public.invite_codes(code text primary key, type text, country text, invitee_name text, invitee_phone text, invitee_email text, invitee_tier text, invite_message text, invited_by text, invited_at text, expires_at text, used boolean default false, used_at text, used_by_name text, used_by_phone text, used_by_email text, member_id text);
create table public.kashikiri_events(id uuid primary key default gen_random_uuid(), venue_name text, event_date date, event_time time, fx_rate numeric, fx_note text, venue_id text);
create table public.kashikiri_teams(id uuid primary key default gen_random_uuid(), seq int, pax int);
create table public.restaurants(id uuid primary key default gen_random_uuid(), name_en text, name_jp text);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid, team_id uuid, label text, payer_name text, payer_phone text, user_id uuid, amount_krw int, amount_jpy int, pay_currency text default 'KRW', pay_fx numeric, pay_amount numeric, status text default 'pending', token text default md5(random()::text), expires_at timestamptz, approved_at timestamptz, receipt_url text, link_invite boolean default false, purpose text default 'custom', title text, subtitle text, payload jsonb default '{}'::jsonb, created_at timestamptz default now());
create table public.tickets(id uuid primary key default gen_random_uuid(), user_id uuid, restaurant_name text, reservation_date text, visit_time text, party_size int, buyer_name text, buyer_phone text, status text, purchase_id text, extra_data jsonb default '{}'::jsonb, created_at timestamptz default now());
grant usage on schema public to authenticated, anon;
SQL
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
# charge_public 원본(20261018 판)을 먼저 올린다 — md5 가드가 「원본과 같음」을 봐야 교체한다
awk '/^create or replace function public.taam_kashikiri_charge_public/{p=1} p{print} /^grant execute on function public.taam_kashikiri_charge_public/{if(p){exit}}' supabase/migrations/20261018_pay_link.sql > /tmp/_cp.sql
$P -f /tmp/_cp.sql >/dev/null 2>&1
out=$($P -f supabase/migrations/20261019_guest_invite.sql 2>&1)
ok "마이그레이션 오류 없음 · ❌ 0 · 공개 함수 ✅ 교체" "|0|1" "$(echo "$out" | grep -E "^ERROR|^psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -c '✅ 교체')"
# ── 비회원 티켓 링크 청구 + LINK- 홀드 → 결제 ──
C1=$($P -c "insert into public.kashikiri_charges(label, payer_name, payer_phone, amount_krw, pay_amount, link_invite, purpose, title, subtitle, expires_at) values ('Joy','Joy','010-1234-5678',2500000,2500000,true,'ticket','마츠카와','2027.05.01 18:00', now()+interval '7 days') returning id")
$P -c "insert into public.tickets(user_id, restaurant_name, reservation_date, visit_time, party_size, buyer_name, buyer_phone, status, purchase_id, extra_data) values ('$SU','마츠카와','2027.05.01','18:00',2,'Joy','010-1234-5678','hold','LINK-c1','{\"linkInvite\":true,\"chargeId\":\"$C1\"}')" >/dev/null
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payer_name='Joy' where id='$C1'; update public.tickets set status='active' where purchase_id='LINK-c1'" >/dev/null
CODE=$($P -c "select payload->>'guest_invite_code' from public.kashikiri_charges where id='$C1'")
ok "결제 → 게스트 초대장: 코드 8자(G…) · A 등급 · 번호 · pay_link · KR · 30일 만료(text 칸) · payload 에 코드" "8|G|A|010-1234-5678|pay_link|KR|1|1" \
   "$($P -c "select length('$CODE')||'|'||left('$CODE',1)||'|'||invitee_tier||'|'||invitee_phone||'|'||invited_by||'|'||country||'|'||(public._taam_ts_safe(expires_at) between now()+interval '29 days' and now()+interval '31 days')::int||'|'||(select count(*) from public.kashikiri_charges where id='$C1' and payload->>'guest_invite_code'='$CODE') from public.invite_codes where code='$CODE'")"
T1=$($P -c "select token from public.kashikiri_charges where id='$C1'")
ok "/pay 읽기: paid·비회원이면 guest_invite {code, expires_at}" "$CODE|1" "$($P -c "select (j->'guest_invite'->>'code')||'|'||((j->'guest_invite'->>'expires_at') is not null)::int from public.taam_kashikiri_charge_public('$T1') j")"
# ── 같은 번호 두 번째 결제 → 코드 재사용 · 회원 청구 → 초대장 없음 · 번호 없음 → 없음 ──
C2=$($P -c "insert into public.kashikiri_charges(label, payer_phone, amount_krw, pay_amount, link_invite, purpose, title, expires_at) values ('Joy2','+82 10-1234-5678',100,100,true,'ticket','사이토', now()+interval '7 days') returning id")
$P -c "update public.kashikiri_charges set status='paid', approved_at=now() where id='$C2'" >/dev/null
C3=$($P -c "insert into public.kashikiri_charges(label, payer_phone, user_id, amount_krw, pay_amount, link_invite, purpose, title, payload, expires_at) values ('회원','010-2222-3333','$M',100,100,true,'ticket','카타오리','{\"member_uid\":\"$M\"}', now()+interval '7 days') returning id")
$P -c "update public.kashikiri_charges set status='paid', approved_at=now() where id='$C3'" >/dev/null
C4=$($P -c "insert into public.kashikiri_charges(label, payer_phone, amount_krw, pay_amount, link_invite, purpose, title, expires_at) values ('번호없음','',100,100,true,'ticket','카타오리', now()+interval '7 days') returning id")
$P -c "update public.kashikiri_charges set status='paid', approved_at=now() where id='$C4'" >/dev/null
ok "같은 번호(+82 표기) 재결제 → 같은 코드 재사용 · 회원 청구·번호 없음 → 초대장 없음 · 초대장 총 1장" "$CODE|0|0|1" "$($P -c "select (select payload->>'guest_invite_code' from public.kashikiri_charges where id='$C2')||'|'||(select count(*) from public.kashikiri_charges where id='$C3' and payload ? 'guest_invite_code')||'|'||(select count(*) from public.kashikiri_charges where id='$C4' and payload ? 'guest_invite_code')||'|'||(select count(*) from public.invite_codes)")"
T3=$($P -c "select token from public.kashikiri_charges where id='$C3'")
ok "/pay 읽기: 회원 청구에는 guest_invite 없음" "1" "$($P -c "select (coalesce(jsonb_typeof(j->'guest_invite'),'null')='null')::int from public.taam_kashikiri_charge_public('$T3') j")"
# ── 해외 번호 → country EN ──
C5=$($P -c "insert into public.kashikiri_charges(label, payer_phone, amount_krw, pay_amount, link_invite, purpose, title, expires_at) values ('Foreign','+1 415 555 0100',100,100,true,'ticket','마츠카와', now()+interval '7 days') returning id")
$P -c "update public.kashikiri_charges set status='paid', approved_at=now() where id='$C5'" >/dev/null
ok "해외 번호 → 초대장은 만들되 country EN" "EN" "$($P -c "select c.country from public.invite_codes c join public.kashikiri_charges k on k.payload->>'guest_invite_code' = c.code where k.id='$C5'")"
# ── 가입: consume-invite 가 used=true 로 (서버) → 번호로 회원을 찾아 티켓 붙이기 ──
# 가입(프로필 INSERT 트리거 → 번호 일치 → 붙는다)
$P -c "insert into public.profiles(id, display_name, phone, role) values ('$NEW','조이','01012345678','user')" >/dev/null
ok "가입(프로필 INSERT · 번호 일치) → 그 번호의 게스트 초대 청구 LINK- 행이 새 회원 것 · memberUid · 청구 user_id 도" "$NEW|$NEW|$NEW|guest_signup" \
   "$($P -c "select t.user_id||'|'||(t.extra_data->>'memberUid')||'|'||(select user_id from public.kashikiri_charges where id='$C1')||'|'||(t.extra_data->>'attachedBy') from public.tickets t where t.purchase_id='LINK-c1'")"
ok "두 번째 청구(C2 · 같은 번호 · 좌석 행 없음)도 user_id 가 붙었다 · 회원 청구 C3 는 그대로 M" "$NEW|$M" "$($P -c "select (select user_id from public.kashikiri_charges where id='$C2')||'|'||(select user_id from public.kashikiri_charges where id='$C3')")"
# 초대 사용 표시 경로 — 다른 손님(해외) 이 코드를 쓰고 가입(프로필은 번호 없이 먼저 생김 → 그 뒤 used=true)
CODE5=$($P -c "select payload->>'guest_invite_code' from public.kashikiri_charges where id='$C5'")
$P -c "insert into public.tickets(user_id, restaurant_name, reservation_date, visit_time, party_size, buyer_name, buyer_phone, status, purchase_id, extra_data) values ('$SU','마츠카와','2027.06.01','18:00',1,'Foreign','+1 415 555 0100','active','LINK-c5','{\"linkInvite\":true,\"chargeId\":\"$C5\"}')" >/dev/null
$P -c "insert into public.profiles(id, display_name, phone, role) values ('$NEW2','포린','+14155550100','user')" >/dev/null
ok "가입 때 번호가 있으면 프로필 경로로 이미 붙는다 (해외 번호 키도 같은 규칙)" "$NEW2" "$($P -c "select user_id from public.tickets where purchase_id='LINK-c5'")"
$P -c "update public.tickets set user_id='$SU', extra_data = extra_data - 'memberUid' where purchase_id='LINK-c5'; update public.kashikiri_charges set user_id=null where id='$C5'" >/dev/null
$P -c "update public.invite_codes set used=true, used_at=now()::text, used_by_phone='+14155550100' where code='$CODE5'" >/dev/null
ok "초대 사용(used=true · consume-invite 경로)으로도 코드→청구→티켓이 붙는다" "$NEW2|$NEW2" "$($P -c "select (select user_id from public.tickets where purchase_id='LINK-c5')||'|'||(select user_id from public.kashikiri_charges where id='$C5')")"
# ── 멱등 · 이미 회원 소유(memberUid) 행은 건드리지 않는다 · 회원 세션은 붙이기 함수를 못 부른다 ──
ok "다시 붙여도 바뀌지 않는다(멱등) · 회원 세션 execute 없음" "0|f" "$($P -c "select public.taam_guest_attach_tickets('$M', null, '010-1234-5678')")|$($P -c "select has_function_privilege('authenticated','public.taam_guest_attach_tickets(uuid,text,text)','execute')")"
# ── timestamptz 칸이어도 들어간다 ──
$P -c "alter table public.invite_codes alter column expires_at type timestamptz using public._taam_ts_safe(expires_at), alter column invited_at type timestamptz using public._taam_ts_safe(invited_at)" >/dev/null
C6=$($P -c "insert into public.kashikiri_charges(label, payer_phone, amount_krw, pay_amount, link_invite, purpose, title, expires_at) values ('Kim','010-9999-8888',100,100,true,'ticket','마츠카와', now()+interval '7 days') returning id")
$P -c "update public.kashikiri_charges set status='paid', approved_at=now() where id='$C6'" >/dev/null
ok "expires_at/invited_at 이 timestamptz 여도 초대장이 만들어진다(30일)" "1" "$($P -c "select count(*) from public.invite_codes c join public.kashikiri_charges k on k.payload->>'guest_invite_code'=c.code where k.id='$C6' and c.expires_at between now()+interval '29 days' and now()+interval '31 days'")"
# ── 두 번째 RUN: 공개 함수 md5 가 이제 다르니 ❌ 건너뜀, 나머지 ✅ ──
out2=$($P -f supabase/migrations/20261019_guest_invite.sql 2>&1)
ok "두 번째 RUN: 공개 함수는 ❌ 건너뜀(이미 새 판) · ②~⑤ ✅" "1|4" "$(echo "$out2" | grep -c '❌ 라이브 본문이')|$(echo "$out2" | grep -cE '^ *[②③④⑤].*✅')"
psql -h /tmp -U postgres -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
