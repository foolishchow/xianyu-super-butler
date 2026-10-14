// Command shell 是闲鱼智控的桌面壳。
//
// 职责边界：只开窗口、拉起 Python 后端、把窗口导航到后端地址。
// 所有业务逻辑都在 Python 侧，Go 侧不接触任何业务数据。
//
// 目录约定（构建产物与 runtime/ 同级）：
//
//	shell-build/shell              本程序
//	shell-build/runtime/           仓库 Python 部分：Start.py / global_config.yml / venv
//	<用户数据目录>/xianyu-super-butler/   数据库 / 日志 / 上传文件
package main

import (
	"fmt"
	"html"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"
	"github.com/wailsapp/wails/v3/pkg/events"
)

const (
	appName      = "闲鱼智控"
	dataDirName  = "xianyu-super-butler"
	backendWait  = 180 * time.Second
	pollInterval = 500 * time.Millisecond
)

// env 是 main() 一次性解析出来的运行环境，向下只读传递。
type env struct {
	runtimeDir string // Python 后端目录：Start.py / global_config.yml / venv
	dataDir    string // 用户数据目录：数据库 / 日志 / 上传
	apiURL     string // 后端地址，形如 http://127.0.0.1:41234
	apiPort    int
	logPath    string // 后端 stdout/stderr 落地位置
}

// startState 承载启动期的可变状态。OnShutdown 需要经由它找到并停掉后端进程，
// 而 startBackend 运行在 goroutine 里，所以这里必须加锁。
type startState struct {
	sync.Mutex
	env   *env
	cmd   *exec.Cmd
	fatal string // 预检失败原因，非空则加载页渲染成静态错误页
}

func (s *startState) setCmd(cmd *exec.Cmd) {
	s.Lock()
	s.cmd = cmd
	s.Unlock()
}

func (s *startState) stop() {
	s.Lock()
	cmd := s.cmd
	s.cmd = nil
	s.Unlock()
	if cmd == nil {
		return
	}
	killBackend(cmd)
}

func main() {
	st := &startState{}
	e, err := resolveEnv()
	if err != nil {
		// 目录结构不对也照样开窗：让用户看到人话提示，而不是进程静默退出。
		// 此时数据目录还没建出来，日志退到系统临时目录，别落到 exe 旁边。
		e = &env{
			apiURL:  "http://127.0.0.1:0",
			dataDir: os.TempDir(),
			logPath: "（数据目录不可用）",
		}
		st.fatal = err.Error()
	}
	st.env = e

	logger := openLogger(e)

	app := application.New(application.Options{
		Name:   appName,
		Logger: logger,
		Mac: application.MacOptions{
			// 显式写出（这也是 Wails mac 的默认值）：最后一个窗口关闭后 app 不退出。
			// 关窗语义是"隐藏到后台继续监听"，退出只能走托盘菜单的「退出」。
			// 关掉这行 app 会随窗口一起退，Dock 图标就点不回来了。
			ApplicationShouldTerminateAfterLastWindowClosed: false,
		},
		Windows: application.WindowsOptions{
			DisableQuitOnLastWindowClosed: true,
		},
		// 后端就绪后 OnShutdown 由 Wails 调用，负责把 Python 进程树收干净。
		OnShutdown: func() {
			st.stop()
			logger.Info("后端进程已停止")
		},
	})

	window := app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:     appName,
		Width:     1440,
		Height:    900,
		MinWidth:  1100,
		MinHeight: 720,
		HTML:      loadingHTML(e, st.fatal),
	})

	// 红叉 = 隐藏到后台，不销毁窗口。
	//
	// 必须用 RegisterHook 而不是 OnWindowEvent：派发时 hook 是同步回调并检查
	// IsCancelled()，listener 是丢进 goroutine 异步跑的，异步那个取消不掉关闭。
	// 用隐藏而不是取消即销毁：窗口对象存活，SPA 登录态/筛选/已展开面板全保留，
	// 唤回是瞬时的，不用重新跑加载页轮询。
	window.RegisterHook(events.Common.WindowClosing, func(ev *application.WindowEvent) {
		logger.Info("窗口关闭 → 隐藏到后台（后端继续运行）")
		window.Hide()
		ev.Cancel()
	})

	// 点 Dock 图标唤回窗口。
	//
	// 不注册这个就是原 bug 的直接原因：Wails 的 applicationShouldHandleReopen:
	// 里 hasListeners 为假，事件根本不派发，点了没有任何反应。
	if runtime.GOOS == "darwin" {
		app.Event.OnApplicationEvent(events.Mac.ApplicationShouldHandleReopen, func(*application.ApplicationEvent) {
			showWindow(window)
		})
	}

	setupTray(app, window, e.dataDir)

	if st.fatal == "" {
		go startBackend(st, logger)
	}

	if err := app.Run(); err != nil {
		logger.Error("app.Run 失败", "err", err)
	}
}

