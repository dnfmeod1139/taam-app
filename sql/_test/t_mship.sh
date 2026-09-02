#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 멤버십 심사 신청 — 서버가 정말 지키는지 (2026-09-02)
# ═══════════════════════════════════════════════════════════════
# 신청서에는 이름·전화번호·소득 수준·다녀온 가게가 들어 있다.
# 앱에서 안 보여주는 것과 **읽을 수 없는 것**은 다르다.
#
#   ① 비회원도 신청할 수 있나 (공개 페이지)
#   ② 두 번 눌러도 한 장인가
#   ③ 남의 신청서를 못 읽나  ← 여기가 핵심
#   ④ 표를 직접 INSERT·UPDATE 로 못 건드리나
#   ⑤ 어드민 함수가 슈퍼어드민만 통과시키나
#
# 먼저:  psql -f sql/membership_apply.sql
# 실행:  bash sql/_test/t_mship.sh
# ═══════════════════════════════════════════════════════════════
P="psql -h /tmp -U postgres -d postgres -q -t -A"
SUP=99999999-9999-9999-9999-999999999999
U1=c0000000-0000-4000-8000-0000000000b1
U2=c0000000-0000-4000-8000-0000000000b2

ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
FAIL=0

# ── 배우 ─────────────────────────────────────────────────────
# ⚠ 로컬 픽스처의 anon 은 public 스키마 USAGE 가 없다. Supabase 에는 있다 —
#   없는 채로 돌리면 「비회원이 신청 못 한다」는 가짜 실패가 난다.
$P -c "grant usage on schema public to anon, authenticated;" >/dev/null 2>&1
$P -c "
insert into auth.users(id) values ('$U1'),('$U2') on conflict do nothing;
insert into public.profiles(id, role, display_name, membership_tier) values
 ('$U1','member','신청자A','A'), ('$U2','member','남남B','A')
 on conflict (id) do update set role='member', membership_tier='A';
delete from public.membership_applications where phone in ('01011112222','01033334444','01055556666');
" >/dev/null 2>&1

