**最终选型（2026-11-12 实测定案）：`webview_all` 1.5.0**

**一套 API 覆盖 6 平台，各平台一律使用系统自带内核，不打包任何浏览器内核。**

| 平台 | 系统内核 | 说明 |
| --- | --- | --- |
| Windows | WebView2 | 系统 Runtime（Win11 预装） |
| Linux | **WebKitGTK** | native 侧 `pkg_check_modules(WEBKIT REQUIRED IMPORTED_TARGET webkit2gtk-4.1)`，直接链接系统库 |
| macOS / iOS | WKWebView | 系统内核 |
| Android | Android WebView | 系统内核 |
| Web | js-interop | 浏览器原生 |

为什么是它（逐项实测依据）：

1. **零内核**：容器内 `ldd libwebview_all_linux_plugin.so` 实际输出
   `libwebkit2gtk-4.1.so.0 => /lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0`——链接的是**系统库**，
   产物仍为 **83 MB**（未增加内核体积）。这直接满足约束 C1。
2. **可内嵌**：其 Linux 实现用 `gtk_overlay_add_overlay(overlay, container)` 把 WebKitWebView
   叠到 Flutter 的 GTK overlay 上，**不是独立窗口**，插件岛 / 伙伴小屋 / Mermaid 都能用。
   （对比 `atomic_webview`：桌面端明确是「run in their own native window」，满足不了内嵌。）
3. **API 与 `webview_flutter` 同形**：`WebViewController` / `WebViewWidget` / `NavigationDelegate`
   签名逐个比对过，迁移成本低。
4. **质量**：pub 评分 **160/160 满分**，MIT，40 小时前发布，20K+ star 项目在用
   （PiliPlus、Miru、SubDock、OpenHarness 等）。

**已被否掉的方案**：

| 方案 | 否决理由 |
| --- | --- |
| `webview_windows` 0.4.0 | 2 年未更新，有窗口焦点丢失缺陷（issue #230），且仅 Windows |
| `webview_flutter_windows` 1.3.1 | 上游 fork，质量尚可，但只覆盖 Windows，仍需为 Linux 另找方案 |
| `flutter_inappwebview_linux` | 走 **WPE WebKit**，构建时把 `libWPEWebKit-2.0.so`（约 160 MB）拷进 App 的 `lib/`，**等于随包带内核** |
| `atomic_webview` | 系统内核符合约束，但桌面端**开独立窗口**，无法内嵌 |
| QtWebEngine 绑定 | 内核即 Chromium；KDE 通常只有运行库无 `-dev` 头文件；GTK+Qt 双事件循环风险高 |
| 自写 GTK 通道 | 退路。`webview_all` 已满足需求，不需要自己写 300–500 行 C++ |
| 外部浏览器降级 | 保底路径，非主方案 |

**迁移结果（已落地，提交 `841d648`）**

- 删除 3 个临时适配层，共 **568 行死代码**：
  `system_webview.dart`(188) / `system_webview_flutter.dart`(119) / `system_webview_win.dart`(261)
- 新增 `ui/web/webview_common.dart`，只收口 3 个平台差异：
  `androidWebViewIdOf()` / `denyAllPermissions()` / `decisionFrom()`
- 6 个业务文件直接使用 `webview_all` 的同名类型。

**API 差异（已逐个对照 pub-cache 源码修正，非猜测）**

| 差异点 | webview_flutter | webview_all |
| --- | --- | --- |
| 导航决策 | 回调返回 `bool` | 返回 `NavigationDecision`（`navigate` / `prevent`） |
| 主框架判定 | `WebResourceError.isMainFrame`（非空） | `isForMainFrame`（**可空**，`?? true`） |
| JS 通道 | 位置参数 `(name, callback(String))` | 命名参数 `onMessageReceived: (JavaScriptMessage m)` |
| Android 原生 id | `AndroidWebViewController.webViewIdentifier` | 同（来自 `webview_all_android`），需 `controller.platform is AndroidWebViewController` |

**构建环境要求（NAS 容器）**：必须安装 **`libwebkit2gtk-4.1-dev`**（镜像 `dsh-go-linux-builder:2` 已含）。
没有它时 CMake 会在 `pkg_check_modules` 处直接报
`The following required packages were not found: webkit2gtk-4.1`。

**已验证 / 未验证**

| 项 | 结果 |
| --- | --- |
| `flutter analyze lib` | ✅ 无 error（22 条 info 级，均为既有 deprecation） |
| `flutter build linux --release` | ✅ 通过，产物 83 MB |
| 链接系统 WebKitGTK | ✅ `ldd` 确认指向 `/lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so.0` |
| Windows 侧编译 | ❌ **未验证**（本机无 Flutter SDK） |
| `?token=` → 303 → `dsh-auth` cookie 链路 | ❌ **未在真机 WebView 验证**（最高优先级 PoC） |
| Linux 桌面实际运行（KDE / GNOME） | ❌ **未验证**（容器无桌面） |
# DSH Go 桌面三端移植方案（Windows / Linux）

> 基线：本仓库 `1.0.21`（提交 `360c45f`），即 **DSH Go 的 macOS 移植版**。
> 目标：在**不重写 UI** 的前提下，把同一份 `app/lib` 带到 Windows 与 Linux，形成 macOS /
> Windows / Linux 三端同源的桌面版。
>
> 本文是移植计划，不是已完成状态。每一节末尾的「出口标准」写的是完成该节后能跑出什么结果。

## 0. 硬性约束（本方案的前提）

| # | 约束 | 落地方式 |
| --- | --- | --- |
| C1 | WebView **必须用系统自带内核**：Windows = WebView2，Linux = WebKitGTK | 见「阶段 3：WebView」。禁止打包 CEF / Chromium |
| C2 | 其余平台能力**尽量用原生实现** | 见「阶段 2：平台通道实现」。通知、窗口、文件、托盘一律走原生 API |
| C3 | 托盘**必须用原生系统托盘** | 见 4.2.1。Windows `Shell_NotifyIcon`；Linux `StatusNotifierItem` |
| C4 | Linux **优先支持 KDE 与 GNOME** 两种桌面环境 | 见「阶段 2 › 4.2.1 托盘」。SNI 为两者共同路径，GNOME 无扩展时降级 |

---

## 1. 结论先行

| 项 | 判断 | 依据 |
| --- | --- | --- |
| 能否跨平台 | **能，且成本可控** | UI 层零改动；平台交互全部收敛在 MethodChannel，且 Dart 侧有 105 处容错 |
| 主要工作量 | **平台接线层 + 系统 WebView 适配** | 参照物是现成的 2100 行 Swift |
| 最大风险 | **系统 WebView 的接口/回环 cookie 行为** | 需 PoC 验证；失败则 Web 模式退化为外部浏览器 |
| 次高风险 | **本机引擎运行时产物** | 需要为 win-x64 / linux-x64 各产一份 Node + DSH 树 |
| 体积约束 | **不打包任何浏览器内核** | 安装包体积与 macOS 版同量级（约 200–300 MB，主体是 Node 运行时） |
| 不建议 | 重写成 Electron/Tauri | 会丢掉 32 万行已打磨的 Flutter 界面 |

