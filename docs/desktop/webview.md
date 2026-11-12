# 系统 WebView 适配（Windows / Linux）

本次改动把「四个业务页面直接 new `WebViewController()`」收成一层按平台分发的薄抽象：

```
ui/web/system_webview.dart        接口 + 平台分发（业务文件只 import 这一个）
ui/web/system_webview_flutter.dart  macOS / Android / iOS → webview_flutter
ui/web/system_webview_win.dart      Windows → webview_windows（WebView2）
ui/web/system_webview_linux.dart    Linux → flutter_inappwebview + flutter_inappwebview_linux
```

**验证状态（先说清楚）**：本机没有 Flutter SDK，所以

- **没有编译过**：`flutter analyze` / `flutter build` 都没跑，文中任何「能编译」都不成立；
- **没有运行过**：Windows 上没有跑过 WebView2，Linux 上没跑过 WPE；
- 做的是**静态正确性检查**：把用到的每个 API 都对着 pub 上的**包源码**逐个核了签名
  （见 §5，附文件行号），并核对了平台声明、依赖约束与原生构建依赖；
- 「依赖能否解析」「能不能编译」「cookie 链路」三件事都在 §7 的未验证清单里。

---

## 1. 一个必须先决策的问题：Linux 这条路线违反硬约束

任务书要求「Linux → `flutter_inappwebview`（WebKitGTK）」。核对 pub 元数据后，
这个前提**不成立**，需要上层先拍板再往下走：

### 1.1 `flutter_inappwebview` 本体没有 Linux 实现

`flutter_inappwebview` 6.1.5（pub 最新）的 pubspec 原文：

```json
"platforms": {"android":…, "ios":…, "macos":…, "web":…, "windows":{"default_package":"flutter_inappwebview_windows"}}
```

没有 `linux`。所以 Linux 必须**额外显式**依赖平台实现包
`flutter_inappwebview_linux`（0.1.0-beta.1，2026-02-04 发布，pub 上只有这一个版本）。
它的 README 说「endorsed，会被自动包含」，但 6.1.5 的依赖列表里并没有它——那句话对
6.1.5 不成立，必须手写进 `pubspec.yaml`（本仓库已加）。

### 1.2 这个 Linux 实现用的是 WPE WebKit，不是 WebKitGTK

- 包自述：`Linux implementation of flutter_inappwebview plugin using WPE WebKit.`
- `WPE_BACKEND.md`：`This plugin uses WPE WebKit for offscreen web rendering` …
  `The following files are automatically copied to your app's lib/ directory:
  libWPEWebKit-2.0.so.* - WPE WebKit library (~160MB), libwpe-1.0.so.*`
- `linux/CMakeLists.txt` 要求 `gtk+-3.0`、`epoxy`，以及 **`wpe-webkit-2.0`**
  （退化到 1.1 / 1.0）+ `wpe-platform-2.0`/`wpe-platform-headless-2.0`
  **或** `wpebackend-fdo-1.0`；两者都找不到时**构建直接失败**。

也就是说：

1. **WPE 是 WebKit 的另一个 port**，和 GTK port（`webkit2gtk-4.1`）不是同一个
   库、不同 pkg-config 名、不能互换。任务书写的「WebKitGTK」不是它。
