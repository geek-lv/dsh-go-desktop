// 在**用户机器上**打补丁：把 App 自带的那份补丁链解压出来，用本机引擎的 node 执行。
//
// 分工（这条边界很重要）：
//   * 补丁规则只有一份（`tools/dsh-patch/*.mjs`，随 App 作为资源发）；
//   * Dart 只负责「解压 → 起 node → 读 JSON 报告 → 渲染」；
//   * 没有 Python，也不需要仓库。
//
// 资源来自 `app/assets/dsh-core/`（由 `tooling/sync-dsh-core-assets.sh` 从
// `tools/dsh-patch/` 与 `runtime/patches/` 同步），运行时落到 `<support>/dsh-core/`。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../desktop/install_trace.dart';

/// 一次补丁运行的结果。
class PatchRunResult {
  const PatchRunResult({
    required this.exitCode,
    required this.report,
    required this.output,
  });

  final int exitCode;

  /// `cli.mjs --json` 写出的报告（解析失败时为 null）。
  final Map<String, Object?>? report;

  /// 子进程输出（已截断到合理长度，用于诊断面板）。
  final String output;

  int get patches => (report?['patches'] as num?)?.toInt() ?? 0;
  int get patchesOk => (report?['patchesOk'] as num?)?.toInt() ?? 0;
  List<String> get lost => [for (final name in (report?['lost'] as List?) ?? const []) '$name'];

  Map<String, Object?> get summary => {
    'ok': patchesOk,
    'total': patches,
    'lost': lost,
  };
}

/// 补丁链的资源解压与执行。
class DshPatchTool {
  DshPatchTool(this.support);

  final Directory support;

  Directory get root => Directory('${support.path}${Platform.pathSeparator}dsh-core');
  Directory get toolDir => Directory('${root.path}${Platform.pathSeparator}tools');
  Directory get patchDir => Directory('${root.path}${Platform.pathSeparator}patches');

  /// 我们审查过的版本对应的锁文件目录（`<root>/locks/dsh-<version>/`）。
  Directory get locksDir => Directory('${root.path}${Platform.pathSeparator}locks');

  /// 有锁文件就用 `npm ci` 复现同一棵依赖树——补丁打在具体版本的文件上，
  /// 浮动安装会让补丁对不上（实测过：`pi-ai` 被装成新版，那个补丁就失效了）。
  Future<Directory?> lockFor(String dshVersion) async {
    final dir = Directory('${locksDir.path}${Platform.pathSeparator}dsh-$dshVersion');
    final lock = File('${dir.path}${Platform.pathSeparator}package-lock.json');
    return await lock.exists() ? dir : null;
  }
  String get cliPath => '${toolDir.path}${Platform.pathSeparator}cli.mjs';
  String get pinsPath => '${patchDir.path}${Platform.pathSeparator}pins.json';

  static const _assetRoot = 'assets/dsh-core';

  /// 把资源写出来（每次覆盖：634 KB，比判断版本便宜）。
  Future<void> ensureExtracted() async {
    await toolDir.create(recursive: true);
    await patchDir.create(recursive: true);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    var files = 0;
    for (final key in manifest.listAssets()) {
      if (!key.startsWith('$_assetRoot/')) continue;
      final name = key.substring(_assetRoot.length + 1);
      if (name.endsWith('/')) continue;
      final bytes = await rootBundle.load(key);
      // 资源的扁平结构要还原成 tools/ 与 patches/ 两个目录（cli.mjs 里按相对路径找 diff/apply）。
      final String relative;
      if (name.endsWith('.mjs')) {
        relative = 'tools${Platform.pathSeparator}$name';
      } else if (name.startsWith('patches/')) {
        relative = name.replaceFirst('patches/', 'patches${Platform.pathSeparator}');
      } else {
        relative = name;
      }
      final target = File('${root.path}${Platform.pathSeparator}$relative');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
      files += 1;
    }
    InstallTrace.add('patch-tool', 'extracted $files assets → ${root.path}');
  }