一句话：**这是一次「平台适配」而不是「重写」**，但需要接受 WebView 相关的四个功能要单独适配。

---

## 2. 现状测绘

### 2.1 代码构成

| 层 | 位置 | 规模 | 移植影响 |
| --- | --- | --- | --- |
| Flutter UI | `app/lib` | 802 个 Dart 文件，约 32 万行 | **不改** |
| macOS 原生层 | `app/macos/Runner/*.swift` | 9 个文件，约 2100 行 | **逐行参照重写** |
| macOS 接入层 | `app/lib/macos/` | 12 个文件，约 2400 行 | 绝大部分可复用 |
| 本机引擎运行时 | `runtime/build-runtime-macos.sh` + `runtime/patches/*.diff` | 157 行脚本 + 105 个补丁 | 换 Node 目标产物 |
| 桥接包 | `packages/dsh_client`、`packages/dsh_remote` | 纯 Dart，无 Flutter 依赖 | **不改** |
| DSH 侧桥 | `runtime/bridge/dsh-go-bridge` | 纯 JS（`type: module`） | **不改** |

### 2.2 关键数字（已实测）

```
Dart                         802 个文件 / 321,672 行
Swift                        9 个文件   / 2,089 行
Platform.isMacOS             9 处       （isWindows 0 处，isLinux 1 处）
MethodChannel                29 个
invokeMethod 调用点          69 处
MissingPluginException 容错  105 处
```

**这组数字是整个方案的立足点**：平台分叉极少，且「原生缺席」是被显式设计过的降级路径。

### 2.3 为什么选 Flutter 而不是重写

原项目（Android 版 `ccch1mneyyy/dsh-go`）就用 Flutter + Kotlin 插件。macOS 移植版选择
「只新增平台目标 + 换掉原生实现」，没有动 `lib/` 一行 UI。这个策略对 Windows/Linux 同样成立。

---

## 3. 移植策略：沿用在 macOS 已被验证的三条缝

macOS 版成功的关键是**三条清晰的接缝**。Windows/Linux 直接复用：

### 缝 1：引擎注入点（唯一需要动的业务代码）

`app/lib/main.dart:44-62`

```dart
final macRuntime = isMacDesktop ? MacRuntimeBridge(official: officialDsh) : null;
// ...
if (macRuntime != null) runtimeBridgeProvider.overrideWithValue(macRuntime),
if (macRuntime != null) macRuntimeBridgeProvider.overrideWithValue(macRuntime),
```

`MacRuntimeBridge` 实现 `RuntimeBridge` 接口（`app/lib/runtime/runtime_bridge.dart`）。
**新平台只需再写一个 `DesktopRuntimeBridge`，在同一处注入**，上层状态与界面零改动。

### 缝 2：平台通道（新增原生实现）

Dart 侧调用 `MethodChannel('dsh/xxx')`；原生缺席时抛 `MissingPluginException`，Dart 侧
已有 105 处捕获，表现为功能不可用而非崩溃。因此**平台层可以分阶段补，不必一次到位**。

### 缝 3：构建产物（Node 运行时）

运行时 = 官方 Node + `npm ci` 装好的 DSH 依赖树 + pnpm + `dsh-go-bridge`。
`build-runtime-macos.sh` 里 Node 只有一处带平台名（`node-v$VERSION-darwin-arm64.tar.gz`），
**换平台标识即可**；105 个 DSH 补丁基本平台无关（仅 1 处显式判 `win32`）。

---

## 4. 分阶段计划

### 阶段 0：环境与骨架（1–2 天）

**做什么**

1. 装 Flutter **3.47.x**（Dart 3.13.5）。`tooling/setup-toolchain.sh` 装的是 Linux 版，Windows 需手动装并开 Developer Mode（Flutter 建符号链接需要）。
2. 在 `app/` 下生成平台骨架：
   ```bash
   cd app
   flutter create --platforms=windows,linux --project-name dsh_app .
   ```
   > 在 `app/` 内执行；先备份 `pubspec.yaml`，确认 `flutter create` 没有覆盖它。
3. 把 `isMacDesktop` 泛化为 `isDesktop`（`app/lib/macos/macos_support.dart:23`）：
   ```dart
   bool get isDesktop => !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
   ```
   同时保留 `isMacDesktop` 用于 macOS 专属功能（Peekaboo、菜单栏、竖屏版式菜单）。
4. 把 `app/lib/macos/` 重命名为 `app/lib/desktop/`，`mac_runtime.dart` 改名 `desktop_runtime.dart`。
   **这一步会改约 24 处引用**（`isMacDesktop`/`macTextActive` 的调用点），是唯一一次大范围文本改动。

**出口标准**：`flutter analyze` 在 Windows 上 0 error；`flutter build windows --debug` 能出 exe；
应用能在无任何平台通道实现的情况下启动到首屏（功能降级但不崩）。

**注意**：此时 `main.dart` 的 `runtimeBridgeProvider` 仍会注入 `MacRuntimeBridge`，
它内部调 `/usr/bin/tar`、`/usr/bin/du` 等 macOS 命令，在 Windows 上会失败。
阶段 1 之前可先让它抛「未实现」走降级路由。

### 阶段 1：本机引擎（Windows 优先，3–5 天）

这是**能让应用真正可用**的最小闭环，优先级最高。

**1.1 运行时产物**

新增 `runtime/build-runtime-desktop.sh`，参数化平台与架构：

| 目标 | Node 发行版 | 产物名 |
| --- | --- | --- |
| Windows x64 | `node-v24.22.1-win-x64.zip` | `runtime-win-x64.tar.gz` |
| Linux x64 | `node-v24.22.1-linux-x64.tar.xz` | `runtime-linux-x64.tar.gz` |

要点：

- Windows 的 Node 目录布局不同：`node.exe` 在根目录（不是 `bin/node`），`npm.cmd` 而非 `npm`。
  启动 argv 要从 manifest 读，**不要硬编码 `bin/node`**（macOS 版已是读 manifest，沿用即可）。
- `npm ci` 在 Windows 上要处理 `.cmd` 脚本；锁文件在 `runtime/locks/dsh-<version>/`，可直接复用。
- 若 Windows 上 `npm ci` 因平台相关的 optionalDependencies（如 `node-pty`）需要重编译，
  优先选**预编译产物**；实在不行再走 VS Build Tools 编译（本机已有 MSVC）。
- 产物 `.gitignore`（约 190 MB/份），从锁文件可重建。

**1.2 `desktop_runtime.dart` 去 macOS 化**

需要抽象的 6 个硬编码点：

