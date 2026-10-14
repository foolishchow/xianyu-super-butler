// tray.go 菜单栏图标与窗口唤回。
//
// 关窗语义：点红叉是"隐藏到后台继续监听"，不是退出。退出只能走托盘菜单的「退出」。
//
// 为什么关窗要隐藏而不是销毁窗口：
//
//  1. 窗口对象存活，SPA 的登录态、筛选条件、已展开的面板全部保留，唤回是瞬时的；
//     销毁重建则要重新跑加载页轮询 /health。
//  2. 后端 Python 进程和它派生的 Playwright Chromium 继续跑，消息监听不打断——
//     这正是"关掉窗口还在盯着"的意义。
//
// Dock 图标策略：macOS 上用动态切换（见 activation_darwin.go）。窗口可见时 Regular
//（Dock 图标可见），窗口隐藏时 Accessory（不占 Dock 位）。启动时 Regular，红叉时
// 切 Accessory，托盘唤回时切回 Regular。唤回入口是菜单栏托盘（见 setupTray）。
//
// ApplicationShouldTerminateAfterLastWindowClosed=false 仍然必要：否则最后一个窗口
// 没了 app 会直接退，消息监听跟着断。实测 shell.log 确认红叉只隐藏窗口、不退进程。
//
// 实测（2026-10-14，macOS 15.8.1 / beta.28，真实 .app 包）：
//  - 红叉隐藏 ✅ Cmd+W → shell.log "Window hiding"，AX 窗口数 1 → 0，幂等
//  - 托盘唤回 ✅ 点托盘 → AX 窗口数 0 → 1，同一个窗口对象，不重跑 /health
//  - 后端存活 ✅ 隐藏/唤回全程 python Start.py 不退出
//  - 图标渲染 ✅ tray_template.png 唯一 RGB = (0,0,0)，符合 template 要求
//  - 托盘菜单 ✅ 人工点验证：右键弹三项、左键唤回、退出时后端 SIGTERM 无孤儿
//
// 注意：**不要用 CGEvent 合成点击去验证托盘**。Wails beta.28 在
// systemtray_darwin.h 里有个 systemTrayCoerceEventType()，注释写着 `See #5752
// rationale`——Wails 自己对 status item 的右键识别就补过一个 hack。合成的右键
// 会被错误归类成左键，测出来的"菜单弹不出来"是假象，必须用真鼠标。
package main

import (
	_ "embed"
	"os/exec"
	"runtime"

	"github.com/wailsapp/wails/v3/pkg/application"
)

// macOS 菜单栏图标必须是 template（纯黑 + alpha），系统按深浅色菜单栏自动反色。
// 不能用 static/icon.svg 那份带黄底方块的，进菜单栏会成一块刺眼的黄斑。
// 44x44 = 菜单栏 22pt @2x；生成方式见 scripts/make-tray-icon.sh。
//
//go:embed tray_template.png
var trayTemplateIcon []byte

// Windows / Linux 没有 template 机制，用彩色版，32x32。
//
//go:embed tray_color.png
var trayColorIcon []byte

// setupTray 建菜单栏图标和菜单。dataDir 用于「打开数据目录」一项。
func setupTray(app *application.App, window application.Window, dataDir string) {
	tray := app.SystemTray.New()
	tray.SetTooltip(appName)
	if runtime.GOOS == "darwin" {
		tray.SetTemplateIcon(trayTemplateIcon)
	} else {
		tray.SetIcon(trayColorIcon)
	}

	menu := app.NewMenu()
	menu.Add("显示窗口").OnClick(func(*application.Context) { showWindow(window) })
	menu.Add("打开数据目录").OnClick(func(*application.Context) { revealPath(dataDir) })
	menu.AddSeparator()
	menu.Add("退出").OnClick(func(*application.Context) { app.Quit() })
	tray.SetMenu(menu)

	// 不用 tray.AttachWindow(window)，改成手动 OnClick 只做唤回。
	//
	// 取舍理由：这个 App 点击永远只"唤回"。AttachWindow 的默认 clickHandler 是
	// ToggleWindow，再次点击就隐藏，不是想要的行为（用户点错一下就看不见窗口了）。
	tray.OnClick(func() { showWindow(window) })
}

// showWindow 把窗口唤回前台。先切回 Regular 让 Dock 图标出现，再 Show 窗口，
// 最后 Focus 把 app 拉到前台。
func showWindow(w application.Window) {
	setActivationPolicy(true)
	w.Show()
	w.Focus()
}

// revealPath 用系统文件管理器打开目录。后端日志 backend.log / shell.log 都在
// 数据目录下，用户排查部署问题时不用自己翻 ~/Library/Application Support/。
func revealPath(path string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("explorer", path)
	case "darwin":
		cmd = exec.Command("open", path)
	default:
		cmd = exec.Command("xdg-open", path)
	}
	_ = cmd.Start()
}
