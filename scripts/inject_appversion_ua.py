#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# capacitor.config.json 의 appendUserAgent 에 이 빌드의 버전을 새긴다
#
# 왜 필요한가
#   server.url 이 원격(taam-app.vercel.app)이라, 앱이 띄우는 화면은 항상 최신 웹이다.
#   그래서 JS 는 "지금 나를 감싸고 있는 네이티브 껍데기가 몇 번 빌드인지" 를 알 방법이
#   없다. 그런데 푸시·플러그인·권한은 껍데기가 바뀌어야 바뀐다 — 구버전에 갇힌 회원에게
#   업데이트를 안내하려면 이 숫자가 반드시 필요하다.
#
#   Capacitor 는 appendUserAgent 문자열을 WebView User-Agent 뒤에 붙여준다.
#   플러그인을 새로 추가하지 않고도 navigator.userAgent 한 줄로 읽힌다.
#
#   앱의 _appNativeBuild() 가 이 형식을 읽는다:  TAAM/<표시버전>(<빌드번호>)
#
# ⚠ cap add / cap sync 보다 먼저 실행돼야 한다 — 그때 네이티브 프로젝트로 복사된다.
#
# 사용: APP_UA_VER=1.02 APP_UA_BUILD=34 python3 scripts/inject_appversion_ua.py
#   성공 0 / 실패 1 (조용히 빠지면 업데이트 안내가 영영 동작하지 않는다)
# ═══════════════════════════════════════════════════════════════
import json
import os
import sys

PATH = 'capacitor.config.json'


def main():
    ver = (os.environ.get('APP_UA_VER') or '').strip()
    build = (os.environ.get('APP_UA_BUILD') or '').strip()
    if not ver or not build:
        print('❌ APP_UA_VER / APP_UA_BUILD 환경변수가 필요합니다 (ver=%r build=%r)' % (ver, build))
        return 1
    if not os.path.exists(PATH):
        print('❌ %s 없음' % PATH)
        return 1

    with open(PATH, encoding='utf-8') as f:
        cfg = json.load(f)

    marker = 'TAAM/%s(%s)' % (ver, build)
    cfg['appendUserAgent'] = marker

    with open(PATH, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write('\n')

    print('✅ appendUserAgent = %s' % marker)

    # 결과를 눈으로 확인 — 선언이 아니라 결과를 본다
    with open(PATH, encoding='utf-8') as f:
        out = json.load(f)
    if out.get('appendUserAgent') == marker:
        print('✅ 확인됨 — 앱이 자기 빌드번호를 알 수 있다')
        return 0
    print('❌ 기록되지 않았다')
    return 1


if __name__ == '__main__':
    sys.exit(main())