| 位置 | 原调用 | Windows 替代 | Linux 替代 |
| --- | --- | --- | --- |
| `mac_runtime.dart:389` | `Process.start('/usr/bin/tar', ['-xzf', …])` | 内置 `package:archive` 解压，或 `tar.exe -xzf`（Win10+ 自带） | `tar -xzf` |
| `mac_runtime.dart:396` | `/usr/bin/du -sk` | 递归求文件大小总和 | `du -sk` |
| `mac_runtime.dart:633` | `/usr/bin/xattr -dr com.apple.quarantine` | **不需要**（无 Gatekeeper） | **不需要** |
| `mac_runtime.dart:864` | `/usr/bin/uname -m` | `Platform.version` / `PROCESSOR_ARCHITECTURE` | `uname -m` |
| `macos/phone_link_page.dart:61` | `/usr/bin/open` | `ShellExecute` 或 `url_launcher` | `xdg-open` |
| `macos/official_dsh.dart:89` | `/usr/sbin/lsof` | `netstat -ano` 解析，或直接探测候选端口 | `ss -ltnp` / `/proc/net/tcp` |

建议：把「解压 / 算大小 / 查架构 / 查监听端口 / 打开外部链接」收进一个
`PlatformServices` 抽象类，按平台给实现，`desktop_runtime.dart` 只依赖抽象。
这样 macOS 分支行为不变，Windows/Linux 各写各的。

**1.3 官方 DSH 直连（可选）**

macOS 通过 `~/.dsh/.credentials.yaml` 的会话密钥签 cookie 直连本机官方 DSH。
Windows/Linux 上若用户装了官方 DSH，同理适用——但**列为阶段 1 的可选项**，
先把「内置引擎」跑通再谈。

**出口标准**：Windows 上装运行时 → 启动 → 日志出现
`dsh web: http://127.0.0.1:<port>/?token=…` → 状态变运行中 → 能发一条消息收到流式回复。

> 这一步可以先用**无头探针**验证（参照 `app/lib/dev/macos_runtime_probe.dart`）：
> 不点 UI，直接跑引擎链路，输出 `PROBE OK`。

### 阶段 2：平台通道实现（Windows 5–8 天，Linux 5–8 天）

按「对日常使用的影响」排序，先做 P0。

#### P0：不做就没法用

| 通道 | Dart 侧 | macOS 参照 | Windows | Linux |
| --- | --- | --- | --- | --- |
| `dsh/notify` + `/taps` + `/actions` | `notify/notify_channel.dart` | `MacNotify.swift` | WinToast / `windows_notification`，需支持按钮回调 | `libnotify` / `org.freedesktop.Notifications` DBus |
| `dsh/window` + `/events` | `macos/window_mode.dart` | `MacHost.swift` | `window_manager` 或 native | 同左 |
| `dsh/files` | `state/artifacts.dart` | `MacFiles.swift` | 直接文件 IO + `ShellExecute` | 直接文件 IO + `xdg-open` |
| `dsh/media` | `media/gallery.dart` | `MacFiles.swift` | 存到 `%USERPROFILE%\Pictures\DSH Go` | `~/Pictures/DSH Go` |

`dsh/files` 的 `pdfInfo`/`pdfPage`（PDF 渲染成 PNG）在 macOS 用 PDFKit。
Windows 可用 **PDFium**（`pdfrx` 包，纯 Dart 绑定）或 MuPDF；Linux 同样。
**建议直接换成 `pdfrx` 这类 Dart 包**，绕开原生实现。

#### P1：严重影响体验

| 通道 | Dart 侧 | 说明 |
| --- | --- | --- |
| `dsh/menubar` | `macos/menu_bar.dart` | 状态栏胶囊，**必须用原生系统托盘**（见 4.2.1）。Windows → `Shell_NotifyIcon`；Linux → `StatusNotifierItem`（KDE Plasma / GNOME 均原生） |
| `dsh/pet_overlay` | `pets/overlay_channel.dart` | 桌宠浮窗（无边框置顶）：`push`/`status`/`setEnabled`/`setAlwaysShow` 等。Windows → 独立 `WS_EX_LAYERED \| WS_EX_TOPMOST` 窗口；Linux → Wayland 下受限，X11 可用 |
| `dsh/voice` + `/events` | `ui/chat/voice/voice_bridge.dart` | `requestPermission`/`startRecognizer`/`startRecorder`/`stop`/`cancel`。Windows → `System.Speech` 或 Whisper 本地；Linux → 无系统级识别，建议只做录音 |

#### P2：锦上添花 / 按不适用处理

| 通道 | 处理建议 |
| --- | --- |
| `dsh/links`（深链 `dshgo://`） | Windows 注册 URL scheme（注册表）；Linux 写 `.desktop` |
| `dsh/update` | `canRequestInstalls` 返回 false；走安装包手动更新（与 macOS 一致） |
| `dsh/diagnostics`、`dsh/app`（时区/OS 版本） | 简单实现，返回真实值 |
| `dsh/launch`、`dsh/launch_clip`、`dsh/shortcuts`、`dsh/launcher_icon`、`dsh/picture_shortcut`、`dsh/dynamic_color`、`dsh/performance`、`dsh/islands`、`dsh/share`、`dsh/web-files`、`dsh/usage`、`dsh/phone`、`dsh/companion_voice`、`dsh/companion_widget`、`dsh/native-files`、`dsh/native-media` | **照抄 `MacStubs` 的做法**：注册通道，返回明确的「不支持」答复，而不是 `MissingPluginException`。界面会自动隐藏入口 |
| `dsh/mac_peekaboo` | **明确不适用**。Windows 若要「操控本机」，需另做基于 UIAutomation + 屏幕捕获的方案，不在本轮 |

**实现语言建议**

- **Windows**：C++（`windows/runner/`，Flutter 模板自带的 Win32 + CMake 工程）。C++ 直连 Win32 API 最省事，且不引入额外运行时。
- **Linux**：C++（GTK，`linux/runner/`）直连 GTK / DBus / StatusNotifierItem，**不依赖第三方 tray 包**，以便精确控制 KDE / GNOME 两种桌面的差异。

**出口标准**：P0 全绿；P1 中至少 `dsh/menubar`、`dsh/pet_overlay` 可用；其余通道返回明确不支持。

#### 4.2.1 托盘：必须用原生系统托盘（硬性约束）

**约束**：不使用任何自带 UI 渲染的「自绘托盘」（如在某些平台上用 Flutter 窗口模拟托盘）。
一律走各系统的原生托盘 API，由系统负责渲染、主题、DPI 与位置。

