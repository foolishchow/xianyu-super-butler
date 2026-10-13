//go:build !windows

package main

import (
	"os/exec"
	"syscall"
	"time"
)

// newBackendCmd 给后端进程建一个独立进程组。
// Python 侧会 fork 出 Playwright 的 Chromium 子进程，只杀 Start.py 本体
// 会留下一堆孤儿浏览器进程；独立进程组才能让 SIGTERM 一次覆盖整棵树。
func newBackendCmd(path string, args []string) *exec.Cmd {
	cmd := exec.Command(path, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

// killBackend 先优雅 SIGTERM，5 秒内不收手再 SIGKILL。
func killBackend(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	pgid := cmd.Process.Pid

	_ = syscall.Kill(-pgid, syscall.SIGTERM)
	for i := 0; i < 20; i++ {
		// 信号 0 只用于探测进程是否存在，不会真的发信号
		if err := syscall.Kill(-pgid, 0); err != nil {
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
}
