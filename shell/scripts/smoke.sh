#!/bin/bash
# 桌面壳冒烟测试：验证"加载页 -> 后端地址"的跨 origin 导航。
#
# 用 shell/test/backend.py 冒充后端，不启动真实闲鱼链路。
# 预期结果：窗口从启动加载页切换到 "STUB BACKEND OK"。
#
# 用法：bash shell/scripts/smoke.sh
set -u

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/shell-smoke.XXXXXX)"
echo "工作目录: $WORK"

cd "$SHELL_DIR" || exit 1
go build -o "$WORK/shell" . 2>&1 | grep -v "^ld: warning"
[ -x "$WORK/shell" ] || { echo "构建失败"; exit 1; }

mkdir -p "$WORK/runtime"
cp "$SHELL_DIR/test/backend.py" "$WORK/runtime/Start.py"
printf 'API_ENDPOINTS: {}\nAPP_CONFIG: {}\nAUTO_REPLY:\n  api: {}\n' \
  > "$WORK/runtime/global_config.yml"

cd "$WORK" || exit 1
./shell > out.txt 2>&1 &
APP=$!
echo "已启动壳进程 pid=$APP，等待 12 秒…"
sleep 12

echo
echo "=== 进程状态 ==="
ps -p "$APP" -o pid=,stat= 2>/dev/null || echo "已退出（异常）"

echo
echo "=== shell.log ==="
find "$HOME/Library/Application Support" "$HOME/.local/share" \
  -maxdepth 2 -name "xianyu-super-butler" -type d 2>/dev/null | while read -r d; do
  tail -8 "$d/shell.log" 2>/dev/null
done

echo
echo "=== backend.log ==="
find "$HOME/Library/Application Support" "$HOME/.local/share" \
  -maxdepth 2 -name "xianyu-super-butler" -type d 2>/dev/null | while read -r d; do
  head -3 "$d/backend.log" 2>/dev/null
done

echo
echo "=== 截图 ==="
if command -v screencapture >/dev/null 2>&1; then
  screencapture -x "$WORK/shot.png" && echo "macOS: $WORK/shot.png"
elif command -v import >/dev/null 2>&1; then
  import -window root "$WORK/shot.png" && echo "Linux: $WORK/shot.png"
else
  echo "无截图工具，请人工查看窗口内容"
fi

kill "$APP" 2>/dev/null
pkill -f "$WORK/shell" 2>/dev/null
pkill -f "$WORK/runtime/Start.py" 2>/dev/null
echo
echo "提示: 窗口内容应为 \"STUB BACKEND OK\"，且 API_PORT 为随机高端口。"
