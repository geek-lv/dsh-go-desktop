# 桌面引擎运行时（Windows / Linux）

对应脚本：`runtime/build-runtime-desktop.sh`（参数化 `--platform windows|linux --arch x64`）。
结构照搬 `runtime/build-runtime-macos.sh`：官方 Node → `npm ci` 装 DSH 树 → 装 pnpm →
拷 `runtime/bridge/dsh-go-bridge` → `python3 runtime/lib/rtbuild.py patch-dsh` 打补丁 →
`tar.gz` + `manifest.json`。**不打包任何浏览器内核**，也不打包 PRoot / Ubuntu rootfs。

- Windows：**本机（Windows 11，Node v26.3.0 宿主、MSVC/CMake/Ninja 已装）实测跑通**，
  产物可启动。原始输出见文末「实测记录」。
- Linux：脚本的 Linux 分支**未运行验证**（本机没有 Linux 环境，也没有开 WSL）。

## 1. 两个平台的布局

`tar.gz` 顶层统一是 `runtime/`（和 macOS 一致，App 解压后取 `runtime/` 这一层）：

```
runtime/
├── node/                         # 官方 Node 发行版，原样打包
│   ├── node.exe  npm.cmd  npx.cmd  pnpm.cmd     ← Windows：可执行文件都在根目录
│   └── bin/{node,npm,npx,pnpm}                  ← Linux：可执行文件在 bin/
├── dsh/                          # npm ci 出来的 DSH 依赖树（已打 105 个补丁）
│   └── node_modules/@deepseek-ai/dsh/lib/bin.js # 启动入口（两平台相同）
├── bridge/dsh-go-bridge/         # DSH 侧桥插件
├── etc/dsh-app/runtime.json      # 运行时自述（版本、平台）
├── home/.dsh/                    # 空 HOME
└── tmp/
```

Windows 实测产物（`runtime-x64.tar.gz`）里这三条关键路径都在：

```
runtime/node/node.exe
runtime/node/npm.cmd
runtime/node/pnpm.cmd
runtime/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js
runtime/bridge/package.json
runtime/etc/dsh-app/runtime.json
```

> **Windows 的 Node 布局是这套方案里最容易踩的坑**：`node.exe` / `npm.cmd` / `npx.cmd`
> 在 zip 的**根目录**，没有 `bin/`；脚本里的 `node_rel` 因此是 `node/node.exe` 而不是
> `node/bin/node`。所有拼路径的地方（启动 argv、PATH）都必须按平台取。

## 2. manifest 字段差异

公共字段与 macOS 相同：`runtimeVersion` / `abi` / `archive` / `archiveBytes` /
`archiveSha256` / `uncompressedBytes` / `dshVersion` / `nodeVersion` / `launch.tokenLine`。
下面只列**平台相关**的：

| 字段 | Windows（`desktop-win-r1`） | Linux（`desktop-linux-r1`） |
| --- | --- | --- |
| `platform` | `win32-x64` | `linux-x64` |
| `launch.argv[0]` | `{RUNTIME}/node/node.exe` | `{RUNTIME}/node/bin/node` |
| `exeSuffix` | `.exe` | `""` |
| `launchEnv` | 只有 `TMPDIR` / `DSH_HOME`（PATH 不能整体替换，见下） | 与 macOS 同款：`HOME` / `DSH_HOME` / `PATH` / `TMPDIR` / `LANG` / `TERM` / `NODE_OPTIONS` |
| `pathPrepend` | `["{RUNTIME}/node"]` | 无 |
| `launch.patch` | `{RUNTIME}/etc/dsh-app/dsh-web.patch.yml` | 同左 |

`launch.argv` 的 `{DSH_PROFILE_ARGS}` 展开成 `web --patch <...>/dsh-web.patch.yml`
（逻辑在 `app/lib/macos/mac_runtime.dart:1162 expandMacLaunchArgs`，两平台通用）。

**PATH 的语义差别（必须由桌面桥实现遵守）**：

- macOS/Linux 现有实现是**整体替换** PATH（`mac_runtime.dart:619`
  `'${runtimeDir.path}/node/bin:/usr/local/bin:...'`），因为 POSIX 上 node 只需要自己的目录。
- Windows **不能替换**：`node.exe` 及其 conpty 依赖系统目录（`System32`），而 Dart 的
  `Process.start(environment:)` 会覆盖同名变量。所以 Windows 的 manifest 不给 PATH，
  改用 `pathPrepend` 表达「把这个目录追加到继承来的 PATH 最前面」。桌面桥实现时按这个
  做（Linux 仍可用 macOS 的 launchEnv 写法）。

## 3. 实测记录（Windows，本机）

