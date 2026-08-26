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


def main():
    if not os.path.exists(PATH):
        print('❌ %s 없음 — cap add ios 가 먼저 실행돼야 합니다' % PATH)
        return 1

    src = open(PATH, encoding='utf-8').read()

    if MARKER in src:
        # 템플릿이 이미 포함하고 있다면 그대로 둔다 (중복 선언은 컴파일 오류다)
        print('ℹ️  이미 있음 — 템플릿이 포함하고 있어 건너뜁니다')
    else:
        idx = src.rstrip().rfind('}')          # 클래스를 닫는 마지막 괄호
        if idx < 0:
            print('❌ AppDelegate.swift 에서 닫는 괄호를 찾지 못했습니다')
            return 1
        open(PATH, 'w', encoding='utf-8').write(src[:idx] + METHODS + src[idx:])
        print('✅ APNs 콜백 주입 완료')

    # 결과를 눈으로 확인할 수 있게 남긴다 — 선언이 아니라 결과를 봐야 한다
    out = open(PATH, encoding='utf-8').read()
    print('==== AppDelegate.swift ====')
    print(out)
    print('==== 판정 ====')
    if 'capacitorDidRegisterForRemoteNotifications' in out:
        print('✅ APNs 콜백 있음 — 토큰이 JS 까지 전달된다')
        return 0
    print('❌ APNs 콜백 없음 — 이 빌드로는 토큰이 JS 로 오지 않는다')
    return 1


if __name__ == '__main__':
    sys.exit(main())
