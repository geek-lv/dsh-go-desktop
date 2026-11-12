// 把 `runtime/patches/*.diff` 应用到 DSH npm 前缀。
//
// 这是 `runtime/lib/rtbuild.py patch-dsh` 的 Node 移植，语义逐条对齐：
//
//   1. 按文件名排序应用（`zz*` 前缀就是为了排在最后）；
//   2. 有 pin 的版本必须逐文件校验 sha256：打之前 == before、打之后 == after；
//      同一文件被多个补丁改过时，哈希必须连成一条链（terminal 表）；
//   3. 已经是我们产物（等于 after 或链上前一个产物）时幂等跳过；
//   4. 写文件走「临时文件 + rename」，不改写 inode（npm ci 的树可能是硬链接）；
//   5. `zzzzzz-session-deletion.diff` 额外带一个源文件，需要一起装。
//
// 新增（Python 版没有）：compat 模式的**逐补丁兼容性报告**——对没有 pin 的更新版本
// dry-run 试打，能打上的记 `wouldApply`，打不上的记 `contextMissing`/`ambiguousContext`，
// 供"跟随上游但别整体崩溃"的策略使用。

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import { PatchContextError, applyHunks, parseUnifiedDiff } from './diff.mjs';

/** 状态：ok 的三态表示"最终符合预期"。 */
export const FILE_STATUS = Object.freeze({
  alreadyPatched: 'alreadyPatched',
  applied: 'applied',
  wouldApply: 'wouldApply',
  fileMissing: 'fileMissing',
  contextMissing: 'contextMissing',
  ambiguousContext: 'ambiguousContext',
  hashMismatch: 'hashMismatch',
  invalidPatch: 'invalidPatch',
});

const OK_STATUSES = new Set([FILE_STATUS.alreadyPatched, FILE_STATUS.applied, FILE_STATUS.wouldApply]);

export const SESSION_DELETION_PATCH = 'zzzzzz-session-deletion.diff';
const SESSION_DELETION_TARGET = 'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/dsh-go-deletion.mjs';

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

/** 读 `runtime/patches/`：按文件名排序的补丁 + pins.json。 */
export function loadPatchSet(patchesDir) {
  const names = fs
    .readdirSync(patchesDir)
    .filter((name) => name.endsWith('.diff'))
    .sort();
  if (names.length === 0) throw new Error(`没有补丁：${patchesDir}`);
  const patches = names.map((name) => ({
    name,
    files: parseUnifiedDiff(fs.readFileSync(path.join(patchesDir, name), 'utf8')),
  }));
  const pinsPath = path.join(patchesDir, 'pins.json');
  const pins = fs.existsSync(pinsPath) ? JSON.parse(fs.readFileSync(pinsPath, 'utf8')) : { schema: 1, patches: {} };
  return { patches, pins, pinsPath };
}

function pinFor(pins, patchName, dshVersion, rel) {
  return pins?.patches?.[patchName]?.[dshVersion]?.[rel];
}

function hasPinsFor(pins, dshVersion) {
  return Object.values(pins?.patches ?? {}).some((byVersion) => byVersion && byVersion[dshVersion]);
}

/**
 * @param {object} options
 * @param {string} options.prefix            npm 前缀目录（里面是 node_modules/）
 * @param {object} options.set               loadPatchSet() 的结果
 * @param {string} options.dshVersion
 * @param {'apply'|'check'|'record'} [options.mode]
 * @param {boolean} [options.allowUnpinned] 没有该版本 pin 时也允许 apply（best-effort）
 * @param {string} [options.companionDir]    runtime/session-deletion（相对仓库）
 * @param {(line: string) => void} [options.log]
 * @returns {{report: object, pins: object}}
 */
