#!/bin/bash
# 小薪薪 · 发布产物归档
#
# 把当前构建产物复制到 ~/Documents/小薪薪-发布版本/v<版本>/，
# 按「安装包 + 手册」成套存放，并在版本索引.md 末尾追加归档记录。
#
# 用法：
#   ./tools/archive_release.sh <版本号> [平台-架构] [选项]
#
#   ./tools/archive_release.sh 1.9.3                # 默认 macOS-arm64
#   ./tools/archive_release.sh 2.0.0 macos-x86_64   # Intel 构建
#   ./tools/archive_release.sh 1.9.3 macos-arm64 --no-html   # 不归档网页版手册
#
# 说明：只复制，不移动、不删除源文件；同名文件会被覆盖（同一版本重复归档是幂等的）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$HOME/Documents/小薪薪-发布版本"

VER="${1:-}"
shift || true
if [ -z "$VER" ]; then
  echo "用法: $0 <版本号> [平台-架构，默认 macos-arm64] [--no-html]" >&2
  exit 1
fi

PLATFORM="macos-arm64"
WITH_HTML=1
for arg in "$@"; do
  case "$arg" in
    --no-html) WITH_HTML=0 ;;
    --*) echo "未知选项: $arg" >&2; exit 1 ;;
    *) PLATFORM="$arg" ;;
  esac
done

DEST="$BASE/v$VER"
mkdir -p "$DEST"

# ---------- 找安装包 ----------
DMG=""
for cand in "$ROOT/xiaoxinxin-v$VER.dmg" "$ROOT/小薪薪-v$VER.dmg" "$ROOT/小薪薪.dmg"; do
  if [ -f "$cand" ]; then DMG="$cand"; break; fi
done
if [ -z "$DMG" ]; then
  echo "✗ 找不到 $VER 的安装包（试过 xiaoxinxin-v$VER.dmg / 小薪薪-v$VER.dmg / 小薪薪.dmg）" >&2
  exit 1
fi

# ---------- 读 dmg 内的版本与 Build，确认不是张冠李戴 ----------
read_plist() {
  local mnt ver build
  mnt=$(hdiutil attach "$1" -nobrowse -readonly 2>/dev/null | tail -1 | awk '{print $NF}')
  [ -z "$mnt" ] && return 0
  local pl="$mnt/小薪薪.app/Contents/Info.plist"
  if [ -f "$pl" ]; then
    ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$pl" 2>/dev/null || true)
    build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$pl" 2>/dev/null || true)
  fi
  hdiutil detach "$mnt" -quiet 2>/dev/null || true
  echo "${ver:-?} ${build:-?}"
}

read -r DMG_VER DMG_BUILD <<< "$(read_plist "$DMG")"
if [ "$DMG_VER" != "$VER" ]; then
  echo "✗ 安装包内版本是 ${DMG_VER}，与参数 $VER 不符，已中止" >&2
  exit 1
fi

# ---------- 复制 ----------
cp -p "$DMG" "$DEST/小薪薪-v$VER-$PLATFORM.dmg"
echo "✓ 安装包  $DEST/小薪薪-v$VER-$PLATFORM.dmg"

MANUAL_LABEL="—"
if [ -f "$ROOT/小薪薪产品手册.pdf" ]; then
  cp -p "$ROOT/小薪薪产品手册.pdf" "$DEST/小薪薪产品手册-v$VER.pdf"
  echo "✓ 手册PDF $DEST/小薪薪产品手册-v$VER.pdf"
  MANUAL_LABEL="PDF"
  if [ "$WITH_HTML" = "1" ] && [ -f "$ROOT/小薪薪产品手册.html" ]; then
    cp -p "$ROOT/小薪薪产品手册.html" "$DEST/小薪薪产品手册-v$VER.html"
    echo "✓ 手册HTML $DEST/小薪薪产品手册-v$VER.html"
    MANUAL_LABEL="PDF + 网页版"
  fi
else
  echo "! 未找到 小薪薪产品手册.pdf，本次只归档安装包"
fi

# ---------- 校验和 ----------
echo
echo "sha256："
( cd "$DEST" && shasum -a 256 * 2>/dev/null | sed 's/^/  /' )

# ---------- 更新索引 ----------
INDEX="$BASE/版本索引.md"
if [ -f "$INDEX" ]; then
  if grep -q "^| v$VER " "$INDEX"; then
    echo
    echo "· 索引里已有 v${VER}，未重复追加"
  else
    case "$PLATFORM" in
      macos-*) PLAT_LABEL="macOS / ${PLATFORM#macos-}" ;;
      *)       PLAT_LABEL="$PLATFORM" ;;
    esac
    ROW="| v${VER} | ${DMG_BUILD} | ${PLAT_LABEL} | $(date +%Y-%m-%d) | v${VER} | ${MANUAL_LABEL} | 归档于 $(date +%H:%M) |"
    printf '%s\n' "$ROW" >> "$INDEX"
    echo
    echo "· 已追加索引行：$ROW"
  fi
fi

echo
echo "归档完成：$DEST"
