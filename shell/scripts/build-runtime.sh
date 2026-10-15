#!/bin/bash
# 拼装分发的 runtime/ 目录：python-build-standalone + 后端源码 + Playwright 浏览器。
#
# 用法:
#   bash shell/scripts/build-runtime.sh                    # 输出到 shell/runtime
#   bash shell/scripts/build-runtime.sh path/to/output     # 指定输出目录
#
# 必须在目标平台本地执行。Python 解释器和 Playwright 浏览器都是平台相关的，
# macOS 的 runtime/ 不能塞进 Windows 包，反之亦然。
#
# 产物布局:
#   runtime/
#   ├── python/            python-build-standalone（可迁移，可被 codesign 签名）
#   ├── playwright/        Chromium（离线可用，壳通过 PLAYWRIGHT_BROWSERS_PATH 指过来）
#   ├── Start.py
#   ├── global_config.yml
#   └── app/  utils/  static/
#
# ⚠️ 输出路径只接受仓库根下的相对路径。Windows Git Bash 把绝对路径给成
#   POSIX 形态（/c/Users/...），Python 看不懂；用相对路径则 Python 和 bash
#   按同一个 cwd 解析，两边都对。
#
# 前端不需要在这里构建：static/ 里的构建产物是入库的（见 .gitattributes 的
# linguist-vendored 注释），所以 CI 不用装 Node 工具链。

# ============================================================================
# 升级 Python 版本时改这里。
#
# 为什么写死而不是拉 latest：这是打进发布产物的第三方解释器，
# 构建必须可复现。Playwright 1.60.0 的 wheel 与 Python 版本有兼容性边界，
# 换版本要重新验证一遍。
#
# 资产命名规则：cpython-<PY_VERSION>+<PY_RELEASE_TAG>-<平台>-install_only.tar.gz
# install_only 变体 = 开箱即用、自带全部动态库、不含开发工具。
# ============================================================================
PY_RELEASE_TAG="${PY_RELEASE_TAG:-20261013}"
PY_VERSION="${PY_VERSION:-3.11.17}"

set -eu

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-shell/runtime}"
cd "$REPO_DIR"