export function runPatchSet({
  prefix,
  set,
  dshVersion,
  mode = 'apply',
  companionDir,
  allowUnpinned = false,
  log = () => {},
}) {
  const dryRun = mode === 'check';
  const record = mode === 'record';
  const pinned = hasPinsFor(set.pins, dshVersion);
  if (mode === 'apply' && !pinned && !allowUnpinned) {
    throw new Error(
      `补丁集没有 DSH ${dshVersion} 的审查记录（pins.json）；` +
        '先用 check 看兼容性，或确认后 record 记录该版本',
    );
  }

  log(`应用 ${set.patches.length} 个补丁到 ${prefix}（dsh=${dshVersion} mode=${mode} pinned=${pinned}）`);

  // terminal 表：每个文件**最终**应该长成什么样（最后一个补丁的 after）。
  // Python 版是预扫一遍算出来的（不是逐个推进）：于是"整棵树已经全打过"可以直接跳过，
  // 而不用重放整条链。这里照抄同一语义，并顺便校验链的连续性。
  const terminal = new Map();
  if (!record) {
    for (const patch of set.patches) {
      const byFile = set.pins?.patches?.[patch.name]?.[dshVersion] ?? {};
      for (const [rel, pin] of Object.entries(byFile)) {
        if (terminal.has(rel) && terminal.get(rel) !== pin.before) {
          throw new Error(`${patch.name}: 补丁哈希链断裂（${rel}）`);
        }
        terminal.set(rel, pin.after);
      }
    }
  }
  // check 模式不写盘，但内容必须像真的一样前进：内存里保存每个文件的虚拟产物。
  const virtual = new Map();
  // 没有 pin 时（跟随上游的新版本）用"本批补丁产生的哈希"做幂等判断。
  const progress = new Map();
  const results = [];
  const recorded = {};

  for (const patch of set.patches) {
    const want = record ? undefined : set.pins?.patches?.[patch.name]?.[dshVersion];
    if (mode === 'apply' && want === undefined && !allowUnpinned) {
      throw new Error(`补丁 ${patch.name} 没有 DSH ${dshVersion} 的 pin`);
    }
    const fileResults = [];
    const observed = {};
    for (const filePatch of patch.files) {
      const result = applyOneFile({
        prefix,
        patchName: patch.name,
        filePatch,
        pin: record ? undefined : want?.[filePatch.path],
        terminal,
        progress,
        virtual,
        dryRun,
        dshVersion,
        record,
        log,
      });
      fileResults.push(result);
      if (record && result.before && result.after) {
        observed[filePatch.path] = { before: result.before, after: result.after };
      }
    }
    if (record) recorded[patch.name] = observed;
    results.push({ patch: patch.name, ok: fileResults.every((f) => OK_STATUSES.has(f.status)), files: fileResults });
  }

  // 会话删除补丁的伴生文件（Python 版在应用完补丁后拷贝）。
  let companion = null;
  if (!dryRun && results.some((r) => r.patch === SESSION_DELETION_PATCH && r.ok) && companionDir) {
    const source = path.join(companionDir, 'core.mjs');
    if (fs.existsSync(source)) {
      const target = path.join(prefix, ...SESSION_DELETION_TARGET.split('/'));
      fs.mkdirSync(path.dirname(target), { recursive: true });
      const tmp = `${target}.dsh-app-patch`;
      fs.copyFileSync(source, tmp);
      fs.chmodSync(tmp, 0o644);
      fs.renameSync(tmp, target);
      companion = { path: SESSION_DELETION_TARGET, sha256: sha256(fs.readFileSync(target)) };
      log(`安装伴生文件 ${SESSION_DELETION_TARGET}`);
    }
  }

  const files = results.flatMap((r) => r.files);
  const report = {
    dshVersion,
    mode,
    pinned,
    dryRun,
    patches: results.length,
    patchesOk: results.filter((r) => r.ok).length,
    files: files.length,
    filesOk: files.filter((f) => OK_STATUSES.has(f.status)).length,
    lost: results.filter((r) => !r.ok).map((r) => r.patch),
    companion,
    results,
  };
  log(
    `dsh ${dshVersion}: ${report.patchesOk}/${report.patches} 补丁可用` +
      (report.lost.length ? `，失效：${report.lost.join(', ')}` : ''),
  );

  if (record) {
    for (const [patchName, observed] of Object.entries(recorded)) {
      set.pins.patches ??= {};
      set.pins.patches[patchName] ??= {};
      set.pins.patches[patchName][dshVersion] = observed;
    }
    writePins(set.pinsPath, set.pins);
    log(`已记录 DSH ${dshVersion} 的哈希到 ${set.pinsPath}`);
  }
  return { report, pins: set.pins };
}

