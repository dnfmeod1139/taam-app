#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 감사 보강 묶음 ① — audit_hardening_2026-09-13.sql (2026-09-13)
# ═══════════════════════════════════════════════════════════════
#   ① 푸시 role 은 서버가 정한다          ② tickets: 회원은 hold 만 · 취소만
#   ③ 요청자 정보는 자기 매장 관련만       ④ 계보 지식 쓰기는 슈퍼어드민만
#   ⑤ invite_codes 는 사용 표시만         ⑥ app_config 쓰기는 슈퍼어드민만
#   ⑦ 공개 RPC 속도 제한 · 코드 검증      ⑧ notify_admins 제한   ⑨ ref_consume 회수
#   ⚠ 픽스처 RLS 는 라이브에서 알려진 모양을 베낀다 (tickets_insert_own/update_own = 본인 행).
# 실행: bash sql/_test/t_audit_hardening.sh   (로컬 pg 필요)
# ═══════════════════════════════════════════════════════════════
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
U=d1000000-0000-4000-8000-000000000001   # 회원
V=d1000000-0000-4000-8000-000000000002   # 다른 회원 (매장 B 에 요청)
A=d1000000-0000-4000-8000-0000000000aa   # 매장 어드민 (V1)
S=d1000000-0000-4000-8000-0000000000ff   # 슈퍼어드민
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
j(){ python3 -c "import sys,json; d=json.loads(sys.stdin.read() or '{}'); print(d.get('$1',''))"; }

