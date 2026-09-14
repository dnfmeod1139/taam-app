#!/bin/bash
# low 묶음 SQL (sql/low_batch_2026-09-14.sql) 재보기. 먼저: 로컬 pg. 실행: bash sql/_test/t_low_batch.sh
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
has(){ echo "$1" | grep -q "$2" && echo 1 || echo 0; }
FAIL=0
$P -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>/tmp/_lb.err || { echo "❌ 픽스처"; head -3 /tmp/_lb.err; exit 1; }
drop schema if exists public cascade; create schema public;
drop schema if exists auth cascade; create schema auth;
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('taam.uid', true), '')::uuid $$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;
grant usage on schema public, auth to anon, authenticated, service_role;
create table public.profiles(id uuid primary key, role text, display_name text, membership_tier text, guest_expires_at timestamptz);
create table public.notifications(id bigserial primary key, user_id uuid, type text, title text, body text, url text, payload jsonb default '{}', created_at timestamptz default now());
create table public.membership_settings(k text primary key, v jsonb);
create table public.kashikiri_events(id uuid primary key default gen_random_uuid(), venue_name text, event_date date, event_time text, fx_rate numeric, fx_note text);
create table public.kashikiri_teams(id uuid primary key default gen_random_uuid(), seq int, pax int);
create table public.kashikiri_charges(id uuid primary key default gen_random_uuid(), event_id uuid, team_id uuid, token text, label text, amount_krw bigint, amount_jpy numeric, pay_currency text, pay_amount numeric, pay_fx numeric, status text default 'pending', expires_at timestamptz, approved_at timestamptz, receipt_url text, order_id text, payer_name text);
create table public.app_errors(id bigserial primary key, created_at timestamptz default now(), user_id uuid, role text, build text, platform text, kind text, message text, stack text, url text, extra jsonb default '{}');
create table public.partner_qr_codes(code text primary key, active boolean default true, restaurant_name text, chef_name text, lang text, meal_price text, beverage_price text, extra_note text);
create table public.partner_qr_views(id bigserial primary key, code text, user_agent text, created_at timestamptz default now());
create table public.partner_logos(id bigserial primary key, image_url text, sort_order int default 0);
create table public.taam_rate_limits(key text primary key, window_start timestamptz default now(), hits int default 0);
create or replace function public.taam_rate_hit(p_key text, p_limit integer, p_window interval) returns boolean language plpgsql security definer as $$
declare v int; begin
  insert into public.taam_rate_limits as r(key,window_start,hits) values (p_key,now(),1)
  on conflict(key) do update set hits = case when r.window_start + p_window < now() then 1 else r.hits+1 end,
    window_start = case when r.window_start + p_window < now() then now() else r.window_start end returning hits into v;
  return v <= p_limit; end $$;
create or replace function public.is_super_admin(uid uuid) returns boolean language sql stable as $$ select exists(select 1 from public.profiles where id=uid and role in ('super_admin','superadmin')) $$;
create or replace function public.taam_guest_days_left(t timestamptz) returns int language sql stable as $$ select ceil(extract(epoch from (t - now()))/86400)::int $$;
grant select, insert, update on all tables in schema public to anon, authenticated, service_role;
SQL
$P -v ON_ERROR_STOP=1 -f sql/low_batch_2026-09-14.sql >/tmp/_lb.out 2>/tmp/_lb.err || { echo "❌ 적용"; grep -i error /tmp/_lb.err | head -3; exit 1; }
ok "확인 표에 ❌ 없음" 0 "$(grep -c '❌' /tmp/_lb.out)"
ok "확인 표 ✅ 5줄" 5 "$(grep -c '✅' /tmp/_lb.out)"