case "$OUT" in
	/*) echo "输出路径必须是仓库根下的相对路径（收到: $OUT）"; exit 1 ;;
esac

# --- 平台 → python-build-standalone 平台串 ---
OS="$(uname -s)"
MACH="$(uname -m)"
case "$OS" in
	Darwin)
		case "$MACH" in
			arm64)  PY_PLAT="aarch64-apple-darwin" ;;
			x86_64) PY_PLAT="x86_64-apple-darwin" ;;
			*) echo "不支持的 macOS 架构: $MACH"; exit 1 ;;
		esac
		PY_BIN="python/bin/python"
		;;
	MINGW*|MSYS*|CYGWIN*)
		PY_PLAT="x86_64-pc-windows-msvc"
		PY_BIN="python/python.exe"
		;;
	*) echo "不支持的操作系统: $OS（CI 只跑 macOS 和 Windows）"; exit 1 ;;
esac

ASSET="cpython-${PY_VERSION}+${PY_RELEASE_TAG}-${PY_PLAT}-install_only.tar.gz"
BASE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE_TAG}"

echo "==> 0/7 清理 $OUT"
[ -d "$OUT" ] && rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> 1/7 拷贝后端源码"
# global_config.yml 必须在 runtime/ 根下（上游从工作目录读），缺了后端预检会拦下来。
cp -R app utils static "$OUT/"
# 顶层 *.py 全拷，不枚举。枚举会漏：XianyuAutoAsync.py 就曾经漏过，
# 在用户机器上才以 ModuleNotFoundError 暴露（reply_server.py / cookie_manager.py 都 import 它）。
cp *.py global_config.yml requirements.txt "$OUT/"
mkdir -p "$OUT/data" "$OUT/static/uploads"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pystand.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TARBALL="$TMP/$ASSET"
SUMS="$TMP/SHA256SUMS"

echo "==> 2/7 下载 python-build-standalone $PY_VERSION ($PY_PLAT)"
curl -fSL --retry 3 -o "$TARBALL" "$BASE_URL/$ASSET"
curl -fSL --retry 3 -o "$SUMS" "$BASE_URL/SHA256SUMS"

# 解压后顶层就是 python/，落在 $OUT/python/
tar xzf "$TARBALL" -C "$OUT"
[ -x "$OUT/$PY_BIN" ] || { echo "解压后找不到 $OUT/$PY_BIN"; exit 1; }

echo "==> 3/7 校验 sha256"
# 用刚解压的解释器自己算哈希，两个平台一条代码路径（Git Bash 不一定带 sha256sum）。
EXPECTED="$(awk -v f="$ASSET" '$2 == f {print $1}' "$SUMS")"
[ -n "$EXPECTED" ] || { echo "SHA256SUMS 里找不到 $ASSET"; exit 1; }
ACTUAL="$($OUT/$PY_BIN - "$TARBALL" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
	for chunk in iter(lambda: f.read(1 << 20), b""):
		h.update(chunk)
print(h.hexdigest())
PY
)"
if [ "$ACTUAL" != "$EXPECTED" ]; then
	echo "sha256 不匹配"
	echo "  期望: $EXPECTED"
	echo "  实际: $ACTUAL"
	exit 1
fi
echo "    校验通过 ($EXPECTED)"

echo "==> 4/7 安装后端依赖到解释器自带 site-packages"
# 不用 venv、不用 --target：直接装进解释器自己的 site-packages，
# 运行时 Python 按正常路径找到，不需要 PYTHONPATH，后端零改动。
"$OUT/$PY_BIN" -m pip install --quiet --upgrade pip
"$OUT/$PY_BIN" -m pip install -r requirements.txt

echo "==> 5/7 下载 Playwright 浏览器（约 413MB）"
# --no-shell 必须加。新版 playwright 会额外下载 chromium_headless_shell（约 267MB），
# 但 XianyuAutoAsync.py:3536 写死了 channel: 'chromium' 强制用完整版，
# 那个 headless shell 会被打包进去却永远用不到 —— 纯死重。
PLAYWRIGHT_BROWSERS_PATH="$OUT/playwright" "$OUT/$PY_BIN" -m playwright install chromium --no-shell

echo "==> 6/7 校验运行时可导入"
# 这一步是防「产物缺模块」的，曾经因为漏拷 XianyuAutoAsync.py 在用户机器上才炸。
# DB_PATH 重定向到 $OUT 之外，避免自检建的空库被打进产物。
# 四个模块覆盖：应用入口 / 消息监听核心 / Cookie 管理 / API 路由。
DB_PATH="$TMP/importcheck.db" "$OUT/$PY_BIN" -c "
import importlib
for m in ('XianyuAutoAsync', 'Start', 'app.cookie_manager', 'app.reply_server'):
    importlib.import_module(m)
print('    四个关键模块导入通过')
"
rm -f "$TMP/importcheck.db"

echo "==> 7/7 清理死重（测试套件 + 字节码缓存）"
# 必须放在第 6 步之后：自检的 import 会重新生成 __pycache__，先删就是白删。
# tests/ 是部分包的 wheel 带进来的测试套件（certifi / numpy / greenlet ...），
# 运行时用不到。两者都不影响功能：__pycache__ 首次运行会自动重建，
# 只多花一点 JIT 预热时间。
BEFORE="$(du -sh "$OUT" 2>/dev/null | cut -f1)"
find "$OUT/python" -type d -name tests -prune -exec rm -rf {} +
find "$OUT/python" -type d -name __pycache__ -prune -exec rm -rf {} +
AFTER="$(du -sh "$OUT" 2>/dev/null | cut -f1)"
echo "    清理 $OUT/python 下的 tests/ 与 __pycache__/：$BEFORE → $AFTER"

echo
echo "==> 完成: $OUT ($(du -sh "$OUT" 2>/dev/null | cut -f1))"
"$OUT/$PY_BIN" --version

# --- 不变量自检 ---
# 这个脚本存在的唯一理由就是解决 venv 的两个问题：不可迁移 + 无法签名。
# 绝对符号链接是两者的共同根因（codesign 报
# "invalid destination for symbolic link in bundle"），所以直接查它。
ABS_LINKS="$(find "$OUT/python" -type l -exec sh -c 'readlink "$1" | grep -q "^/" && echo X' _ {} \; 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ABS_LINKS" != "0" ]; then
	echo "❌ 发现 $ABS_LINKS 个指向绝对路径的符号链接，产物不可签名："
	find "$OUT/python" -type l -exec sh -c 'readlink "$1" | grep -q "^/" && echo "   $1 -> $(readlink "$1")"' _ {} \;
	exit 1
fi
echo "✅ 绝对符号链接: 0（产物可迁移、可被 codesign 签名）"
