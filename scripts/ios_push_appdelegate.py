#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# AppDelegate 에 APNs 콜백을 넣는다 — iOS 푸시가 동작하기 위한 필수 조건
#
# 왜 필요한가
#   @capacitor/push-notifications 는 iOS 가 발급한 APNs 토큰을 직접 받지 않는다.
#   AppDelegate 가 받아서 NotificationCenter 로 넘겨줘야 플러그인이 집어간다.
#   그런데 Capacitor 가 만드는 기본 AppDelegate 템플릿에는 그 두 메서드가 없다 —
#   플러그인 문서가 "직접 추가하라" 고 안내하는 부분이다.
#
# 없으면 어떻게 되나 (2026-08-26 에 실제로 겪은 증상)
#   register() 는 성공한다. iOS 도 토큰을 만들어 AppDelegate 를 부른다.
#   그런데 AppDelegate 가 아무 데도 전달하지 않으니 JS 는 토큰도 오류도 못 받는다.
#   권한 granted · 플러그인 정상 · entitlement 정상인데 영원히 침묵한다.
#   어디를 봐도 멀쩡해서, 화면만 보고는 원인을 찾을 수 없는 상태가 된다.
#
# ios/ 는 저장소에 두지 않고 빌드마다 `cap add ios` 로 새로 만들기 때문에,
# 매 빌드에서 이 스크립트가 다시 넣어줘야 한다.
#
# 사용: python3 scripts/ios_push_appdelegate.py
#   성공 시 0, 실패 시 1 (빌드를 세운다 — 조용히 빠지면 또 같은 일이 반복된다)
# ═══════════════════════════════════════════════════════════════
import sys
import os

PATH = 'ios/App/App/AppDelegate.swift'

METHODS = '''
    // ── APNs 콜백 → Capacitor 전달 (@capacitor/push-notifications 필수) ──
    //   이 두 메서드가 없으면 register() 는 성공하는데 토큰도 오류도 JS 로 오지 않는다.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(
            name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(
            name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }
'''

MARKER = 'didRegisterForRemoteNotificationsWithDeviceToken'

# ── 앱을 열면 아이콘 배지(빨간 숫자)를 지운다 ────────────────────────────
#   서버는 알림마다 badge:1 을 보낸다. 그런데 그 값을 0 으로 되돌리는 쪽이
#   아무 데도 없어서, 알림을 다 읽어도 홈 화면 아이콘의 「1」이 영영 남았다.
#   배지는 알림센터와 별개라 알림을 지워도 사라지지 않는다 — 앱이 직접 꺼야 한다.
BADGE_MARKER = 'TAAM_BADGE_CLEAR'
BADGE_BODY = '''
        // ── TAAM_BADGE_CLEAR — 앱을 열면 아이콘 배지를 지운다 ──
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
'''

BADGE_METHOD = '''
    // ── TAAM_BADGE_CLEAR — 앱을 열면 아이콘 배지를 지운다 ──
    func applicationDidBecomeActive(_ application: UIApplication) {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
'''


def _ensure_import(src):
    """UNUserNotificationCenter 를 쓰려면 UserNotifications 가 import 돼 있어야 한다."""
    if 'import UserNotifications' in src:
        return src
    lines = src.split('\n')
    last = -1
    for i, ln in enumerate(lines):
        if ln.strip().startswith('import '):
            last = i
    if last < 0:
        return 'import UserNotifications\n' + src
    lines.insert(last + 1, 'import UserNotifications')
    return '\n'.join(lines)


def _inject_badge_clear(src):
    """이미 있는 applicationDidBecomeActive 안에 넣고, 없으면 메서드째 추가한다.

    같은 메서드를 하나 더 선언하면 컴파일이 깨진다 — Capacitor 기본 템플릿은
    이 메서드를 이미 가지고 있으므로, 반드시 '안에' 넣어야 한다.
    """
    if BADGE_MARKER in src:
        print('ℹ️  배지 초기화: 이미 있음 — 건너뜁니다')
        return src

    src = _ensure_import(src)

    key = 'func applicationDidBecomeActive'
    at = src.find(key)
    if at >= 0:
        brace = src.find('{', at)
        if brace < 0:
            print('❌ applicationDidBecomeActive 의 여는 괄호를 찾지 못했습니다')
            return None
        print('✅ 배지 초기화 주입 (기존 applicationDidBecomeActive 안)')
        return src[:brace + 1] + BADGE_BODY + src[brace + 1:]

    idx = src.rstrip().rfind('}')
    if idx < 0:
        print('❌ AppDelegate.swift 에서 닫는 괄호를 찾지 못했습니다')
        return None
    print('✅ 배지 초기화 주입 (메서드 신규 추가)')
    return src[:idx] + BADGE_METHOD + src[idx:]


def main():
    if not os.path.exists(PATH):
        print('❌ %s 없음 — cap add ios 가 먼저 실행돼야 합니다' % PATH)
        return 1

    src = open(PATH, encoding='utf-8').read()

    if MARKER in src:
        # 템플릿이 이미 포함하고 있다면 그대로 둔다 (중복 선언은 컴파일 오류다)
        print('ℹ️  APNs 콜백: 이미 있음 — 템플릿이 포함하고 있어 건너뜁니다')
    else:
        idx = src.rstrip().rfind('}')          # 클래스를 닫는 마지막 괄호
        if idx < 0:
            print('❌ AppDelegate.swift 에서 닫는 괄호를 찾지 못했습니다')
            return 1
        src = src[:idx] + METHODS + src[idx:]
        print('✅ APNs 콜백 주입 완료')

    src = _inject_badge_clear(src)
    if src is None:
        return 1

    open(PATH, 'w', encoding='utf-8').write(src)

    # 결과를 눈으로 확인할 수 있게 남긴다 — 선언이 아니라 결과를 봐야 한다
    out = open(PATH, encoding='utf-8').read()
    print('==== AppDelegate.swift ====')
    print(out)
    print('==== 판정 ====')
    ok = True
    if 'capacitorDidRegisterForRemoteNotifications' in out:
        print('✅ APNs 콜백 있음 — 토큰이 JS 까지 전달된다')
    else:
        print('❌ APNs 콜백 없음 — 이 빌드로는 토큰이 JS 로 오지 않는다')
        ok = False
    if BADGE_MARKER in out and 'import UserNotifications' in out:
        print('✅ 배지 초기화 있음 — 앱을 열면 아이콘의 빨간 숫자가 사라진다')
    else:
        print('❌ 배지 초기화 없음 — 아이콘 배지가 계속 남는다')
        ok = False
    # 같은 메서드가 두 번 선언되면 컴파일이 깨진다 — 여기서 잡는다
    if out.count('func applicationDidBecomeActive') > 1:
        print('❌ applicationDidBecomeActive 가 두 번 선언됨 — 컴파일 실패한다')
        ok = False
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
