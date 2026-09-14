#!/bin/bash
# 미감사 5개 영역 SQL (sql/audit5_hardening_2026-09-14.sql) 재보기. 먼저: 로컬 pg. 실행: bash sql/_test/t_audit5.sh
cd "$(dirname "$0")/../.."
P="psql -h /tmp -U postgres -d postgres -q -t -A"
U=c1000000-0000-4000-8000-000000000001; S=c1000000-0000-4000-8000-0000000000ff; V=c1000000-0000-4000-8000-000000000002
ok(){ if [ "$2" = "$3" ]; then echo "✅ $1"; else echo "❌ $1  (기대 $2, 실제 $3)"; FAIL=1; fi; }
has(){ echo "$1" | grep -q "$2" && echo 1 || echo 0; }
FAIL=0
$P -v ON_ERROR_STOP=1 -f sql/_test/fx_audit5.sql >/dev/null 2>/tmp/_a5.err || { echo "❌ 픽스처"; head -3 /tmp/_a5.err; exit 1; }
$P -c "insert into auth.users(id,email,phone) values ('$U','me@x.com','+821012345678'),('$S','sa@x.com',null),('$V','victim@x.com','+821099998888');
insert into public.profiles(id,role,membership_tier,display_name,phone,email) values ('$U','member','','회원','010-1234-5678','me@x.com'),('$S','super_admin','','슈퍼',null,null),('$V','member','M','피해자','010-9999-8888','victim@x.com');
insert into public.invite_codes(member_id,invitee_tier,invitee_phone) values ('$V','M','010-9999-8888');
insert into auth.sessions(user_id) values ('$U'),('$U'); insert into auth.refresh_tokens(user_id) values ('$U'); insert into public.active_sessions(user_id,device_id) values ('$U','d1');" >/dev/null

echo "── 적용 전 (사고 모양)"
ok "옛 invited_tier 는 회원이 넘긴 번호로 M 을 돌려준다" "M" "$($P -c "select public.taam_invited_tier('$U','','010-9999-8888');" | tail -1)"
ok "mark_paid 가 authenticated 에 열려 있다" "t" "$($P -c "select has_function_privilege('authenticated','public.taam_kashikiri_mark_paid(text,text,bigint,text,text)','execute');" | tail -1)"

echo "── 적용"
$P -v ON_ERROR_STOP=1 -f sql/audit5_hardening_2026-09-14.sql >/tmp/_a5.out 2>/tmp/_a5.err || { echo "❌ 적용 실패"; grep -i "error" /tmp/_a5.err | head -5; exit 1; }
ok "확인 표에 ❌ 없음" 0 "$(grep -c '❌' /tmp/_a5.out)"
ok "확인 표 ✅ 9줄" 9 "$(grep -c '✅' /tmp/_a5.out)"
grep "⚠" /tmp/_a5.out | head -2

echo "── ① 권한"
ok "mark_paid 닫힘" "f" "$($P -c "select has_function_privilege('authenticated','public.taam_kashikiri_mark_paid(text,text,bigint,text,text)','execute');" | tail -1)"
ok "알림 RPC anon 닫힘" "f" "$($P -c "select has_function_privilege('anon','public.taam_visit_reminder_notify()','execute');" | tail -1)"
ok "service_role 은 된다" "t" "$($P -c "select has_function_privilege('service_role','public.taam_guest_expiry_notify()','execute');" | tail -1)"

echo "── ④ guest_expires_at 가드"
$P -c "update public.profiles set guest_expires_at = now() where id='$U';" >/dev/null
OUT=$($P -c "set role authenticated; select set_config('taam.uid','$U',false); update public.profiles set guest_expires_at = now() + interval '10 year' where id='$U';" 2>&1)
ok "회원이 밀어도 되돌아온다 ⭐" "t" "$($P -c "select guest_expires_at < now() + interval '1 day' from public.profiles where id='$U';" | tail -1)"
$P -c "set role authenticated; select set_config('taam.uid','$S',false); update public.profiles set guest_expires_at = now() + interval '10 year' where id='$U';" >/dev/null 2>&1
ok "슈퍼어드민은 바꾼다" "t" "$($P -c "select guest_expires_at > now() + interval '9 year' from public.profiles where id='$U';" | tail -1)"

