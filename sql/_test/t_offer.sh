#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 오퍼 — 서버가 정말 지키는지 (2026-09-02)
# ═══════════════════════════════════════════════════════════════
#   ① 금액을 **보낸 순간의 값으로 박제**하는가  ← 설정이 바뀌어도 안 흔들려야
#   ② 공개 링크가 전화번호를 안 주는가          ← 토큰만 알면 번호가 새면 안 된다
#   ③ 만료·취소된 링크가 막히는가
#   ④ 두 장을 안 만드는가
#   ⑤ 통과를 오퍼에서만 세우는가 (심사 큐에서는 못 세운다)
#   ⑥ 취소하면 신청이 큐로 돌아오는가          ← 안 돌아오면 영영 사라진다
#   ⑦ 금액이 비었으면 아예 안 만드는가
#
# 먼저: membership_apply.sql · membership_settings.sql · membership_offer.sql
# 실행: bash sql/_test/t_offer.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
U1=e0000000-0000-4000-8000-0000000000d1

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0
SA="set role authenticated; select set_config('taam.uid','$SUP',false);"

$P -c "grant usage on schema public to anon, authenticated;" >/dev/null 2>&1
# ⚠ 셋업을 한 덩이로 묶지 않는다. psql -c 는 한 트랜잭션이라,
#   그 안에서 하나가 실패하면 **앞의 insert 까지 통째로 롤백**된다.
#   여기서 두 번 당했다:
#     ① 슈퍼어드민 없이 설정 RPC → 권한 예외 → 배우가 안 생김
#     ② set role authenticated 를 먼저 → auth.users INSERT 가 막힘
#   배우는 postgres 로, 설정은 슈퍼어드민으로 — 따로 돌린다.
$P -c "
insert into auth.users(id) values ('$U1') on conflict do nothing;
insert into public.profiles(id,role,display_name,membership_tier)
 values ('$U1','member','오퍼받을사람','A')
 on conflict (id) do update set membership_tier='A', role='member';
