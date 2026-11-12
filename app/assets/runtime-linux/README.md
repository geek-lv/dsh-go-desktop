# Linux 本机引擎运行时（构建产物）

这个目录在构建前是空的（只有本说明和 `.gitkeep`）。运行时包由脚本生成：

```bash
# 在 Linux（或任意带 xz 的 POSIX 环境）上跑
bash runtime/build-runtime-desktop.sh --platform linux
```

生成后会有：

- `manifest.json`：版本、sha256、启动 argv（`{RUNTIME}/node/bin/node`）
- `runtime-x64.tar.gz`：Node 24（linux-x64）+ DSH + pnpm + dsh-go-bridge

两者都被 `.gitignore` 忽略：包太大，可以从 `runtime/locks/` 里的锁文件重建。
**Linux 分支尚未在任何 Linux 机器上实际构建过**（见 `docs/desktop/runtime-desktop.md`
的「Linux 分支的未验证项」）。

接入 `app/` 时还需要（不在本目录范围内）：

1. `app/pubspec.yaml` 的 `flutter: assets:` 加 `assets/runtime-linux/`；
2. 一个 `DesktopRuntimeBridge` 读 manifest、解包、起 `node`；
3. 解压不要用 `/usr/bin/tar` 硬编码（见 `docs/desktop/README.md` 阶段 1.2）。
