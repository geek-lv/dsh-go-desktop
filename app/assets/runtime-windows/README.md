# Windows 本机引擎运行时（构建产物）

这个目录在构建前是空的（只有本说明和 `.gitkeep`）。运行时包由脚本生成：

```bash
# Windows 上用 Git Bash 跑（自带 curl / unzip / tar / sha256sum）
bash runtime/build-runtime-desktop.sh --platform windows
```

生成后会有：

- `manifest.json`：版本、sha256、启动 argv（`{RUNTIME}/node/node.exe`）
- `runtime-x64.tar.gz`：Node 24（win-x64）+ DSH + pnpm + dsh-go-bridge，约 184 MiB

两者都被 `.gitignore` 忽略：包太大，而且完全可以从 `runtime/locks/` 里的锁文件重建。
构建细节、manifest 字段差异和实测记录见 `docs/desktop/runtime-desktop.md`。

接入 `app/` 时还需要（不在本目录范围内）：

1. `app/pubspec.yaml` 的 `flutter: assets:` 加 `assets/runtime-windows/`；
2. 一个 `DesktopRuntimeBridge` 读 manifest、解包、起 `node.exe`；
3. Windows 上 PATH 用 manifest 的 `pathPrepend` 语义（追加，不要替换）。
