# shell — 桌面壳

Wails v3 壳层，给闲鱼智控包一个原生窗口。

**职责边界**：只开窗口、拉起 Python 后端、把窗口导航到后端地址。
所有业务逻辑都在 Python 侧，Go 侧不接触任何业务数据。

```
shell                    ← 本程序
runtime/                 ← 仓库 Python 部分（Start.py / global_config.yml / python-build-standalone）
~/Library/Application Support/xianyu-super-butler/   ← 数据库 / 日志 / 上传
```

## 平台范围

**只做 macOS 和 Windows，不做 Linux 桌面版。**

Linux 从「待验证」降级为「不投入」，不是被搁置的技术难点——Web 版（`python Start.py`
或 Docker）在任何 Linux 机器上都照常可用，桌面壳只是给不愿开浏览器的用户多一个
选择。理由：

- WebKitGTK 的跨 origin 导航限制较严，本壳的加载页 → 后端跳转依赖这个能力，
  Linux 上的行为无法预判，等于多一条要长期跟的验证/维护线。
- Wails v3 的 WebKitGTK 支持仍在 beta，Linux 上要自己跟上游修 bug。
- 现有用户主体是 macOS / Windows 的自部署场景（Docker + 网页），Linux 桌面版的
  需求没有量。

所以 Linux 不纳入待办，也不做 `GOOS=linux` 的构建产物。代码里的 `proc_unix.go`
（`!windows` 约束）和托盘的非 darwin 分支仍然保留——它们对 macOS 同样是生效路径，
删掉反而要重构构建标签。

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

⏳ **待办**：`go.mod` 还在 `beta.28`，最新是 `beta.29`（2026-10-13 发布）。是 nightly
自动发布、间隔仅 8 天，风险低但不是零。建议等托盘那批改动落地、bisect 基线干净之后再升，
单独一个 commit，不要和功能性改动混在一起。

> 实测结论（macOS 15.8.1 / WKWebView）：从 Wails `HTML` origin 跳转到
> `http://127.0.0.1:<随机端口>` 的跨 origin 导航**通过**。Linux WebKitGTK
> 已明确不投入（见「平台范围」），不是待办项。

### 为什么不迁到 Tauri

结论：**继续用 Wails，不迁。** 决定因素不是「哪个框架更强」，是「要不要给桌面壳
做正式发布」。

Tauri v2 在两点上确实更好：

- **稳定性**。Wails v3 至今仍是 beta（`beta.29` 于 2026-10-13 发布），而 `WebviewWindowOptions.URL`
  这个本壳赖以成立的能力在稳定版 v2 里**根本不存在**——等于把发布基线绑死在一个未转正的分支上。
  Tauri 的 `WebviewUrl::External(Url)` 从 2.0 起就是稳定枚举变体，已经走了两年半。
- **发布工程**。Tauri 的 bundler 原生支持 `bundle.macOS.signingIdentity` + 公证，
  能替换掉本目录手写的 `build-macos.sh` 和 ad-hoc 签名（见「已知限制」#7）。

但没选它，因为：

1. **sidecar 是为 PyInstaller 单文件二进制设计的**（`binaries/<name>-<target-triple>` 命名），
   而本壳嵌的是**完整 venv 目录树 + Playwright Chromium**。要把 venv 的 python 按 target
   triple 伪装成 sidecar，`PLAYWRIGHT_BROWSERS_PATH` 在 `.app` 内能否正确解析得重新验证，
   457MB 目录树走 `bundle.resources` 官方文档也没有示例。**风险恰恰落在文档覆盖最薄的地方。**
2. 迁过去，macOS 十项实机验证（bundle 布局、内嵌 venv、端口注入、`cmd.Dir`、真实后端
   全 200、进程树清理……）**每一项都要重跑**。
3. Tauri 的常规优势在本项目上都不成立：体积（包 457MB，壳占比 <1%）、内存（两者都用
   系统 WebView，不打包 Chromium）、跨平台（Linux 已砍，见「平台范围」）、
   Rust 核心（业务数据走 HTTP，壳不接触数据）。

