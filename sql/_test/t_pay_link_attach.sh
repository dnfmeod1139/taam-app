#!/usr/bin/env bash
# 결제 링크 → 회원 예약 연결 · 결제되면 회원 알림 회귀 — supabase/migrations/20261023_pay_link_member_visible.sql (2026-10-23)
# 로컬 Postgres: psql -h /tmp -U postgres (trust). 실행: bash sql/_test/t_pay_link_attach.sh
#   결제 링크 픽스처(t_pay_link.sh 를 PL_KEEP 으로 남김 · 실제 중복 가드 20261014 포함) 위에 이 파일을 올린다.
cd "$(dirname "$0")/../.."
PSQL="psql -h /tmp -U postgres -X -q"
DB=t_plattach
MIG=supabase/migrations/20261023_pay_link_member_visible.sql
FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
BASE=$(PL_DB=$DB PL_KEEP=1 bash sql/_test/t_pay_link.sh 2>&1 | tail -1)
ok "결제 링크 회귀(기반) 통과" "=== 전부 통과 ===" "$BASE"
P="$PSQL -d $DB -At"
SU=a1000000-0000-4000-8000-000000000001; M2=a1000000-0000-4000-8000-000000000002; M3=a1000000-0000-4000-8000-000000000003; M5=a1000000-0000-4000-8000-000000000006; ADM=a1000000-0000-4000-8000-000000000005; M6=a1000000-0000-4000-8000-000000000007
S="set taam.uid='$SU'; set taam.super='1';"
RS=b1000000-0000-4000-8000-0000000000aa
$P >/dev/null 2>&1 <<SQL
alter table public.profiles add column if not exists phone text;
alter table public.profiles add column if not exists notif_prefs jsonb;
create table if not exists public.deposit_transactions(id bigserial primary key, user_id uuid, deposit_type text, change_type text, amount bigint, balance_after bigint, description text, metadata jsonb, created_at timestamptz default now());
-- 라이브 모양: taam_admin_push 는 public 만 막혀 있고 anon·authenticated 에 직접 실행 권한(Supabase 기본 권한)
create or replace function public.taam_admin_push(p_title text, p_body text, p_url text default '/', p_tag text default null, p_category text default 'system') returns jsonb language sql security definer as \$\$ select '{}'::jsonb \$\$;
revoke all on function public.taam_admin_push(text,text,text,text,text) from public;
grant execute on function public.taam_admin_push(text,text,text,text,text) to anon, authenticated;
create or replace function public._taam_fee_caller_ok() returns boolean language plpgsql stable security definer set search_path = public as \$\$
begin if auth.uid() is not null then return coalesce(public._taam_uid_is_super(), false); end if; return session_user = 'postgres'; end \$\$;
insert into public.restaurants values ('$RS','스시 사이토','Sushi Saito','鮨 さいとう');
insert into public.ticket_products(id, rest_id, rest_name, date, time, total_pax, meal_fee, agency_fee, wine_min, type_class) values
  ('tpS', '$RS', '스시 사이토', '2027.03.15', '12:00', 4, 800000, 100000, 0, 'Standard'),
  ('tpG', '$RS', '스시 사이토', '2027.04.10', '19:00', 4, 800000, 100000, 0, 'Standard');
-- 슈퍼어드민이 캘린더 「수동 추가」로 잡아 둔 좌석 둘(에릭 몫 2인 · 다른 손님 2인) — 정원 4 가 다 찼다
insert into public.tickets(id,user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,buyer_name,extra_data) values
  (gen_random_uuid(),'$SU','$RS','스시 사이토','tpS','2027.03.15','12:00',2,0,'manual','MAN-eric','에릭','{"manualEntry":true}'),
  (gen_random_uuid(),'$SU','$RS','스시 사이토','tpS','2027.03.15','12:00',2,0,'manual','MAN-other','다른손님','{"manualEntry":true}');
-- 자유 금액 링크(회원 에릭 · \$1,800 · 회차 없음) — 결제 전
insert into public.kashikiri_charges(id, event_id, label, user_id, amount_krw, pay_currency, pay_fx, pay_amount, purpose, title, subtitle, status, payer_name)
  values ('c1000000-0000-4000-8000-000000000001', null, 'Eric', '$M3', 2416167, 'USD', 1342.315, 1800, 'custom', 'Sushi saito', 'Eric', 'pending', 'Eric');