delete from public.membership_offers;
delete from public.membership_applications where phone in ('01077778888');
" >/dev/null 2>&1
$P -c "$SA
select public.taam_mship_settings_set('deposit_amount','10125000'::jsonb);
select public.taam_mship_settings_set('annual_fee_cash','1125000'::jsonb);
select public.taam_mship_settings_set('annual_fee_card','1270000'::jsonb);
select public.taam_mship_settings_set('offer_days','7'::jsonb);
" >/dev/null 2>&1
APP=$($P -c "set role authenticated; select set_config('taam.uid','$U1',false);
  select (public.taam_mship_apply('오퍼받을사람','010-7777-8888','{}'::jsonb))->>'id';" | tail -1)

echo "── ① 만들기 ──"
TOK=$($P -c "$SA select (public.taam_mship_offer_create('$APP'))->>'token';" | tail -1)
ok "토큰 32자" 32 "$(printf %s "$TOK" | wc -c)"
ok "신청이 통과로 바뀐다" offered \
   "$($P -c "select status from public.membership_applications where id='$APP';" | tail -1)"
ok "7일 뒤 만료" 7 \
   "$($P -c "select ceil(extract(epoch from (expires_at-now()))/86400)::int
             from public.membership_offers where token='$TOK';" | tail -1)"

echo "── ② 금액 박제 ── ⭐"
ok "보낸 순간의 이체 연회비" 1125000 \
   "$($P -c "select annual_fee_cash from public.membership_offers where token='$TOK';" | tail -1)"
$P -c "$SA select public.taam_mship_settings_set('annual_fee_cash','9999999'::jsonb);" >/dev/null 2>&1
ok "설정을 바꿔도 오퍼는 안 흔들린다 ⭐" 1125000 \
   "$($P -c "select annual_fee_cash from public.membership_offers where token='$TOK';" | tail -1)"
ok "공개 링크도 박제된 값을 준다 ⭐" 1125000 \
   "$($P -c "set role anon; select (public.taam_mship_offer_public('$TOK'))->>'annual_fee_cash';" | tail -1)"
$P -c "$SA select public.taam_mship_settings_set('annual_fee_cash','1125000'::jsonb);" >/dev/null 2>&1

echo "── ③ 공개 링크가 주는 것 ── ⭐"
ok "성만 준다" 오 \
   "$($P -c "set role anon; select (public.taam_mship_offer_public('$TOK'))->>'surname';" | tail -1)"
if $P -c "set role anon; select (public.taam_mship_offer_public('$TOK'))->>'phone';" 2>/dev/null | grep -q "7777";
then echo "❌ 공개 링크가 전화번호를 줬다"; FAIL=1; else echo "✅ 전화번호를 안 준다 ⭐"; fi
if $P -c "set role anon; select count(*) from public.membership_offers;" >/dev/null 2>&1;
then echo "❌ anon 이 오퍼 표를 읽었다"; FAIL=1; else echo "✅ 표에는 손도 못 댄다 ⭐"; fi
ok "열면 열었다고 남는다" opened \
   "$($P -c "select status from public.membership_offers where token='$TOK';" | tail -1)"
ok "잔여석은 지금 값" t \
   "$($P -c "set role anon;
             select ((public.taam_mship_offer_public('$TOK'))->>'seats_left')::int is not null;" | tail -1)"

echo "── ④ 두 장을 안 만든다 ──"
ok "이미 있으면 그것을 준다 ⭐" true \
   "$($P -c "$SA select (public.taam_mship_offer_create('$APP'))->>'already';" | tail -1)"
ok "그래도 한 장뿐" 1 \
   "$($P -c "select count(*) from public.membership_offers where application_id='$APP';" | tail -1)"

echo "── ⑤ 심사 큐에서는 통과를 못 세운다 ──"
if $P -c "$SA select public.taam_mship_apply_status('$APP','offered');" >/dev/null 2>&1;
then echo "❌ 심사 큐에서 offered 를 세웠다"; FAIL=1; else echo "✅ 링크 없이 통과가 안 된다 ⭐"; fi

echo "── ⑥ 시작하겠다 ──"
ok "accept 된다" true \
   "$($P -c "set role anon; select (public.taam_mship_offer_accept('$TOK','cash'))->>'ok';" | tail -1)"
ok "상태가 accepted" accepted \
   "$($P -c "select status from public.membership_offers where token='$TOK';" | tail -1)"
ok "희망 결제 수단이 남는다" t \
   "$($P -c "select admin_memo like '%cash%' from public.membership_offers where token='$TOK';" | tail -1)"
if $P -c "set role anon; select public.taam_mship_offer_accept('$TOK','bitcoin');" >/dev/null 2>&1;
then echo "❌ 모르는 결제 수단이 들어갔다"; FAIL=1; else echo "✅ 모르는 결제 수단은 거절"; fi
# ⚠ accept 는 돈을 안 움직인다. 등급도 안 올린다.
ok "등급을 올리지 않는다 ⭐" A \
   "$($P -c "select membership_tier from public.profiles where id='$U1';" | tail -1)"

echo "── ⑦ 취소하면 큐로 돌아온다 ── ⭐"
OID=$($P -c "select id from public.membership_offers where token='$TOK';" | tail -1)
$P -c "$SA select public.taam_mship_offer_cancel('$OID');" >/dev/null 2>&1
ok "오퍼가 취소된다" cancelled \
   "$($P -c "select status from public.membership_offers where token='$TOK';" | tail -1)"
ok "신청이 심사 중으로 돌아온다 ⭐" screening \
   "$($P -c "select status from public.membership_applications where id='$APP';" | tail -1)"
ok "취소된 링크는 막힌다" cancelled \
   "$($P -c "set role anon; select (public.taam_mship_offer_public('$TOK'))->>'blocked';" | tail -1)"

echo "── ⑧ 만료 ──"
TOK2=$($P -c "$SA select (public.taam_mship_offer_create('$APP'))->>'token';" | tail -1)
$P -c "update public.membership_offers set expires_at = now() - interval '1 day' where token='$TOK2';" >/dev/null
ok "만료된 링크는 막힌다 ⭐" expired \
   "$($P -c "set role anon; select (public.taam_mship_offer_public('$TOK2'))->>'blocked';" | tail -1)"
if $P -c "set role anon; select public.taam_mship_offer_accept('$TOK2');" >/dev/null 2>&1;
then echo "❌ 만료된 링크로 시작됐다"; FAIL=1; else echo "✅ 만료되면 시작도 안 된다 ⭐"; fi
ok "없는 토큰은 조용히 없다고" false \
   "$($P -c "set role anon; select (public.taam_mship_offer_public('nope'))->>'found';" | tail -1)"

echo "── ⑨ 금액이 없으면 안 만든다 ── ⭐"
$P -c "$SA select public.taam_mship_settings_set('deposit_amount','0'::jsonb);" >/dev/null 2>&1
$P -c "update public.membership_offers set status='cancelled' where application_id='$APP';" >/dev/null
if $P -c "$SA select public.taam_mship_offer_create('$APP');" >/dev/null 2>&1;
then echo "❌ 금액 없이 오퍼를 만들었다 (가격 공개 페이지에 가격이 없다)"; FAIL=1;
else echo "✅ 금액이 없으면 안 만든다 ⭐"; fi
$P -c "$SA select public.taam_mship_settings_set('deposit_amount','10125000'::jsonb);" >/dev/null 2>&1

echo "── ⑩ 권한 ──"
if $P -c "set role authenticated; select set_config('taam.uid','$U1',false);
          select public.taam_mship_offer_create('$APP');" >/dev/null 2>&1;
then echo "❌ 회원이 오퍼를 만들었다"; FAIL=1; else echo "✅ 오퍼는 슈퍼어드민만 ⭐"; fi
if $P -c "set role authenticated; select set_config('taam.uid','$U1',false);
          select public.taam_mship_offer_list(10);" >/dev/null 2>&1;
then echo "❌ 회원이 오퍼 목록을 봤다"; FAIL=1; else echo "✅ 목록도 슈퍼어드민만"; fi

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
