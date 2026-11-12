# app/windows/ — 手工生成的 Flutter Windows 平台骨架

> **状态：未经编译验证。** 本机没有 Flutter SDK，也没有 Windows 端构建产物；
> 这批文件是照 Flutter 官方 `flutter create --platforms=windows` 模板**手工等价生成**的
> C++ / CMake 骨架，**没有跑过 `flutter build windows`，不保证一次就能编译通过**。
> 接入 Flutter 3.47.x 之后的第一件事，是按下文「三、接入后的核对清单」逐项核对。

---

## 一、这批文件从哪来

按任务要求，`app/windows/` 原先不存在，需要补齐 `flutter create --platforms=windows`
的等效产物。本机没有 Flutter SDK，也按要求**没有联网下载模板**。

生成依据是一次真实模板产出：磁盘上 `C:\Works\.tmp-webview\` 下两个第三方 pub 包
（`flutter_inappwebview 6.1.5`、`webview_windows 0.4.0`）的 `example/windows/`，它们
都是当年由 `flutter create` 生成、并被 pub 发布保留在包里的原始模板产物。
因此：

- 未修改的文件（`flutter/CMakeLists.txt`、`runner/CMakeLists.txt`、`flutter_window.*`、
  `utils.*`、`resource.h`、`runner.exe.manifest`）逐字节等于该真实模板产出（已用
  SHA256 比对确认 `IDENTICAL`）。
- 需要按项目改的文件（`CMakeLists.txt`、`main.cpp`、`win32_window.*`、`Runner.rc`）
  以该产出为基底做定向修改，改动点见第二节，且每处都留了 `// NOTE:` 注释。
- `runner/resources/app_icon.ico`（33,772 字节）是从上述模板产出**原样复制**的 Flutter
  默认图标；两个独立工程的该文件 SHA256 完全一致，可认定就是官方模板自带资源。
  `Runner.rc` 的 `IDI_APP_ICON` 引用它，缺了它就编译不过。

**版本差异风险**：参照的模板产出大约相当于 Flutter 3.13–3.19 的 windows 模板。
Flutter 3.47.x（Dart 3.13.5）的 windows 模板有没有再变，本机无法确认——凡是可能有
出入的地方都标了 `// NOTE: 需与官方模板核对`，汇总见第三节。

## 二、文件清单与本地改动

### 与官方模板一致、未做修改

| 文件 | 作用 |
| --- | --- |
| `flutter/CMakeLists.txt` | Flutter 引擎 / C++ client wrapper 的构建规则（官方注明 "should not be edited"） |
| `runner/CMakeLists.txt` | runner 可执行目标的源文件、编译选项、`dwmapi.lib` 链接 |
| `runner/flutter_window.h` / `.cpp` | 承载 `FlutterViewController` 的窗口，转发窗口消息给 Flutter |
| `runner/utils.h` / `.cpp` | 控制台附加、命令行参数转 UTF-8 |
| `runner/win32_window.h` / `.cpp` | 除第二节列出的改动外，其余与模板一致（含深色标题栏、DPI 缩放、窗口类注册） |
| `runner/resource.h` | `IDI_APP_ICON = 101` |
| `runner/runner.exe.manifest` | PerMonitorV2 DPI 感知 + supportedOS 列表 |
| `runner/resources/app_icon.ico` | 模板默认图标（复制而来） |
| `.gitignore` | 只有 `flutter/ephemeral/` 一行规则（多了一段注释，见第三节） |

### 本地修改

**`CMakeLists.txt`（顶层）**

| 行 | 改动 |
| --- | --- |
| `project(dsh_app LANGUAGES CXX)` | 模板是 `project(<projectName>` |
| `set(BINARY_NAME "dsh_app")` | 任务要求 |
| `set(APPLICATION_ID "io.github.dshgo.desktop")` | 任务要求；**官方 windows 模板可能没有这个变量**，见第三节 |

**`runner/main.cpp`** — 窗口尺寸 / 最小尺寸 / 标题

