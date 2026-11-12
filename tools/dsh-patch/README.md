# dsh-patch — DSH 核心补丁链（Node 单一实现）

把 `runtime/patches/*.diff` 应用到 DSH 的 npm 前缀。**构建机与用户机共用这一份实现**：
用户机器上没有 Python，而 Node 本来就要随 App 发（用来跑 DSH 自己）。

`runtime/lib/rtbuild.py patch-dsh` 与它语义逐条对齐，并由 `parity.sh` 每次对拍保证：
同一份 pristine 树打同一套补丁，产物逐字节一致、`--record` 写出的 `pins.json` 内容一致。

## 用法

```bash
# 应用（必须是已审查、pins.json 里有该版本的记录）
node tools/dsh-patch/cli.mjs apply  --prefix <npm 前缀> --dsh-version 0.2.2-rc.1

# 兼容性预检：对**没审查过的新版本**逐个补丁试打，不写盘，输出报告
node tools/dsh-patch/cli.mjs check  --prefix <npm 前缀> --dsh-version 0.2.3-rc.1 --json report.json

# 记录审查结果（人工看过上游文件与新上下文后才用）
node tools/dsh-patch/cli.mjs record --prefix <npm 前缀> --dsh-version 0.2.2-rc.1
```

参数：`--patches <dir>`（默认 `runtime/patches`）、`--companion <dir>`（默认 `runtime/session-deletion`，
`zzzzzz-session-deletion.diff` 的伴生文件）、`--json <file>`、`--quiet`。

退出码：`0` 全部通过；`1` 有补丁失效（报告里逐条写明 `contextMissing` / `ambiguousContext` /
`hashMismatch` / `fileMissing`）；`2` 参数或环境错误。

## 规则（与 Python 版一致，这是补丁链可信的全部来源）

1. 纯 unified diff，**不 fuzz**：每个 hunk 的原文块必须在文件里恰好出现一次；
2. 有 pin 的版本逐文件校验 sha256：打前 == `before`，打后 == `after`；
3. 同一文件被多个补丁改过时，哈希必须连成一条链（`terminal` 表），断链直接报错；
4. 整棵树已经是最终产物时幂等跳过；
5. 写盘走「临时文件 + rename」，不改 inode（`npm ci` 的树里可能是硬链接）。

`check` 模式额外做的事：没有该版本的 pin 时，用**内存里的哈希链推进**模拟真实应用顺序
（`virtual` / `progress`），因此同一文件被多个补丁改过也能判断出后一个补丁是否还成立。

## 为什么不用 Python（构建机仍保留 Python，但只用于 Android rootfs）

- 用户机上没有 Python，而补丁要在用户机上打；
- 双实现必然漂移（本次移植就踩到两处：dry-run 的哈希链推进、`record` 的幂等跳过）；
- Python 在 Windows 上以文本模式写 `pins.json` 会变成 CRLF（本仓库约定 LF），
  读 `*.diff` 还会受本地代码页影响（见 `docs/desktop/runtime-desktop.md:191`）。

`runtime/lib/rtbuild.py` 里的 `deb-extract` / `resolve-debs` / `patch-dynstr` / `elf-info` /
`hoist-candidates` / `assemble` / `manifest` 仍然留在 Python：那是 Android rootfs 的构建工具，
只在构建机上跑。

## 测试与对拍

```bash
node --test tools/dsh-patch/test/patch.test.mjs   # 规则单测（8 例，无外部依赖）
bash tools/dsh-patch/parity.sh                    # 与 Python 版对拍（默认用桌面构建缓存里的 pristine 树）
```

`parity.sh` 只复制补丁实际触碰的文件（约 70 个），所以对拍是秒级的，不需要 548 MB 的整棵树。
