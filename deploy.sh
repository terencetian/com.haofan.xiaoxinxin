#!/bin/bash
# 分刻 · Countmin 构建 + 安装脚本（原名「小薪薪」，2.7 起改名）
# 注意：签名必须在 /tmp 里做（workspace 目录下 codesign 的临时文件删除会被安全策略拦截）
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
APP_NAME="分刻"
SRC_APP="$APP_NAME.app"
STAGE_ROOT="/tmp/xiaoxinxin-build"
STAGE="$STAGE_ROOT/$APP_NAME.app"
INSTALL="/Applications/$APP_NAME.app"
LEGACY_INSTALL="/Applications/小薪薪.app"
BUNDLE_ID="com.haofan.xiaoxinxin"

# 资源来源 bundle 随改名换目录，旧的 workspace 目录自动迁一次（内容不变）
if [ ! -d "$SRC_APP" ] && [ -d "小薪薪.app" ]; then
  mv "小薪薪.app" "$SRC_APP"
  echo "    已将 workspace 里的 小薪薪.app 迁为 $SRC_APP"
fi

# 本机进程 pid（两种匹配都试，pgrep -x 对中文进程名未必生效；旧名也算，避免残留进程抢占）
app_pids() {
  { pgrep -x "$APP_NAME" 2>/dev/null
    pgrep -f "$INSTALL/Contents/MacOS/$APP_NAME" 2>/dev/null
    pgrep -x "小薪薪" 2>/dev/null
  } | sort -u
}

# 确保旧进程真的退出：AppleScript → SIGTERM → SIGKILL
# 不能只依赖 osascript：本机 TCC 会拒（-10004），静默失败后仍跑旧二进制，
# 表现为「装完版本号变了、行为没变、快照没有新字段」，极难排查。
stop_app() {
  if [ -z "$(app_pids)" ]; then
    echo "    旧进程未运行"
    return 0
  fi
  # 先按 bundle id 找（改名前后都能命中），再退回显示名
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  osascript -e 'tell application "小薪薪" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    [ -z "$(app_pids)" ] && { echo "    旧进程已正常退出"; return 0; }
    sleep 0.5
  done
  echo "    osascript 退出未生效（TCC 常拒），改用 SIGTERM"
  pkill -TERM -x "$APP_NAME" 2>/dev/null || true
  pkill -TERM -x "小薪薪" 2>/dev/null || true
  for _ in $(seq 1 20); do
    [ -z "$(app_pids)" ] && { echo "    旧进程已终止（SIGTERM）"; return 0; }
    sleep 0.5
  done
  echo "    SIGTERM 无效，改用 SIGKILL"
  pkill -KILL -x "$APP_NAME" 2>/dev/null || true
  pkill -KILL -x "小薪薪" 2>/dev/null || true
  for _ in $(seq 1 10); do
    [ -z "$(app_pids)" ] && { echo "    旧进程已终止（SIGKILL）"; return 0; }
    sleep 0.5
  done
  echo "    ✗ 旧进程仍在运行（pid: $(app_pids | tr '\n' ' ')），中止安装"
  return 1
}

# 安装前记下在跑的 pid，安装后用来确认「起来的是新进程」而不是残留旧进程
PRE_PIDS=$(app_pids)

echo "[1/8] 准备 staging bundle（/tmp）"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/PlugIns"
# 版本号以仓库里的 AppInfo.plist 为准（*.app/ 被 gitignore，改在 bundle 里下次就找不到了）
[ -f AppInfo.plist ] || { echo "✗ 缺 AppInfo.plist（版本号源）"; exit 1; }
cp AppInfo.plist "$STAGE/Contents/Info.plist"
cp AppInfo.plist "$SRC_APP/Contents/Info.plist"   # 同步回 bundle，两者不打架
cp -R "$SRC_APP/Contents/Resources/." "$STAGE/Contents/Resources/"

echo "[2/8] 编译小组件扩展（入口必须是 -e _NSExtensionMain，和 Xcode 对 appex 的设置一致）"
# appex 的入口必须是 _NSExtensionMain（Xcode 对 appex 也设 LD_ENTRY_POINT=_NSExtensionMain）
# 用 @main 生成的 main 会绕过 NSExtension 宿主上下文，在 _EXRunningExtension 引导阶段 trap
swiftc -O -parse-as-library -sdk "$SDK" -target arm64-apple-macos14.0 \
  -Xfrontend -disable-sandbox \
  -Xlinker -e -Xlinker _NSExtensionMain \
  Widget/SalaryWidget.swift -o "$STAGE/Contents/PlugIns/SalaryWidget.bin"

echo "[3/8] 编译主程序前先停掉旧进程（否则编完也是旧二进制在跑）"
stop_app
swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 \
  -Xfrontend -disable-sandbox \
  main.swift Logic.swift -o "$STAGE/Contents/MacOS/$APP_NAME"

echo "[4/8] 组装 appex"
AEX="$STAGE/Contents/PlugIns/Salary.appex"
mkdir -p "$AEX/Contents/MacOS"
cp Widget/Salary-Info.plist "$AEX/Contents/Info.plist"
mv "$STAGE/Contents/PlugIns/SalaryWidget.bin" "$AEX/Contents/MacOS/SalaryWidget"