| 平台 / 桌面 | 原生机制 | 说明 |
| --- | --- | --- |
| Windows | `Shell_NotifyIcon`（`NOTIFYICONDATA`） | 原生托盘，随系统 DPI 缩放；气泡菜单用 `CreatePopupMenu` |
| KDE Plasma | `org.kde.StatusNotifierItem`（DBus，经 `StatusNotifierWatcher`） | Plasma 原生支持，是 Plasma 的**一等公民** |
| GNOME | 同一套 `StatusNotifierItem` D-Bus 规范 | GNOME 需装 **AppIndicator 扩展**（`gnome-shell-extension-appindicator`，多数发行版 GNOME 桌面默认预装）；没有扩展时需探测并降级 |

**Linux 实现要点（KDE 与 GNOME 双优先）**

1. **统一走 StatusNotifierItem over D-Bus**，而不是 `XEmbed`（legacy）——KDE 与 GNOME 都优先支持 SNI。
2. **运行时探测**：检查 `org.kde.StatusNotifierWatcher` 是否在会话总线上；
   - 存在 → 注册 SNI item；
   - 不存在（GNOME 无扩展）→ 降级：不显示托盘，把「引擎/回合/待批准」状态改为在窗口标题栏内呈现，
     并在设置页提示「安装 AppIndicator 扩展可启用托盘」。
3. **GNOME 另有原生入口**：通过 `org.gnome.Shell.Extensions` 无法绕过扩展限制，
   **不要**尝试自己实现 GNOME 顶栏图标（不可行）。降级路径才是正解。
4. KDE 上额外验证：SNI 的 `ContextMenu`（右键菜单）、`Activate`（左键点击）、
   `NewIcon`/`NewTitle`（状态更新）三个信号。
5. 图标资源：SNI 走 `IconName`（主题图标名）或 `IconPixmap`（ARGB 原始像素）。
   **优先 `IconName` + 自带 hicolor 主题图标**，避免高分屏模糊；动态状态色用 `IconPixmap`。

**工程组织**：Linux 侧建议单独做一个 `linux/tray.cc`，内部抽象
`TrayBackend { SniBackend, XEmbedBackend }`，与 Dart 的 `dsh/menubar` 通道对接。

### 阶段 3：WebView（用系统内核，2–4 天/平台）

**硬性约束：只使用系统自带的 WebView 内核，不打包任何浏览器内核。**

| 平台 | 系统内核 | 获取方式 |
| --- | --- | --- |
| Windows | **WebView2**（Microsoft Edge WebView2 Runtime） | Windows 11 预装；Win10 需分发 Evergreen Bootstrapper（约 1.5 MB，安装时才下载内核） |
| Linux（GNOME） | **WebKitGTK**（`webkit2gtk-4.1`） | GNOME 桌面的基础依赖，几乎必然已安装 |
| Linux（KDE） | **WebKitGTK** | KDE 不自带 WebKit，需依赖 `webkit2gtk-4.1`；`.deb`/`rpm` 里声明依赖，AppImage 需在文档里提示安装 |

**明确排除的方案**（因违反「不携带过大内核」约束）：

| 方案 | 排除原因 |
| --- | --- |
| `webview_cef` / 任何 CEF 绑定 | 自带约 150 MB Chromium 内核 |
| Electron / Tauri（WebView 之外） | 不在本方案内 |
| 打包 Chromium | 体积与更新负担 |

**候选实现（2026-11-12 实测更新）**

| 方案 | Windows | Linux | 结论 |
| --- | --- | --- | --- |
| `webview_windows`（WebView2） | ✅ | ❌ | **Windows 采用**。薄封装系统 WebView2，零内核打包 |
| `flutter_inappwebview` + `_linux` | ✅（WebView2） | ❌ **已排除** | Linux 实现走 **WPE WebKit**（不是 WebKitGTK），构建时把 `libWPEWebKit-2.0.so`（约 160 MB）拷进 App 的 `lib/`，**等于随包带内核**，违反约束 C1。NAS 容器实测报 `CMake Error: WPE WebKit not found` |
| `atomic_webview` 0.2.0 | ✅ | ✅（系统 webkit2gtk-4.1） | 符合「零内核」，**但桌面端是独立原生窗口，不是内嵌 widget**，满足不了插件岛/伙伴小屋 |
| 自写 GTK 通道包 `WebKitWebView` | — | ✅ | 同工具包（GTK 嵌 GTK），约 300–500 行 C++，**Linux 完整方案** |
| 外部浏览器降级 | ✅ | ✅ | 零成本保底，**当前 Linux 采用** |

> **WPE vs WebKitGTK 选型说明**（回答「WPE 有多大 / 谁兼容性更好」）：
> 两者是**同一份 WebKit 源码的两个前端**，核心库体积同量级（150–200 MB），WPE 并无体积优势。
> WPE 面向嵌入式/kiosk，**中文输入法、剪贴板、文件对话框都要自己接**，且发行版基本不提供 dev 包，
> 需自行编译并自行跟安全更新；WebKitGTK 是桌面版，是 GNOME 的基础依赖，上述能力全部成熟，
> 并随发行版更新。**结论：WebKitGTK 全面更优，WPE 完全不适用于本项目。**

> **QtWebEngine 为什么不做**（KDE 用 Qt，是否可复用）：QtWebEngine 内核即 Chromium（
> ~150–200 MB）；KDE 发行版通常只装运行库、没有 `-dev` 头文件；且需在 GTK 的 Flutter runner
> 里混入 Qt 事件循环，属跨工具包嵌入，风险与工作量远高于自写 WebKitGTK 通道。**不采用。**

**实现现状（本轮已落地）**

1. 新建 `app/lib/ui/web/system_webview.dart`：统一抽象（`SystemWebViewController` /
   `SystemWebViewNavigationDelegate` / `createSystemWebViewController()`），按平台分发：
   - macOS / Android / iOS → `system_webview_flutter.dart`（`webview_flutter`）
   - Windows → `system_webview_win.dart`（`webview_windows` → WebView2）
   - Linux → **返回 null**，`systemWebViewBackend == unavailable`，调用方降级
2. 6 个业务文件（`web_view_page`、`island_handle`、`companion_stage`、`mermaid_preview`、
   `web_view_guard`、`web_file_chooser`）改为经抽象取 controller，**不再直接 `WebViewController()`**。
3. `pubspec.yaml` 已移除 `flutter_inappwebview*`，保留 `webview_windows: ^0.4.0`。
4. 新增 l10n key `webNoEmbeddedBrowser`（zh/en）。

**已验证**：NAS 容器内 `flutter analyze lib` 无 error；`flutter build linux --release` 通过，
产物 `build/linux/x64/release/bundle/` **83 MB**（未含任何浏览器内核，印证约束 C1）。
**未验证**：Windows 侧未编译（本机无 Flutter SDK）；`?token=`→cookie 链路未在真机 WebView 验证。

**关键验证点**：DSH Web 页面依赖 `?token=` → 303 → `dsh-auth` cookie。要确认：
WebView2 / WebKitGTK 对 `http://127.0.0.1` 回环地址**保留 cookie**，并把它当作安全上下文。
这是 Web 模式能否工作的前提，PoC 必须先过这一关。若失败，退化到外部浏览器打开
`http://127.0.0.1:<port>/?token=…`（token 一次性，需每次重新取）。

