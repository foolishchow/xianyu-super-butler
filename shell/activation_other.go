//go:build !darwin

package main

// setActivationPolicy 在非 macOS 平台是空操作。
// Windows 没有 Dock/ActivationPolicy 的概念，"隐藏不退出"语义由
// DisableQuitOnLastWindowClosed 独立保证（见 main.go）。
func setActivationPolicy(regular bool) {}
