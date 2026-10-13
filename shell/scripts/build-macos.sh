#!/bin/bash
# 构建 macOS .app 包。
#
# 用法:
#   bash shell/scripts/build-macos.sh                        # 只打壳
#   bash shell/scripts/build-macos.sh runtime/               # 壳 + 后端
#   bash shell/scripts/build-macos.sh runtime/ AppIcon.icns  # 壳 + 后端 + 图标
#
# 产物: shell/out/闲鱼智控.app
#
# 注意: 编译必须发生在拼装 bundle 之前，否则后面的 rm -rf 会把二进制删掉。
set -eu

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$SHELL_DIR/.." && pwd)"
RUNTIME_SRC="${1:-}"
ICON_SRC="${2:-}"

APP_NAME="闲鱼智控"
OUT_DIR="$SHELL_DIR/out"
APP_DIR="$OUT_DIR/${APP_NAME}.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
BIN_NAME="shell"

# 允许相对路径（相对仓库根）或绝对路径
resolve() {
	if [ "${1#/}" != "$1" ]; then printf '%s' "$1"; else printf '%s/%s' "$REPO_DIR" "$1"; fi
}
RUNTIME_ABS="$(resolve "$RUNTIME_SRC")"
ICON_ABS="$(resolve "$ICON_SRC")"

cd "$SHELL_DIR"

echo "==> 1/5 编译 Go 壳"
mkdir -p "$OUT_DIR"
go build -o "$OUT_DIR/$BIN_NAME" . 2>&1 | grep -v "^ld: warning" || true
[ -x "$OUT_DIR/$BIN_NAME" ] || { echo "编译失败"; exit 1; }

echo "==> 2/5 拼装 bundle 结构"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
mv "$OUT_DIR/$BIN_NAME" "$MACOS_DIR/$BIN_NAME"

echo "==> 3/5 写入 Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>闲鱼智控</string>
	<key>CFBundleDisplayName</key>
	<string>闲鱼智控</string>
	<key>CFBundleIdentifier</key>
	<string>com.xianyu.butler</string>
	<key>CFBundleExecutable</key>
	<string>shell</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>仅在 127.0.0.1 本地回环地址上启动后端服务。</string>
</dict>
</plist>
PLIST

echo "==> 4/5 放入后端与图标"
if [ -n "$RUNTIME_SRC" ]; then
	if [ ! -f "$RUNTIME_ABS/Start.py" ]; then
		echo "    警告: $RUNTIME_SRC 里找不到 Start.py，跳过后端"
	else
		echo "    拷贝后端 (可能较慢)..."
		rsync -a --exclude='__pycache__' --exclude='*.pyc' \
			"$RUNTIME_ABS/" "$RES_DIR/runtime/"
	fi
fi

if [ -z "$ICON_SRC" ]; then
	echo "    未提供图标，尝试从 static/favicon.svg 自动生成..."
	if bash "$SHELL_DIR/scripts/make-icon.sh" >/dev/null 2>&1; then
		ICON_ABS="$SHELL_DIR/out/AppIcon.icns"
	fi
fi
if [ -n "${ICON_ABS:-}" ] && [ -f "$ICON_ABS" ]; then
	cp "$ICON_ABS" "$RES_DIR/AppIcon.icns"
	echo "    已放入 AppIcon.icns ($(du -h "$RES_DIR/AppIcon.icns" | awk '{print $1}'))"
else
	echo "    (无图标，Finder 会显示通用图标；用 scripts/make-icon.sh 生成)"
fi

echo "==> 5/5 代码签名（ad-hoc）"
codesign --force --deep --sign - "$APP_DIR" 2>&1 | tail -2 || \
	echo "    签名失败（不影响本地运行，但 Gatekeeper 会更严格拦截）"

echo
echo "==> 完成"
du -sh "$APP_DIR"
echo "    运行: open \"$APP_DIR\""
