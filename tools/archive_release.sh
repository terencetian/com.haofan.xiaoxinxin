#!/bin/bash
# 分刻 · Countmin 发布产物归档（原名「小薪薪」，2.7 起改名）
#
# 把当前构建产物复制到 ~/Documents/分刻-发布版本/v<版本>/，
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
BASE="$HOME/Documents/分刻-发布版本"
LEGACY_BASE="$HOME/Documents/小薪薪-发布版本"

# 2.7 改名：老的归档目录一次性挪到新名下，历史版本不散落（只改名，不动内容）
if [ ! -d "$BASE" ] && [ -d "$LEGACY_BASE" ]; then
  mv "$LEGACY_BASE" "$BASE"
  echo "· 发布归档目录已迁移：小薪薪-发布版本 → 分刻-发布版本"
fi

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
for cand in "$ROOT/countmin-v$VER.dmg" "$ROOT/分刻-v$VER.dmg" \
            "$ROOT/xiaoxinxin-v$VER.dmg" "$ROOT/小薪薪-v$VER.dmg" \
            "$ROOT/分刻.dmg" "$ROOT/小薪薪.dmg"; do
  if [ -f "$cand" ]; then DMG="$cand"; break; fi
done
if [ -z "$DMG" ]; then
  echo "✗ 找不到 $VER 的安装包（试过 countmin- / 分刻- / xiaoxinxin- / 小薪薪- 等命名）" >&2
  exit 1
fi

# ---------- 读 dmg 内的版本与 Build，确认不是张冠李戴 ----------
read_plist() {
  local mnt app pl="" ver build
  # hdiutil 输出是按 TAB 分列的，最后一段才是挂载点；用 awk 默认按空白切分会被卷名里的空格切坏
  mnt=$(hdiutil attach "$1" -nobrowse -readonly 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')
  [ -z "$mnt" ] && return 0
  # 新名优先，旧的 2.6 及以前安装包仍能归档
  for app in "分刻.app" "小薪薪.app"; do
    if [ -f "$mnt/$app/Contents/Info.plist" ]; then pl="$mnt/$app/Contents/Info.plist"; break; fi
  done
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
cp -p "$DMG" "$DEST/countmin-v$VER-$PLATFORM.dmg"
echo "✓ 安装包  $DEST/countmin-v$VER-$PLATFORM.dmg"

# 手册：新名优先，旧名兼容
MANUAL=""
for f in "$ROOT/分刻产品手册.pdf" "$ROOT/小薪薪产品手册.pdf"; do
  [ -f "$f" ] && { MANUAL="$f"; break; }
done
MANUAL_LABEL="—"
if [ -n "$MANUAL" ]; then
  cp -p "$MANUAL" "$DEST/分刻产品手册-v$VER.pdf"
  echo "✓ 手册PDF $DEST/分刻产品手册-v$VER.pdf"
  MANUAL_LABEL="PDF"
  HTML=""
  for f in "$ROOT/分刻产品手册.html" "$ROOT/小薪薪产品手册.html"; do
    [ -f "$f" ] && { HTML="$f"; break; }
  done
  if [ "$WITH_HTML" = "1" ] && [ -n "$HTML" ]; then
    cp -p "$HTML" "$DEST/分刻产品手册-v$VER.html"
    echo "✓ 手册HTML $DEST/分刻产品手册-v$VER.html"
    MANUAL_LABEL="PDF + 网页版"
  fi
else
  echo "! 未找到产品手册 PDF，本次只归档安装包"
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