#### 4.3.1 Linux 双版本 AppImage（已定方案）

AppImage 在**构建期**链接 `libwebkit2gtk`，因此「运行时探测再降级」来不及——链接了 WebKitGTK
的二进制在无该库的机器上会**启动失败**。所以出两个变体，由用户按需下载：

| 变体 | 构建期链接 WebKitGTK | 目标用户 | 体积（相对） |
| --- | --- | --- | --- |
| `DSH-Go-full.AppImage` | 是（CMake 开关打开） | 已装 WebKitGTK（GNOME 默认） | +约 150 MB |
| `DSH-Go-lite.AppImage` | 否（`systemWebViewBackend` 编译期固定为 unavailable） | KDE、无 WebKitGTK 环境 | 基础大小（实测 83 MB） |

实现要点：同一工程用 CMake option `DSH_WEBKITGTK=ON|OFF` 构建两次；
Dart 侧通过编译期常量（`--dart-define=DSH_NO_WEBVIEW=true`）把后端固定为 `unavailable`。

**完整版 AppRun 必须前置检查**：在启动 Flutter 之前检测 `libwebkit2gtk-4.1.so`，缺失则弹原生提示
（建议改用轻量版或安装库），**不要让应用段错误退出**。

#### 4.3.2 WebKitGTK 缺失时的弹窗（已定文案）

**固定文案，四条命令平铺，各配独立复制按钮，命令带 `sudo`；不做发行版检测、不折叠。**

```
┌──────────────────────────────────────────┐
│ 需要系统组件 WebKitGTK                     │
│                                          │
│ 这个功能需要系统自带的 WebKitGTK 网页内核。   │
│ 装好之后点「重新检测」即可启用。              │
│                                          │
│ Debian / Ubuntu                      [复制]
│   sudo apt install libwebkit2gtk-4.1-0      │
│                                          │
│ Arch / Manjaro                       [复制]
│   sudo pacman -S webkit2gtk-4.1             │
│                                          │
│ Fedora                               [复制]
│   sudo dnf install webkit2gtk4.1            │
│                                          │
│ openSUSE                             [复制]
│   sudo zypper install libwebkit2gtk-4_1-0   │
│                                          │
│ [已安装，重新检测] [下载完整版] [用浏览器打开]   │
└──────────────────────────────────────────┘
```

包名易错点（已核对）：Debian 系 `libwebkit2gtk-4.1-0`（带 `-0`）；Arch `webkit2gtk-4.1`；
Fedora `webkit2gtk4.1`（无连字符）；openSUSE `libwebkit2gtk-4_1-0`（**下划线**）。

三个出口：`已安装，重新检测`（免重启，检测到即切回内嵌）、`下载完整版`（打开 releases 页）、
`用浏览器打开`（本次降级，不永久静音）。

**降级影响范围**（必须让用户知道）：

| 功能 | 需要内嵌 WebView | 缺失时 |
| --- | --- | --- |
| 聊天、审批、文件、设置 | 否 | **完全正常** |
| 网页模式 | 是 | 跳系统浏览器 |
| 插件岛面板 / 伙伴小屋 / Mermaid 预览 | 是 | **不可用** |


### 阶段 4：打包分发（3–5 天）

| 平台 | 产物 | 工具 | 系统内核依赖 |
| --- | --- | --- | --- |
| Windows | `.exe`（Inno Setup，未签名可用）/ `.msi`（MSIX，需签名） | Inno Setup / NSIS / `msix` | 随包带 WebView2 **Bootstrapper**（约 1.5 MB，非内核） |
| Linux | `.deb` / `.rpm` / `.AppImage` | `dpkg-deb` / `rpmbuild` / AppImage-builder | `deb`/`rpm` 声明 `libwebkit2gtk-4.1-0`；AppImage 运行期检测 |
| macOS | 维持现状 `.app` / `.dmg` | `tooling/build-macos.sh` | — |

参照 `tooling/build-macos.sh` 写 `tooling/build-windows.ps1` 与 `tooling/build-linux.sh`：
「确保运行时已生成 → flutter build → 把 runtime 资源塞进包 → 打安装包」四步。

**Linux 桌面适配验收**（对应约束 C4）：

| 桌面 | 版本基线 | 验收项 |
| --- | --- | --- |
| KDE Plasma | Plasma 6.x（Wayland 与 X11 各测一） | SNI 托盘图标/菜单/点击、通知带按钮、窗口最小尺寸、桌宠置顶窗 |
| GNOME | 45+（Wayland 与 X11 各测一） | 有/无 AppIndicator 扩展两种状态、通知按钮、窗口行为 |

CI 参照 `.github/workflows/build-macos.yml` 增加两个 job（`windows-latest` / `ubuntu-latest`）。

### 阶段 5：Linux 构建环境（绿联 NAS 容器，不污染宿主）

**约束**：Linux 侧的编译**不在 NAS 宿主上装任何东西**。宿主只有 Docker，
所有工具链（Flutter、GTK 头文件、clang、CMake、dpkg/rpm 打包工具）都放在镜像里。

宿主现状（已核实）：Docker 29.6.2 + Compose v5.1.3，用户 `lvzhaobing` 已在 `docker` 组，
6 核 / 15 GB 内存（**已用 8 GB，可分配约 6 GB**），`/volume4` 可用 3.0 TB，已有 17 个容器在跑
（含 openwrt、siyuan、homeassistant 等）。

#### 5.1 为什么用容器而不是直接装

| 理由 | 说明 |
| --- | --- |
| 不污染宿主 | UGOS 的宿主包管理是 `opkg`-风格，装 Flutter/GTK 开发包极易与系统库冲突 |
| 可重现 | 镜像即环境，换机器/重装只需 `docker compose up` |
| 可控版本 | Flutter 3.47.x、Ubuntu 24.04 基线（与 `setup-toolchain.sh` 一致）由镜像固定 |
| 资源隔离 | `mem_limit` 限制内存，避免挤占 NAS 上已有的 17 个容器 |

#### 5.2 目录与文件（新增，全部在仓库内）

```
deploy/linux-build/
  Dockerfile              # Ubuntu 24.04 + Flutter 3.47.7 + GTK/WebKitGTK + 打包工具
  compose.yml             # 资源限制、卷挂载、工作目录
  entrypoint.sh           # 首次运行时的 flutter doctor / precache
```

`compose.yml` 关键配置：

```yaml
services:
  builder:
    build: .
    image: dsh-go-linux-builder:1
    container_name: dsh-go-linux-builder
    mem_limit: 6g
    cpus: 4
    working_dir: /work
    volumes:
      - /volume4/Works/dsh-go-desktop:/work          # 源码（NAS 上的 git clone）
      - dsh-flutter-cache:/opt/flutter-cache          # Flutter pub/gradle 缓存，独立卷
      - dsh-out:/out                                  # 构建产物
    environment:
      - FLUTTER_ROOT=/opt/flutter
      - PUB_HOSTED_URL=https://pub.flutter-io.cn      # 国内镜像，避免 pub 超时
      - FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
volumes:
  dsh-flutter-cache:
  dsh-out:
```