// runtimeCandidates 按优先级列出后端目录的可能位置。
//
// macOS .app 里二进制在 Contents/MacOS/，runtime 放 Contents/Resources/ 才符合
// 打包惯例；开发期的裸二进制则和 exe 同级。Windows/Linux 只有同级一种。
func runtimeCandidates(exeDir string) []string {
	return []string{
		filepath.Join(exeDir, "runtime"),
		filepath.Join(exeDir, "..", "Resources", "runtime"),
	}
}

// findRuntimeDir 返回第一个真的存在 Start.py 的候选目录。
func findRuntimeDir(exeDir string) (string, error) {
	candidates := runtimeCandidates(exeDir)
	for _, dir := range candidates {
		if _, err := os.Stat(filepath.Join(dir, "Start.py")); err == nil {
			if abs, err := filepath.Abs(dir); err == nil {
				return abs, nil
			}
			return dir, nil
		}
	}
	return "", fmt.Errorf(
		"找不到后端入口：以下候选目录都没有 Start.py\n  %s\n\n请把仓库的 Python 部分（含 Start.py 和 global_config.yml）放到 runtime/ 目录",
		strings.Join(candidates, "\n  "))
}

// resolveEnv 校验目录结构、分配端口、确定数据目录。
// 返回非 nil 错误时说明产物布局有问题，此时不应尝试启动后端。
func resolveEnv() (*env, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("无法定位可执行文件: %w", err)
	}
	runtimeDir, err := findRuntimeDir(filepath.Dir(exe))
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(filepath.Join(runtimeDir, "global_config.yml")); err != nil {
		return nil, fmt.Errorf(
			"runtime/ 目录缺少 global_config.yml\n\n后端启动时会从工作目录读取该文件，缺了会直接读不到配置")
	}

	dataDir := filepath.Join(userBaseDir(), dataDirName)
	for _, sub := range []string{"", "logs", "backups", filepath.Join("static", "uploads", "images")} {
		if err := os.MkdirAll(filepath.Join(dataDir, sub), 0o755); err != nil {
			return nil, fmt.Errorf("创建数据目录失败 %s: %w", filepath.Join(dataDir, sub), err)
		}
	}

	port, err := freePort()
	if err != nil {
		return nil, fmt.Errorf("分配端口失败: %w", err)
	}

	return &env{
		runtimeDir: runtimeDir,
		dataDir:    dataDir,
		apiURL:     fmt.Sprintf("http://127.0.0.1:%d", port),
		apiPort:    port,
		logPath:    filepath.Join(dataDir, "backend.log"),
	}, nil
}

// userBaseDir 取跨平台用户数据目录；取不到时退回可执行文件所在目录。
func userBaseDir() string {
	if d := application.Path(application.PathDataHome); filepath.IsAbs(d) {
		return d
	}
	if exe, err := os.Executable(); err == nil {
		return filepath.Dir(exe)
	}
	return "."
}

// freePort 向系统要一个空闲端口。占用与释放之间存在极小的竞态窗口，
// 若真的被抢走，后端会启动失败并写入日志，用户可据此排查。
func isDir(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

func freePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return port, nil
}

// startBackend 拉起 Python 后端并等待健康检查通过。
// 跑在 goroutine 里，让窗口能立刻显示加载页而不是黑屏干等。
func startBackend(st *startState, logger *slog.Logger) {
	e := st.env

	python := pythonBin(e.runtimeDir)
	logger.Info("准备启动后端", "python", python, "cwd", e.runtimeDir, "port", e.apiPort)

	logFile, err := os.OpenFile(e.logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		logger.Error("打开后端日志失败", "path", e.logPath, "err", err)
		return
	}
	defer logFile.Close()

	cmd := newBackendCmd(python, []string{"Start.py"})
	cmd.Dir = e.runtimeDir
	cmd.Env = append(os.Environ(),
		"API_HOST=127.0.0.1",
		fmt.Sprintf("API_PORT=%d", e.apiPort),
		fmt.Sprintf("DB_PATH=%s", filepath.Join(e.dataDir, "xianyu_data.db")),
		"PYTHONUNBUFFERED=1",
	)

	// 把 Playwright 浏览器一并打包时指给它，避免首次启动联网下载 Chromium。
	// 上游 Start.py 已经认识 PLAYWRIGHT_BROWSERS_PATH 这个环境变量，后端零改动。
	if pw := filepath.Join(e.runtimeDir, "playwright"); isDir(pw) {
		cmd.Env = append(cmd.Env, "PLAYWRIGHT_BROWSERS_PATH="+pw)
		logger.Info("使用内置 Playwright 浏览器", "path", pw)
	}

	cmd.Stdout, cmd.Stderr = logFile, logFile

	if err := cmd.Start(); err != nil {
		logger.Error("后端进程启动失败", "err", err)
		return
	}
	st.setCmd(cmd)

	go func() {
		if err := cmd.Wait(); err != nil {
			logger.Warn("后端进程退出", "err", err)
		}
	}()

	if err := waitHealth(e.apiURL, backendWait); err != nil {
		logger.Error("后端健康检查超时", "url", e.apiURL+"/health", "log", e.logPath)
		return
	}
	logger.Info("后端已就绪", "url", e.apiURL)
}