环境：Windows 11 `10.0.26100`，`node v26.3.0`、`npm 11.16.0`、Git Bash（`uname -s` =
`MINGW64_NT-10.0-26100`）、`C:\Program Files\Python312\python.exe`。没有 Flutter SDK。

### 3.1 先做的可行性验证：`npm ci` 到临时目录

在仓库外 `C:\Works\.tmp-rt-desktop\npmci`（只拷 `runtime/locks/dsh-0.2.2-rc.1/` 的
`package.json` + `package-lock.json`）：

```
> npm ci --no-audit --no-fund --loglevel=error
added 589 packages in 16s
EXIT=0
```

这一条同时回答了「Windows 上要不要为平台相关的 optionalDependencies 重编译」：
**不需要**。锁文件共 662 个包、其中 76 个带 `os`/`cpu` 约束，`npm ci` 按当前平台挑了
589 个，win32-x64 的预编译产物都在：

```
@img/sharp-win32-x64                   ✓
@koromix/koffi-win32-x64               ✓
@vscode/ripgrep-win32-x64              ✓
sherpa-onnx-win-x64                    ✓
@deepseek-ai/libreoffice-kit-win32-x64 ✓
node-addon-require-builtin-win32-x64-msvc ✓
@deepseek-ai/dsh-win32-process         ✓
@deepseek-ai/node-addon-system         ✗（锁文件里只有 darwin/linux 变体，Windows 上没有）
```

`node-pty@1.2.0-beta.15` 带 `hasInstallScript`，但它**自带预编译**，不需要 node-gyp：

```
node_modules/node-pty/prebuilds/win32-x64/conpty.node
node_modules/node-pty/prebuilds/win32-x64/conpty_console_list.node
```

所以脚本和 macOS/Android 一样用 `--ignore-scripts`，MSVC 也不必开工。

### 3.2 正式构建（`--platform windows`）

命令：

```bash
& 'C:\Program Files\Git\bin\bash.exe' runtime/build-runtime-desktop.sh --platform windows
```

关键输出（完整日志在 `C:\Works\.tmp-rt-desktop\build-win2.log`，120 行补丁输出此处省略）：

```
== 下载 Node 24.22.1 (win-x64)          # node-v24.22.1-win-x64.zip，35.99 MB，已用
                                          # nodejs.org 的 SHASUMS256.txt 校验 sha256
v24.22.1
== 安装 DSH 0.2.2-rc.1（npm ci，os=win32 cpu=x64）
added 589 packages in 52s
== 安装 pnpm 11.28.5
added 1 package in 3s
== 组装运行时
== 应用 dsh 补丁
  … 105 个 .diff，逐条 "zzz…-xxx.diff: patched node_modules/… (旧sha -> 新sha)"
== 打包（gzip）
== 写 manifest
{
  "runtimeVersion": "desktop-win-r1",
  "platform": "win32-x64",
  "archiveBytes": 193245593,
  "dshVersion": "0.2.2-rc.1",
  "nodeVersion": "24.22.1",
  "pnpmVersion": "11.28.5"
}
== 校验 manifest
manifest ok: desktop-win-r1 / DSH 0.2.2-rc.1 / win32-x64
== 完成：…/app/assets/runtime-windows/runtime-x64.tar.gz（184 MiB，解包 677 MiB）
EXIT=0
```

产物：

| 项 | 值 |
| --- | --- |
| 归档 | `app/assets/runtime-windows/runtime-x64.tar.gz` |
| 字节 | `193,245,593`（184 MiB） |
| sha256 | `51c783c4e067d9207ccb6bd6f7bd5afebc877f01f59195e3a31c41174f50ff4e` |
| 解包 | `710,378,496` 字节（677 MiB） |
| DSH 补丁 | 105 个 `.diff`，合计 134 次文件级应用（`grep -c ': patched '`） |

### 3.3 产物真的能跑（Windows，实测）

在 `runtime/.work/desktop-windows/stage/runtime` 上直接跑（HOME/DSH_HOME/TMPDIR 指到
运行时自己的 home/tmp）：

```
> node\node.exe --version
v24.22.1

> node\node.exe dsh\node_modules\@deepseek-ai\dsh\lib\bin.js --version
0.2.2-rc.1
EXIT=0
```

再按 manifest 的 argv 真启动一次 Web 引擎（`--patch` 由 App 启动时生成，这里先不给）：

```
> node\node.exe …\dsh\lib\bin.js web --host 127.0.0.1 --port 38917 --no-open
dsh web: http://127.0.0.1:38917/?token=a-s9mN3SWswTeWvHd1xkORbdW1Nj-Jv-2kmP-_fnUfo
```