echo "[5/8] 签名（优先用本机自建身份，回退 ad-hoc）"
SIGN_ID="Xiaoxinxin Dev"
security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID" || SIGN_ID="-"
echo "    使用身份：$SIGN_ID"
find "$STAGE" \( -name ".BC.T_*" -o -name "*.cstemp" \) -delete 2>/dev/null || true
# 关键：先签 appex（带沙盒 entitlements），再签主 app，且绝不能 --deep
# --deep 重签嵌套代码会把扩展的 entitlements 覆盖掉 → 未沙盒化的扩展系统永不注册
codesign --force --sign "$SIGN_ID" --entitlements Widget/Salary.entitlements "$AEX"
# codesign 偶发留下 *.cstemp 临时二进制，不清掉会破坏封装签名（codesign -v 报 sealed resource is missing）
find "$AEX" -name "*.cstemp" -delete 2>/dev/null || true
codesign --force --sign "$SIGN_ID" "$STAGE"
echo "    appex entitlements："
codesign -d --entitlements - "$AEX" 2>&1 | grep -E "app-sandbox|temporary-exception" | head -3
# 严格校验：appex 必须单独通过，主 app 也要通过（不带 --deep，--deep 会连带验嵌套组件）
codesign -v --strict "$AEX" || { echo "✗ appex 签名校验失败，中止"; exit 1; }
codesign -v --strict "$STAGE" || { echo "✗ 主 app 签名校验失败，中止"; exit 1; }

echo "[6/8] 安装到 /Applications（workspace 里的 .app 不再覆盖：安全策略会拦截）"
# 编译耗时期间用户可能又把旧版打开了，覆盖前再确认一次
stop_app
ditto "$STAGE" "$INSTALL"
# ditto 会在目标内留下 .BC.T_* 临时文件，破坏封装签名，必须清掉并复核
find "$INSTALL" \( -name ".BC.T_*" -o -name "*.cstemp" \) -delete 2>/dev/null || true
codesign -v --strict "$INSTALL/Contents/PlugIns/Salary.appex" || { echo "✗ 安装后 appex 校验失败，中止"; exit 1; }
codesign -v --strict "$INSTALL" || { echo "✗ 安装后主 app 校验失败，中止"; exit 1; }
echo "    签名校验：appex ✓ 主 app ✓"

# 2.7 改名：旧名的安装包留着会和新的抢同一个 bundle id（Dock 里两个图标、启动项指向旧路径）。
# 新版校验通过后才动它，且只移到废纸篓，不直接删——万一要回滚还能捞回来。
if [ -d "$LEGACY_INSTALL" ]; then
  mkdir -p "$HOME/.Trash"
  DEST="$HOME/.Trash/小薪薪.app.$(date +%Y%m%d-%H%M%S)"
  if mv "$LEGACY_INSTALL" "$DEST" 2>/dev/null; then
    echo "    旧名安装包已移到废纸篓：$DEST"
  else
    echo "    ⚠ 旧名安装包挪不动，请手动删除 $LEGACY_INSTALL"
  fi
fi

echo "[7/8] 重新注册扩展并重启 chronod / Dock"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -f "$INSTALL"
pluginkit -a "$INSTALL/Contents/PlugIns/Salary.appex" 2>/dev/null || true
killall chronod 2>/dev/null || true
killall Dock 2>/dev/null || true

echo "[8/8] 启动新版本并校验"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALL/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALL/Contents/Info.plist")
EXT_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALL/Contents/PlugIns/Salary.appex/Contents/Info.plist")
EXT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALL/Contents/PlugIns/Salary.appex/Contents/Info.plist")
if [ "$VER" != "$EXT_VER" ] || [ "$BUILD" != "$EXT_BUILD" ]; then
  echo "    ✗ 主 App（$VER/$BUILD）与扩展（$EXT_VER/$EXT_BUILD）版本不同步"
  exit 1
fi
[ -d "$INSTALL/Contents/PlugIns/Salary.appex" ] || { echo "    ✗ 扩展没装上"; exit 1; }

open -a "$INSTALL"
RUN_PID=""
for _ in $(seq 1 20); do
  RUN_PID=$(app_pids | head -1)
  [ -n "$RUN_PID" ] && break
  sleep 0.5
done
[ -n "$RUN_PID" ] || { echo "    ✗ 新版没启动起来"; exit 1; }
# pid 与安装前不同才算真正换过进程（ps 在部分环境被 TCC 挡，只能靠 pid 判）
if [ -n "$PRE_PIDS" ] && printf '%s\n' "$PRE_PIDS" | grep -qx "$RUN_PID"; then
  echo "    ✗ 还是安装前那个进程（pid $RUN_PID），未真正重启"
  exit 1
fi
AGE=$(ps -o etimes= -p "$RUN_PID" 2>/dev/null | tr -d ' ')
if [ -n "$AGE" ] && [ "$AGE" -gt 120 ]; then
  echo "    ✗ 进程已运行 ${AGE}s，仍是旧进程（未替换成功）"
  exit 1
fi
echo "    ✓ $VER ($BUILD)，pid $RUN_PID${AGE:+，已运行 ${AGE}s}"

echo "完成：$INSTALL 已是 $VER ($BUILD) 并已启动"
