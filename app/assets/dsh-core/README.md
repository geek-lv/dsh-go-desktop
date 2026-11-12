# dsh-core（App 资源，自动同步，别手改）

这里是「在用户机器上安装/更新 DSH 核心」所需的一切：

| 路径 | 内容 | 来源 |
|---|---|---|
| `*.mjs` | 补丁链（`cli` / `diff` / `apply`） | `tools/dsh-patch/` |
| `patches/` | 106 个补丁 + `pins.json` | `runtime/patches/` |
| `locks/dsh-<ver>/` | 审查过的版本的锁文件 | `runtime/locks/` |

运行时由 `lib/runtime/dsh_patch_tool.dart` 解压到 `<app support>/dsh-core/`，用本机引擎
自带的 node 执行 `tools/cli.mjs`。用户机器上没有仓库、也没有 Python，所以必须随 App 发。

## 同步 / 防漂移

```bash
bash tooling/sync-dsh-core-assets.sh          # 同步（改完 tools/dsh-patch 或 runtime/patches 后跑）
bash tooling/sync-dsh-core-assets.sh --check  # 只检查是否已同步（CI/发版前用）
```

改补丁链或补丁集之后**忘了同步**，App 里装出来的核心就会和构建机不一致：
`--check` 会列出不同步与多余的文件并以非零退出。