`Dockerfile` 要点：

1. 基础镜像 `ubuntu:24.04`。
2. 安装 GTK3 / `libwebkit2gtk-4.1-dev` / `clang` / `cmake` / `ninja-build` / `pkg-config` /
   `libsecret-1-dev`（`flutter_secure_storage` Linux 依赖）/ `clang` 工具链 / `dpkg-dev` / `rpm`。
3. 下载 Flutter 3.47.7 stable 到 `/opt/flutter`（**镜像构建期下载一次**，不要每次跑容器再下）。
4. `flutter config --enable-linux-desktop` + `flutter precache --linux`。

#### 5.3 运行方式

```bash
# 在 NAS 上（纯容器操作，宿主零安装）
cd /volume4/Works/dsh-go-desktop/deploy/linux-build
docker compose build          # 首次 ~10 分钟
docker compose run --rm builder bash tooling/build-linux.sh
```

产物从 `dsh-out` 卷或挂载目录取回本机（可复用 `nas_transfer.py get`）。

#### 5.4 实测结果（2026-11-12）

构建环境**已搭好并跑通**，以下为实测数据：

| 项 | 结果 |
| --- | --- |
| 镜像 | `dsh-go-linux-builder:1`，2.46 GB（Ubuntu 24.04 + Flutter 3.47.7） |
| Flutter / Dart | 3.47.7 / Dart 3.13.5 ✅ |
| Linux 工具链 | clang 18.1.3 / cmake 3.28.3 / ninja 1.11.1 ✅ |
| `flutter pub get` | 151 依赖解析成功 |
| `flutter analyze lib` | **无 error**（20 条 info 级 deprecation，为既有问题） |
| `flutter build linux --release` | ✅ `build/linux/x64/release/bundle/dsh_app`，**83 MB** |
| 代码同步 | 源码在 NAS `/volume4/Works/dsh-go-desktop`，用 zip 增量同步（走 `/volume2/Downloads/_xfer`） |

**踩过的坑（已解决，后人可直接照做）**：

1. **`docker build` 不能用 `--network=openwrt_lan`**——buildkit 不支持 macvlan，报
   `network mode "openwrt_lan" not supported by buildkit`。改用 **`--network=host`**（NAS 宿主本身能直连 GitHub）。
2. **`--rm` 会丢 pub-cache**——cache 在容器 `/root/.pub-cache`，容器销毁后 `pubspec.lock` 里的路径
   全部失效，表现为大量 `Error when reading '.../flutter_riverpod-3.5.0/...'`。
   必须挂**命名卷** `-v dsh-pub-cache:/root/.pub-cache`。
3. **PowerShell 传脚本给 NAS 会被引号/转义破坏**——`\$PATH`、`<<'EOF'` heredoc 都会坏。
   可靠做法：**本地把脚本转 base64，远端 `base64 -d` 落盘，再 `bash 该文件`**。
4. **`nas_transfer.py sh` 输出含 emoji 会崩**（GBK 编码）——设 `PYTHONIOENCODING=utf-8`。
5. **Git 自带 tar 不认 Windows 路径**——`tar -czf C:\...` 报 `Cannot connect to C:`。
   改用 .NET `System.IO.Compression.ZipFile` 打包。
6. **`flutter create` 的副作用**：会新增 `test/widget_test.dart`（引用不存在的 `MyApp`，导致 analyze 报错）
   并向 `analysis_options.yaml` 的 exclude 追加 `linux/**`。前者应删除。

#### 5.5 运行期验证（KDE / GNOME 桌面兼容）

容器只负责**编译**。桌面行为（托盘、通知、窗口）必须在真实桌面上验证，建议两条路：

1. **优先**：找一台装了 KDE Plasma 6 与一台 GNOME 45+ 的机器（或虚拟机）跑 AppImage/binary 做验收（见阶段 4 验收表）。
2. **备选**：NAS 上用 `xpra`/`xvfb` + 远程查看做**冒烟测试**（能启动、无崩溃），
   但**不能**验证托盘和通知的真实系统集成——这两项必须在真桌面环境验。

> 若后续需要，可再起一个带 Xvfb 的验证容器（同样不污染宿主），但它的定位只是「不崩」，
> 不替代真机验收。

#### 5.6 性能参考

| 环节 | 实测/预期 |
| --- | --- |
| 首次镜像构建 | 约 8–12 分钟（含 Flutter SDK 与 precache） |
| 首次 `pub get` | 约 1–2 分钟 |
| `build linux --release`（含 WebView 适配改动） | 约 4–6 分钟（4 核 / 6 GB 限制下） |
| 局限 | 这是**构建**环境，不是 GUI 运行环境。NAS 无桌面，无法直观看界面 |

---

## 6. 里程碑与总工期估算

| 里程碑 | 内容 | 估算 | 状态 |
| --- | --- | --- | --- |
| M0 | NAS 容器构建环境（`deploy/linux-build/`） | 1–2 天 | ✅ **已完成并实测** |
| M1 | 阶段 0 + 阶段 1：Windows 上能跑起来、能对话 | 4–7 天 | 待做 |
| M2 | 阶段 2 P0：通知 + 窗口 + 文件（原生） | +5–8 天 | 待做 |
| M3 | 阶段 2 P1 + 原生托盘（Windows） | +2–3 天 | 待做 |
| M4 | 系统 WebView 适配（WebView2） | +2–4 天 | 待做 |
| **M5** | **Linux WebKitGTK 内嵌通道（自写 GTK 插件）** | **5–8 天** | **立即要做，见 6.1** |
| M6 | Linux 对齐 + 托盘双桌面（KDE/GNOME） | +10–15 天 | 待做 |
| M7 | 打包 + CI（含双版本 AppImage） | +3–5 天 | 待做 |

**单平台可达最小可用约 2 周；三端完整对齐约 5–7 周**（单人全职估算）。
若 P1（桌宠、语音）延后，周期可缩短约 30%。

### 6.1 M5：Linux WebKitGTK 内嵌通道（立即执行）

**为什么立即做**：这是 Linux 端唯一能同时满足「零内核」与「可内嵌到 Flutter 布局」的方案。
不做它，插件岛、伙伴小屋、Mermaid 预览在 Linux 上永久不可用。`atomic_webview` 虽然是系统内核，
但桌面端开独立窗口，满足不了内嵌需求，**不能替代**。

#### 6.1.1 技术路线（API 已核实）

采用 **离屏渲染 + `FlTextureGL`** 方案。所有用到的 C API 均已对照官方头文件核实：