**重新评估的条件**：一旦要给桌面壳做正式发布（Developer ID 签名 + 公证 + 自动更新 +
分发 dmg），就重新拿 Tauri 的 bundler 对比一次。在那之前 Wails beta 基线是可接受的
已知约束。

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
```

Linux 不构建，见上方「平台范围」。

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

包内自带 python-build-standalone 时，Python 路径是
`Contents/Resources/runtime/python/bin/python`，
壳的 `pythonBin()` 会优先找到它，不依赖用户系统 Python。

#### 应用图标

```bash
bash shell/scripts/make-icon.sh                     # 默认用 static/favicon.svg
bash shell/scripts/make-icon.sh path/to/logo.svg
```

管线：`qlmanage` 把 SVG 渲成 1024×1024 PNG → `sips` 缩出标准 10 档 →
`iconutil` 合成 icns。产物在 `shell/out/AppIcon.icns`，`build-macos.sh` 没收到
图标参数时会自己调这个脚本。

⚠️ **iconset 目录名必须以 `.iconset` 结尾**，否则 `iconutil` 报
`Invalid Iconset.`。这个报错信息完全没提目录名，排查了很久。对照实验：
同一批逐字节相同的 PNG，目录名 `iconset` 失败、`a.iconset` 成功。
`icon_64x64.png` 这类非标准条目名也不要放进来。三个工具都是 macOS 自带的，
不用额外安装。

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
    ├── python/          # python-build-standalone，自带解释器和 site-packages
    ├── Start.py
    ├── global_config.yml
    ├── app/  utils/  frontend/dist → static/ ...
```

`runtime/` 不在版本库里（见 `.gitignore`），是分装时拼出来的。

### Playwright 浏览器：要么打包，要么忍受首启联网下载

后端启动时会检查 Playwright 浏览器，缺了就自动下载（`Start.py:147` 的
`_check_and_install_playwright()`），默认走 `cdn.npmmirror.com` 镜像。这意味着：

- **不打包** → 首次启动要联网下 Chromium，离线环境直接不可用
- **打包** → 放进 `runtime/playwright/chromium-*/`，壳会自动设置
  `PLAYWRIGHT_BROWSERS_PATH` 指过去（后端零改动，上游 `Start.py` 本来就认这个变量）

推荐打包。注意上游对 PyInstaller 场景的约定是 `<exe>/playwright` 且仅当
`sys.frozen` 为真时生效；我们内嵌的是解释器不是 frozen bundle，所以走环境变量这条路。

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

1. **Windows 未验证**。macOS 已全链路实机验证，见下节。Linux 不是待办项，
   见「平台范围」。
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

以下均在真实 `.app` 包里验证通过（该次是 venv 布局，457M；后来迁到
python-build-standalone，布局变为 `runtime/python/`，见下方说明）：

| 项 | 结果 |
| --- | --- |
| 跨 origin 导航 | ✅ 加载页 → `http://127.0.0.1:<随机端口>` 成功跳转 |
| bundle 布局 | ✅ 二进制在 `Contents/MacOS/`，壳从 `../Resources/runtime` 找到后端 |
| 内嵌 Python | ✅ 用 `Contents/Resources/runtime/python/bin/python` 启动，不依赖系统 Python |

> 该表验证时是 venv 布局（`runtime/bin/python`）。后来迁到 python-build-standalone，
> 原因：venv 的绝对符号链接（`bin/python3 -> 构建机的 Python`）让
> `codesign --verify --deep --strict` 报 `invalid destination for symbolic link
> in bundle`，签名永远无效；而 pystand 0 个绝对符号链接，签名校验通过。
| 端口注入 | ✅ `API_PORT` 生效，后端只监听 `127.0.0.1` |
| 工作目录 | ✅ `cmd.Dir` 指向 runtime，`global_config.yml` 读得到 |
| 真实后端 | ✅ SPA / JS / CSS / `/system-settings/public` / SQLite 全部 200 |
| 数据目录 | ✅ `~/Library/Application Support/xianyu-super-butler/`（logs / backups / static/uploads） |
| 进程清理 | ✅ 退出时 Python 进程树被收走 |
| 预检失败 | ✅ 缺 `runtime/` 时显示中文错误页，不静默退出 |
| ad-hoc 签名 | ✅ `codesign --sign -` 成功 |

实测过程中遇到的坑：

- **`iconutil` 的 `Invalid Iconset.` 报错是假象**。真因是 iconset 目录名必须
  以 `.iconset` 结尾，报错信息本身完全没提目录名。当时误判为沙箱限制，
  后来用逐字节相同的 PNG 做目录名对照实验才定位到。已写入
  `scripts/make-icon.sh`，图标管线现在可用。
- **链接警告无法消除**。设 `MACOSX_DEPLOYMENT_TARGET=15.0` 和
  `CGO_CFLAGS=-mmacosx-version-min=15.0` 都无效，`LC_BUILD_VERSION.minos`
  仍是 11.0。原因见上方"链接警告"一节。

## 托盘与关窗语义（实测）

实测日期：2026-10-14，macOS 15.8.1 / arm64 / Go 1.25.12 / Wails v3.0.0-beta.28

> ⚠️ **本轮跑的是工作区代码，不是提交态。** `.app` 的启动日志里
> `vcs.revision=474153c` 但 `vcs.modified=true`——`tray.go` 和 `main.go` 里的
> 托盘改动当时还没提交就编进去了。复现这个结果需要先 `git stash list` 看清楚。

