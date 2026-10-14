#!/bin/bash
# 拼装分发的 runtime/ 目录：Python venv + 后端源码 + Playwright 浏览器。
#
# 用法:
#   bash shell/scripts/build-runtime.sh                    # 输出到 shell/runtime
#   bash shell/scripts/build-runtime.sh path/to/output     # 指定输出目录
#
# 必须在目标平台本地执行。venv 的目录布局（bin/ vs Scripts/）和 Playwright
# 浏览器都是平台相关的，macOS 的 runtime/ 不能塞进 Windows 包，反之亦然。
#
# ⚠️ 输出路径只接受仓库根下的相对路径。Windows Git Bash 把绝对路径给成
#   POSIX 形态（/c/Users/...），Python 看不懂；用相对路径则 Python 和 bash
#   按同一个 cwd 解析，两边都对。
#
# 前端不需要在这里构建：static/ 里的构建产物是入库的（见 .gitattributes 的
# linguist-vendored 注释），所以 CI 不用装 Node 工具链。
set -eu

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-shell/runtime}"
cd "$REPO_DIR"

case "$OUT" in
	/*) echo "输出路径必须是仓库根下的相对路径（收到: $OUT）"; exit 1 ;;
esac

if [ -d "$OUT" ]; then
	echo "==> 0/4 清理 $OUT"
	rm -rf "$OUT"
fi
mkdir -p "$OUT"

echo "==> 1/4 拷贝后端源码"
# 只拷运行需要的。global_config.yml 必须在 runtime/ 根下（上游从工作目录读），
# 缺了后端预检会拦下来。
cp -R app utils static "$OUT/"
cp Start.py global_config.yml requirements.txt "$OUT/"
# uploads 是运行期写入的图片目录，git 里是空的
mkdir -p "$OUT/data" "$OUT/static/uploads"

echo "==> 2/4 创建 Python venv"
# Windows 上没有 python3 这个命令名
if command -v python3 >/dev/null 2>&1; then
	PY=python3
else
	PY=python
fi
"$PY" -m venv "$OUT"
if [ -x "$OUT/Scripts/python.exe" ]; then
	VENV_PY="$OUT/Scripts/python.exe"
else
	VENV_PY="$OUT/bin/python"
fi
echo "    解释器: $("$VENV_PY" --version)  ($VENV_PY)"

echo "==> 3/4 安装依赖"
"$VENV_PY" -m pip install --quiet --upgrade pip
"$VENV_PY" -m pip install -r requirements.txt

echo "==> 4/4 下载 Playwright 浏览器（约 534MB）"
# 装进 bundle 内部，壳会通过 PLAYWRIGHT_BROWSERS_PATH 指过去，避免用户首启联网。
PLAYWRIGHT_BROWSERS_PATH="$OUT/playwright" "$VENV_PY" -m playwright install chromium

echo
echo "==> 完成: $OUT ($(du -sh "$OUT" 2>/dev/null | cut -f1))"

# ⚠️ 已知问题（未修，等决策）：这个 venv 不可迁移。
#
# pyvenv.cfg 的 home= 写死创建 venv 时所用基础解释器的绝对路径，bundle 里的
# bin/python 是指向它的符号链接。拷到别的机器后该路径不存在，
# shell/main.go 的 pythonBin() 用 os.Stat 探测会失败，回退到用户系统 python3，
# 然后因缺依赖崩掉 —— 表现是「窗口开了但后端起不来」，比直接打不开更难查。
#
# 真正自包含要走 python-build-standalone（不用 venv，依赖直接装进它的
# site-packages）。在决策前，下面的输出就是 CI 日志里唯一的诊断线索：
# 只要 home= 不落在 bundle 目录内，这份产物在别人机器上就是坏的。
echo "⚠️  venv 可迁移性检查（home= 必须落在 bundle 内，否则别人机器上坏）:"
grep -E '^(home|executable) =' "$OUT/pyvenv.cfg" 2>/dev/null || true