| 用途 | API | 核实来源 |
| --- | --- | --- |
| 取插件注册器 | `FlPluginRegistrar` + `fl_plugin_registrar_get_texture_registrar()` / `_get_messenger()` / `_get_view()` | `shell/platform/linux/public/flutter_linux/fl_plugin_registrar.h` |
| 注册纹理 | `fl_texture_registrar_register_texture()` / `_unregister_texture()` / `_mark_texture_frame_available()` | `fl_texture_registrar.h` |
| 自定义 GL 纹理 | `FlTextureGL`（`G_DECLARE_DERIVABLE_TYPE`），覆写 klass 的 `populate(FlTextureGL*, uint32_t* target, uint32_t* name, uint32_t* width, uint32_t* height, GError**)` | `fl_texture_gl.h`（含官方示例） |
| 截图取像素 | `webkit_web_view_get_snapshot()` / `webkit_web_view_get_snapshot_finish()` | WebKitGTK 2.42 `class.WebView.html` |
| 加载 | `webkit_web_view_load_uri()` / `_load_html()` / `_load_request()` | 同上 |
| 导航拦截 | `WebKitWebView::decide-policy` 信号 + `webkit_policy_decision_ignore()` / `_use()` | 同上（signals 列表） |
| 加载状态 | `WebKitWebView::load-changed`（`WEBKIT_LOAD_STARTED` / `_FINISHED`）、`:estimated-load-progress` 属性 | 同上 |
| 加载失败 | `WebKitWebView::load-failed` 信号 | 同上 |
| JS 执行 | `webkit_web_view_evaluate_javascript()`（2.40+，`run_javascript` 已 deprecated 2.40） + `_finish()` | 同上 deprecated 标注 |
| JS→Native 消息 | `WebKitUserContentManager` + `WebKitUserScript`（`at-document-start`）+ `script-message-received` 信号；或 `webkit_web_view_send_message_to_page()` | 同上 |

**关键实现要点（务必遵守）**：

1. `FlTextureGL::populate` 里的 GL 上下文已由 Flutter 设好，**直接 `glBindTexture` 即可**，
   不要自己 `gdk_window_create_gl_context()`。纹理格式只能是 **`GL_RGBA8`**。
2. WebKitGTK 是 GTK widget，**不需要**放进可见窗口即可截图；但必须
   `gtk_widget_realize()` 并给它一个尺寸（`gtk_widget_set_size_request()`），否则快照为空。
3. 用 `webkit_web_view_get_snapshot()` 取 `cairo_surface_t`，转 `GL_RGBA8` 上传纹理，
   然后 `fl_texture_registrar_mark_texture_frame_available()` 通知 Flutter 重绘。
4. **输入转发**是最大工作量：Flutter 的 pointer 事件需转成 GDK 事件喂给 WebView
   （`gtk_widget_event()`）。至少要覆盖鼠标移动/按下/抬起/滚轮。中文输入法走
   `WebKitInputMethodContext`（GTK IM 已集成），不需额外处理。
5. 插件形态：做成 `linux/` 下的静态源文件（不必发布成 pub 包），在
   `linux/flutter/generated_plugin_registrant.cc` 里注册。
6. **CMake 开关** `DSH_WEBKITGTK=ON|OFF` 控制是否编译该通道——这就是 4.3.1 双版本 AppImage 的
   构建开关，与 Dart 侧 `--dart-define=DSH_NO_WEBVIEW=true` 配套。

#### 6.1.2 分步交付（每步都可独立验证）

| 步骤 | 产出 | 验收标准 |
| --- | --- | --- |
| S1 | `linux/dsh_webview/dsh_webview_plugin.cc` 骨架：注册 `dsh/webview` 通道，`status` 返回 `{available:true, version:<webkit 版本>}` | 容器内 `flutter build linux` 通过；运行输出 `available:true`，版本号非空 |
| S2 | `FlTextureGL` 子类 + 空白纹理注册，Dart 侧 `Texture(textureId:)` 能显示纯色 | 屏幕上出现纯色块（需真桌面或 Xvfb 截图验证） |
| S3 | `WebKitWebView` 创建 + `load_uri` + `get_snapshot` 周期刷新（如 30 fps） | 能显示真实网页内容 |
| S4 | 输入事件转发（鼠标 + 滚轮） | 能在页面里点击链接、滚动 |
| S5 | `decide-policy` 导航拦截 + `load-changed` 状态 + `evaluate_javascript` | 与 `SystemWebViewController` 契约完全对齐 |
| S6 | 接入 `ui/web/system_webview_linux.dart`，替换当前 `unavailable` 分支 | 网页模式 / 插件岛 / Mermaid 预览在 Linux 上恢复可用 |

**风险提示**：S2/S3 的「快照转纹理」性能是最大不确定项。WebKit 快照是 CPU 路径
（cairo → 像素 → 上传 GPU），高帧率下可能吃 CPU。**S3 验收时必须实测 CPU 占用**；
若不可接受，退路是改用 `WebKitWebViewBase` 的 X11 子窗口 + `FlutterTexture` 共享纹理，
或直接在 GTK 布局里叠加原生 `GtkNative` 窗口（非 Flutter 纹理方案）。

---

## 7. 风险清单

| 风险 | 等级 | 缓解 |
| --- | --- | --- |
| 系统 WebView 不保留回环地址 cookie，网页模式失效 | **高** | PoC 第一项就验证；失败则 Web 模式永久走外部浏览器 |
| Win10 机器未装 WebView2 Runtime | **中** | 安装包带 Evergreen Bootstrapper，1.5 MB，启动时检测 |
| KDE 发行版未预装 WebKitGTK | **中** | 包管理器声明依赖；缺失时降级外部浏览器并提示 |
| GNOME 未装 AppIndicator 扩展 → 无托盘 | **中** | 运行时探测 SNI watcher；降级为窗口内状态呈现 + 设置页提示 |
| Windows `npm ci` 需编译原生模块（node-pty 等） | **中** | 优先预编译二进制；本机已有 MSVC 兜底 |
| 运行时体积（约 190 MB/平台）导致安装包巨大 | **中** | 与 macOS 一致：运行时作为独立下载，而非打进安装包 |
| Linux Wayland 下置顶窗（桌宠）受限 | **中** | X11 优先；Wayland 下桌宠降级，其余功能不受影响 |
| NAS 内存紧张（15 GB 已用 8 GB） | **中** | 容器 `mem_limit: 6g` + `cpus: 4`；构建期间注意其他容器 |
| 容器内构建无法验证桌面集成 | **中** | 托盘/通知必须在真 KDE/GNOME 桌面验收，容器只做编译与冒烟 |
| 105 个 DSH 补丁在 Windows 上路径语义不同 | **低** | 补丁基本平台无关；用 `runtime/tests/` 回归 |
| 上游持续演进，macOS 侧改动需同步 | **中** | 平台层隔离在 `lib/desktop/` + 各平台目录，冲突面小 |

