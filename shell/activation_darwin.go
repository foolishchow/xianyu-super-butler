//go:build darwin

package main

/*
#cgo LDFLAGS: -lobjc
#include <objc/runtime.h>
#include <objc/message.h>

void _setPolicyRegular() {
	Class cls = objc_getClass("NSApplication");
	SEL sharedApplication = sel_registerName("sharedApplication");
	id app = ((id(*)(id, SEL))objc_msgSend)((id)cls, sharedApplication);
	SEL setPolicy = sel_registerName("setActivationPolicy:");
	((void(*)(id, SEL, long))objc_msgSend)(app, setPolicy, 0);
}

void _setPolicyAccessory() {
	Class cls = objc_getClass("NSApplication");
	SEL sharedApplication = sel_registerName("sharedApplication");
	id app = ((id(*)(id, SEL))objc_msgSend)((id)cls, sharedApplication);
	SEL setPolicy = sel_registerName("setActivationPolicy:");
	((void(*)(id, SEL, long))objc_msgSend)(app, setPolicy, 1);
}
*/
import "C"

// setActivationPolicy 动态切换 Dock 图标显隐。
//
// Regular：有 Dock 图标、进 Cmd+Tab、有顶部应用菜单栏。
// Accessory：三者全无，菜单栏托盘是唯一入口。
//
// 这个 App 的策略：窗口可见时切 Regular（用户在 Dock 能找到），窗口隐藏时切
// Accessory（不占 Dock 位）。启动时已经是 Regular，不需要在启动路径上调。
//
// 实现：用 Objective-C runtime C API（objc_msgSend），因为 CGo 把 C 代码当 C
// 编译，不认 Objective-C 的消息发送语法 [obj msg:]。
func setActivationPolicy(regular bool) {
	if regular {
		C._setPolicyRegular()
	} else {
		C._setPolicyAccessory()
	}
}
