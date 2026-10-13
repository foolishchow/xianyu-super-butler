//go:build windows

package main

import (
	"os/exec"
	"strconv"
	"time"
)

// newBackendCmd Windows 上不需要设置进程组标志：taskkill /T 是按父子关系
// 递归杀整棵进程树的，和进程组无关。
func newBackendCmd(path string, args []string) *exec.Cmd {
	return exec.Command(path, args...)
}

// killBackend 用 taskkill /T 连 Python 派生的 Playwright Chromium 一起收掉。
func killBackend(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	_ = exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid)).Run()
	time.Sleep(500 * time.Millisecond)
}