  /// 这个 DSH 版本是否**整批**都审查过（决定 strict / 原样）。
  ///
  /// 注意「有 pin」和「整批都有 pin」是两件事：`0.2.1-rc.4` 只有部分补丁有 pin，
  /// 按 strict 去跑会半途中止、留下半套补丁的树。所以这里要求每个 `.diff` 都有 pin。
  Future<bool> fullyPinned(String dshVersion) async {
    try {
      final decoded = jsonDecode(await File(pinsPath).readAsString());
      final patches = decoded is Map ? decoded['patches'] : null;
      if (patches is! Map) return false;
      final pinned = <String>{};
      for (final entry in patches.entries) {
        if (entry.value is Map && (entry.value as Map).containsKey(dshVersion)) {
          pinned.add('${entry.key}');
        }
      }
      if (pinned.isEmpty) return false;
      final diffs = await patchDir
          .list()
          .where((e) => e is File && e.path.endsWith('.diff'))
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .toList();
      if (diffs.isEmpty) return false;
      return diffs.every(pinned.contains);
    } catch (_) {
      return false;
    }
  }

  /// 在 [prefix] 上跑补丁链。[apply] 为 false 时只检查（`check`，不写盘）。
  Future<PatchRunResult> run({
    required Directory prefix,
    required String dshVersion,
    required bool apply,
    bool allowUnpinned = true,
  }) async {
    if (!await File(cliPath).exists()) {
      throw StateError('补丁链没解压成功：$cliPath 不存在');
    }
    final node = await _nodePath();
    if (node == null) {
      throw StateError('找不到可用的 node：本机引擎未安装，且系统 PATH 里也没有 node');
    }
    final reportFile = File('${root.path}${Platform.pathSeparator}patch-report-$dshVersion.json');
    final args = <String>[
      cliPath,
      apply ? 'apply' : 'check',
      '--prefix',
      prefix.path,
      '--patches',
      patchDir.path,
      '--dsh-version',
      dshVersion,
      '--json',
      reportFile.path,
      '--quiet',
      if (apply && allowUnpinned) '--allow-unpinned',
    ];
    InstallTrace.add('patch-tool', '$node ${args.join(' ')}');
    final result = await Process.run(node, args, stdoutEncoding: utf8, stderrEncoding: utf8);
    final output = '${result.stdout}\n${result.stderr}'.trim();
    Map<String, Object?>? report;
    try {
      if (await reportFile.exists()) {
        final decoded = jsonDecode(await reportFile.readAsString());
        if (decoded is Map) report = decoded.cast<String, Object?>();
      }
    } catch (error, stack) {
      InstallTrace.error('patch-tool', error, stack);
    }
    InstallTrace.add(
      'patch-tool',
      '${apply ? 'apply' : 'check'} $dshVersion: exit=${result.exitCode} '
          'ok=${report?['patchesOk'] ?? '?'}/${report?['patches'] ?? '?'}',
    );
    if (output.isNotEmpty) InstallTrace.add('patch-tool', output);
    return PatchRunResult(exitCode: result.exitCode, report: report, output: output);
  }

  /// 本机引擎自带的 node 优先（版本和核心匹配），否则用系统 PATH 里的。
  Future<String?> _nodePath() async {
    final bundled = File(
      '${support.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}node'
      '${Platform.pathSeparator}${Platform.isWindows ? 'node.exe' : 'bin/node'}',
    );
    if (await bundled.exists()) return bundled.path;
    // Linux/macOS 的运行时布局是 node/bin/node。
    final bundledUnix = File('${support.path}${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}node${Platform.pathSeparator}bin${Platform.pathSeparator}node');
    if (await bundledUnix.exists()) return bundledUnix.path;
    final probe = await Process.run(Platform.isWindows ? 'where' : 'which', ['node']);
    if (probe.exitCode == 0) {
      final first = '${probe.stdout}'.split('\n').first.trim();
      if (first.isNotEmpty) return first;
    }
    return null;
  }
}
