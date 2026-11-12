#!/usr/bin/env node
// 补丁链命令行：构建机与应用（用户机器上只有 Node）共用这一份实现。
//
//   node tools/dsh-patch/cli.mjs apply  --prefix <npm 前缀> --patches runtime/patches --dsh-version 0.2.2-rc.1
//   node tools/dsh-patch/cli.mjs check  --prefix <npm 前缀> --patches runtime/patches --dsh-version 0.2.3-rc.1 [--json out.json]
//   node tools/dsh-patch/cli.mjs record --prefix <npm 前缀> --patches runtime/patches --dsh-version 0.2.2-rc.1
//
// 参数：
//   --prefix <dir>        npm 前缀（含 node_modules/），必填
//   --patches <dir>       补丁目录（*.diff + pins.json），默认仓库的 runtime/patches
//   --dsh-version <ver>   必填；应用/记录时的目标版本
//   --companion <dir>     session-deletion 伴生文件目录，默认 runtime/session-deletion
//   --json <file>         把完整报告写到文件（check 模式下用它给界面用）
//   --out <file>          只写「已应用的补丁名」数组（与 Python 版 --out 同格式，供构建脚本消费）
//   --allow-unpinned      没有该版本 pin 时也允许 apply（best-effort：能打上的打上，
//                         打不上的记进报告；跟随上游的新版本走这条）
//   --quiet               不打印逐文件日志
//
// 退出码：0 全部通过；1 有补丁失效；2 参数/环境错误。

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import { loadPatchSet, runPatchSet } from './apply.mjs';

const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const REPO = path.resolve(HERE, '..', '..');

function usage(code = 0) {
  const text = fs.readFileSync(new URL(import.meta.url), 'utf8');
  const header = text.split('\n').filter((line) => line.startsWith('//')).map((line) => line.slice(3));
  (code === 0 ? console.log : console.error)(header.join('\n'));
  process.exit(code);
}

function parseArgs(argv) {
  const [mode, ...rest] = argv;
  const options = {
    mode,
    patches: path.join(REPO, 'runtime', 'patches'),
    companion: path.join(REPO, 'runtime', 'session-deletion'),
    quiet: false,
  };
  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i];
    const next = () => {
      const value = rest[i + 1];
      if (value === undefined) usage(2);
      i += 1;
      return value;
    };
    switch (arg) {
      case '--prefix':
        options.prefix = next();
        break;
      case '--patches':
        options.patches = next();
        break;
      case '--companion':
        options.companion = next();
        break;
      case '--dsh-version':
        options.dshVersion = next();
        break;
      case '--json':
        options.json = next();
        break;
      case '--out':
        options.out = next();
        break;
      case '--allow-unpinned':
        options.allowUnpinned = true;
        break;
      case '--quiet':
        options.quiet = true;
        break;
      case '-h':
      case '--help':
        usage(0);
        break;
      default:
        console.error(`未知参数 ${arg}`);
        usage(2);
    }
  }
  if (!['apply', 'check', 'record'].includes(mode)) usage(2);
  if (!options.prefix || !options.dshVersion) {
    console.error('需要 --prefix 与 --dsh-version');
    usage(2);
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
const log = options.quiet ? () => {} : (line) => console.log(`  ${line}`);

try {
  const set = loadPatchSet(options.patches);
  const { report } = runPatchSet({
    prefix: path.resolve(options.prefix),
    set,
    dshVersion: options.dshVersion,
    mode: options.mode,
    allowUnpinned: options.allowUnpinned === true,
    companionDir: options.companion,
    log,
  });

  if (options.out) {
    const applied = report.results.filter((r) => r.ok).map((r) => r.patch);
    fs.mkdirSync(path.dirname(path.resolve(options.out)), { recursive: true });
    fs.writeFileSync(path.resolve(options.out), `${JSON.stringify(applied)}
`, 'utf8');
  }
  if (options.json) {
    fs.mkdirSync(path.dirname(path.resolve(options.json)), { recursive: true });
    fs.writeFileSync(path.resolve(options.json), `${JSON.stringify(report, null, 2)}\n`, 'utf8');
    console.log(`报告已写入 ${options.json}`);
  }
  if (report.lost.length) {
    console.log('\n失效的补丁：');
    for (const result of report.results.filter((r) => !r.ok)) {
      console.log(`  ${result.patch}`);
      for (const file of result.files.filter((f) => !['alreadyPatched', 'applied', 'wouldApply'].includes(f.status))) {
        console.log(`    ${file.status}: ${file.path}`);
        if (file.detail) console.log(`      ${file.detail}`);
      }
    }
  }
  process.exit(report.lost.length === 0 ? 0 : 1);
} catch (error) {
  console.error(`dsh-patch: ${error.message}`);
  process.exit(2);
}
