#!/bin/bash
# 生成 Windows 应用图标。
#
# 用法:
#   bash shell/scripts/make-windows-icon.sh
#
# 产物（都是 //go:embed / 链接期的构建输入，必须提交进版本库）:
#   shell/app.ico                   多尺寸 ICO（16~256），喂给两边：
#   shell/rsrc_windows_amd64.syso   PE 资源段 → 资源管理器文件图标、属性对话框
#
# 为什么需要这两份，而不是一份？
#
#   Wails v3 beta.28 取窗口图标的顺序（pkg/application/webview_window_windows.go:620）：
#     1. 先 LoadIcon 找 PE 资源 ID 3  —— 注意是写死的 3
#     2. 找不到才回退 application.Options.Icon
#
#   rsrc 生成的 RT_GROUP_ICON 资源 ID 固定是 1（rsrc.go 里 newid() 从 0 递增），
#   对不上 3。所以 syso 只能覆盖资源管理器那条路径，任务栏/窗口图标必须靠
#   Options.Icon 兜住。两份都要，缺一个都有半边的图标还是通用默认。
#
#   资源 ID 3 不是约定，是 Wails 自己的实现细节 —— beta.28 里没有公开的
#   SetWindowIcon() API（只存在 pkg/w32/icon.go 里，外部包 import 不到）。
#   升级 Wails 后这一条要重新验证。

set -eu

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$REPO_DIR/shell"
SRC="$REPO_DIR/static/favicon.svg"

command -v rsvg-convert >/dev/null || { echo "需要 rsvg-convert（brew install librsvg）"; exit 1; }
command -v go >/dev/null || { echo "需要 go"; exit 1; }
[ -f "$SRC" ] || { echo "找不到 SVG: $SRC"; exit 1; }

# Pillow 在项目依赖里，优先用仓库 venv（CI 和本地都保证有）。
if [ -x "$REPO_DIR/venv/bin/python" ]; then
	PYTHON="$REPO_DIR/venv/bin/python"
elif command -v python3 >/dev/null; then
	PYTHON=python3
else
	echo "找不到 python"; exit 1
fi
"$PYTHON" -c 'import PIL' 2>/dev/null || { echo "需要 Pillow（pip install -r requirements.txt）"; exit 1; }

TMPDIR256="$(mktemp -d)"
trap 'rm -rf "$TMPDIR256"' EXIT

# 1. SVG → 256x256 PNG（ICO 的母版）
#    用 favicon.svg（100x100 满铺），不用 icon.svg（那个 12.5px 内边距是给菜单栏剪影用的）。
#    和 build-macos.sh 生成 AppIcon.icns 用的是同一份源，两个平台图标一致。
rsvg-convert -w 256 -h 256 "$SRC" -o "$TMPDIR256/src256.png" >/dev/null

# 2. 多尺寸 PNG → ICO
#    Windows 任务栏按 DPI 请求不同尺寸，单尺寸会被缩放发虚。
#    256 这一档 Pillow 会写成 PNG 压缩条目（Vista+ 支持），Win10/11 没问题。
"$PYTHON" - "$TMPDIR256/src256.png" "$OUT_DIR/app.ico" <<'PY'
import sys
from PIL import Image

src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
im.save(out, format="ICO", sizes=sizes)
print(f"    尺寸: {sizes}")
PY

# 3. ICO → syso（PE 资源段，链接期自动打进 exe）
#    命名带 _windows_amd64 后缀，go build 按 GOOS_GOARCH 约束自动识别。
#    只出 amd64：Windows 发布线只有一条 amd64。
( cd "$OUT_DIR" && go run github.com/akavel/rsrc@v0.10.2 \
    -ico app.ico -arch amd64 -o rsrc_windows_amd64.syso )

echo "==> $OUT_DIR/app.ico ($(du -h "$OUT_DIR/app.ico" | awk '{print $1}'))"
echo "==> $OUT_DIR/rsrc_windows_amd64.syso ($(du -h "$OUT_DIR/rsrc_windows_amd64.syso" | awk '{print $1}'))"
