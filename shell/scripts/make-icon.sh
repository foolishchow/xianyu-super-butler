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

command -v sips >/dev/null || { echo "需要 sips（macOS 自带）"; exit 1; }
command -v iconutil >/dev/null || { echo "需要 iconutil（macOS 自带）"; exit 1; }
[ -f "$SVG" ] || { echo "找不到 SVG: $SVG"; exit 1; }

CANVAS=1024
MARGIN=0.10
# 内容边长 = 画布 * (1 - 2*留白) = 1024 * 0.80。
# 留白取 10% 的依据：实测 Safari AppIcon，256px 档内容占 80.5%、左边距 9.8%。
# macOS 桌面图标不满铺，四周要有透明安全边距。
CONTENT=819
# 圆角半径占内容边长的比例，对应 static/favicon.svg 的 viewBox 100x100 + rx="20"
RADIUS_FRAC=0.20

WORK="$(mktemp -d /tmp/mkicon.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT_DIR"

# 1. SVG -> 内容尺寸的 PNG（满铺，不含安全边距）
#
#    优先 rsvg-convert：它渲染透明背景是正确的。
#    退回 qlmanage：Quick Look 会先把整块画布涂白再画图形，圆角缺口露白，
#    在深色 Dock 里是一条刺眼的白边，必须用 iconfix.py 把四角清成透明。
RAW="$WORK/raw.png"
if command -v rsvg-convert >/dev/null 2>&1; then
	echo "    渲染: rsvg-convert"
	rsvg-convert -w "$CONTENT" -h "$CONTENT" "$SVG" -o "$RAW" >/dev/null
elif command -v qlmanage >/dev/null 2>&1; then
	echo "    渲染: qlmanage"
	qlmanage -t -s "$CONTENT" -o "$WORK" "$SVG" >/dev/null 2>&1
	RAW="$WORK/$(basename "$SVG").png"
	[ -f "$RAW" ] || { echo "qlmanage 转换失败: $SVG"; exit 1; }
else
	echo "找不到 rsvg-convert 或 qlmanage"; exit 1
fi
[ -f "$RAW" ] || { echo "PNG 渲染失败"; exit 1; }

# 2. 清角 + 垫安全边距 -> 最终 1024x1024 底图
BASE="$WORK/base.png"
if "$REPO_DIR/shell/runtime/bin/python" "$REPO_DIR/shell/scripts/iconfix.py" \
	"$RAW" "$BASE" --canvas "$CANVAS" --margin "$MARGIN" --radius "$RADIUS_FRAC" \
	2>/dev/null; then :
else
	python3 "$REPO_DIR/shell/scripts/iconfix.py" \
		"$RAW" "$BASE" --canvas "$CANVAS" --margin "$MARGIN" --radius "$RADIUS_FRAC"
fi

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
  sips -z "${pair%%:*}" "${pair%%:*}" "$BASE" \
    --out "$ICONSET/${pair##*:}" >/dev/null
done

# 3. iconset -> icns
iconutil -c icns "$ICONSET" -o "$OUT_ICNS"

echo "==> 完成: $OUT_ICNS ($(du -h "$OUT_ICNS" | awk '{print $1}'))"