| 位置 | 模板原值 | 本项目 |
| --- | --- | --- |
| `Win32Window::Size size(...)` | `(1280, 720)` | **`(1180, 820)`** — 对齐 macOS 版初始内容区尺寸 |
| 新增 `window.SetMinimumSize(...)` | 无 | **`(860, 620)`** — 对齐 macOS 版 `NSWindow.minSize` |
| `window.Create(L"...", ...)` | `L"<projectName>"`（即 `L"dsh_app"`） | **`L"DSH Go Windows"`** — 对齐 macOS 版标题 `DSH Go Mac` |
| `Win32Window::Point origin(10, 10)` | `(10, 10)` | 未改；居中改在 `Win32Window::Create()` 里做（见下），这里只用作「挑哪块显示器」的取点 |

**`runner/win32_window.cpp` / `win32_window.h`** — 居中与最小尺寸

1. `Win32Window::Create()` 里 `UpdateTheme(window)` 之后新增一段：取所在显示器的
   `MONITORINFO::rcWork`（工作区，已扣掉任务栏），用 `GetWindowRect` 取窗口实际尺寸，
   算出居中坐标，`SetWindowPos(..., SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)`
   把窗口挪到中间。等价于 macOS Runner 里的 `self.center()`。窗口此时仍不可见，
   不会闪一下。
2. `MessageHandler()` 新增 `case WM_GETMINMAXINFO`：先 `DefWindowProc` 拿到默认值
   （保留「最大化铺满工作区」等行为），再把 `ptMinTrackSize` 下界设成
   `860x620 × 显示器 DPI / 96`。等价于 macOS 的 `minSize`。
   DPI 用的是 `FlutterDesktopGetDpiForMonitor()`——官方模板 `Create()` 已经在用它，
   不引入新的 API 依赖。
3. 头文件新增 `public: void SetMinimumSize(unsigned, unsigned)` 与两个私有成员
   `min_width_ / min_height_`（逻辑像素，0 表示不限制）。

**`runner/Runner.rc`** — 版本资源里的字符串按项目替换：

| 字段 | 模板 | 本项目 |
| --- | --- | --- |
| `CompanyName` | `<organization>` | `io.github.dshgo` |
| `FileDescription` / `InternalName` / `ProductName` | `<projectName>` | `dsh_app` |
| `OriginalFilename` | `<projectName>.exe` | `dsh_app.exe` |
| `LegalCopyright` | `Copyright (C) <year> <organization>. ...` | `Copyright (C) 2026 io.github.dshgo. ...` |

其余（`VERSIONINFO` 结构、`FLUTTER_VERSION*` 宏的回退、`#pragma code_page(65001)`）未改。

### 编码说明（不是内容改动，但会和模板产物有字节差异）

`main.cpp`、`win32_window.h`、`win32_window.cpp` 里带中文注释，因此保存为
**UTF-8 with BOM**。原因：`runner/CMakeLists.txt` 用 `/W4 /WX` 编译，源码含非 ASCII
却没有 BOM 时，MSVC 在非中文代码页下会报 C4819，再被 `/WX` 变成编译错误。其余文件
没有非 ASCII 字符，保持无 BOM。

## 三、不确定 / 需要核对的地方（全部已用 `// NOTE:` 标注）

