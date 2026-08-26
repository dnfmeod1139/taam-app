-- ═══════════════════════════════════════════════════════════════
-- TAAM — 앱 업데이트 안내 설정 · 2026-08
-- Supabase SQL Editor 에 붙여넣고 RUN (값을 바꿔 여러 번 실행해도 안전)
--
-- 무엇인가
--   구버전 네이티브 앱을 쓰는 회원에게 "업데이트하세요" 를 띄우는 기준값이다.
--   앱(index.html)의 taamCheckAppUpdate() 가 로그인 직후 이 한 줄을 읽는다.
--
-- 왜 필요한가
--   server.url 이 taam-app.vercel.app 이라 화면·로직은 웹 배포만으로 전 기기에
--   즉시 반영된다. 그런데 푸시·플러그인·권한 같은 네이티브 껍데기는 스토어
--   업데이트를 받아야만 바뀐다. 그래서 "화면은 최신인데 푸시만 안 오는" 회원이
--   생길 수 있고, 그 사람은 자기가 구버전이라는 걸 알 방법이 없다.
--
-- 왜 버전 문자열이 아니라 빌드번호로 비교하나
--   '1.01' 이 1.1 인지 1.0.1 인지 스토어마다 해석이 다르고, iOS 표시버전과
--   Android versionName 이 어긋날 수도 있다. 빌드번호는 두 스토어 모두
--   '단조 증가하는 정수' 라 다툼의 여지가 없다.
--     · iOS     빌드번호   = Codemagic BUILD_NUMBER + 1   (예: 33)
--     · Android versionCode = 1000 + BUILD_NUMBER         (예: 1009)
--
-- 규칙
--   설치 빌드 <  min_build     → 강제 안내 (닫을 수 없음)
--   설치 빌드 <  latest_build  → 권장 안내 (나중에 하기 · 하루 1회)
--   그 외                      → 아무것도 뜨지 않는다
--
-- ⚠ 앱의 APP_UPDATE_LIVE 플래그가 true 여야 실제로 뜬다.
--   지금 스토어에 있는 1.01 에는 자기 빌드번호를 알려주는 표식이 없어서,
--   켜면 최신 사용자에게도 뜬다. 표식이 들어간 빌드가 출시된 뒤에 켠다.
--
-- ⚠ min_build 를 함부로 올리지 말 것.
--   강제 안내는 그 버전 이하 회원의 앱을 사실상 잠근다. 보안·결제 사고처럼
--   "구버전을 쓰게 두면 안 되는" 경우에만 올린다. 평소에는 0 으로 둔다.
-- ═══════════════════════════════════════════════════════════════

insert into public.app_config (key, value, updated_at)
values (
  'app_version',
  jsonb_build_object(
    'ios', jsonb_build_object(
      'min_build',    0,          -- 강제 기준 (0 = 강제 안 함)
      'latest_build', 0,          -- ← 새 빌드를 출시할 때마다 이 숫자를 올린다
      'url',          'https://apps.apple.com/kr/app/id6783459650'
    ),
    'android', jsonb_build_object(
      'min_build',    0,
      'latest_build', 0,          -- ← 새 versionCode 를 출시할 때마다 올린다 (예: 1010)
      'url',          'https://play.google.com/store/apps/details?id=com.playtaam.app'
    )
  ),
  now()
)
on conflict (key) do update
  set value = excluded.value,
      updated_at = now();

-- ═══════════════════════════════════════════════════════════════
-- 나중에 숫자만 바꾸고 싶을 때 (전체를 다시 쓰지 않고 한 칸만)
--
--   -- iOS 최신 빌드를 34 로
--   update public.app_config
--      set value = jsonb_set(value, '{ios,latest_build}', '34'::jsonb),
--          updated_at = now()
--    where key = 'app_version';
--
--   -- App Store 주소 바꾸기 (앱 이름이 URL 에 붙어도 id 만 맞으면 열린다)
--   update public.app_config
--      set value = jsonb_set(value, '{ios,url}',
--                            to_jsonb('https://apps.apple.com/kr/app/id6783459650'::text)),
--          updated_at = now()
--    where key = 'app_version';
--
--   -- Android 최신 versionCode 를 1010 으로
--   update public.app_config
--      set value = jsonb_set(value, '{android,latest_build}', '1010'::jsonb),
--          updated_at = now()
--    where key = 'app_version';
--
-- 확인
--   select value from public.app_config where key = 'app_version';
-- ═══════════════════════════════════════════════════════════════