// waitHealth 只要拿到任意 HTTP 响应就认为服务可访问。
// 503 只代表后端内部子服务未就绪（见 reply_server.py 的 /health），
// 不至于让启动页一直转圈。
func waitHealth(base string, timeout time.Duration) error {
	client := &http.Client{Timeout: 3 * time.Second}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := client.Get(base + "/health")
		if err == nil {
			_ = resp.Body.Close()
			return nil
		}
		time.Sleep(pollInterval)
	}
	return fmt.Errorf("健康检查超时: %s/health", base)
}

// pythonBin 依次尝试显式指定、内置 venv、系统 PATH。
func pythonBin(runtimeDir string) string {
	if p := os.Getenv("PYTHON_BIN"); p != "" {
		return p
	}
	for _, c := range []string{
		filepath.Join(runtimeDir, "python.exe"),
		filepath.Join(runtimeDir, "bin", "python"),
	} {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	if p, err := exec.LookPath("python3"); err == nil {
		return p
	}
	return "python"
}

func openLogger(e *env) *slog.Logger {
	f, err := os.OpenFile(filepath.Join(e.dataDir, "shell.log"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		f = os.Stdout
	}
	return slog.New(slog.NewTextHandler(f, &slog.HandlerOptions{Level: slog.LevelDebug}))
}

// loadingHTML 生成启动加载页。
//
// 页面自己轮询 /health 并在成功后跳转，Go 侧不需要介入导航。
// fatal 非空时渲染成静态错误页，此时后端根本没启动。
func loadingHTML(e *env, fatal string) string {
	if fatal != "" {
		return `<!doctype html>
<meta charset="utf-8">
<title>` + appName + `</title>
<style>
body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
  background:#0f172a;color:#e2e8f0;font:14px/1.7 system-ui,-apple-system,"PingFang SC","Microsoft YaHei"}
.wrap{max-width:560px;padding:32px;background:#1e293b;border:1px solid #334155;border-radius:12px}
h1{margin:0 0 8px;font-size:18px;color:#f5b301}
p{margin:0 0 16px;color:#94a3b8}
pre{white-space:pre-wrap;word-break:break-all;margin:0;padding:12px;
  background:#0f172a;border-radius:8px;color:#fca5a5;font-size:12px}
</style>
<div class="wrap">
  <h1>启动失败</h1>
  <p>桌面壳未能找到后端程序，请检查安装是否完整。</p>
  <pre>` + html.EscapeString(fatal) + `
</pre>
</div>`
	}
	return strings.NewReplacer(
		"__API__", strconv.Quote(e.apiURL),
		"__LOG__", strconv.Quote(filepath.ToSlash(e.logPath)),
	).Replace(`<!doctype html>
<meta charset="utf-8">
<title>` + appName + ` - 启动中</title>
<style>
*{box-sizing:border-box}
body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
  background:linear-gradient(160deg,#0f172a,#1e293b);color:#e2e8f0;
  font:14px/1.7 system-ui,-apple-system,"PingFang SC","Microsoft YaHei"}
.wrap{text-align:center;max-width:440px;padding:28px}
.brand{font-size:20px;font-weight:600;margin-bottom:24px;color:#f8fafc}
.brand span{color:#f5b301}
.spin{width:42px;height:42px;margin:0 auto 20px;border:3px solid #334155;
  border-top-color:#f5b301;border-radius:50%;animation:s 1s linear infinite}
@keyframes s{to{transform:rotate(360deg)}}
#msg{min-height:22px;color:#94a3b8}
#sub{margin-top:14px;color:#64748b;font-size:12px;word-break:break-all}
.fail{color:#fca5a5}
</style>
<div class="wrap">
  <div class="brand">闲鱼<span>智控</span></div>
  <div class="spin"></div>
  <div id="msg">正在启动本地服务…</div>
  <div id="sub">__LOG__</div>
</div>
<script>
const API = __API__;
const msg = document.getElementById("msg");
const sub = document.getElementById("sub");
const LIMIT = 240; // 240 * 500ms = 120s
let tries = 0;

async function ping() {
  try {
    const r = await fetch(API + "/health", {cache:"no-store"});
    return r.ok ? (await r.json().catch(() => ({}))) : null;
  } catch (_) {
    // CORS 被拦时退化为 no-cors 探测：只要连接通了就算后端已起
    try { await fetch(API + "/health", {mode:"no-cors"}); return {}; }
    catch (_) { return null; }
  }
}

function fail(text) {
  msg.textContent = text;
  msg.classList.add("fail");
  document.querySelector(".spin").style.display = "none";
}

(async function tick() {
  const d = await ping();
  if (d) {
    const s = d.services || {};
    const ok = k => s[k] === "ok" ? "✓" : "…";
    msg.textContent = "服务已就绪：数据库 " + ok("database") + " · 任务 " + ok("cookie_manager");
    setTimeout(() => { location.href = API + "/"; }, 600);
    return;
  }
  if (++tries >= LIMIT) {
    fail("启动超时。后端日志已写入：\n" + sub.textContent + "\n请把该文件发给作者排查。");
    return;
  }
  if (tries > 12) msg.textContent = "仍在启动，首次运行较慢…";
  setTimeout(tick, 500);
})();
</script>`)
}