echo "── ⑤ is_admin"
$P -c "set role authenticated; select set_config('taam.uid','$U',false); update public.profiles set is_admin = true where id='$U';" >/dev/null 2>&1
ok "회원이 켜도 꺼진 채 ⭐" "f" "$($P -c "select is_admin from public.profiles where id='$U';" | tail -1)"
ok "is_admin 을 보던 Storage 정책 0" 0 "$($P -c "select count(*) from pg_policies where schemaname='storage' and (coalesce(qual,'')||coalesce(with_check,'')) like '%is_admin%';" | tail -1)"
ok "chef_photos_admin_update 가 슈퍼어드민 전용" 1 "$(has "$($P -c "select qual||with_check from pg_policies where policyname='chef_photos_admin_update';")" _taam_uid_is_super)"

echo "── ⑥ 게스트 연장"
$P -c "update public.profiles set membership_tier='A', guest_expires_at = now() + interval '5 day' where id='$U';" >/dev/null
$P -c "insert into public.tickets(user_id,purchase_id,status) values ('$U','PAYH-1','hold');" >/dev/null
ok "홀드 INSERT 로는 안 밀린다 ⭐" "t" "$($P -c "select guest_expires_at < now() + interval '6 day' from public.profiles where id='$U';" | tail -1)"
$P -c "insert into public.tickets(user_id,purchase_id,status) values ('$U','taam-1','hold'); update public.tickets set status='active' where purchase_id='taam-1';" >/dev/null
ok "hold→active 확정에 +90일" "t" "$($P -c "select guest_expires_at > now() + interval '89 day' from public.profiles where id='$U';" | tail -1)"

echo "── ⑦ invited_tier"
ok "회원이 넘긴 남의 번호는 무시 ⭐" "" "$($P -c "select coalesce(public.taam_invited_tier('$U','','010-9999-8888'),'');" | tail -1)"
ok "auth.users 의 인증 번호로는 찾는다" "M" "$($P -c "select public.taam_invited_tier('$V','','');" | tail -1)"

echo "── ⑧ restaurant-videos"
ok "넓은 authenticated INSERT/UPDATE 정책 제거" 0 "$($P -c "select count(*) from pg_policies where policyname in ('restaurant_videos_auth_insert','restaurant_videos_auth_update');" | tail -1)"
OUT=$($P -c "set role authenticated; select set_config('taam.uid','$U',false); insert into storage.objects(bucket_id,name) values ('restaurant-videos','x.mp4');" 2>&1)
ok "일반 회원 업로드 거부 ⭐" 1 "$(has "$OUT" "row-level security")"
$P -c "insert into public.admin_grants(user_id,rest_id) values ('$U','r1');" >/dev/null
OUT=$($P -c "set role authenticated; select set_config('taam.uid','$U',false); insert into storage.objects(bucket_id,name) values ('restaurant-videos','x.mp4');" 2>&1)
ok "파트너 어드민(admin_grants) 업로드 허용" 0 "$(has "$OUT" ERROR)"
OUT=$($P -c "set role authenticated; select set_config('taam.uid','$U',false); update storage.objects set name='y.mp4' where name='x.mp4';" 2>&1)
ok "파트너의 덮어쓰기(UPDATE)는 0행" "x.mp4" "$($P -c "select name from storage.objects where bucket_id='restaurant-videos';" | tail -1)"
ok "Public read 정책은 남아 있다" 1 "$($P -c "select count(*) from pg_policies where policyname='Public read videos';" | tail -1)"

echo "── ⑨ 버킷 제한"
ok "restaurant-videos 50MB·video/*" "52428800" "$($P -c "select file_size_limit from storage.buckets where id='restaurant-videos';" | tail -1)"
ok "taam-photos 이미지만" "t" "$($P -c "select 'image/jpeg' = any(allowed_mime_types) and not ('video/mp4' = any(allowed_mime_types)) from storage.buckets where id='taam-photos';" | tail -1)"

echo "── ③ 탈퇴"
OUT=$($P -c "set role authenticated; select set_config('taam.uid','$U',false); select public.taam_delete_my_account();" 2>&1)
ok "ok·banned·sessions_killed 반환" 1 "$(has "$OUT" '"banned" : true')"
ok "banned_until = infinity ⭐" "t" "$($P -c "select banned_until = 'infinity' from auth.users where id='$U';" | tail -1)"
ok "세션·토큰·active_sessions 0" "0|0|0" "$($P -c "select (select count(*) from auth.sessions where user_id='$U')||'|'||(select count(*) from auth.refresh_tokens where user_id='$U')||'|'||(select count(*) from public.active_sessions where user_id='$U');" | tail -1)"
ok "kill_sessions 는 authenticated 못 부름" "f" "$($P -c "select has_function_privilege('authenticated','public.taam_kill_sessions(uuid)','execute');" | tail -1)"

echo; [ $FAIL = 0 ] && echo "=== 전부 통과 ===" || { echo "=== 실패 있음 ==="; exit 1; }
