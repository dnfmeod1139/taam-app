#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# TAAM — 안드로이드 알림 아이콘 주입 (2026-08-28)
# ═══════════════════════════════════════════════════════════════
# 무엇을 하나
#   ① res/drawable-*/ic_stat_taam.png  (흰색 실루엣, 투명 배경) 생성
#   ② AndroidManifest.xml 에 기본 알림 아이콘·색 메타데이터 삽입
#
# 왜 필요한가
#   안드로이드 상태바 알림 아이콘은 '알파 채널만' 쓴다. 색이 있는 앱 아이콘을
#   그대로 쓰면 OS 가 전부 한 덩어리로 뭉개서 회색 원으로 보인다 — 지금 그렇다.
#   무엇에서 온 알림인지 알 수 없고, 알림이 여러 개면 더 심하다.
#   흰 실루엣 아이콘을 따로 넣어야 아이폰처럼 또렷하게 나온다.
#
#   FCM 의 android.notification.color 도 이 아이콘이 있어야 의미가 있다.
#   아이콘 없이 색만 주면 칠할 대상이 없다.
#
# 왜 빌드 때 만드나
#   ios/ · android/ 는 저장소에 없다. cap add 가 매번 새로 만들기 때문에
#   손으로 넣은 리소스는 다음 빌드에서 사라진다. 그래서 스크립트로 넣는다.
#   (scripts/ios_push_appdelegate.py 와 같은 이유·같은 방식)
#
# 실행 위치: cap add/sync 뒤, 빌드 전
# ═══════════════════════════════════════════════════════════════
import os
import re
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("⚠ Pillow 없음 — 알림 아이콘 생성 건너뜀 (알림은 기본 아이콘으로 나온다)")
    sys.exit(0)

RES = "android/app/src/main/res"
MANIFEST = "android/app/src/main/AndroidManifest.xml"

# 상태바 아이콘 규격 — 24dp 기준, 밀도별 배수
DENSITIES = {
    "drawable-mdpi": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}


def draw_icon(size: int) -> Image.Image:
    """TAAM 의 'T' 를 획으로 그린다.

    폰트를 쓰지 않는다 — 빌드 머신마다 있는 폰트가 달라 결과가 흔들린다.
    도형으로 그리면 어디서 빌드해도 같은 그림이 나온다.
    색은 흰색 단색. 안드로이드가 알파만 읽고 나머지는 버린다.
    """
    S = size * 4  # 4배로 그린 뒤 줄여서 가장자리를 부드럽게
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    W = (255, 255, 255, 255)
    pad = S * 0.16          # 상태바 아이콘은 여백이 있어야 답답하지 않다
    bar = S * 0.15          # 획 두께
    top = pad
    left = pad
    right = S - pad
    bottom = S - pad

    # T 의 가로획
    d.rectangle([left, top, right, top + bar], fill=W)
    # T 의 세로획 (가운데)
    cx = S / 2
    d.rectangle([cx - bar / 2, top, cx + bar / 2, bottom], fill=W)

    return img.resize((size, size), Image.LANCZOS)


def write_icons() -> int:
    if not os.path.isdir(RES):
        print(f"⚠ {RES} 없음 — 안드로이드 프로젝트가 아직 없다. 건너뜀")
        return 0
    n = 0
    for folder, size in DENSITIES.items():
        outdir = os.path.join(RES, folder)
        os.makedirs(outdir, exist_ok=True)
        path = os.path.join(outdir, "ic_stat_taam.png")
        draw_icon(size).save(path, "PNG")
        n += 1
    print(f"✅ 알림 아이콘 {n}개 생성 (ic_stat_taam)")
    return n


META = """        <meta-data
            android:name="com.google.firebase.messaging.default_notification_icon"
            android:resource="@drawable/ic_stat_taam" />
        <meta-data
            android:name="com.google.firebase.messaging.default_notification_color"
            android:resource="@color/taam_notif" />
"""

COLORS_XML = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="taam_notif">#5C0A14</color>
</resources>
"""


def patch_manifest() -> bool:
    if not os.path.isfile(MANIFEST):
        print(f"⚠ {MANIFEST} 없음 — 건너뜀")
        return False
    with open(MANIFEST, encoding="utf-8") as f:
        src = f.read()

    if "default_notification_icon" in src:
        print("· AndroidManifest 이미 설정됨 — 건너뜀")
        return True

    # </application> 바로 앞에 넣는다
    m = re.search(r"[ \t]*</application>", src)
    if not m:
        print("⚠ </application> 을 찾지 못했다 — 수동 확인 필요")
        return False
    out = src[: m.start()] + META + src[m.start():]
    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write(out)
    print("✅ AndroidManifest 에 알림 아이콘·색 메타데이터 추가")
    return True


def write_color() -> None:
    vals = os.path.join(RES, "values")
    os.makedirs(vals, exist_ok=True)
    path = os.path.join(vals, "taam_notif_color.xml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(COLORS_XML)
    print("✅ 알림 색상 리소스 생성 (taam_notif = #5C0A14)")


if __name__ == "__main__":
    if write_icons():
        write_color()
        patch_manifest()
    print("── 알림 아이콘 주입 완료 ──")
