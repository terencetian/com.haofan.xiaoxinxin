#!/usr/bin/env bash
# 生成双端（macOS + Android）朋友圈海报 1080x1440
# 用法：bash poster/build-dual.sh
#
# 依赖两张素材（不入库，需现场准备）：
#   mac-home.png   ← 小薪薪.app --export-shots <dir> --shot-salary 20000 --shot-worked 133
#   phone-mint.png ← 安卓薄荷主题首页截图（模拟器 adb screencap，裁到 1080x2292）
# 其余（icon.png / qr.png）由本脚本自动准备。
set -euo pipefail
cd "$(dirname "$0")"
ROOT=".."

cp "$ROOT/assets/AppIcon-1024.png" icon.png

python3 - <<'PY'
import qrcode
from qrcode.constants import ERROR_CORRECT_H
url = "https://terencetian.github.io/com.haofan.xiaoxinxin/"
qr = qrcode.QRCode(error_correction=ERROR_CORRECT_H, box_size=20, border=1)
qr.add_data(url); qr.make(fit=True)
qr.make_image(fill_color="#0E2A20", back_color="white").save("qr.png")
PY

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
  --force-device-scale-factor=1 --window-size=1080,1440 \
  --screenshot="小薪薪-双端海报-1080x1440.png" "file://$PWD/poster-dual.html" >/dev/null 2>&1

echo "已生成：小薪薪-双端海报-1080x1440.png"
