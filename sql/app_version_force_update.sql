-- ═══════════════════════════════════════════════════════════════
-- TAAM — 강제 업데이트 걸기 (2026-08-28)
-- ═══════════════════════════════════════════════════════════════
-- 정책 (2026-08-28 결정)
--   **새 빌드를 스토어에 내면 그 빌드로 강제한다.** 두 스토어 모두.
--   구버전을 남겨두지 않는다 — 화면은 웹이라 최신이어도 네이티브 껍데기
--   (푸시·플러그인·권한)는 스토어 업데이트를 받아야만 바뀌고, 그 차이는
--   회원이 스스로 알 방법이 없다. "화면은 최신인데 알림만 안 오는" 회원을
--   만들지 않는 쪽을 택했다.
--
--   그래서 출시할 때마다 이 파일에서 숫자 하나만 바꿔 돌린다.
--     min_build = latest_build = 새 빌드번호
--
-- 동작 (index.html · taamCheckAppUpdate)
--   설치 빌드 <  min_build     → 강제. 「나중에」 버튼이 없다. 앱을 못 쓴다
--   설치 빌드 <  latest_build  → 권장. 「나중에」 가능, 하루 1회
--   그 외                      → 아무것도 안 뜬다
--   웹·PWA 회원은 빌드번호가 없어 어느 쪽에도 걸리지 않는다
--   조회 실패(네트워크·RLS) 시에는 아무것도 하지 않는다 — 멀쩡한 회원을 잠그지 않는다
--
-- ⚠⚠ 하나만은 반드시 지킨다 — 스토어에 그 빌드가 '실제로 출시된 뒤'에 실행한다.
--   출시 전에 걸면 회원은 앱이 잠긴 채 스토어엔 옛 버전밖에 없다. 빠져나갈 길이 없다.
--   심사 통과 ≠ 출시다. 스토어에서 직접 보이는 것을 확인하고 돌린다.
--
-- ⚠⚠ 이 파일은 위에서 아래로 통째로 돌리는 파일이 아니다.
--   ⑤ 는 사고 났을 때만 쓰는 되돌리기다. 끝까지 돌리면 방금 건 강제가
--   마지막에 전부 풀린다 — 실제로 2026-08-28 에 그렇게 됐다.
--   ①(확인) → 필요한 것 하나 → ④(확인). 이 셋만 쓴다.
--
-- 실행: Supabase SQL Editor 에 **필요한 블록만 골라** 붙여넣고 RUN.
--       값을 바꿔 여러 번 실행해도 안전하다.
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- ⓪ 출시 전 정상 상태 — 헷갈리면 이걸로 돌아온다
-- ═══════════════════════════════════════════════════════════════
--   iOS 1.02 가 아직 App Store 에 없고, Android 는 1.02(1011)가 나가 있는 상태.
--     iOS     0 / 0        → 아무것도 안 뜬다
--     Android 1011 / 1011  → 1010 이하만 강제 (푸시가 없거나 반쪽인 구버전)
--
--   ⚠ iOS latest_build 를 미리 35 로 올려두면 안 된다. 1.01 은 빌드 표식이 없어
--     앱이 build:0 으로 읽으므로 0 < 35 라 매일 「업데이트하세요」가 뜨는데,
--     스토어엔 받을 게 없다. 눌러도 안 사라지고 다음 날 또 뜬다.
/*
update public.app_config
   set value = jsonb_set(jsonb_set(jsonb_set(jsonb_set(value,
                 '{ios,min_build}',        '0'::jsonb),
                 '{ios,latest_build}',     '0'::jsonb),
                 '{android,min_build}',    '1011'::jsonb),
                 '{android,latest_build}', '1011'::jsonb),
       updated_at = now()
 where key = 'app_version';
*/


-- ═══════════════════════════════════════════════════════════════
-- ① 지금 값 확인 — 손대기 전에 항상 먼저 본다
-- ═══════════════════════════════════════════════════════════════
select
  value->'ios'->>'min_build'          as "iOS_강제기준",
  value->'ios'->>'latest_build'       as "iOS_최신빌드",
  value->'android'->>'min_build'      as "AOS_강제기준",
  value->'android'->>'latest_build'   as "AOS_최신빌드",
  to_char(updated_at,'MM-DD HH24:MI') as "마지막수정"
from public.app_config
where key = 'app_version';


-- ═══════════════════════════════════════════════════════════════
-- ② iOS 강제 — App Store 에 그 버전이 보인 뒤에 실행
-- ═══════════════════════════════════════════════════════════════
--   ⚠ 바꿀 곳은 아래 `select 35` 의 숫자 하나뿐이다.
--
--   1.02 = 빌드 35 다. Codemagic 빌드 이름은 #34 지만 ipa 에 박히는 값은 +1 이라
--   하나 어긋난다. 넣어야 할 값은 항상 ipa 쪽이다.
--
--   1.01 에는 빌드 표식이 없어 앱이 build:0 으로 읽는다. 0 < 35 이므로
--   1.01 사용자 전원이 강제 대상이 되고, 1.02 사용자(35)는 걸리지 않는다.
/*
with v as (select 35 as build)                 -- ← iOS 빌드번호 (ipa 기준)
update public.app_config a
   set value = jsonb_set(
                 jsonb_set(a.value, '{ios,min_build}',    to_jsonb(v.build)),
                                    '{ios,latest_build}', to_jsonb(v.build)),
       updated_at = now()
  from v
 where a.key = 'app_version';
*/


-- ═══════════════════════════════════════════════════════════════
-- ③ Android 강제 — Play 에 그 빌드가 출시된 뒤에 실행
-- ═══════════════════════════════════════════════════════════════
--   ⚠ 바꿀 곳은 아래 `select 1011` 의 숫자 하나뿐이다.
--
--   versionCode 는 Codemagic 빌드 로그나 .aab 파일 이름에서 확인한다
--   (Android versionCode = 1000 + BUILD_NUMBER).
--
--   1011 = 1.02 (2026-08-27 출시, 현재 스토어에 나가 있는 것)
--   1012 = 2026-08-28 빌드 (상태바 알림 아이콘) — Play 에 올린 뒤 이 숫자로 바꾼다
/*
with v as (select 1011 as code)                -- ← Android versionCode
update public.app_config a
   set value = jsonb_set(
                 jsonb_set(a.value, '{android,min_build}',    to_jsonb(v.code)),
                                    '{android,latest_build}', to_jsonb(v.code)),
       updated_at = now()
  from v
 where a.key = 'app_version';
*/


-- ═══════════════════════════════════════════════════════════════
-- ④ 확인
-- ═══════════════════════════════════════════════════════════════
select value from public.app_config where key = 'app_version';


-- ═══════════════════════════════════════════════════════════════
-- ⑤ 되돌리기 — 잘못 걸었을 때
-- ═══════════════════════════════════════════════════════════════
--   min_build 만 0 으로 내리면 강제가 즉시 풀린다 (권장 안내는 남는다).
--   회원은 앱을 다시 열면 바로 쓸 수 있다.
--
--   더 급하면 index.html 의 APP_UPDATE_LIVE 를 false 로 배포한다 —
--   안내가 통째로 사라진다. 웹 배포라 전 기기에 즉시 닿는다.
/*
update public.app_config
   set value = jsonb_set(
                 jsonb_set(value, '{ios,min_build}',     '0'::jsonb),
                                  '{android,min_build}', '0'::jsonb),
       updated_at = now()
 where key = 'app_version';
*/
