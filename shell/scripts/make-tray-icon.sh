#!/bin/bash
# 生成菜单栏（系统托盘）图标。
#
# 用法:
#   bash shell/scripts/make-tray-icon.sh
#
# 产物（都会被 //go:embed 打进 Go 二进制，必须提交进版本库）:
#   shell/tray_template.png   macOS：纯黑 + alpha 的 template 图标，44x44
#   shell/tray_color.png      Windows / Linux：彩色图标，32x32
set -eu

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$REPO_DIR/shell"
TEMPLATE_SRC="$REPO_DIR/static/tray.svg"
COLOR_SRC="$REPO_DIR/static/icon.svg"

command -v rsvg-convert >/dev/null || { echo "需要 rsvg-convert（brew install librsvg）"; exit 1; }
[ -f "$TEMPLATE_SRC" ] || { echo "找不到 SVG: $TEMPLATE_SRC"; exit 1; }
[ -f "$COLOR_SRC" ] || { echo "找不到 SVG: $COLOR_SRC"; exit 1; }

# 1. macOS 菜单栏图标
#
#    macOS 菜单栏图标必须是 template（纯黑 + alpha），系统按深浅色菜单栏自动反色。
#    不能用 static/icon.svg——那个带黄底方块，进菜单栏会成一块刺眼的黄斑。
#    菜单栏高 22pt，@2x 取 44px。static/tray.svg 里字形已调到占画布 ~82%。
rsvg-convert -w 44 -h 44 "$TEMPLATE_SRC" -o "$OUT_DIR/tray_template.png" >/dev/null
echo "==> $OUT_DIR/tray_template.png ($(du -h "$OUT_DIR/tray_template.png" | awk '{print $1}'))"

# 2. Windows / Linux 图标
#    这两个平台没有 template 机制，直接用彩色版。
rsvg-convert -w 32 -h 32 "$COLOR_SRC" -o "$OUT_DIR/tray_color.png" >/dev/null
echo "==> $OUT_DIR/tray_color.png ($(du -h "$OUT_DIR/tray_color.png" | awk '{print $1}'))"