---

## 8. 环境与资源现状

### 8.1 本机（Windows）

| 项 | 状态 |
| --- | --- |
| 仓库 | ✅ `C:\Works\dsh-go-desktop`，`360c45f`，工作区干净 |
| Flutter SDK | ❌ **未安装**（PATH 无 `flutter` / `dart`） |
| CMake | ✅ `C:\Program Files\CMake\bin\cmake.exe` |
| Ninja | ✅ 已装（winget） |
| MSVC | ✅ VS 18 Community + VS 2022 BuildTools（含 C++ 工具） |
| 系统 | ✅ Windows 11 LTSC 10.0.26100 |
| WebView2 Runtime | ✅ 已装 `157.0.4341.46`（满足约束 C1，无需打包内核） |
| Node | 待确认（构建运行时需要） |

**开工前必须先装 Flutter 3.47.x，并开启 Windows Developer Mode。**

### 8.2 绿联 NAS（Linux 构建机）

| 项 | 状态 |
| --- | --- |
| 主机 | `DXP4800PLUS`，x86_64，6 核，15 GB 内存（已用 8 GB） |
| Docker | ✅ 29.6.2 + Compose v5.1.3，用户已在 `docker` 组 |
| 磁盘 | `/volume4` 可用 3.0 TB（建议工作目录 `/volume4/Works/dsh-go-desktop`） |
| 宿主污染 | ✅ 当前无 Flutter/GTK 开发包，符合「不污染宿主」前提 |
| 既有负载 | 17 个容器在跑（openwrt、siyuan、homeassistant、libretv 等），构建容器需限资源 |
| 桌面环境 | ❌ 无桌面，只能做编译与冒烟，**不能**验证托盘/通知 |

---

## 9. 建议的下一步

1. **本机装 Flutter 3.47.x**，`flutter doctor` 确认 Windows 工具链齐全（WebView2 已就绪）。
2. **NAS 上准备构建环境**：把仓库 clone 到 `/volume4/Works/dsh-go-desktop`，
   写 `deploy/linux-build/{Dockerfile,compose.yml}`，先跑通 `flutter build linux --debug`。
   这一步与 Windows 侧互不阻塞，可并行。
3. 执行阶段 0，跑通**空壳 Windows 构建**（此时所有平台功能降级）。
4. 启动 **系统 WebView PoC**（WebView2 优先），验证回环地址 `?token=` → cookie 链路。
5. PoC 结论出来后按阶段 1 → 2 → 3 推进；托盘按 4.2.1 的原生方案实现。

---

## 附录 A：通道速查

| 通道 | Dart 侧文件 | macOS 实现 | 建议分级 |
| --- | --- | --- | --- |
| `dsh/notify` | `notify/notify_channel.dart` | MacNotify | P0 |
| `dsh/notify/taps` | `notify/notify_channel.dart` | MacNotify | P0 |
| `dsh/notify/actions` | `notify/notify_channel.dart` | MacNotify | P0 |
| `dsh/window` | `macos/window_mode.dart` | MacHost | P0 |
| `dsh/window/events` | `macos/window_mode.dart` | MacHost | P0 |
| `dsh/files` | `state/artifacts.dart` | MacFiles | P0 |
| `dsh/media` | `media/gallery.dart` | MacFiles | P0 |
| `dsh/menubar` | `macos/menu_bar.dart` | MacMenuBar | P1 |
| `dsh/pet_overlay` | `pets/overlay_channel.dart` | MacPetOverlay | P1 |
| `dsh/voice` | `ui/chat/voice/voice_bridge.dart` | MacVoice | P1 |
| `dsh/voice/events` | `ui/chat/voice/voice_bridge.dart` | MacVoice | P1 |
| `dsh/links` | `links/app_links.dart` | MacHost | P2 |
| `dsh/update` | `update/installer.dart` | MacStubs | P2 |
| `dsh/diagnostics` | `diagnostics/diagnostics_channel.dart` | MacStubs | P2 |
| `dsh/app` | `ui/features/schedule_editor/time_zones.dart` | MacHost | P2 |
| `dsh/mac_peekaboo` | `macos/mac_peekaboo.dart` | MacPeekaboo | 不适用 |
| `dsh/runtime` | `state/voice_model_state.dart` | Dart 实现，M1 取代 | 由 M1 取代 |
| `dsh/islands` | `ui/plugins/islands/island_platform.dart` | MacStubs | P2 |
| `dsh/native-media` | `plugins/native/native_platform.dart` | MacStubs | P2 |
| `dsh/native-files` | `plugins/native/native_file_platform.dart` | MacStubs | P2 |
| `dsh/launch` | `launch/launch_state.dart` | MacStubs | P2 |
| `dsh/launch_clip` | `launch/launch_video.dart` | MacStubs | P2 |
| `dsh/shortcuts` | `links/launcher_entries.dart` | MacStubs | P2 |
| `dsh/share` | `links/share_intake.dart` | MacStubs | P2 |
| `dsh/launcher_icon` | `state/app_icon_state.dart` | MacStubs | P2 |
| `dsh/picture_shortcut` | `state/icon_shortcut_state.dart` | MacStubs | P2 |
| `dsh/dynamic_color` | `state/appearance_state.dart` | MacStubs | P2 |
| `dsh/performance` | `performance/performance_state.dart` | MacStubs | P2 |
| `dsh/usage` | `usage/usage_net.dart` | MacStubs | P2 |
| `dsh/phone` | `phone/phone_channel.dart` | — | P2 |
| `dsh/companion_voice` | `companion/companion_voice.dart` | — | P2 |
| `dsh/companion_widget` | `companion/companion_widget.dart` | — | P2 |
| `dsh/web-files` | `ui/web/web_file_chooser.dart` | — | P2 |

## 附录 B：与 macOS 版的关键差异

| 方面 | macOS | Windows | Linux |
| --- | --- | --- | --- |
| 数据目录 | `~/Library/Application Support/<bundle id>/` | `%APPDATA%\<app>\` | `~/.local/share/<app>/` |
| 引擎 HOME | `.../runtime/home` | 同 | 同 |
| 导出图片 | `~/Pictures/DSH Go` | `%USERPROFILE%\Pictures\DSH Go` | `~/Pictures/DSH Go` |
| 另存文件 | `~/Downloads/DSH-Go` | `%USERPROFILE%\Downloads\DSH-Go` | `~/Downloads/DSH-Go` |
| 解压 | `/usr/bin/tar` | 内置 archive 或 `tar.exe` | `tar` |
| 密钥存储 | 0600 文件（无 Keychain entitlement） | `flutter_secure_storage` → DPAPI | `flutter_secure_storage` → libsecret |
| 状态栏 | NSStatusItem + NSPopover | 系统托盘 + 托盘菜单 | StatusNotifierItem |
| 不适用能力 | — | Mac 操控 | Mac 操控 |