2. 它会把 ~160 MB 的 `libWPEWebKit-2.0.so` **拷进 App 的 lib/**，实质是随包带内核，
   与「只用系统自带 WebView 内核、严禁打包浏览器内核」的约束 1 冲突（虽然内核不是
   CEF/Chromium，但体积与更新负担同级）。
3. 主流发行版没有预装 `wpe-webkit-2.0` + `wpe-platform-2.0`；`WPE_BACKEND.md` 的
   「安装」章节整篇就是在教你自己编 WebKit 2.50.4（1.5 GB 内存/进程、几小时）。
   这与「Linux = 系统 WebKitGTK，声明 `libwebkit2gtk-4.1-0` 依赖即可」的设计前提相反。

### 1.3 满足约束的备选（已核到原生 CMake）

`atomic_webview` 0.2.0（2026-10-27，github.com/Yoda-Man/atomic_webview）：

- `linux/CMakeLists.txt:10-18`：`# Prefer the GTK4 variant (webkit2gtk-4.1)…`
  `pkg_check_modules(WebKit IMPORTED_TARGET webkit2gtk-4.1)`，找不到才退到
  `webkit2gtk-4.0` —— 正是**系统 WebKitGTK**；
- `windows/…`：WebView2（`WEBVIEW2_ARCH`）；
- 对外一套 API 覆盖 windows / macos / linux / android / ios / web，内部复用
  `webview_flutter`（macOS/Android 侧）；
- 代价：`sdk: ^3.13.7`、`flutter: >=3.47.8`（比本仓库 `sdk: ^3.13.5` 与
  `docs/desktop/README.md` 计划的 3.47.x 更紧一点），且是个人维护的社区包
  （**它的 Dart API 与成熟度我没有评估**）。

其它只核了元数据、没核实现的候选：`webview_all` 1.5.0（federated，有
`webview_all_linux`/`webview_all_windows` 子包）、`desktop_webview_linux` 0.2.0、
`zikzak_inappwebview_linux` 6.3.4（inappwebview 的 Linux fork）、
`flutter_linux_webview` 0.1.3（2023 年，实现 `webview_flutter_platform_interface`）。

### 1.4 三条可选路线（建议按顺序评估）

| 路线 | 满足约束 1 | 工作量 | 风险 |
| --- | --- | --- | --- |
| A. 换 `atomic_webview`（Win+Linux 都走它） | ✅ | 只需替换 `system_webview_linux.dart`，Windows 也可一并换 | 新包、版本约束紧、API 未评估 |
| B. 自写 GTK WebKitGTK 通道（`linux/` 里的 C++ 插件） | ✅ | 最大（约 200–400 行 C++ + MethodChannel/Texture） | 控制力最强，要自己处理纹理/输入法 |
| C. 按任务书继续 `flutter_inappwebview_linux` | ❌（WPE + 带 160 MB 内核） | 已写好 | 构建环境要自己编 WebKit；体积/更新负担 |

本次按任务书实现了 C，但把**整个 Linux 后端关在一个文件里**：换成 A 或 B 时
`system_webview_linux.dart` 之外的代码不用动。

---

## 2. 每个文件的改动点

业务文件只换「拿 controller / 拿 widget」的两个动作，回调体、布局、业务逻辑一行没动。

| 文件 | 改动 | 行数 |
| --- | --- | --- |
| `ui/web/system_webview.dart` | **新增**：接口、`SystemNavigationRequest` / `SystemWebResourceError` / `SystemWebViewNavigationDelegate`、`createSystemWebViewController()`、`systemWebViewBackend` | 新文件 |
| `ui/web/system_webview_flutter.dart` | **新增**：`webview_flutter` 适配器（macOS/Android/iOS） | 新文件 |
| `ui/web/system_webview_win.dart` | **新增**：WebView2 适配器（含命名通道垫片、导航近似拦截） | 新文件 |
| `ui/web/system_webview_linux.dart` | **新增**：WPE 适配器（延迟 controller、垫片、`shouldOverrideUrlLoading`） | 新文件 |
| `ui/web/web_view_page.dart` | import 换成 `system_webview.dart`；`WebViewController` → `SystemWebViewController`；`setJavaScriptMode(JavaScriptMode.unrestricted)` → `setJavaScriptModeUnrestricted()`；`NavigationDelegate(` → `SystemWebViewNavigationDelegate(`；`_onDshWebNavigation` 参数换 `SystemNavigationRequest`、返回 `NavigationDecision` 改成 `bool`；3 个 `addJavaScriptChannel(name, onMessageReceived: (m) => …m.message)` → `addJavaScriptChannel(name, (message) => …)`；`_onState`/`_onOpened` 参数 `JavaScriptMessage` → `String`；`WebViewWidget(key:…, controller:…)` → `_controller.build(key:…)` | 9 处 |
| `ui/chat/render/mermaid_preview.dart` | 同上（`loadHtmlString` 保留；导航策略改成返回 bool） | 5 处 |
| `ui/companion/companion_stage.dart` | `WebViewController(onPermissionRequest: …deny())` → `createSystemWebViewController(denyPermissionRequests: true)`；`WebViewWidget(controller:)` → `web.build(gestureRecognizers:)`；错误判断 `error.isForMainFrame ?? false` → `error.isMainFrame` | 5 处 |
| `ui/plugins/islands/island_handle.dart` | **注意：`island_view.dart` 里没有 controller**，创建在 `island_handle.dart`（`start()`）。同样换 controller/delegate/通道签名；`_identifierOf(controller)` 删除，改用 `controller.androidWebViewId` | 6 处 |
| `ui/plugins/islands/island_view.dart` | `WebViewWidget(key: ObjectKey(handle), controller: handle.controller, gestureRecognizers: _gestures)` → `handle.controller.build(key: ObjectKey(handle), gestureRecognizers: _gestures)` | 2 处 |
| `ui/web/web_view_guard.dart` | Android 专属的 native 接管：`WebViewController` → `SystemWebViewController`，`identifierOf` 改走 `controller.androidWebViewId`。桌面后端该值是 null，`attach()` 在拿不到 id 时本来就 return（空实现） | 2 处 |
| `ui/web/web_file_chooser.dart` | Android 专属：`attach(WebViewController)` → `attach(SystemWebViewController)`，取底层 controller 用 `controller.vendorController`（桌面为 null → 不是 `AndroidWebViewController` → 直接 return，空实现） | 2 处 |
| `app/pubspec.yaml` | 加 `webview_windows: ^0.4.0`、`flutter_inappwebview: ^6.1.5`、`flutter_inappwebview_linux: ^0.1.0-beta.1`（带注释说明约束） | 3 行 |

未改动：`assets/web/*.js`、页面 HTML、`island.js`、`companion` 页面、任何布局与文案。
**页面里仍然用 `Name.postMessage(...)`**，桌面后端靠垫片兼容（见 §4）。

---

## 3. 三个后端的实现要点

### 3.1 `webview_flutter`（macOS/Android/iOS）

纯转发，语义与改动前完全一致（macOS 是当前唯一跑通的桌面平台，不能有偏移）。
`androidWebViewId` 沿用原来的 `(controller.platform as dynamic).webViewIdentifier`
反射写法；`vendorController` 返回原始 `WebViewController`（文件选择器要用）。

### 3.2 `webview_windows` → WebView2（Windows）

- `initialize()` 必须在 `loadUrl` 之前；所有配置方法内部 `await` 它。
- **命名 JS 通道不存在**：只有一个 `webMessage` 流，且页面侧是
  `window.chrome.webview.postMessage`。适配器用
  `addScriptToExecuteOnDocumentCreated` 注入垫片，把
  `window.<name>.postMessage(x)` 包成 `{c:<name>, m:x}` 再分发。
- **没有导航前拦截**：URL 变了以后问策略，不允许就 `goBack()`（近似）。
- **没有进度百分比**：只有 `LoadingState`（none / loading / navigationCompleted），
  所以 `onProgress` 永不触发 —— 网页模式的进度条在 Windows 上不显示。
- `canGoBack` 没有查询接口，只能从 `historyChanged` 流缓存。
- `Webview` widget 的构造函数**只有位置参数**（没有 `super.key`），所以 key 挂在
  `KeyedSubtree` 上，保证「重新打开 = 新平台视图」。
- **必须做的一件接入工作**：`Webview2` 的 user data 目录。`webview_windows` 不传
  `userDataPath` 时把 `nullptr` 交给 `CreateCoreWebView2EnvironmentWithOptions`
  （`windows/webview_host.cc:26-28`），由 WebView2 自己挑默认目录（通常在 exe 旁，
  安装到 `Program Files` 时可能不可写）。App 启动时应先调一次
  `WebviewController.initializeEnvironment(userDataPath: '<app support>/webview2')`
  （全进程只能调一次，必须在任何 controller 创建前），否则 cookie/站点数据可能
  不持久 —— 这直接影响 `dsh-auth` cookie 能否跨重启保留（§6）。

### 3.3 `flutter_inappwebview`（Linux，WPE）

- controller 由 widget 创建（`onWebViewCreated`），所以这里是**延迟交付**的控制器：
  配置调用排到 widget 建好后落到真 controller；业务代码的调用顺序不变。
- 导航回调在 widget 上，**`setNavigationDelegate` 必须在 `build` 之前**调用
  （现有业务代码本来就是这个顺序）。
- 同样没有命名通道，只有 `addJavaScriptHandler`；用 `initialUserScripts`
  （`AT_DOCUMENT_START`）注入垫片，把 `postMessage` 转成
  `window.flutter_inappwebview.callHandler(name, x)`。
- **没有 `setBackgroundColor`**：只支持 `transparentBackground`（bool）。所以
  「伙伴小屋」的 `0xFF0D2F55` 背景与 Mermaid 的背景色在 Linux 上是空操作，
  颜色交给页面自己的 CSS。
- `shouldOverrideUrlLoading` 是真拦截（返回 `NavigationActionPolicy.ALLOW/CANCEL`）。

---

## 4. 能力差异表（业务代码要知道的降级）

| 能力 | webview_flutter | WebView2（webview_windows） | WPE（flutter_inappwebview） |
| --- | --- | --- | --- |
| 命名 JS 通道 `X.postMessage` | 原生支持 | **垫片注入** | **垫片注入** |
| 导航前拦截（外部链接策略） | ✅ | ⚠️ 事后近似（`goBack`） | ✅ |
| 加载进度百分比 | ✅ | ❌ 不触发 | ✅ |
| `onPageStarted/Finished` | ✅ | ⚠️ 由 `LoadingState` 近似 | ✅ |
| `setBackgroundColor` | ✅ | ✅（半透明按不透明算） | ⚠️ 只支持全透明 |
| `canGoBack()` | ✅ | ⚠️ 缓存自 `historyChanged` | ✅ |
| `runJavaScriptReturningResult` | `Future<Object>` | `executeScript`（已 jsonDecode） | `evaluateJavascript`（dynamic） |
| `currentUrl()` | ✅ | ⚠️ 最近一次 `urlChanged` | ✅ |
| 渲染进程崩溃恢复 | Android 专属通道 | ❌（无对应钩子） | ❌ |
| 文件选择器接管 | Android 专属 | ❌（应由系统对话框，未做） | ❌（未做） |

`web_view_guard.dart` 在 macOS 上一直是空实现（拿不到 Android id），Windows/Linux
继承这个行为：**崩溃后不会自动报「网页已关闭」，只会白屏/停住**。这是已知降级，
不在本次范围内补。

---

## 5. 签名核实表（对着包源码，不是凭记忆）

来源：`pub.dev/api/archives/<pkg>-<ver>.tar.gz` 解包后 grep，包与版本：
`webview_flutter 4.14.1`、`webview_flutter_platform_interface 2.15.1`、
`webview_windows 0.4.0`、`flutter_inappwebview 6.1.5`、
`flutter_inappwebview_platform_interface 1.4.0-beta.3`、
`flutter_inappwebview_linux 0.1.0-beta.1`。

| 用到的 API | 出处 | 结论 |
| --- | --- | --- |
| `WebViewController({void Function(WebViewPermissionRequest)? onPermissionRequest})` | webview_flutter `lib/src/webview_controller.dart:59` | ✅ 与业务代码现有用法一致 |
| `setJavaScriptMode` / `setNavigationDelegate` / `addJavaScriptChannel(String, {required void Function(JavaScriptMessage) onMessageReceived})` / `loadRequest` / `loadHtmlString` / `runJavaScript` / `runJavaScriptReturningResult` / `canGoBack` / `goBack` / `reload` / `currentUrl` / `setBackgroundColor` | 同文件 145–338 行 | ✅ 全部核对 |
| `JavaScriptMessage.message` | platform_interface `lib/src/types/javascript_message.dart:41` | ✅ |
| `NavigationRequest{String url, bool isMainFrame}` | platform_interface `lib/src/types/navigation_request.dart:6-15` | ✅ |
| `WebResourceError{int errorCode, String description, WebResourceErrorType? errorType, bool? isForMainFrame}` | 同包 `types/web_resource_error.dart:101-125` | ✅ |
| `WebViewWidget({Key?, required controller, Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers = const {}})` | webview_flutter `lib/src/webview_widget.dart:42-47` | ✅ **注意 gestureRecognizers 非空**（适配器已补 `?? const {}`） |
| `WebviewController`：`initialize()` / `loadUrl(String)` / `loadStringContent(String)` / `executeScript(String) → dynamic` / `reload` / `goBack` / `setBackgroundColor(Color)` / `addScriptToExecuteOnDocumentCreated(String)` / `dispose()`；流 `url` / `loadingState` / `onLoadError` / `historyChanged` / `webMessage` | webview_windows `lib/src/webview.dart:165-563` | ✅ |
| `LoadingState {none, loading, navigationCompleted}`、`WebErrorStatus` 枚举 | webview_windows `lib/src/enums.dart` | ✅ |
| `Webview(this.controller, {…})`（**无 key 参数**） | webview_windows `lib/src/webview.dart:584-589` | ✅（故用 KeyedSubtree） |
| `InAppWebView({key, gestureRecognizers, initialSettings, initialUserScripts, onWebViewCreated, onLoadStart, onLoadStop, onProgressChanged, onReceivedError, shouldOverrideUrlLoading, …})` | flutter_inappwebview `lib/src/in_app_webview/in_app_webview.dart:38-192` | ✅ 参数名逐个核对 |
| `InAppWebViewController.evaluateJavascript({required String source})` / `loadUrl({required URLRequest urlRequest})` / `loadData({required String data})` / `getUrl() → WebUri?` / `canGoBack` / `goBack` / `reload` / `addJavaScriptHandler({required String handlerName, required JavaScriptHandlerCallback callback})` | flutter_inappwebview `lib/src/in_app_webview/in_app_webview_controller.dart:170, 246–…` | ✅ |
| `InAppWebViewSettings{bool? javaScriptEnabled, bool? useShouldOverrideUrlLoading, bool? transparentBackground}` | platform_interface `lib/src/in_app_webview/in_app_webview_settings.dart:76,182,455` | ✅ |
| `URLRequest{WebUri? url}`、`WebUri(String)`、`NavigationActionPolicy.ALLOW/.CANCEL`、`NavigationAction{URLRequest request, bool isForMainFrame}` | platform_interface `lib/src/types/{url_request,navigation_action_policy,navigation_action}.dart`、`lib/src/web_uri.dart:33` | ✅ |
| `WebResourceError{WebResourceErrorType type, String description}`、`WebResourceRequest{WebUri url, bool? isForMainFrame}` | 同包 `types/web_resource_error.dart:10-18`、`types/web_resource_request.dart:12-35` | ✅ |
| `UserScript{String source, UserScriptInjectionTime injectionTime, bool forMainFrameOnly}` | 同包 `types/user_script.dart:12-37` | ✅（Linux 上 `forMainFrameOnly` 只是注解限制，Dart 字段存在） |

**没核实到的**（写代码时留了防御，但仍算风险）：

1. `JavaScriptHandlerCallback` 的 typedef 在 `flutter_inappwebview 6.1.5` 依赖的
   `platform_interface ^1.3.0` 里，我没下 1.3.x（下的是 1.4.0-beta.3，里面没有这个
   typedef）。适配器里回调参数**不写显式类型**（`(arguments) { … }`）以免撞签名。
2. `flutter_inappwebview` 6.1.5 依赖 `platform_interface ^1.3.0`，而
   `flutter_inappwebview_linux` 依赖 `^1.4.0-beta.3`。两者在语义版本上可以同时满足
   （`1.4.0-beta.3` 落在 `^1.3.0` 的范围内），但**pub 会不会真的这样解、6.1.5 的代码
   与 1.4.0-beta.3 会不会有 breaking change，本机没法验证**。
3. `webview_windows 0.4.0` 的 SDK 约束是 `>=2.13.0 <3.0.0`，本仓库是 `sdk: ^3.13.5`。
   靠 pub 对「空安全包的 `<3.0.0` 上界」的兼容规则才能解析，**没实际 `pub get` 过**。
   若解析失败，退路是 fork 一份改上界，或改用 `atomic_webview`。
4. `flutter` 版本：`flutter_inappwebview_linux` 要 `>=3.32.0`、`atomic_webview` 要
   `>=3.47.8`，本机没有 Flutter，无法确认实际版本。
5. `Color.a`（Linux 后端判断透明用）是 Flutter 3.27+ 的 API；按仓库其它文件的
   `toARGB32()` 用法推断版本足够新，但没编译验证。

---

## 6. 最关键的待验证项：`?token=` → 303 → `dsh-auth` cookie

DSH Web 的登录链是：引擎打印 `dsh web: http://127.0.0.1:<port>/?token=<T>` →
WebView 打开带 token 的地址 → 服务端 **303** 到 `/` 并 `Set-Cookie: dsh-auth=…` →
之后所有请求靠这个 cookie。**只要 cookie 没保住，页面每次都要重新取 token。**

Windows 侧我已经实测到第 0 步（引擎确实打印出符合 manifest 正则的那一行，见
`docs/desktop/runtime-desktop.md` §3.3），第 1 步之后**全部未验证**。

### 6.1 待验证清单（按顺序做）

| # | 验证项 | 为什么可能失败 | 期望/判断方式 |
| --- | --- | --- | --- |
| 1 | WebView2 是否把 `http://127.0.0.1:<port>` 当**安全上下文** | Chromium 把 `127.0.0.1`/`localhost` 视为 potentially trustworthy origin，理论上 `isSecureContext === true` | 页面里 `window.isSecureContext`；`navigator.clipboard` / `crypto.subtle` 是否可用 |
| 2 | 303 + `Set-Cookie` 是否被接受 | 若 cookie 带 `Secure`，在 http 上只有「安全上下文」才存；若带 `SameSite=Strict/Lax`，303 属于导航请求，一般没问题 | DevTools/Network 看 303 响应头 + `document.cookie`（HttpOnly 则改为看后续请求是否 200） |
| 3 | cookie 是否**持久**（跨页面 reload、跨进程重启） | WebView2 的 user data 目录：不调用 `initializeEnvironment` 时由 WebView2 选默认目录，可能不可写/每次不同（见 §3.2） | 关掉 App 重开，直接打开 `http://127.0.0.1:<port>/`（不带 token）是否能进 |
| 4 | token 是否只够一次 | 服务端可能在 303 后作废 token；`currentUrl()` 不应再暴露 token（`web_view_page.dart:_openExternal` 会用它） | 记录 303 后的 `location.href`、`currentUrl()` |
| 5 | WPE（Linux）侧的同样五项 | WebKit 对回环地址的安全上下文判定与 Chromium 不同实现；libsoup 处理 cookie | 同 1–4，用 webkit2gtk 的最小程序先测（不经过 Flutter） |
| 6 | 垫片是否挡住 `postMessage` | 桌面后端靠注入的 `window.<name>.postMessage`；若页面在注入前就调用，消息会丢（`dsh_web_open.js` 可能在 DOMContentLoaded 前就跑） | 打开网页模式，看 `DshAppOpen`/`DshAppState` 是否收到消息 |

### 6.2 建议的最小 PoC（不依赖 Flutter）

1. Windows：起引擎（`docs/desktop/runtime-desktop.md` §3.3 已能给出一行带 token 的 URL），
   用任意 WebView2 宿主（例如 WebView2 官方示例，或一个 20 行的 Win32 程序）打开它；
   在页面里执行 `window.isSecureContext`、读 `document.cookie`、然后重开看是否免 token。
2. Linux：写 40 行 GTK3 + `webkit2gtk-4.1` 的程序，`webkit_web_view_load_uri`
   打开同一行 URL，用 `webkit_cookie_manager_get_cookies` 读 cookie，再重启看是否还在。
3. 两条都过了，再谈 Flutter 侧接 `system_webview_*`。

若第 2/3 项失败，降级方案（任务书已给出）：Web 模式退回**外部浏览器**打开
`http://127.0.0.1:<port>/?token=…`，token 一次性、每次重新取；嵌入式 WebView 只用于
Mermaid 预览与伙伴小屋（这两个不依赖 cookie）。

---

## 7. 未验证清单与测试影响

**未验证**

- 任何编译（`flutter pub get` / `flutter analyze` / `flutter build windows|linux`）。
- 任何运行（WebView2 / WPE 都没跑过）。
- 依赖解析（`webview_windows` 的 `<3.0.0` 上界、`flutter_inappwebview_linux` 与
  `flutter_inappwebview` 的 platform_interface 交叉）。
- Windows 上 `flutter_inappwebview`（它自带 `flutter_inappwebview_windows`）与
  `webview_windows` **同时存在**会不会在 Windows 构建里冲突（两个包都注册 WebView2
  环境的初始化；`initializeEnvironment` 只能调一次，两个插件各调一次可能报
  `环境已初始化`）。真接入时**建议 Windows 只留一个**：要么 `webview_windows`（本方案），
  要么 `flutter_inappwebview`（Win+Linux 一套 API）。
- Android 上同时存在 `webview_flutter_android` 与 `flutter_inappwebview_android`
  两个 WebView 插件（体积 +1，功能不冲突，未测）。

**测试**

- `app/test/web/support/fake_webview.dart` 与 `app/test/plugins/islands/support/fakes.dart`
  注册的是 `webview_flutter` 的假平台。`flutter test` 里 `defaultTargetPlatform` 是
  `TargetPlatform.android`（`FLUTTER_TEST` 环境变量生效），所以分发仍然走
  `webview_flutter` 适配器 → 现有断言（`calls` 顺序：`setNavigationDelegate` 早于
  `loadRequest`）**理论上不受影响**，但**没有跑过**。
- `app/test/web/web_file_chooser_page_test.dart` 期望页面加载后
  `AndroidWebViewController.setOnShowFileSelector` 被调用；而 `lib` 里
  `WebFileChooser.attach` 目前**没有任何调用点**（`grep WebFileChooser lib/` 只命中
  定义自身）。这是改动前就存在的疑点，与本次改动无关，但会让这个测试在跑的时候
  大概率失败——接入时注意。