function applyOneFile({ prefix, patchName, filePatch, pin, terminal, progress, virtual, dryRun, dshVersion, record, log }) {
  const label = `${patchName} ${filePatch.path}`;
  const abs = path.join(prefix, ...filePatch.path.split('/'));
  const cached = virtual.get(filePatch.path);
  if (cached === undefined && !fs.existsSync(abs)) {
    log(`${label}: 目标文件不存在`);
    return { path: filePatch.path, status: FILE_STATUS.fileMissing, detail: abs };
  }
  const bytes = cached ?? fs.readFileSync(abs);
  const before = sha256(bytes);

  if (pin) {
    if (before === pin.after || before === terminal.get(filePatch.path)) {
      // 已经是这个补丁的产物，或者整棵树已经是最终产物：幂等跳过。
      progress.set(filePatch.path, before);
      return { path: filePatch.path, status: FILE_STATUS.alreadyPatched, before, after: before };
    }
    if (before !== pin.before) {
      const detail = `before ${before.slice(0, 12)} ≠ pin ${String(pin.before).slice(0, 12)}`;
      log(`${label}: ${detail}（DTS ${dshVersion}）`);
      return { path: filePatch.path, status: FILE_STATUS.hashMismatch, before, detail };
    }
  } else if (!record && progress.get(filePatch.path) === before) {
    // 只在 check 模式用「本批前面补丁的产物」做幂等判断：同一文件被多个补丁改过时，
    // record 必须逐个真打（Python 版在 record 下也跳过所有幂等/哈希检查）。
    return { path: filePatch.path, status: FILE_STATUS.alreadyPatched, before, after: before };
  }

  let patched;
  try {
    patched = applyHunks(bytes.toString('utf8'), filePatch.hunks, label);
  } catch (error) {
    if (error instanceof PatchContextError) {
      log(`${label}: ${error.message}`);
      return {
        path: filePatch.path,
        status: error.ambiguous ? FILE_STATUS.ambiguousContext : FILE_STATUS.contextMissing,
        before,
        detail: error.message,
      };
    }
    throw error;
  }

  const after = sha256(Buffer.from(patched, 'utf8'));
  if (pin && after !== pin.after) {
    const detail = `after ${after.slice(0, 12)} ≠ pin ${String(pin.after).slice(0, 12)}`;
    log(`${label}: ${detail}`);
    return { path: filePatch.path, status: FILE_STATUS.hashMismatch, before, after, detail };
  }

  progress.set(filePatch.path, after);
  if (dryRun) {
    virtual.set(filePatch.path, Buffer.from(patched, 'utf8'));
    log(`${label}: 可应用（${before.slice(0, 12)} → ${after.slice(0, 12)}）`);
    return { path: filePatch.path, status: FILE_STATUS.wouldApply, before, after };
  }

  // 临时文件 + rename：npm ci 的树里可能有硬链接，就地改写会波及别处。
  const mode = fs.statSync(abs).mode & 0o777;
  const tmp = `${abs}.dsh-app-patch`;
  fs.writeFileSync(tmp, patched, 'utf8');
  fs.chmodSync(tmp, mode);
  fs.renameSync(tmp, abs);
  virtual.set(filePatch.path, Buffer.from(patched, 'utf8'));
  log(`${label}: 已应用（${before.slice(0, 12)} → ${after.slice(0, 12)}）`);
  return { path: filePatch.path, status: FILE_STATUS.applied, before, after };
}

/** 与 Python 版 `json.dump(pins, indent=2, sort_keys=True)` 等价的输出。 */
export function writePins(pinsPath, pins) {
  fs.writeFileSync(pinsPath, `${JSON.stringify(sortedDeep(pins), null, 2)}\n`, 'utf8');
}

function sortedDeep(value) {
  if (Array.isArray(value)) return value.map(sortedDeep);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, sortedDeep(value[key])]),
    );
  }
  return value;
}
