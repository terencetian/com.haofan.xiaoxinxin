#!/bin/bash
# 小薪薪 构建 + 安装脚本
# 注意：签名必须在 /tmp 里做（workspace 目录下 codesign 的临时文件删除会被安全策略拦截）
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
SRC_APP="小薪薪.app"
STAGE_ROOT="/tmp/xiaoxinxin-build"
STAGE="$STAGE_ROOT/小薪薪.app"
INSTALL="/Applications/小薪薪.app"

echo "[1/7] 准备 staging bundle（/tmp）"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/PlugIns"
cp "$SRC_APP/Contents/Info.plist" "$STAGE/Contents/Info.plist"
cp -R "$SRC_APP/Contents/Resources/." "$STAGE/Contents/Resources/"

echo "[2/7] 编译小组件扩展（入口必须是 -e _NSExtensionMain，和 Xcode 对 appex 的设置一致）"
# appex 的入口必须是 _NSExtensionMain（Xcode 对 appex 也设 LD_ENTRY_POINT=_NSExtensionMain）
# 用 @main 生成的 main 会绕过 NSExtension 宿主上下文，在 _EXRunningExtension 引导阶段 trap
swiftc -O -parse-as-library -sdk "$SDK" -target arm64-apple-macos14.0 \
  -Xlinker -e -Xlinker _NSExtensionMain \
  Widget/SalaryWidget.swift -o "$STAGE/Contents/PlugIns/SalaryWidget.bin"

echo "[3/7] 编译主程序"
osascript -e 'tell application "小薪薪" to quit' >/dev/null 2>&1 || true
sleep 1
swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 \
  main.swift Logic.swift -o "$STAGE/Contents/MacOS/小薪薪"

echo "[4/7] 组装 appex"
AEX="$STAGE/Contents/PlugIns/Salary.appex"
mkdir -p "$AEX/Contents/MacOS"
cp Widget/Salary-Info.plist "$AEX/Contents/Info.plist"
mv "$STAGE/Contents/PlugIns/SalaryWidget.bin" "$AEX/Contents/MacOS/SalaryWidget"

echo "[5/7] 签名（优先用本机自建身份，回退 ad-hoc）"
SIGN_ID="Xiaoxinxin Dev"
security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID" || SIGN_ID="-"
echo "    使用身份：$SIGN_ID"
find "$STAGE" -name ".BC.T_*" -delete 2>/dev/null || true
# 关键：先签 appex（带沙盒 entitlements），再签主 app，且绝不能 --deep
# --deep 重签嵌套代码会把扩展的 entitlements 覆盖掉 → 未沙盒化的扩展系统永不注册
codesign --force --sign "$SIGN_ID" --entitlements Widget/Salary.entitlements "$AEX"
codesign --force --sign "$SIGN_ID" "$STAGE"
echo "    appex entitlements："
codesign -d --entitlements - "$AEX" 2>&1 | grep -E "app-sandbox|temporary-exception" | head -3
codesign -v --verbose=2 "$STAGE" 2>&1 | tail -1

echo "[6/7] 安装到 /Applications（workspace 里的 .app 不再覆盖：安全策略会拦截）"
ditto "$STAGE" "$INSTALL"
# ditto 会在目标内留下 .BC.T_* 临时文件，破坏封装签名，必须清掉并复核
find "$INSTALL" -name ".BC.T_*" -delete 2>/dev/null || true
codesign -v --verbose=2 "$INSTALL" 2>&1 | tail -1
# ditto 会在目标内留下 .BC.T_* 临时文件，破坏封装签名，必须清掉并复核
find "$INSTALL" -name ".BC.T_*" -delete 2>/dev/null || true
codesign -v --verbose=2 "$INSTALL" 2>&1 | tail -1

echo "[7/7] 重新注册扩展并重启 chronod / Dock"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -f "$INSTALL"
pluginkit -a "$INSTALL/Contents/PlugIns/Salary.appex" 2>/dev/null || true
killall chronod 2>/dev/null || true
killall Dock 2>/dev/null || true

echo "完成：open -a $INSTALL"