把这一行喂给 manifest 里的 `tokenLine.regex`：

```
^dsh web: (http://127\.0\.0\.1:[0-9]+/)\?token=([A-Za-z0-9_-]+)
→ REGEX OK  group1=http://127.0.0.1:38917/  group2len=43
```

也就是说 Windows 上「起引擎 → 拿到 baseUrl + token」这条链路**已经验证**。
（这一跑用的是临时端口；用完已结束进程。）

## 4. 实测遇到的问题

1. **`rtbuild.py` 在 Windows 上读补丁会崩（已绕开，未改共享代码）**：

   ```
   UnicodeDecodeError: 'gbk' codec can't decode byte 0x94 in position 991
   ```

   `runtime/lib/rtbuild.py:352` 用 `open(...).read()` 读 `runtime/patches/*.diff`，
   没指定编码；Linux/macOS 默认 UTF-8 没问题，Windows 按 `locale.getpreferredencoding()`
   取到 GBK 就炸。**没有改 rtbuild.py**（它是 Android/macOS 共用的），而是在脚本里所有
   Python 调用都加 `-X utf8`（等价于 `PYTHONUTF8=1`），对 POSIX 平台无行为变化。

2. **Git Bash 的 `python3` 是 Microsoft Store 占位程序**，`python3 -c` 会失败。
   脚本里加了解释器探测：`PYTHON` 环境变量 → `python3` → `python` → 常见的
   `C:\Program Files\Python312\python.exe`。

3. **Git Bash 的 `tar` 会把 `C:` 当成远程主机**（`tar: Cannot connect to C: resolve failed`）。
   解包 zip 用 `unzip`（Git Bash 自带），打 tar.gz 时只用相对/`-C` 路径，实测没问题。
   手工核对产物时用 `C:\Windows\System32\tar.exe`。

4. **`npm` 是 `npm.cmd`**：从 bash 调它、以及把 MSYS 路径传给原生 npm 都会出问题。
   脚本用 `cygpath -w`（Git Bash 自带）把 `--cache` / `--prefix` / `--userconfig` /
   `--globalconfig` 翻成 Windows 路径，并 `cd` 进目录再跑 `npm ci`。

5. **`chmod 700 home/.dsh` 在 Windows 上是空操作**（Git Bash 只动模拟位）。脚本里
   `|| true`，Linux 上仍按原样生效。

6. **`dsh-web.patch.yml` 不在运行时包里**：macOS 是 App 启动时用
   `mac_runtime.dart:_ensureRuntimeLayout` 现写（bridge 绝对路径每次都变），所以 manifest
   只声明路径、产物里可以没有。桌面桥必须做同样的事，否则 `--patch` 指向不存在的文件。

## 5. 交付物与接入待办

- `runtime/build-runtime-desktop.sh`：本次新增，Windows 分支实测通过。
- 产物目录 `app/assets/runtime-windows/`（`runtime-x64.tar.gz` + `manifest.json`）。
  体积大、可重建，**不要提交**；`app/assets/runtime-macos/README.md` 的约定同样适用。
- 接入 App 还差三件（都不在本次改动范围）：
  1. `app/pubspec.yaml` 的 `flutter: assets:` 加 `assets/runtime-windows/`（以及 Linux 的）；
  2. `DesktopRuntimeBridge`（参照 `MacRuntimeBridge`）读 manifest、解包、起进程；
     解压要换掉 `/usr/bin/tar`、`/usr/bin/du`、`/usr/bin/xattr`（见
     `docs/desktop/README.md` 阶段 1.2 的表格）；
  3. Windows 上 PATH 用 `pathPrepend` 语义，不要照抄 macOS 的整体替换。

### Linux 分支的未验证项

- 整条链路没跑过：`node-v24.22.1-linux-x64.tar.xz` 下载/校验、`npm ci --os=linux
  --libc=glibc`、`lib/node_modules/pnpm/bin` 布局、`tar -xJf`。
- Linux 上 `npm ci` 会挑 `@img/sharp-linux-x64`、`@koramix/koffi-linux-x64`、
  `@vscode/ripgrep-linux-x64`、`sherpa-onnx-linux-x64`、`node-addon-require-builtin-linux-x64-gnu`
  等（锁文件里都有），按 Windows 的结果推断应当同样免编译，但**没有实际装过**。
- 产物名按 `docs/desktop/README.md` 的约定是 `runtime-linux-x64.tar.gz`，脚本目前两个
  平台都叫 `runtime-x64.tar.gz`（放在各自的 `assets/runtime-<platform>/` 目录里，
  目录已经区分平台）。若打包脚本按文件名取产物，需要改一行。
