#!/usr/bin/env python3
"""小薪薪 App 图标生成：assets/AppIcon.svg (纯矢量) → 1024 PNG → iconset → AppIcon.icns

设计说明：
  - 图形全部由矢量绘制，无第三方素材，不含 IP 角色特征
  - squircle 尺寸 824×824 / 圆角 185，符合 Apple macOS 图标网格 (1024 画布)
  - 视觉上的 Liquid Glass 效果在此烘焙为 PNG；若日后需上架 App Store 用
    Icon Composer 出分层素材，只需保留 svg 的图形层

用法：python3 make_icon.py
"""
import os
import subprocess
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(BASE, "assets", "AppIcon.svg")
OUT_DIR = os.path.join(BASE, "assets")
ICON_1024 = os.path.join(OUT_DIR, "AppIcon-1024.png")
ICONSET = os.path.join(OUT_DIR, "AppIcon.iconset")
ICNS = os.path.join(OUT_DIR, "AppIcon.icns")

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
]


# ---------- 1. SVG → 1024 PNG（Chrome headless，透明背景） ----------
def find_chrome():
    for p in CHROME_CANDIDATES:
        if os.path.exists(p):
            return p
    return None


def render_svg():
    chrome = find_chrome()
    if not chrome:
        if os.path.exists(ICON_1024):
            print(f"未找到 Chrome，沿用已有 {ICON_1024}")
            return
        sys.exit("未找到 Chrome，无法渲染 SVG，且 assets/AppIcon-1024.png 不存在")

    with open(SVG, encoding="utf-8") as f:
        svg = f.read()
    wrap = os.path.join(BASE, "_icon_render.html")
    with open(wrap, "w", encoding="utf-8") as f:
        f.write(
            '<!doctype html><html><head><meta charset="utf-8"><style>'
            "html,body{margin:0;padding:0;background:transparent;overflow:hidden}"
            "svg{display:block;width:1024px;height:1024px}"
            "</style></head><body>" + svg + "</body></html>"
        )
    subprocess.run(
        [
            chrome,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            "--default-background-color=00000000",
            "--window-size=1024,1024",
            f"--screenshot={ICON_1024}",
            f"file://{wrap}",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    os.remove(wrap)
    print(f"渲染完成: {ICON_1024}")


# ---------- 2. PNG → iconset → icns ----------
def build_icns():
    from PIL import Image

    src = Image.open(ICON_1024).convert("RGBA")
    if src.size != (1024, 1024):
        sys.exit(f"渲染尺寸异常: {src.size}，应为 1024×1024")

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
    render_svg()
    build_icns()
    print("完成。下一步：替换 小薪薪.app/Contents/Resources/AppIcon.icns 并重打包 dmg。")
