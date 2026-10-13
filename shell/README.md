# shell — 桌面壳

Wails v3 壳层，给闲鱼智控包一个原生窗口。

**职责边界**：只开窗口、拉起 Python 后端、把窗口导航到后端地址。
所有业务逻辑都在 Python 侧，Go 侧不接触任何业务数据。

```
shell                    ← 本程序
runtime/                 ← 仓库 Python 部分（Start.py / global_config.yml / venv）
~/Library/Application Support/xianyu-super-butler/   ← 数据库 / 日志 / 上传
```

## 为什么选 Wails v3，不选 v2

这是本目录存在的前提，先说清楚。

| 版本 | 能否把 WebView 指向外部 URL |
| --- | --- |
| Wails v2（稳定版 v2.16.0） | ❌ `options.App` 没有 `StartURL` 字段 |
| Wails v3（v3.0.0-beta.28） | ✅ `WebviewWindowOptions.URL` / `.HTML` 官方支持 |

v2 的起始 URL 是写死的常量：

```go
// v2/internal/frontend/desktop/windows/frontend.go:40
const startURL = "http://wails.localhost/"
```

社区 issue #2116 / #3181 / #4186 全是求这个能力的。v3 里 `internal/assetserver/assetserver.go` 的处理：

```go
if userURL != "" {
    parsedURL, err := baseURL.Parse(userURL)   // 绝对 URL 覆盖默认 wails:// origin
    startURL = parsedURL.String()
}
```

官方 example `v3/examples/events-bug/main.go` 直接写着 `URL: "https://google.com"`。

⚠️ **v3 仍是 beta**。官方 FAQ 的表述是 "beta software with a stable desktop API"。
本壳代码量很小、不需要频繁升级，用 beta.28 可以接受——**但 `go.mod` 必须锁死版本**。

> 实测结论（macOS 15.8.1 / WKWebView）：从 Wails `HTML` origin 跳转到
> `http://127.0.0.1:<随机端口>` 的跨 origin 导航**通过**。Linux WebKitGTK 尚未验证。

## 启动流程

```
1. resolveEnv()   校验 runtime/、分配空闲端口、建数据目录
2. 开窗           内联加载页（WebviewWindowOptions.HTML，三平台支持）
3. startBackend() go 协程里 exec python Start.py，注入 API_HOST / API_PORT / DB_PATH
4. 加载页轮询     fetch(/health) → 成功后 location.href 跳到后端
5. OnShutdown     杀掉整个 Python 进程树（含 Playwright 派生的 Chromium）
```

加载页自己负责轮询和跳转，Go 侧不用介入导航——`app.Run()` 之前创建的窗口还在
队列里，那时调 `ExecJS` 是不安全的，绕开这个问题比对抗它省事。

## 后端需要的接线（后端一行业务代码都不用改）

这些开关上游已经备好，本壳只是调用方：

| 需求 | 上游入口 |
| --- | --- |
| 换端口 | `Start.py:692` → `int(os.getenv('API_PORT', '8080'))` |
| 只绑本机 | `Start.py:691` → `os.getenv('API_HOST', '0.0.0.0')` |
| 数据目录可搬 | `app/db_manager.py:30` → `os.getenv('DB_PATH', 'data/xianyu_data.db')` |
| 健康检查 | `app/reply_server.py:436` → `@app.get('/health')` |
| 不会弹外部浏览器 | 全仓无 `webbrowser.open` |

唯一需要改后端的地方是 CORS，见 `app/reply_server.py` 里 `app.add_middleware(...)`
那一段。加载页跑在 Wails 内置 origin 上，跨 origin 读 `/health` 的 JSON 才能显示
真实启动进度（数据库 / 任务管理器各自状态）。

**必须用 `allow_origin_regex` 而不是 `allow_origins`**——Starlette 的 `allow_origins`
是精确匹配（`origin in allow_origins`），不支持 `127.0.0.1:*` 这种端口通配符。
端口是随机分配的，regex 是唯一可行的写法。

加载页 JS 里已经留了兜底：CORS 被拦时退化为 `mode:"no-cors"` 探测，只要连接通了就跳转。
所以就算哪天把 CORS 那段删了，壳也还能用，只是启动页会退化成纯转圈。

## 构建

```bash
cd shell

# macOS
go build -o out/shell .

# Windows
GOOS=windows GOARCH=amd64 go build -o out/shell.exe .

# Linux
GOOS=linux GOARCH=amd64 go build -o out/shell .
```

需要 CGO（Wails 依赖平台 WebKit/WebView2 原生库）。
Windows 目标机需要预装 WebView2 Runtime（Win10 1803+ 通常自带）。

### macOS 打 .app 包

```bash
bash shell/scripts/build-macos.sh                     # 只打壳
bash shell/scripts/build-macos.sh runtime/            # 壳 + 后端
bash shell/scripts/build-macos.sh runtime/ icon.icns  # 壳 + 后端 + 图标
```

产物在 `shell/out/闲鱼智控.app`，后端放进 `Contents/Resources/runtime/`。
壳会按顺序探测 `<exe>/runtime` 和 `<exe>/../Resources/runtime`，所以裸二进制和
.app 包两种布局都能跑。

包内自带 venv 时，Python 路径是 `Contents/Resources/runtime/bin/python`，
壳的 `pythonBin()` 会优先找到它，不依赖用户系统 Python。

#### 链接警告（已知，无法消除）

`go build` 会报 17 条：

```
ld: warning: object file was built for newer 'macOS' version (15.0) than being linked (11.0)
```

原因是 Wails beta.28 自己编译的 CGO 对象按 macOS 15 目标构建。设了
`MACOSX_DEPLOYMENT_TARGET=15.0` 和 `CGO_CFLAGS=-mmacosx-version-min=15.0`
都无效——Go 把 darwin 的 `LC_BUILD_VERSION.minos` 写死为 11.0，改不动。