S=d1000000-0000-4000-8000-0000000000ff; G=d1000000-0000-4000-8000-000000000001
$P -c "insert into public.profiles values ('$S','super_admin','슈퍼',null,null),('$G','member','게스트','A', now() + interval '3 day');" >/dev/null
echo "── ① 게스트 만료 알림"
ok "첫 실행: 슈퍼어드민 1 · 본인 1" "1|1" "$($P -c "select (r->>'admin')||'|'||(r->>'self') from public.taam_guest_expiry_notify() r;" | tail -1)"
ok "같은 날 두 번째: 0 · 0" "0|0" "$($P -c "select (r->>'admin')||'|'||(r->>'self') from public.taam_guest_expiry_notify() r;" | tail -1)"
$P -c "update public.notifications set created_at = now() - interval '60 day';" >/dev/null
ok "60일 전 기록은 열쇠에서 빠져 다음 주기에 다시 간다 ⭐" "1|1" "$($P -c "select (r->>'admin')||'|'||(r->>'self') from public.taam_guest_expiry_notify() r;" | tail -1)"
ok "payload 에 expires_on" 1 "$($P -c "select count(*) from public.notifications where type='guest_expiry_admin' and payload ? 'expires_on' and created_at > now() - interval '1 minute';" | tail -1)"

echo "── ② order_start"
$P -c "insert into public.kashikiri_events(id,venue_name,event_date) values ('e1000000-0000-4000-8000-000000000001','스시',current_date); insert into public.kashikiri_charges(event_id,token,amount_krw) values ('e1000000-0000-4000-8000-000000000001','tok_0123456789abcdef',100000);" >/dev/null
OUT=$($P -c "set role anon; select public.taam_kashikiri_order_start('tok_0123456789abcdef', repeat('가', 200));" 2>&1)
ok "anon 결제 시작 통과" 0 "$(has "$OUT" ERROR)"
ok "payer_name 60자로 잘림" 60 "$($P -c "select length(payer_name) from public.kashikiri_charges;" | tail -1)"
for i in $(seq 1 30); do $P -c "set role anon; select public.taam_kashikiri_order_start('tok_0123456789abcdef');" >/dev/null 2>&1; done
OUT=$($P -c "set role anon; select public.taam_kashikiri_order_start('tok_0123456789abcdef');" 2>&1)
ok "31번째부터 「너무 잦음」 ⭐" 1 "$(has "$OUT" "너무 잦")"
ok "짧은 토큰은 즉시 거부" 1 "$(has "$($P -c "set role anon; select public.taam_kashikiri_order_start('abc');" 2>&1)" "없는 링크")"

echo "── ③ 오류 신고"
$P -c "set role anon; select public.taam_report_error('js','x',null,null,null,null, jsonb_build_object('sid','S1','big', repeat('a', 5000)));" >/dev/null
ok "4KB 넘는 extra 는 표지로 대체" 1 "$($P -c "select count(*) from public.app_errors where extra->>'_truncated' = 'true';" | tail -1)"
for i in $(seq 1 25); do $P -c "set role anon; select public.taam_report_error('js','flood',null,null,null,null,'{\"sid\":\"S2\"}');" >/dev/null; done
ok "sid S2 는 20건에서 선다 ⭐" 20 "$($P -c "select count(*) from public.app_errors where extra->>'sid'='S2';" | tail -1)"
$P -c "set role anon; select public.taam_report_error('boot_stuck','real',null,null,null,null,'{\"sid\":\"S3\"}');" >/dev/null
ok "다른 세션(S3)의 신고는 그대로 들어간다 ⭐" 1 "$($P -c "select count(*) from public.app_errors where extra->>'sid'='S3';" | tail -1)"

echo "── ④ QR 조회"
$P -c "insert into public.partner_qr_codes(code,restaurant_name,lang) values ('ABCD1234','스시','ja');" >/dev/null
ok "정상 조회 ok" "true" "$($P -c "set role anon; select (public.partner_qr_lookup('abcd1234','ua'))->>'ok';" | tail -1)"
ok "3자 코드는 거부" "false" "$($P -c "set role anon; select (public.partner_qr_lookup('abc','ua'))->>'ok';" | tail -1)"
for i in $(seq 1 125); do $P -c "set role anon; select public.partner_qr_lookup('ABCD1234','ua');" >/dev/null; done
ok "코드당 120건 뒤엔 열람 기록만 멈춘다" 120 "$($P -c "select count(*) from public.partner_qr_views;" | tail -1)"
ok "그래도 데이터는 준다 ⭐" "true" "$($P -c "set role anon; select (public.partner_qr_lookup('ABCD1234','ua'))->>'ok';" | tail -1)"
echo; [ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