-- 회원 없는 자유 금액 결제 · 멤버십 결제 · 정산 조 몫
insert into public.kashikiri_charges(id, event_id, label, amount_krw, pay_currency, pay_fx, pay_amount, purpose, title, status)
  values ('c1000000-0000-4000-8000-000000000002', null, '손님', 500000, 'KRW', 1, 500000, 'custom', '기타', 'pending');
insert into public.kashikiri_charges(id, event_id, label, user_id, amount_krw, pay_currency, pay_fx, pay_amount, purpose, title, status, payload)
  values ('c1000000-0000-4000-8000-000000000003', null, '김회원', '$M2', 1125000, 'KRW', 1, 1125000, 'membership', '멤버십 M 갱신 (연회비)', 'pending', '{"tier":"M","kind":"renew","fee":1125000}');
SQL
out=$($P -f $MIG 2>&1)
ok "마이그레이션: 오류 없음 · ❌ 0 · ①②③④⑥⑦⑧⑨ ✅" "|0|8" "$(echo "$out" | grep -E "^ERROR|psql:.*ERROR" | head -1)|$(echo "$out" | grep -c '❌')|$(echo "$out" | grep -cE '^(① RPC|② 결제|③ anon|④ 도우미|⑥ 링크|⑦ 링크|⑧ taam_admin_push|⑨ 「예약).*\|✅')"
ok "  taam_admin_push: anon·회원 실행 불가로" "f|f" "$($P -c "select has_function_privilege('anon','public.taam_admin_push(text,text,text,text,text)','execute')||'|'||has_function_privilege('authenticated','public.taam_admin_push(text,text,text,text,text)','execute')")"

echo "── 결제되면 회원에게 알린다"
$P -c "update public.kashikiri_charges set status='paid', approved_at = now() - interval '3 days', payment_key='pkE' where id='c1000000-0000-4000-8000-000000000001'" >/dev/null
ok "자유 금액(회원 에릭) 결제 → 회원 알림 1 · 「결제가 완료되었습니다」 · 결제 통화 금액만(\$1,800.00 · ₩ 없음)" "1|결제가 완료되었습니다|Sushi saito · Eric · \$1,800.00|0" "$($P -c "select count(*)||'|'||max(title)||'|'||max(body)||'|'||count(*) filter (where body like '%₩%') from public.notifications where user_id='$M3' and type='pay_link_paid'")"
$P -c "update public.kashikiri_charges set status='paid', approved_at = now() where id in ('c1000000-0000-4000-8000-000000000002','c1000000-0000-4000-8000-000000000003')" >/dev/null 2>&1
ok "회원 없는 결제 → 회원 알림 없음 · 멤버십 결제 → 「멤버십 결제가 완료되었습니다 · 멤버십 M 갱신 (연회비) · ₩1,125,000 — 감사합니다」(회원 이름 없음)" "0|멤버십 결제가 완료되었습니다|멤버십 M 갱신 (연회비) · ₩1,125,000 — 감사합니다" "$($P -c "select count(*) from public.notifications where type='pay_link_paid' and payload->>'charge_id'='c1000000-0000-4000-8000-000000000002'")|$($P -c "select title from public.notifications where user_id='$M2' and type='pay_link_paid' and payload->>'charge_id'='c1000000-0000-4000-8000-000000000003'")|$($P -c "select body from public.notifications where user_id='$M2' and type='pay_link_paid' and payload->>'charge_id'='c1000000-0000-4000-8000-000000000003'")"
EVX=$($P -c "insert into public.kashikiri_events(venue_id, venue_name, event_date, status) values ('vx','정산매장','2027-07-01','open') returning id" | head -1)
$P -c "insert into public.kashikiri_charges(id, event_id, label, user_id, amount_krw, pay_currency, pay_fx, pay_amount, status) values
         ('c1000000-0000-4000-8000-0000000000a1', '$EVX', 'Trina', '$ADM', 2254000, 'USD', 1342, 1679.85, 'pending'),
         ('c1000000-0000-4000-8000-0000000000a2', '$EVX', '김회원', '$M2', 900000, 'KRW', 1, 900000, 'pending'),
         ('c1000000-0000-4000-8000-0000000000a3', null, '매장', '$ADM', 50000, 'KRW', 1, 50000, 'pending'),
         ('c1000000-0000-4000-8000-0000000000a4', null, '슈퍼', '$SU', 50000, 'KRW', 1, 50000, 'pending')" >/dev/null