| # | 位置 | 不确定点 |
| --- | --- | --- |
| 1 | `CMakeLists.txt` `APPLICATION_ID` | 官方 windows 模板里**可能根本没有** `APPLICATION_ID`（macOS 用 `PRODUCT_BUNDLE_IDENTIFIER`、Linux 模板才用 `APPLICATION_ID`）。这里按任务要求写上；CMake 里它只是个普通变量，模板自身不引用，**不影响构建**，留给后续打包脚本用。需要核对 3.47 模板是否已原生引入同名变量。 |
| 2 | `main.cpp` 初始尺寸 | 官方模板是 `1280x720`。另外 **Win32 的 `CreateWindow` 宽高含边框和标题栏**，而 macOS 的 `setContentSize` 只算内容区，所以同为「1180x820」时 Windows 的实际内容区会小约 16×39 px。若要严格等效，需要 `AdjustWindowRectExForDpi` 补偿——本批没做，属已知偏差。 |
| 3 | `main.cpp` 最小尺寸 | 官方模板没有任何最小尺寸逻辑，`SetMinimumSize()` 是 DSH 新增 API。`WM_GETMINMAXINFO` 的 `ptMinTrackSize` 同样是**整窗**尺寸（含边框），所以用户能拉到的内容区略小于 860×620。 |
| 4 | `win32_window.cpp` 居中 | 官方模板不居中（固定落在 `origin`）。这里改为「居中到所在显示器工作区」。多显示器下取的是 `MonitorFromWindow(...MONITOR_DEFAULTTONEAREST)`，即 `Create` 时按 `origin(10,10)` 落到的那块屏。 |
| 5 | `win32_window.cpp` 最小尺寸的 DPI 来源 | 用 `FlutterDesktopGetDpiForMonitor()`（模板已在用），而不是 `GetDpiForWindow()`。两者在 PerMonitorV2 下可能有细微差别；这样选是为了不引入模板未依赖的 API。 |
| 6 | `main.cpp` 标题 | 官方模板用项目名（`L"dsh_app"`）。这里用 `L"DSH Go Windows"` 与 macOS 版 `"DSH Go Mac"` 对称——任务里没有明确规定标题，属我的推断。 |
| 7 | `Runner.rc` 年份 | `LegalCopyright` 的年份取 2026（本机当前年份），模板是按创建时的年份填入。纯展示字段，无功能影响。 |
| 8 | `.gitignore` | 官方模板只有 `flutter/ephemeral/` 一行规则，我多加了注释；规则本身相同。 |
| 9 | 模板整体版本 | 参照的模板产物约为 3.13–3.19 时期。3.47.x 是否改了 `cmake_policy(VERSION 3.14...3.25)`、`cmake_minimum_required`、native assets 的 install 段等，本机无法确认。 |

## 四、接入后的核对清单（装好 Flutter 3.47.x 之后）

1. `cd app && flutter pub get`——生成 `windows/flutter/generated_plugins.cmake`
   与 `windows/flutter/ephemeral/generated_config.cmake`。**这两个文件本批故意没有创建**：
   它们是 build 时由 Flutter 工具生成的，官方 `flutter create` 的产出里也没有，
   而且 `.gitignore` 已经忽略 `flutter/ephemeral/`。
2. 想让工具链把模板对齐到 3.47 的官方版本，可以在 `app/` 下再跑一次：
   ```bash
   flutter create --platforms=windows --project-name dsh_app .
   ```
   它只会补齐缺失/过期的平台文件（`pubspec.yaml` 不会被覆盖，但**跑之前仍建议先
   `git stash` 或备份**，方便用 `git diff` 对比它和本批手工产物的差异）。
   跑完把 `BINARY_NAME` / `APPLICATION_ID` / 尺寸 / 居中那几处改动重新加回去，
   或直接用 `git diff` 把本批的改动挪到新模板上。
3. 跑 `flutter build windows --debug`，确认能出 `dsh_app.exe`（**这一步本机没做过**）。
4. 需要时把 `windows` 追加到 `app/.metadata` 的 `migration.platforms` 里
   （本批没改 `.metadata`，因为超出任务范围）。
5. 注意：`app/lib/**`、`app/pubspec.yaml`、`app/macos/**` 本批**未做任何修改**；
   本批也**没有**创建 `dsh_channels.cpp` 之类的自定义平台通道代码——这一批只要官方模板骨架。

## 五、明确没有做的事

- 未下载/安装 Flutter SDK，未联网抓模板。
- 未尝试编译，未验证 `flutter build windows` 能否通过。
- 未创建 `windows/runner/resources/app_icon.ico` 以外的任何资源（图标即模板默认图标，
  后续换成 DSH 品牌图标时替换这个文件即可）。
- 未修改 `app/lib/**`、`app/pubspec.yaml`、`app/macos/**`，未做任何 git commit/push。
