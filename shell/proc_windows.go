//go:build windows

package main

import (
	"os/exec"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

// newBackendCmd Windows 上不需要设置进程组标志：taskkill /T 是按父子关系
// 递归杀整棵进程树的，和进程组无关。
//
// CREATE_NO_WINDOW 是必须的。壳本身是 GUI 子系统（PE subsystem=2），
// 但它要拉起的 python.exe 自己是 console 子系统（subsystem=3）——
// GUI 父进程启动 console 子进程时，Windows 会为子进程分配一个全新的控制台，
// 那才是用户看到的黑窗口，跟壳自己的子系统无关。
// 后端 stdout/stderr 已重定向到 backend.log（main.go:275），控制台本来就没用。
func newBackendCmd(path string, args []string) *exec.Cmd {
	cmd := exec.Command(path, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	return cmd
}

// killBackend 用 taskkill /T 连 Python 派生的 Playwright Chromium 一起收掉。
// taskkill 同样是 console 子系统程序，不加这个标志每次退出都会闪一下黑窗口。
func killBackend(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	taskkill := exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid))
	taskkill.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	_ = taskkill.Run()
	time.Sleep(500 * time.Millisecond)
}