### 已通过

| 项 | 证据 |
| --- | --- |
| 图标 template 合规 | `tray_template.png` 44×44，**唯一 RGB 值 = (0,0,0)**，非纯黑像素 0 个。纯黑+alpha 是 template 的硬要求，否则深浅色菜单栏反色会出问题。截图确认深色菜单栏下「闲」字形正确反白 |
| 隐藏到后台 | Cmd+W → `shell.log` 出现 `窗口关闭 → 隐藏到后台` + `Window hiding`，AX 窗口数 `1 → 0`。连按两次幂等 |
| 托盘唤回 | 点托盘 → AX 窗口数 `0 → 1`，**同一个窗口对象**，没重跑加载页的 `/health` 轮询。SPA 登录态/筛选/展开面板全保留 |
| 后端存活 | 隐藏/唤回全程 `python Start.py` 不退出，消息监听不打断 |
| 干净退出 | 走「退出」路径时依次 `后端进程退出 err="signal: terminated"` → `后端进程已停止`。无孤儿进程、端口已释放、`DiagnosticReports` 无 crash |

图标内容包围盒 x[4,39] y[3,41]，宽度占画布 81.8%、**高度 88.6%**。菜单栏图标
惯例是 70–80%，88% 贴得太紧。次要视觉问题，`static/tray.svg` 里
`font-size="20.5"` 调小一点即可。

### 托盘菜单（人工点，已验证）

| 项 | 结果 |
| --- | --- |
| 右键弹菜单 | ✅ 三项都在：显示窗口 / ─ / 打开数据目录 / 退出 |
| 左键 | ✅ 唤回窗口，不弹菜单 |
| 关窗后再唤回 | ✅ 登录页 / 筛选状态保留 |
| 打开数据目录 | ✅ Finder 跳到 `~/Library/Application Support/xianyu-super-butler/` |
| 点「退出」 | ✅ `后端进程退出 err="signal: terminated"` → `后端进程已停止`。无孤儿进程、端口已释放、无 crash |
| 图标观感 | ✅ 高度占画布 88.6% 略高于菜单栏惯例的 70–80%，实机看可接受，暂不改 |

**上一轮用命令行测出的「菜单弹不出来」是测试手段的问题，不是产品 bug。**
合成右键事件不可靠：Wails beta.28 的 `systemtray_darwin.h` 里就有一个
`systemTrayCoerceEventType(rawEventType, pressedMouseButtons)`，注释写着
`See #5752 rationale`——Wails 自己对 status item 的右键识别就补过一个 hack。

**以后别用 CGEvent 合成点击去验证托盘**，直接用真鼠标。

**取舍：为什么不 attach window。** 官方 `examples/systray-menu` 用的是
`systemTray.AttachWindow(window)` + `SetMenu(...)`，这里故意不用 `AttachWindow`、
改成手动 `OnClick → showWindow`。查了 beta.28 源码，`applySmartDefaults()` 只赋
`ToggleWindow` 和 `ShowMenu`，**没有任何平台有"失焦自动隐藏"**（`justClosed` 那处
判断只包在 `if runtime.GOOS == "windows"` 里）——所以之前注释里写的理由是错的，
真正的理由只是语义明确：这个 App 点击永远只唤回，`ToggleWindow` 的"再点一次隐藏"
不是想要的行为（用户点错一下就看不见窗口了）。

### 读源码时发现的三件事

1. **`openMenu()` 失败是静默的**：
   ```go
   func (s *macosSystemTray) openMenu() {
       if s.nsMenu == nil { return }   // 不报错、不打日志
       C.showMenu(s.nsStatusItem, s.nsMenu)
   }
   ```
2. **菜单创建时机脆弱**：`Menu.Update()` 在 `app.running == false` 时直接 return、
   不建 impl。而 `setupTray()` 是在 `app.Run()` **之前**调的（`runOrDeferToAppRun`
   会延迟创建），所以 tray 的 impl 一开始是 nil、`SetMenu` 只把值存进 Go 结构体。
   菜单全靠 `macosSystemTray.run()` 里那句回放建立起来。整条链路任何一环断掉，
   表现就是「菜单静默消失」——**没有日志可查**，只能靠人工点。
3. **`tray_color.png` 不在 macOS 二进制里**：字节匹配 0 次，被 linker 当死代码消掉
   了（`runtime.GOOS == "darwin"` 编译期常量折枝）。功能上没问题（macOS 走 template），
   但**这个分支是零验证的死代码**，跟「已知限制」#1 的 Windows 未验证是同一件事。
   别拿 macOS 产物去判断非 darwin 路径的对错。