$P -v ON_ERROR_STOP=1 <<SQL >/dev/null 2>/tmp/_ah.err || { echo "❌ 픽스처"; head -5 /tmp/_ah.err; exit 1; }
drop schema if exists public cascade; create schema public;
drop schema if exists auth cascade; create schema auth;
create table auth.users(id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as
\$\$ select nullif(current_setting('taam.uid', true), '')::uuid \$\$;
do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
end \$\$;
grant usage on schema public, auth to anon, authenticated;

-- ⚠ 라이브의 「옛 판」을 흉내낸다 — single_device_exempt · partner_agreements.agreed_meal 등이 없다.
--   2026-09-14 실제로 라이브에 agreed_meal 이 없어 SQL 이 통째로 실패했다. 파일이 스스로 보장해야 한다.
create table public.profiles(id uuid primary key, role text default 'member', display_name text, phone text,
  nationality text, membership_tier text);
create or replace function public.is_super_admin(uid uuid) returns boolean
language sql stable security definer set search_path=public as
\$\$ select coalesce((select role in ('super_admin','superadmin') from public.profiles where id=uid), false) \$\$;
grant select on public.profiles to anon, authenticated;

-- tickets (라이브 모양의 일부) + 본인 행 정책
create table public.tickets(purchase_id text primary key, user_id uuid, restaurant_id text, restaurant_name text,
  reservation_date text, party_size int, price bigint default 0, status text, extra_data jsonb default '{}',
  buyer_name text, buyer_phone text, ticket_product_id text, visit_time text);
alter table public.tickets enable row level security;
grant select, insert, update on public.tickets to authenticated;
create policy tickets_select_own on public.tickets for select to authenticated using (auth.uid()=user_id or public.is_super_admin(auth.uid()));
create policy tickets_insert_own on public.tickets for insert to authenticated with check (auth.uid()=user_id or public.is_super_admin(auth.uid()));
create policy tickets_update_own on public.tickets for update to authenticated using (auth.uid()=user_id or public.is_super_admin(auth.uid()));

create table public.push_subscriptions(id uuid primary key default gen_random_uuid(), user_id uuid, endpoint text not null unique,
  p256dh text, auth text, role text, created_at timestamptz default now());   -- 옛 판: user_agent·device_label·topics·last_seen_at 없음

create table public.invite_codes(code text primary key, used boolean default false, used_at timestamptz,
  used_by_email text, used_by_name text, used_by_phone text, invitee_tier text, member_id text, expires_at timestamptz);
alter table public.invite_codes enable row level security;
grant select, update on public.invite_codes to authenticated;
create policy inv_all on public.invite_codes for all to authenticated using (true) with check (true);   -- 최악(열린) 가정

create table public.app_config(key text primary key, value jsonb, updated_at timestamptz);
grant all on public.app_config to anon, authenticated;
insert into public.app_config values ('fx_settings', '{"rate_usd":1400}', now());

create table public.chef_lineage_knowledge(lineage_id text primary key, lineage_name_ko text not null,
  lineage_kind text not null default 'sushi', is_published boolean default false);
alter table public.chef_lineage_knowledge enable row level security;
grant select, insert, update, delete on public.chef_lineage_knowledge to authenticated;
create policy "Auth users read all lineage knowledge" on public.chef_lineage_knowledge for select to authenticated using (true);
create policy "Auth users insert lineage knowledge" on public.chef_lineage_knowledge for insert to authenticated with check (true);
create policy "Auth users update lineage knowledge" on public.chef_lineage_knowledge for update to authenticated using (true) with check (true);
create policy "Auth users delete lineage knowledge" on public.chef_lineage_knowledge for delete to authenticated using (true);

create table public.reservation_requests(id uuid primary key default gen_random_uuid(), user_id uuid, venue_id text,
  reserve_date date, reserve_time time, party_size int, status text default 'pending', visit_status text);
create table public.admin_grants(user_id uuid, venue_id text, rest_id text);
create table public.venue_admins(admin_user_id uuid, venue_id text);
create or replace function public.is_venue_admin_of(p_venue_id text) returns boolean
language sql stable security definer set search_path = public as
\$\$ select exists (select 1 from public.admin_grants where user_id = auth.uid() and venue_id = p_venue_id)
        or exists (select 1 from public.venue_admins where admin_user_id = auth.uid() and venue_id = p_venue_id) \$\$;

create table public.partner_qr_codes(code text primary key, restaurant_name text not null, chef_name text, active boolean default true);
create table public.partner_agreements(id bigint generated always as identity primary key, code text, restaurant_name text,
  chef_name text, signer_name text not null, agreed_at timestamptz not null default now(), agreed_min text);   -- 옛 판: user_agent·signature_data·agreed_meal 없음
insert into public.partner_qr_codes(code, restaurant_name) values ('QHFF', '스시 사사다');

create table public.membership_applications(id uuid primary key default gen_random_uuid(), user_id uuid, name text, phone text not null,
  answers jsonb not null default '{}', referral_code text, lang text not null default 'ko', source text not null default 'app',
  status text not null default 'applied', created_at timestamptz not null default now());
create table public.corporate_inquiries(id uuid primary key default gen_random_uuid(), company text, contact text, phone text,
  email text, memo text, lang text default 'ko', status text default 'new', created_at timestamptz default now());
create table public.notifications(id uuid primary key default gen_random_uuid(), user_id uuid, type text, title text, body text,
  url text, payload jsonb, created_at timestamptz default now());
create table public.membership_referrals(id uuid primary key default gen_random_uuid(), code text, owner_id uuid, status text, expires_at timestamptz, applied_at timestamptz, application_id uuid);
create or replace function public.taam_ref_consume(p_code text, p_application_id uuid) returns jsonb
language sql security definer as \$\$ select '{"ok":false}'::jsonb \$\$;
grant execute on function public.taam_ref_consume(text, uuid) to anon, authenticated;

insert into auth.users values ('$U'),('$V'),('$A'),('$S');
insert into public.profiles(id,role,display_name,phone,membership_tier) values
  ('$U','member','회원','01011112222','T'),('$V','member','다른회원','01033334444','M'),
  ('$A','admin','매장어드민',null,null),('$S','super_admin','슈퍼',null,null);
insert into public.admin_grants values ('$A','V1',null);
insert into public.reservation_requests(user_id, venue_id, reserve_date, party_size) values ('$U','V1','2026-10-01',2), ('$V','V2','2026-10-02',2);
insert into public.invite_codes(code, invitee_tier) values ('ABCD1234','T');
-- 잘못 저장돼 있던 구독 (백필 대상)
insert into public.push_subscriptions(user_id, endpoint, p256dh, auth, role) values ('$U','https://push/old','k','a','super_admin');
SQL
$P -v ON_ERROR_STOP=1 -f sql/audit_hardening_2026-09-13.sql >/dev/null 2>/tmp/_ah.err || { echo "❌ SQL 적용"; head -8 /tmp/_ah.err; exit 1; }

as(){   $P -c "set role authenticated; select set_config('taam.uid','$1',false); $2" 2>&1 | grep -v "^$1\$"; }
asq(){  $P -c "set role authenticated; select set_config('taam.uid','$1',false); $2" >/dev/null 2>&1; echo $?; }
anon(){ $P -c "set role anon; $1" 2>&1; }
has(){ echo "$1" | grep -q "$2" && echo 1 || echo 0; }

echo "── ① 푸시 role ── ⭐"
as $U "select public.save_push_subscription('https://push/u','k','a',null,null,'super_admin','{}','ko');" >/dev/null
ok "회원이 super_admin 이라 해도 user 로 저장 ⭐" user "$($P -c "select role from public.push_subscriptions where endpoint='https://push/u'")"
as $S "select public.save_push_subscription('https://push/s','k','a',null,null,null,'{}',null);" >/dev/null
ok "슈퍼어드민은 superadmin" superadmin "$($P -c "select role from public.push_subscriptions where endpoint='https://push/s'")"
as $A "select public.save_push_subscription(p_endpoint=>'https://push/a',p_p256dh=>'k',p_auth=>'a',p_role=>'user');" >/dev/null   # PostgREST 식 이름 인자 · p_lang 생략
ok "매장 어드민은 admin" admin "$($P -c "select role from public.push_subscriptions where endpoint='https://push/a'")"
ok "옛 구독의 잘못된 role 도 바로잡힘" user "$($P -c "select role from public.push_subscriptions where endpoint='https://push/old'")"
ok "anon 은 실행 불가" f "$($P -c "select has_function_privilege('anon','public.save_push_subscription(text,text,text,text,text,text,text[],text)','execute')")"
ok "7인자 판은 사라졌다 (공존하면 호출이 모호해진다)" "" "$($P -c "select to_regprocedure('public.save_push_subscription(text,text,text,text,text,text,text[])')")"
# 앱이 실제로 먼저 부르는 8인자(p_lang) 판 — 여기서도 role 은 서버가 정해야 한다
as $U "select public.save_push_subscription('https://push/u8','k','a',null,null,'super_admin','{}','ja-JP');" >/dev/null
ok "8인자 판도 회원의 super_admin 을 user 로 ⭐" "user|ja" "$($P -c "select role||'|'||lang from public.push_subscriptions where endpoint='https://push/u8'")"
as $U "select public.save_push_subscription('https://push/u8','k','a',null,null,'admin','{}',null);" >/dev/null
ok "언어 없이 다시 저장해도 role 은 user · 언어는 유지" "user|ja" "$($P -c "select role||'|'||lang from public.push_subscriptions where endpoint='https://push/u8'")"

echo "── ② tickets INSERT ── ⭐"
R=$(as $U "insert into public.tickets(purchase_id,user_id,restaurant_id,status,price,party_size) values ('taam-1','$U','R1','active',0,2);")
ok "회원의 active 행 직접 INSERT 거부 ⭐" 1 "$(has "$R" "서버가 확정")"
R=$(as $U "insert into public.tickets(purchase_id,user_id,restaurant_id,status,price,party_size) values ('taam-2','$U','R1','hold',0,2);")
ok "회원의 hold INSERT 통과" 0 "$(has "$R" ERROR)"
R=$(as $U "insert into public.tickets(purchase_id,user_id,restaurant_id,status,price,party_size) values ('taam-3','$V','R1','hold',0,2);")
ok "남의 이름으로는 hold 도 거부" 1 "$(has "$R" ERROR)"
R=$(as $A "insert into public.tickets(purchase_id,user_id,restaurant_id,status,price,party_size) values ('MAN-1','$A','R1','manual',0,2);")
ok "매장 어드민의 manual 행 통과" 0 "$(has "$R" ERROR)"
R=$(as $A "insert into public.tickets(purchase_id,user_id,restaurant_id,status,price,party_size) values ('MAN-2','$A','R1','active',0,2);")
ok "매장 어드민도 active 는 거부" 1 "$(has "$R" "서버가 확정")"
R=$(as $S "insert into public.tickets(purchase_id,user_id,restaurant_id,status,price,party_size) values ('SA-1','$U','R1','active',100000,2);")
ok "슈퍼어드민의 수동 active 통과" 0 "$(has "$R" ERROR)"
R=$($P -c "insert into public.tickets(purchase_id,user_id,restaurant_id,status,price,party_size) values ('SRV-1','$U','R1','active',100000,2);" 2>&1)
ok "서버(postgres) INSERT 통과" 0 "$(has "$R" ERROR)"

echo "── ② tickets UPDATE ── ⭐"
R=$(as $U "update public.tickets set status='active', price=0 where purchase_id='taam-2';")
ok "회원 hold→active (price 0) 거부 ⭐" 1 "$(has "$R" ERROR)"
ok "여전히 hold" hold "$($P -c "select status from public.tickets where purchase_id='taam-2'")"
R=$(as $U "update public.tickets set price=1 where purchase_id='SA-1';")
ok "회원 price 변경 거부" 1 "$(has "$R" "금액은 서버만")"
R=$(as $U "update public.tickets set visit_time='19:00' where purchase_id='SA-1';")
ok "회원의 시간 변경은 통과" 0 "$(has "$R" ERROR)"
R=$(as $U "update public.tickets set status='cancelled' where purchase_id='taam-2';")
ok "회원 취소 통과" 0 "$(has "$R" ERROR)"
R=$(as $U "update public.tickets set status='active' where purchase_id='taam-2';")
ok "취소 되살리기 거부" 1 "$(has "$R" ERROR)"
$P -c "insert into public.tickets(purchase_id,user_id,restaurant_id,status,price,party_size) values ('taam-4','$U','R1','hold',0,2);" >/dev/null
R=$($P -c "update public.tickets set status='active', price=250000 where purchase_id='taam-4';" 2>&1)
ok "서버(RPC 롤)의 hold→active 확정 통과" 0 "$(has "$R" ERROR)"
ok "확정 금액 반영" 250000 "$($P -c "select price from public.tickets where purchase_id='taam-4'")"

echo "── ③ 요청자 정보 ── ⭐"
R=$(as $A "select display_name from public.get_requester_info('$U','V1');")
ok "자기 매장에 요청한 회원은 본다" "회원" "$R"
R=$(as $A "select display_name from public.get_requester_info('$V','V1');")
ok "관계없는 회원은 FORBIDDEN ⭐" 1 "$(has "$R" FORBIDDEN)"
R=$(as $A "select display_name from public.get_requester_info('$V','V2');")
ok "남의 매장은 FORBIDDEN" 1 "$(has "$R" FORBIDDEN)"
R=$(as $S "select display_name from public.get_requester_info('$V','V1');")
ok "슈퍼어드민은 전원" "다른회원" "$R"

echo "── ④ 계보 지식 ──"
as $U "insert into public.chef_lineage_knowledge(lineage_id,lineage_name_ko) values ('x','회원이 넣음');" >/dev/null
ok "회원 INSERT 막힘" 0 "$($P -c "select count(*) from public.chef_lineage_knowledge")"
as $S "insert into public.chef_lineage_knowledge(lineage_id,lineage_name_ko) values ('sugita','스기타');" >/dev/null
ok "슈퍼어드민 INSERT 통과" 1 "$($P -c "select count(*) from public.chef_lineage_knowledge")"
as $U "update public.chef_lineage_knowledge set lineage_name_ko='망침' where lineage_id='sugita';" >/dev/null
ok "회원 UPDATE 막힘" "스기타" "$($P -c "select lineage_name_ko from public.chef_lineage_knowledge where lineage_id='sugita'")"
as $U "delete from public.chef_lineage_knowledge;" >/dev/null
ok "회원 DELETE 막힘" 1 "$($P -c "select count(*) from public.chef_lineage_knowledge")"
ok "회원 읽기는 그대로" 1 "$(as $U "select count(*) from public.chef_lineage_knowledge;")"

echo "── ⑤ invite_codes ── ⭐"
R=$(as $U "update public.invite_codes set invitee_tier='M' where code='ABCD1234';")
ok "회원이 invitee_tier 를 M 으로 → 거부 ⭐" 1 "$(has "$R" "사용 표시만")"
ok "여전히 T" T "$($P -c "select invitee_tier from public.invite_codes where code='ABCD1234'")"
R=$(as $U "update public.invite_codes set used=true, used_at=now(), used_by_email='a@b.c', used_by_name='회원', used_by_phone='0101' where code='ABCD1234';")
ok "사용 표시(앱의 그 UPDATE)는 통과" 0 "$(has "$R" ERROR)"
R=$(as $U "update public.invite_codes set used=false where code='ABCD1234';")
ok "used 되돌리기 거부" 1 "$(has "$R" "되살릴")"
R=$(as $S "update public.invite_codes set invitee_tier='M' where code='ABCD1234';")
ok "슈퍼어드민은 등급 수정 가능" 0 "$(has "$R" ERROR)"

echo "── ⑥ app_config ── ⭐"
as $U "update public.app_config set value='{\"rate_usd\":1}' where key='fx_settings';" >/dev/null
ok "회원이 환율을 덮어쓰지 못한다 ⭐" 1400 "$($P -c "select value->>'rate_usd' from public.app_config where key='fx_settings'")"
as $U "insert into public.app_config values ('evil','{}',now());" >/dev/null
ok "회원 INSERT 도 막힘" 0 "$($P -c "select count(*) from public.app_config where key='evil'")"
ok "anon 읽기는 그대로" 1400 "$(anon "select value->>'rate_usd' from public.app_config where key='fx_settings';")"
as $S "update public.app_config set value='{\"rate_usd\":1450}' where key='fx_settings';" >/dev/null
ok "슈퍼어드민 수정 통과" 1450 "$($P -c "select value->>'rate_usd' from public.app_config where key='fx_settings'")"

echo "── ⑦ partner_agree ── ⭐"
R=$(anon "select public.partner_agree('ZZZZ','가짜매장','가짜셰프','누군가',null,null,null,null);")
ok "모르는 코드 거부 ⭐" code_invalid "$(echo "$R" | j error)"
R=$(anon "select public.partner_agree('qhff','스시 사사다','佐々田','사사다',null,'data:image/png;base64,AA','¥5,000','¥38,000');")
R_OK="$R"; ID=$(echo "$R" | j id)
ok "발급된 코드(대소문자 무관) 통과" True "$(echo "$R" | j ok)"
ok "토큰이 같이 온다" 32 "$(echo -n "$(echo "$R" | j token)" | wc -c)"
R=$(anon "select public.partner_agree('','일반랜딩','셰프','서명자',null,null,null,null);")
ok "빈 코드(일반 랜딩)는 통과" True "$(echo "$R" | j ok)"
for i in $(seq 1 28); do anon "select public.partner_agree('QHFF','x','y','z$i',null,null,null,null);" >/dev/null; done
R=$(anon "select public.partner_agree('QHFF','x','y','z99',null,null,null,null);")
ok "시간당 30건 넘으면 rate_limited" rate_limited "$(echo "$R" | j error)"

echo "── ⑦ mship_apply / corp_inquire ──"
for i in $(seq 1 6); do anon "select public.taam_mship_apply('홍길동','010-5555-6666','{}'::jsonb,'ko',null,'web');" >/dev/null; done
R=$(anon "select public.taam_mship_apply('홍길동','010-5555-6666','{}'::jsonb,'ko',null,'web');")
ok "같은 번호 7번째 신청은 거부" 1 "$(has "$R" "잠시 후")"
ok "신청서는 한 장만 (already 동작 유지)" 1 "$($P -c "select count(*) from public.membership_applications where phone='01055556666'")"
R=$(anon "select public.taam_mship_apply('김철수','010-7777-8888','{}'::jsonb,'ko',null,'web');")
ok "다른 번호는 통과" True "$(echo "$R" | j ok)"
for i in $(seq 1 6); do anon "select public.taam_corp_inquire('회사','담당','010-1111-0000',null,null,'ko');" >/dev/null; done
R=$(anon "select public.taam_corp_inquire('회사','담당','010-1111-0000',null,null,'ko');")
ok "기업 문의도 같은 번호 7번째 거부" 1 "$(has "$R" "잠시 후")"

echo "── ⑧ notify_admins ──"
for i in $(seq 1 30); do as $U "select public.taam_notify_admins('t','제목$i');" >/dev/null; done
ok "30건까지는 들어간다" 30 "$($P -c "select count(*) from public.notifications")"
ok "31번째는 0 (예외 없이)" 0 "$(as $U "select public.taam_notify_admins('t','제목31');")"
ok "슈퍼어드민은 제한 없음" 0 "$(as $S "select public.taam_notify_admins('t','슈퍼가 보냄');")"   # 자기 제외 → 다른 슈퍼 없음 = 0, 예외 없음

echo "── ⑪⑫⑬ 접힌 파일들 ──"
ok "⑪ 증서 id 만으로는 거부" False "$(anon "select public.partner_agreement_get($ID);" | j ok)"
ok "⑪ id+토큰은 통과" True "$(anon "select public.partner_agreement_get($ID, '$(echo "$R_OK" | j token)');" | j ok)"
as $U "update public.profiles set single_device_exempt=true where id='$U';" >/dev/null
ok "⑫ 회원이 면제를 못 켠다" f "$($P -c "select single_device_exempt from public.profiles where id='$U'")"
anon "select public.taam_report_error('js','boom',null,'/','2026.09.13-a','web','{}'::jsonb);" >/dev/null
ok "⑬ 익명도 오류를 적을 수 있다" 1 "$($P -c "select count(*) from public.app_errors")"
ok "⑬ 회원은 못 읽는다" 0 "$(as $U "select count(*) from public.app_errors;" | tail -1)"

echo "── ⑨ ref_consume ──"
ok "anon 실행 권한 회수" f "$($P -c "select has_function_privilege('anon','public.taam_ref_consume(text, uuid)','execute')")"
ok "authenticated 도 회수" f "$($P -c "select has_function_privilege('authenticated','public.taam_ref_consume(text, uuid)','execute')")"

echo "── 확인 쿼리 ──"
$P -f sql/audit_hardening_2026-09-13.sql 2>/dev/null | grep -c "❌" | { read n; ok "확인 쿼리에 ❌ 없음 (두 번 돌려도)" 0 "$n"; }

echo; [ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
exit $FAIL
