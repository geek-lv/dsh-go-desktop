// `node --test tools/dsh-patch/` —— 补丁链的规则单测（不依赖 Flutter / Python）。
//
// 这些用例锁住的都是「补丁链可信」的那几条规则：不 fuzz、恰好命中一次、哈希链、
// 幂等、以及**未知版本不抛异常而是给报告**（跟随上游时的降级前提）。

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { loadPatchSet, runPatchSet } from '../apply.mjs';
import { applyHunks, parseUnifiedDiff } from '../diff.mjs';

const ORIGINAL = 'line one\nline two\nline three\n';

/** 造一个最小 npm 前缀 + 一套补丁目录。 */
function fixture({ diff, pins, file = 'node_modules/pkg/lib/index.js', content = ORIGINAL }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-patch-'));
  const prefix = path.join(root, 'prefix');
  const patches = path.join(root, 'patches');
  fs.mkdirSync(path.join(prefix, path.dirname(file)), { recursive: true });
  fs.mkdirSync(patches, { recursive: true });
  fs.writeFileSync(path.join(prefix, file), content);
  fs.writeFileSync(path.join(patches, 'a-test.diff'), diff);
  fs.writeFileSync(
    path.join(patches, 'pins.json'),
    `${JSON.stringify({ schema: 1, patches: pins ?? {} }, null, 2)}\n`,
  );
  return { root, prefix, patches, file };
}

/** line two → line 2。 */
const DIFF = `--- a/${'node_modules/pkg/lib/index.js'}\n+++ b/${'node_modules/pkg/lib/index.js'}\n@@ -1,3 +1,3 @@\n line one\n-line two\n+line 2\n line three\n`;

test('unified diff 解析与 hunk 应用', () => {
  const files = parseUnifiedDiff(DIFF);
  assert.equal(files.length, 1);
  assert.equal(files[0].path, 'node_modules/pkg/lib/index.js');
  const out = applyHunks(ORIGINAL, files[0].hunks, 'test');
  assert.equal(out, 'line one\nline 2\nline three\n');
});

test('原文块必须恰好命中一次：命中 0 次报 context，命中多次报 ambiguous', () => {
  const hunk = parseUnifiedDiff(
    '--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n',
  )[0].hunks;
  // 只在末尾出现一次：能打上
  assert.equal(applyHunks('z\na\nb\n', hunk, 'x'), 'z\na\nB\n');

  // 出现两次：不 fuzz，直接拒绝
  assert.throws(() => applyHunks('a\nb\na\nb\n', hunk, 'x'), /命中 2 处/);

  // 一次都没有：上游文件变了
  assert.throws(() => applyHunks('nothing here\n', hunk, 'x'), /命中 0 处/);
});

test('严格模式：有 pin 且哈希匹配时应用，产物与 pin.after 一致', async () => {
  const { prefix, patches } = fixture({ diff: DIFF });
  // 先用 record 生成 pin，再清空文件重跑 apply
  const set = loadPatchSet(patches);
  runPatchSet({ prefix, set, dshVersion: '1.0.0', mode: 'record', log: () => {} });

  const fresh = fixture({ diff: DIFF, pins: set.pins.patches });
  const again = loadPatchSet(fresh.patches);
  const { report } = runPatchSet({ prefix: fresh.prefix, set: again, dshVersion: '1.0.0', mode: 'apply' });
  assert.equal(report.lost.length, 0);
  assert.equal(fs.readFileSync(path.join(fresh.prefix, fresh.file), 'utf8'), 'line one\nline 2\nline three\n');
});

test('幂等：已是我们产物的树再 apply 一次不报错', async () => {
  const { prefix, patches } = fixture({ diff: DIFF });
  const set = loadPatchSet(patches);
  runPatchSet({ prefix, set, dshVersion: '1.0.0', mode: 'record', log: () => {} });
  const { report } = runPatchSet({ prefix, set, dshVersion: '1.0.0', mode: 'apply' });
  assert.equal(report.lost.length, 0);
  assert.equal(report.results[0].files[0].status, 'alreadyPatched');
});

test('严格模式拒绝没有 pin 的版本（发版绑定版本的保证）', () => {
  const { prefix, patches } = fixture({ diff: DIFF });
  const set = loadPatchSet(patches);
  assert.throws(() => runPatchSet({ prefix, set, dshVersion: '9.9.9', mode: 'apply' }), /pins\.json/);
});

test('未知版本 check 模式：上下文失配只出报告，不抛异常', () => {
  // 模拟上游改了上下文（line two → line 2 already），补丁应被判失效
  const { prefix, patches } = fixture({ diff: DIFF, content: 'line one\nline 2\nline three\n' });
  const set = loadPatchSet(patches);
  const { report } = runPatchSet({ prefix, prefix, set, dshVersion: '9.9.9', mode: 'check' });
  assert.equal(report.lost.length, 1);
  assert.equal(report.results[0].files[0].status, 'contextMissing');
  // 文件没被改动
  assert.equal(fs.readFileSync(path.join(prefix, 'node_modules/pkg/lib/index.js'), 'utf8'), 'line one\nline 2\nline three\n');
});

test('未知版本 check 模式：能打上时报告 wouldApply 且不写盘', () => {
  const { prefix, patches } = fixture({ diff: DIFF });
  const set = loadPatchSet(patches);
  const { report } = runPatchSet({ prefix, set, dshVersion: '9.9.9', mode: 'check' });
  assert.equal(report.lost.length, 0);
  assert.equal(report.results[0].files[0].status, 'wouldApply');
  assert.equal(fs.readFileSync(path.join(prefix, 'node_modules/pkg/lib/index.js'), 'utf8'), ORIGINAL);
});

test('哈希链断裂要报错，而不是悄悄跳过', () => {
  const rel = 'node_modules/pkg/lib/index.js';
  const { prefix, patches } = fixture({
    diff: DIFF,
    pins: {
      'a-test.diff': { '1.0.0': { [rel]: { before: 'a'.repeat(64), after: 'b'.repeat(64) } } },
      'b-other.diff': { '1.0.0': { [rel]: { before: 'c'.repeat(64), after: 'd'.repeat(64) } } },
    },
  });
  fs.writeFileSync(path.join(patches, 'b-other.diff'), DIFF);
  const set = loadPatchSet(patches);
  assert.throws(() => runPatchSet({ prefix, set, dshVersion: '1.0.0', mode: 'apply' }), /补丁哈希链断裂/);
});
