#!/usr/bin/env python3
"""分刻 App 图标生成：assets/AppIcon-1024.png → iconset → AppIcon.icns

2026-11-16 起图标与 iOS 端统一为「小刻」形象定稿，源图不再由本脚本生成。

源图出处（唯一可信来源）：
  Countmin-iOS/Countmin/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
  即《小刻品牌形象手册 V1.0》定稿：1024×1024 / RGB / 不透明深紫底，
  iOS 自己裁圆角，所以 macOS 端直接沿用同一张满幅图，不做二次重绘。

改图标的正确姿势：
  1. 先把 iOS 工程里的 AppIcon.png 覆盖到 assets/AppIcon-1024.png
  2. 再跑 python3 make_icon.py（只重出 iconset + icns，不改动源图）
  3. 同步 分刻.app/Contents/Resources/AppIcon.icns，然后跑 deploy.sh 重建

历史：2.6.0 那版「一半人民币 + 一半沙漏」的纯矢量稿留在
  assets/AppIcon-legacy.svg，仅作存档，不参与任何构建。

用法：python3 make_icon.py
"""
import os
import subprocess
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(BASE, "assets")
ICON_1024 = os.path.join(OUT_DIR, "AppIcon-1024.png")
ICONSET = os.path.join(OUT_DIR, "AppIcon.iconset")
ICNS = os.path.join(OUT_DIR, "AppIcon.icns")


# ---------- 1. 校验源图（不生成、不重绘，保证与 iOS 同款） ----------
def check_source():
    from PIL import Image

    if not os.path.exists(ICON_1024):
        sys.exit(f"缺源图 {ICON_1024}；请从 iOS 工程 AppIcon.appiconset/AppIcon.png 复制过来")
    with Image.open(ICON_1024) as im:
        if im.size != (1024, 1024):
            sys.exit(f"源图尺寸异常: {im.size}，应为 1024×1024")
        print(f"源图: {ICON_1024} ({im.size[0]}×{im.size[1]} {im.mode})")


# ---------- 2. PNG → iconset → icns ----------
def build_icns():
    from PIL import Image

    src = Image.open(ICON_1024).convert("RGBA")

    if os.path.isdir(ICONSET):
        subprocess.run(["rm", "-rf", ICONSET], check=True)
    os.makedirs(ICONSET)

    # Apple 标准命名（缺一个 iconutil 会报错）
    pairs = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for name, size in pairs:
        src.resize((size, size), Image.LANCZOS).save(os.path.join(ICONSET, name))

    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)
    print(f"icns 生成: {ICNS} ({os.path.getsize(ICNS)} bytes)")


if __name__ == "__main__":
    check_source()
    build_icns()
    print("完成。下一步：同步 分刻.app/Contents/Resources/AppIcon.icns 并跑 deploy.sh 重建。")
