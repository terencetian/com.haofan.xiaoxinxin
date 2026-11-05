#!/usr/bin/env bash
# 生成朋友圈海报：拉素材 → 生成二维码 → Chrome 无头渲染成 1080x1440
# 用法：bash poster/build.sh
set -euo pipefail
cd "$(dirname "$0")"
ROOT=".."

cp "$ROOT/assets/AppIcon-1024.png" icon.png
cp "$ROOT/screenshots/home.png" home.png

python3 - <<'PY'
import qrcode
from qrcode.constants import ERROR_CORRECT_H

url = "https://github.com/terencetian/com.haofan.xiaoxinxin"
qr = qrcode.QRCode(error_correction=ERROR_CORRECT_H, box_size=16, border=2)
qr.add_data(url)
qr.make(fit=True)
qr.make_image(fill_color="#0a1526", back_color="white").save("qr.png")
PY

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
  --force-device-scale-factor=1 --window-size=1080,1440 \
  --screenshot="小薪薪-朋友圈海报-1080x1440.png" "file://$PWD/poster.html" >/dev/null 2>&1

echo "已生成：小薪薪-朋友圈海报-1080x1440.png"