实际后果：二进制声明 `minos 11.0`，但部分依赖符号可能真的需要 15.0。
所以 Info.plist 里按 `LSMinimumSystemVersion = 15.0` 声明，和 Wails 的实际
要求对齐。要彻底消除只能等 Wails 正式版或 patch 掉它的 CGO 对象。

## 分发

壳和后端是两套产物，需要一起分发：

```
闲鱼智控.app / 闲鱼智控.exe
├── shell(.exe)          # 本目录构建产物
└── runtime/
    ├── python(.exe)     # 内嵌 venv，别依赖用户系统 Python
    ├── Start.py
    ├── global_config.yml
    ├── app/  utils/  frontend/dist → static/ ...
    └── site-packages/   # playwright / node 依赖
```

`runtime/` 不在版本库里（见 `.gitignore`），是分装时拼出来的。

### Playwright 浏览器：要么打包，要么忍受首启联网下载

后端启动时会检查 Playwright 浏览器，缺了就自动下载（`Start.py:147` 的
`_check_and_install_playwright()`），默认走 `cdn.npmmirror.com` 镜像。这意味着：

- **不打包** → 首次启动要联网下 Chromium，离线环境直接不可用
- **打包** → 放进 `runtime/playwright/chromium-*/`，壳会自动设置
  `PLAYWRIGHT_BROWSERS_PATH` 指过去（后端零改动，上游 `Start.py` 本来就认这个变量）

推荐打包。注意上游对 PyInstaller 场景的约定是 `<exe>/playwright` 且仅当
`sys.frozen` 为真时生效；我们用 venv 不是 frozen，所以走环境变量这条路。

下载命令：

```bash
PLAYWRIGHT_BROWSERS_PATH=runtime/playwright playwright install chromium
```

## 冒烟测试

不启动真实闲鱼链路，用 stub 后端验证最关键的跨 origin 导航：

```bash
bash shell/scripts/smoke.sh
```

预期：窗口从启动加载页切到 `STUB BACKEND OK`，日志里看到
`后端已就绪 url=http://127.0.0.1:<随机端口>`。

stub 后端在 `shell/test/backend.py`，只复现 `/health` 和首页两个端点。

## 已知限制

1. **Windows / Linux 未验证**。跨 origin 导航在 WebKitGTK 上限制较严，Linux 是下一个
   必测项。macOS 已全链路实机验证，见下节。
2. **端口分配有竞态窗口**。`freePort()` 占用后立刻释放，理论上可能被别的进程抢走。
   真被抢了后端会启动失败并写进 `backend.log`，用户可据此排查。
3. **Playwright 子进程清理依赖进程组**（Unix `Setpgid` / Windows `taskkill /T`）。
   只杀 `Start.py` 本体会留孤儿 Chromium。
4. **反检测回归未做**。换成"应用内嵌后端 + WebView"形态后，运行环境特征和纯服务器
   部署不同。`utils/xianyu_slider_stealth.py` 的 UA/字体/WebGL 伪造是针对独立
   Chromium 调的，接真实账号前滑块链路要单独回归一遍。
5. **`global_config.yml` 必须在 `runtime/` 里**。上游从工作目录读这个文件，缺了直接
   读不到配置，预检会拦下来。
6. **WebView 自己的缓存目录**（登录态、localStorage）落在 WebKit 的用户数据目录，
   没有归拢到本壳的数据目录。要卸载不留残留的话得额外处理。
7. **ad-hoc 签名，没过 Notarization**。`codesign --sign -` 只够自己机器跑，
   发给别人会被 Gatekeeper 拦（"无法验证开发者"）。要公开发布得走 Developer ID
   + 公证，那需要 Apple 付费账户。

## macOS 实测结果（已验证）

环境：macOS 15.8.1 Sequoia / arm64 / Go 1.25.12 / Wails v3.0.0-beta.28

以下均在真实 `.app` 包（457M，含内嵌 venv）里验证通过：

| 项 | 结果 |
| --- | --- |
| 跨 origin 导航 | ✅ 加载页 → `http://127.0.0.1:<随机端口>` 成功跳转 |
| bundle 布局 | ✅ 二进制在 `Contents/MacOS/`，壳从 `../Resources/runtime` 找到后端 |
| 内嵌 venv | ✅ 用 `Contents/Resources/runtime/bin/python` 启动，不依赖系统 Python |
| 端口注入 | ✅ `API_PORT` 生效，后端只监听 `127.0.0.1` |
| 工作目录 | ✅ `cmd.Dir` 指向 runtime，`global_config.yml` 读得到 |
| 真实后端 | ✅ SPA / JS / CSS / `/system-settings/public` / SQLite 全部 200 |
| 数据目录 | ✅ `~/Library/Application Support/xianyu-super-butler/`（logs / backups / static/uploads） |
| 进程清理 | ✅ 退出时 Python 进程树被收走 |
| 预检失败 | ✅ 缺 `runtime/` 时显示中文错误页，不静默退出 |
| ad-hoc 签名 | ✅ `codesign --sign -` 成功 |

实测过程中遇到的坑：

- **`iconutil` 在本环境无法生成 icns**——连单张合法 PNG 的 iconset 都报
  `Invalid Iconset`，`sips -s format icns` 也直接失败。疑似沙箱限制而非真实
  macOS 行为，换一台干净机器复验过后再把图标生成写进脚本。
- **链接警告无法消除**。设 `MACOSX_DEPLOYMENT_TARGET=15.0` 和
  `CGO_CFLAGS=-mmacosx-version-min=15.0` 都无效，`LC_BUILD_VERSION.minos`
  仍是 11.0。原因见上方"链接警告"一节。
