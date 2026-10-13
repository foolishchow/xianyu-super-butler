#!/bin/bash
# 从 SVG 生成 macOS AppIcon.icns。
#
# 用法:
#   bash shell/scripts/make-icon.sh                     # 默认用 static/favicon.svg
#   bash shell/scripts/make-icon.sh path/to/logo.svg
#
# 产物: shell/out/AppIcon.icns
set -eu

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SVG="${1:-$REPO_DIR/static/favicon.svg}"
OUT_DIR="$REPO_DIR/shell/out"
OUT_ICNS="$OUT_DIR/AppIcon.icns"

command -v qlmanage >/dev/null || { echo "需要 qlmanage（macOS 自带）"; exit 1; }
command -v iconutil  >/dev/null || { echo "需要 iconutil（macOS 自带）";  exit 1; }
[ -f "$SVG" ] || { echo "找不到 SVG: $SVG"; exit 1; }

WORK="$(mktemp -d /tmp/mkicon.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT_DIR"

# 1. SVG -> 1024x1024 PNG
#    qlmanage 会输出 <文件名>.png，即 favicon.svg.png
qlmanage -t -s 1024 -o "$WORK" "$SVG" >/dev/null 2>&1
BASENAME="$(basename "$SVG").png"
[ -f "$WORK/$BASENAME" ] || { echo "qlmanage 转换失败: $SVG"; exit 1; }

# 2. 生成标准 10 档 iconset
#
#    ⚠️ 目录名必须以 .iconset 结尾，否则 iconutil 报 "Invalid Iconset."。
#    这个报错信息完全没提目录名，排查了很久。icon_64x64.png 这类非标准条目
#    也不要放进来。
ICONSET="$WORK/App.iconset"
mkdir "$ICONSET"
for pair in \
  "16:icon_16x16.png" \
  "32:icon_16x16@2x.png" \
  "32:icon_32x32.png" \
  "64:icon_32x32@2x.png" \
  "128:icon_128x128.png" \
  "256:icon_128x128@2x.png" \
  "256:icon_256x256.png" \
  "512:icon_256x256@2x.png" \
  "512:icon_512x512.png" \
  "1024:icon_512x512@2x.png"
do
  sips -z "${pair%%:*}" "${pair%%:*}" "$WORK/$BASENAME" \
    --out "$ICONSET/${pair##*:}" >/dev/null
done

# 3. iconset -> icns
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"

echo "==> 完成: $OUT_ICNS ($(du -h "$OUT_ICNS" | awk '{print $1}'))"