$P -c "update public.kashikiri_charges set status='paid', approved_at=now() where id::text like 'c1000000-0000-4000-8000-0000000000a%'" >/dev/null 2>&1
ok "정산 청구(회차 있음 · 링크 초대 아님)는 회원 알림 없음 — 어드민 uid 가 실려도 · 매장 어드민·슈퍼어드민 user_id 자유 금액도 없음" "0" "$($P -c "select count(*) from public.notifications where type='pay_link_paid' and payload->>'charge_id' like 'c1000000-0000-4000-8000-0000000000a%'")"
$P -c "update public.profiles set notif_prefs='{\"all\":false}' where id='$M2'" >/dev/null
ok "「알림 전체 끔」 회원 → 푸시 건너뜀(prefs_off) · 켠 회원은 다음 단계(설정 없음 no_config)" "prefs_off|no_config" "$($P -c "select (public._taam_member_push('$M2','t','b')->>'reason')||'|'||(public._taam_member_push('$M3','t','b')->>'reason')")"
$P -c "update public.profiles set notif_prefs=null where id='$M2'" >/dev/null
R=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp2','name','김회원','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','19:30','user_id','$M2'))::text" 2>&1)
CT=$(echo "$R" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pkT' where id='$CT'" >/dev/null 2>&1
ok "티켓 링크(회원) 결제 → 좌석이 회원 것으로 붙고 「예약 결제가 완료되었습니다 … 1인 — 예약 내역에서 확인」 · url 구매내역" "1|1|/?open_ticket_hist=1" "$($P -c "select count(*) from public.tickets where extra_data->>'chargeId'='$CT' and user_id='$M2' and extra_data->>'memberUid'='$M2'")|$($P -c "select count(*) from public.notifications where user_id='$M2' and title='예약 결제가 완료되었습니다' and body like '%· 1인 — 예약 내역에서 확인하실 수 있습니다'")|$($P -c "select url from public.notifications where user_id='$M2' and title='예약 결제가 완료되었습니다'")"

echo "── 회원 예약 내역에 안 보이는 결제 목록"
U=$($P -c "$S select public.taam_pay_link_unattached(50)::text")
ok "목록: 에릭 자유 금액(좌석 없음 · no_seat) · 회원 없는 결제 · 멤버십은 없음 · 회원 티켓 링크는 없음" "1|1|0|0" "$(echo "$U" | grep -c '"id": "c1000000-0000-4000-8000-000000000001"')|$(echo "$U" | grep -c 'c1000000-0000-4000-8000-000000000002')|$(echo "$U" | grep -c 'c1000000-0000-4000-8000-000000000003')|$(echo "$U" | grep -c "$CT")"
ok "  에릭 줄: reason no_seat · 회원 이름 · 결제 통화" "no_seat|Eric Cheok|USD" "$($P -c "$S select (e->>'reason')||'|'||(e->>'member_name')||'|'||(e->>'pay_currency') from jsonb_array_elements(public.taam_pay_link_unattached(50)) e where e->>'id'='c1000000-0000-4000-8000-000000000001'")"
ok "회원 세션은 목록·연결 못 함 → FORBIDDEN" "1|1" "$($P -c "set taam.uid='$M3'; set taam.super='0'; select public.taam_pay_link_unattached(5)" 2>&1 | grep -c FORBIDDEN)|$($P -c "set taam.uid='$M3'; set taam.super='0'; select public.taam_pay_link_attach_ticket('c1000000-0000-4000-8000-000000000001','tpS',2)" 2>&1 | grep -c FORBIDDEN)"

echo "── 연결 규칙"
att(){ $P -c "$S select public.taam_pay_link_attach_ticket($1)::text" 2>&1; }
ok "정원이 다 찼는데 대신할 수동 좌석을 안 고르면 → TICKET_SOLD_OUT · 아무것도 안 바뀜" "1|manual|custom" "$(att "'c1000000-0000-4000-8000-000000000001','tpS',2" | grep -c TICKET_SOLD_OUT)|$($P -c "select status from public.tickets where purchase_id='MAN-eric'")|$($P -c "select purpose from public.kashikiri_charges where id='c1000000-0000-4000-8000-000000000001'")"
ok "없는 수동 좌석 → REPLACE_NOT_FOUND · 다른 회차의 날짜 없는 회차(tp1 '05.01') → TICKET_DATE_UNKNOWN" "1|1" "$(att "'c1000000-0000-4000-8000-000000000001','tpS',2,null,'MAN-nope'" | grep -c REPLACE_NOT_FOUND)|$(att "'c1000000-0000-4000-8000-000000000001','tp1',2" | grep -c TICKET_DATE_UNKNOWN)"
ok "다른 회원으로 바꾸려 하면 → MEMBER_MISMATCH · 회원 없는 결제를 회원 없이 → MEMBER_REQUIRED · 멤버십 결제 → BAD_PURPOSE" "1|1|1" "$(att "'c1000000-0000-4000-8000-000000000001','tpS',2,'$M2','MAN-eric'" | grep -c MEMBER_MISMATCH)|$(att "'c1000000-0000-4000-8000-000000000002','tpS',1" | grep -c MEMBER_REQUIRED)|$(att "'c1000000-0000-4000-8000-000000000003','tpS',1" | grep -c BAD_PURPOSE)"
ok "결제 안 된 청구 → NOT_PAID" "1" "$($P -c "insert into public.kashikiri_charges(id,event_id,label,amount_krw,pay_currency,pay_fx,pay_amount,purpose,status) values ('c1000000-0000-4000-8000-000000000009',null,'x',1000,'KRW',1,1000,'custom','pending')" >/dev/null; att "'c1000000-0000-4000-8000-000000000009','tpS',1,'$M2'" | grep -c NOT_PAID)"

echo "── 에릭 — 자유 금액 결제를 그 회원의 예약으로 (수동 좌석 MAN-eric 대신)"
A=$(att "'c1000000-0000-4000-8000-000000000001','tpS',2,null,'MAN-eric','10/18 자유 금액으로 받은 것'")
ok "연결 ok · mode created · 대체 MAN-eric" "true|created|MAN-eric" "$(echo "$A" | grep -oE '"ok": (true|false)' | head -1 | grep -oE 'true|false')|$(echo "$A" | grep -oE '"mode": "[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"')|$(echo "$A" | grep -oE '"replaced": "[A-Za-z-]+"' | grep -oE 'MAN-[a-z]+')"
PID=$($P -c "select purchase_id from public.tickets where extra_data->>'chargeId'='c1000000-0000-4000-8000-000000000001' and status='active'")
ok "  MAN-eric 취소(converted) · 새 LINK- 좌석: 에릭 소유 · memberUid · active · 2인 · 날짜·시각 = 회차 · 가격 = 정가×인원 1,800,000 · 협의 금액 표시만(priceOverride) · payAmount 없음" "cancelled|converted_to_pay_link|$M3|$M3|active|2|2027.03.15|12:00|1800000|true|false" "$($P -c "select status||'|'||(extra_data->>'cancelledBy') from public.tickets where purchase_id='MAN-eric'")|$($P -c "select user_id||'|'||(extra_data->>'memberUid')||'|'||status||'|'||party_size||'|'||reservation_date||'|'||visit_time||'|'||price||'|'||(extra_data->>'priceOverride')||'|'||(extra_data ? 'payAmount') from public.tickets where purchase_id='$PID'")"
ok "  대행비 스냅샷: agencyFee ₩100,000 · agencyPay \$74.50(÷1342.315) · LINK- 접두어" "100000|74.50|1" "$($P -c "select (extra_data->>'agencyFee')||'|'||(extra_data->>'agencyPay') from public.tickets where purchase_id='$PID'")|$(echo "$PID" | grep -c '^LINK-c1000000-')"
ok "  청구 → 티켓 링크(purpose ticket · link_invite · 회원 · 제목 회차 · 부제 날짜 시각 · 원래 제목 보관)" "ticket|true|$M3|스시 사이토|2027.03.15 12:00|Sushi saito|custom" "$($P -c "select purpose||'|'||link_invite||'|'||user_id||'|'||title||'|'||subtitle||'|'||(payload->>'orig_title')||'|'||(payload->>'attached_from') from public.kashikiri_charges where id='c1000000-0000-4000-8000-000000000001'")"
ok "  어드민 메모 한 줄 · 회원 알림 「예약이 등록되었습니다」(2인 · 예약 내역 url)" "1|1|/?open_ticket_hist=1" "$($P -c "select count(*) from public.kashikiri_charge_admin where charge_id='c1000000-0000-4000-8000-000000000001' and note like '%[예약 연결 %스시 사이토 2027.03.15 · 2인 · LINK-%MAN-eric 대체 · 10/18 자유 금액으로 받은 것%'")|$($P -c "select count(*) from public.notifications where user_id='$M3' and type='pay_link_attached' and title='예약이 등록되었습니다' and body='스시 사이토 · 2027.03.15 12:00 · 2인 — 결제하신 예약이 예약 내역에 추가되었습니다'")|$($P -c "select url from public.notifications where user_id='$M3' and type='pay_link_attached'")"
ok "  구매 일시 = 결제한 날(3일 전 · 연결한 날 아님) · 청구 payload.price_override=true(판매 현황 「✎ 금액 수정」)" "t|true" "$($P -c "select (created_at < now() - interval '2 days')::text from public.tickets where purchase_id='$PID'" | cut -c1)|$($P -c "select payload->>'price_override' from public.kashikiri_charges where id='c1000000-0000-4000-8000-000000000001'")"
ok "  LINK- 좌석 인원 변경 → LINK_PAX_CHANGE (어느 세션이든) · 원장 ticket_pax_change(LINK-/KSK-) → 거절" "1|1|1|2" "$($P -c "update public.tickets set party_size=1 where purchase_id='$PID'" 2>&1 | grep -c LINK_PAX_CHANGE)|$($P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M3','membership','ticket_pax_change',800000,jsonb_build_object('purchase_id','$PID'))" 2>&1 | grep -c LINK_PAX_CHANGE)|$($P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M3','membership','ticket_pax_change',1,'{\"purchase_id\":\"KSK-x\"}')" 2>&1 | grep -c LINK_PAX_CHANGE)|$($P -c "select party_size from public.tickets where purchase_id='$PID'")"
ok "  다른 좌석의 인원 변경 원장은 그대로 · 상태 변경(취소)은 막지 않음" "1" "$($P -c "insert into public.deposit_transactions(user_id,deposit_type,change_type,amount,metadata) values ('$M3','membership','ticket_pax_change',1,'{\"purchase_id\":\"PAYH-x\"}') returning 1")"
ok "  링크 환불 견적: 회원·매장 어드민 세션 → FORBIDDEN · 슈퍼어드민 → 됨 · 서버(uid 없음)는 위에서 됨" "1|1|paid" "$($P -c "set taam.uid='$M3'; set taam.super='0'; select public.taam_link_invite_refund_quote('c1000000-0000-4000-8000-000000000001')" 2>&1 | grep -c FORBIDDEN)|$($P -c "set taam.uid='$ADM'; set taam.super='0'; select public.taam_link_invite_refund_quote('c1000000-0000-4000-8000-000000000001')" 2>&1 | grep -c FORBIDDEN)|$($P -c "$S select public.taam_link_invite_refund_quote('c1000000-0000-4000-8000-000000000001')->>'status'")"
ok "  정원은 그대로 4/4 (수동 좌석 2 → 회원 좌석 2)" "4" "$($P -c "select sum(party_size) from public.tickets where ticket_product_id='tpS' and status <> 'cancelled'")"
ok "  목록에서 빠짐 · 다시 연결 → ALREADY_ATTACHED" "0|1" "$($P -c "$S select count(*) from jsonb_array_elements(public.taam_pay_link_unattached(50)) e where e->>'id'='c1000000-0000-4000-8000-000000000001'")|$(att "'c1000000-0000-4000-8000-000000000001','tpS',2" | grep -c ALREADY_ATTACHED)"
ok "  회원은 자기 청구를 읽는다(kc_mine 모양 — user_id = 회원)" "1" "$($P -c "select count(*) from public.kashikiri_charges where id='c1000000-0000-4000-8000-000000000001' and user_id='$M3'")"
Q=$($P -c "select public.taam_link_invite_refund_quote('c1000000-0000-4000-8000-000000000001')::text")
ok "  환불 견적: 티켓 규정(D-31 · 결제 통화) — \$1,800 − \$74.50×2 = \$1,651.00" "d31_minus_agency|1651.00" "$(echo "$Q" | grep -oE '"policy" ?: ?"[a-z0-9_]+"' | grep -oE '[a-z0-9_]+"$' | tr -d '"')|$(echo "$Q" | grep -oE '"refund_amount" ?: ?[0-9.]+' | grep -oE '[0-9.]+$')"
$P -c "update public.kashikiri_charges set status='refunded', refunded_at=now() where id='c1000000-0000-4000-8000-000000000001'" >/dev/null 2>&1
ok "  환불되면 좌석도 풀린다(링크 초대 트리거)" "cancelled" "$($P -c "select status from public.tickets where purchase_id='$PID'")"

echo "── 같은 회차를 이미 가진 회원 · 규정 예외"
$P -c "update public.tickets set status='cancelled' where purchase_id='MAN-other'" >/dev/null
$P -c "insert into public.kashikiri_charges(id, event_id, label, user_id, amount_krw, pay_currency, pay_fx, pay_amount, purpose, title, status, approved_at)
         values ('c1000000-0000-4000-8000-000000000004', null, 'Eric', '$M3', 900000, 'KRW', 1, 900000, 'custom', '추가 1인', 'paid', now()),
                ('c1000000-0000-4000-8000-000000000005', null, 'Eric', '$M3', 900000, 'KRW', 1, 900000, 'custom', '추가 1인 b', 'paid', now())" >/dev/null
att "'c1000000-0000-4000-8000-000000000004','tpS',1" >/dev/null
ok "회원이 이미 이 회차 좌석을 가지면 → DUPLICATE_PURCHASE (실제 가드) · 바뀐 것 없음" "1|custom" "$(att "'c1000000-0000-4000-8000-000000000005','tpS',1" | grep -c DUPLICATE_PURCHASE)|$($P -c "select purpose from public.kashikiri_charges where id='c1000000-0000-4000-8000-000000000005'")"
EX=$($P -f supabase/migrations/20261022_purchase_rule_exception.sql 2>&1 | grep -c '❌')
$P -c "$S select public.taam_purchase_exception_grant('$M3','tpS',true,false,1,now()+interval '2 days','일행 추가 협의')" >/dev/null 2>&1
ok "  「🔓 구매 규정 예외」(같은 회차 +1) 뒤 → 연결 ok" "0|true" "$EX|$(att "'c1000000-0000-4000-8000-000000000005','tpS',1" | grep -oE '"ok": (true|false)' | head -1 | grep -oE 'true|false')"

echo "── 좌석은 있는데 회원 것이 아닌 결제(비회원 티켓 링크) → 회원에게 넘긴다"
R2=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tpG','name','손님','pax',1,'currency','KRW','visit_date','2027.04.10','visit_time','19:00'))::text" 2>&1); echo "$R2" | grep -q charge_id || echo "R2: $R2" | head -3
CG=$(echo "$R2" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
$P -c "update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pkG' where id='$CG'" >/dev/null 2>&1
ok "비회원 결제는 목록에 not_member · 회원 알림 없음" "not_member|0" "$($P -c "$S select e->>'reason' from jsonb_array_elements(public.taam_pay_link_unattached(50)) e where e->>'id'='$CG'")|$($P -c "select count(*) from public.notifications where type='pay_link_paid' and payload->>'charge_id'='$CG'")"
B=$(att "'$CG',null,1,'$M5'")
ok "  회원 M5 에게 → mode transfer · 그 좌석 행이 M5 소유 · memberUid · 청구 회원 M5" "transfer|$M5|$M5|$M5" "$(echo "$B" | grep -oE '"mode": "[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"')|$($P -c "select user_id||'|'||(extra_data->>'memberUid') from public.tickets where extra_data->>'chargeId'='$CG' and status='active'")|$($P -c "select user_id from public.kashikiri_charges where id='$CG'")"
ok "  다른 회차를 고르면 → SEAT_OTHER_TICKET (좌석은 그대로)" "1" "$($P -c "update public.tickets set user_id='$SU', extra_data = extra_data - 'memberUid' where extra_data->>'chargeId'='$CG'; update public.kashikiri_charges set user_id=null where id='$CG'" >/dev/null; att "'$CG','tpS',1,'$M5'" | grep -c SEAT_OTHER_TICKET)"

echo "── 소유자 이전이 보류된 티켓 링크 → 「예약 내역에서 확인」이라 하지 않는다"
$P -c "insert into public.tickets(id,user_id,restaurant_id,restaurant_name,ticket_product_id,reservation_date,visit_time,party_size,price,status,purchase_id,extra_data) values (gen_random_uuid(),'$M2','b1000000-0000-4000-8000-000000000003','마츠카와','tp1','2027.05.01','18:00',1,100,'active','INV-m2x','{\"invitePaid\":true}')" >/dev/null 2>&1
R3=$($P -c "$S select public.taam_pay_link_create('ticket', jsonb_build_object('ticket_id','tp1','name','김회원','pax',1,'currency','KRW','visit_date','2027.05.01','visit_time','18:00'))::text" 2>&1)
CP=$(echo "$R3" | grep -oE '"charge_id": "[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
$P -c "update public.kashikiri_charges set user_id='$M2' where id='$CP'; update public.kashikiri_charges set status='paid', approved_at=now(), payment_key='pkP' where id='$CP'" >/dev/null 2>&1
ok "  보류(memberUidPending) → 회원 알림은 「결제가 완료되었습니다」(예약 내역 문구 아님)" "1|결제가 완료되었습니다" "$($P -c "select count(*) from public.tickets where extra_data->>'chargeId'='$CP' and extra_data ? 'memberUidPending'")|$($P -c "select title from public.notifications where user_id='$M2' and type='pay_link_paid' and payload->>'charge_id'='$CP'")"

echo "── 「예약 아님」으로 목록에서 빼기"
$P -c "insert into public.kashikiri_charges(id, event_id, label, amount_krw, pay_currency, pay_fx, pay_amount, purpose, title, status, approved_at) values ('c1000000-0000-4000-8000-0000000000b1', null, '손님', 300000, 'KRW', 1, 300000, 'custom', '와인 추가분', 'paid', now())" >/dev/null
ok "목록에 있음 → 회원 세션 빼기 FORBIDDEN → 슈퍼어드민 빼기 → 목록에서 빠짐 · 어드민 메모 「[예약 아님 …] 와인」" "1|1|0|1" "$($P -c "$S select count(*) from jsonb_array_elements(public.taam_pay_link_unattached(100)) e where e->>'id'='c1000000-0000-4000-8000-0000000000b1'")|$($P -c "set taam.uid='$M3'; set taam.super='0'; select public.taam_pay_link_unattached_dismiss('c1000000-0000-4000-8000-0000000000b1')" 2>&1 | grep -c FORBIDDEN)|$($P -c "$S select public.taam_pay_link_unattached_dismiss('c1000000-0000-4000-8000-0000000000b1', true, '와인'); $S select count(*) from jsonb_array_elements(public.taam_pay_link_unattached(100)) e where e->>'id'='c1000000-0000-4000-8000-0000000000b1'" | tail -1)|$($P -c "select count(*) from public.kashikiri_charge_admin where charge_id='c1000000-0000-4000-8000-0000000000b1' and note like '[예약 아님 %] 와인'")"
ok "  되돌리기(p_on=false) → 다시 목록에" "1" "$($P -c "$S select public.taam_pay_link_unattached_dismiss('c1000000-0000-4000-8000-0000000000b1', false); $S select count(*) from jsonb_array_elements(public.taam_pay_link_unattached(100)) e where e->>'id'='c1000000-0000-4000-8000-0000000000b1'" | tail -1)"

out2=$($P -f $MIG 2>&1)
ok "두 번째 RUN: 오류 없음 · ❌ 0" "|0" "$(echo "$out2" | grep -E "^ERROR|psql:.*ERROR" | head -1)|$(echo "$out2" | grep -c '❌')"
$PSQL -c "drop database if exists $DB" >/dev/null 2>&1
[ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