echo "── ① 신청 ──"
# 비회원(anon) — 공개 페이지에서 들어온 신청
R=$($P -c "set role anon;
  select (public.taam_mship_apply('비회원','010-1111-2222',
    '{\"visits\":\"연 3회 이상\",\"spend\":\"200만원 이상\"}'::jsonb,'ko',null,'web'))->>'ok';" 2>&1 | tail -1)
ok "비회원도 신청된다 ⭐" true "$R"

# 회원 — 앱에서
R=$($P -c "set role authenticated; select set_config('taam.uid','$U1',false);
  select (public.taam_mship_apply('신청자A','010-3333-4444','{}'::jsonb,'ko',null,'app'))->>'ok';" 2>&1 | tail -1)
ok "회원도 신청된다" true "$R"
ok "회원 신청에는 user_id 가 붙는다" "$U1" \
   "$($P -c "select user_id from public.membership_applications where phone='01033334444';" | tail -1)"
ok "비회원 신청에는 user_id 가 없다" "" \
   "$($P -c "select coalesce(user_id::text,'') from public.membership_applications where phone='01011112222';" | tail -1)"

echo "── ② 두 번 눌러도 한 장 ──"
R=$($P -c "set role anon;
  select (public.taam_mship_apply('비회원','01011112222','{}'::jsonb))->>'already';" 2>&1 | tail -1)
ok "두 번째는 already" true "$R"
ok "그래도 한 장뿐이다 ⭐" 1 \
   "$($P -c "select count(*) from public.membership_applications where phone='01011112222';" | tail -1)"

echo "── ③ 빈 값은 안 받는다 ──"
if $P -c "set role anon; select public.taam_mship_apply('','01055556666','{}'::jsonb);" >/dev/null 2>&1;
then echo "❌ 이름이 비어도 들어갔다"; FAIL=1; else echo "✅ 이름이 비면 거절"; fi
if $P -c "set role anon; select public.taam_mship_apply('아무개','123','{}'::jsonb);" >/dev/null 2>&1;
then echo "❌ 번호가 짧아도 들어갔다"; FAIL=1; else echo "✅ 짧은 번호는 거절"; fi

echo "── ④ 남의 신청서 ── ⭐ 여기가 핵심"
ok "내 것은 보인다" 1 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$U1',false);
             select count(*) from public.membership_applications where phone='01033334444';" | tail -1)"
ok "남의 것은 안 보인다 ⭐" 0 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$U2',false);
             select count(*) from public.membership_applications where phone='01033334444';" | tail -1)"
# anon 은 0건이 아니라 **아예 권한이 없다**. RLS 정책 하나가 잘못 들어가도
# 열리지 않는 상태 — 0건보다 한 겹 강하다.
if $P -c "set role anon; select count(*) from public.membership_applications;" >/dev/null 2>&1;
then echo "❌ 비회원(anon)이 신청서 표를 읽었다"; FAIL=1;
else echo "✅ 비회원(anon)은 표에 손도 못 댄다 ⭐"; fi
ok "슈퍼어드민은 다 본다" 2 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select count(*) from public.membership_applications
              where phone in ('01011112222','01033334444');" | tail -1)"

echo "── ⑤ 표를 직접 못 건드린다 ──"
if $P -c "set role authenticated; select set_config('taam.uid','$U1',false);
          insert into public.membership_applications(phone) values ('01099998888');" >/dev/null 2>&1;
then echo "❌ 직접 INSERT 가 됐다"; FAIL=1; else echo "✅ 직접 INSERT 는 막힌다"; fi
if $P -c "set role authenticated; select set_config('taam.uid','$U1',false);
          update public.membership_applications set status='screening' where phone='01033334444';" \
     2>&1 | grep -q "UPDATE 1";
then echo "❌ 자기 신청 상태를 스스로 바꿨다"; FAIL=1; else echo "✅ 상태를 스스로 못 바꾼다 ⭐"; fi

echo "── ⑥ 어드민 ──"
if $P -c "set role authenticated; select set_config('taam.uid','$U1',false);
          select public.taam_mship_apply_list(null,10);" >/dev/null 2>&1;
then echo "❌ 회원이 심사 큐를 봤다"; FAIL=1; else echo "✅ 회원은 심사 큐를 못 본다 ⭐"; fi
ok "슈퍼어드민은 큐를 본다" 2 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select jsonb_array_length(public.taam_mship_apply_list(null,10));" | tail -1)"
ok "상태를 바꾼다" screening \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select (public.taam_mship_apply_status(
               (select id from public.membership_applications where phone='01033334444'),
               'screening','확인 중'))->>'status';" | tail -1)"
if $P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
          select public.taam_mship_apply_status(
            (select id from public.membership_applications where phone='01033334444'), 'offered');" \
     >/dev/null 2>&1;
then echo "❌ offered 를 여기서 세웠다 (링크 없이 통과 상태가 된다)"; FAIL=1;
else echo "✅ offered 는 여기서 못 세운다 ⭐"; fi

echo "── ⑦ 심사 중이면 다시 신청해도 한 장 ──"
R=$($P -c "set role authenticated; select set_config('taam.uid','$U1',false);
  select (public.taam_mship_apply('신청자A','01033334444','{}'::jsonb))->>'already';" | tail -1)
ok "screening 중에도 already" true "$R"

echo "── ⑧ 정원 ──"
if $P -c "set role authenticated; select set_config('taam.uid','$U1',false);
          select public.taam_mship_seats_set(40,1);" >/dev/null 2>&1;
then echo "❌ 회원이 정원을 바꿨다"; FAIL=1; else echo "✅ 회원은 정원을 못 바꾼다"; fi
ok "슈퍼어드민은 바꾼다" 5 \
   "$($P -c "set role authenticated; select set_config('taam.uid','$SUP',false);
             select (public.taam_mship_seats_set(33,28))->>'left';" | tail -1)"
ok "잔여석은 누구나 읽는다 (오퍼 페이지)" 33 \
   "$($P -c "set role anon; select capacity from public.membership_seats;" | tail -1)"
$P -c "select public.taam_mship_seats_set(33,0);" >/dev/null 2>&1

echo
[ "$FAIL" = "1" ] && echo "=== 실패 있음 ===" || echo "=== 전부 통과 ==="
