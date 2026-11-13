// 从 npm 安装 / 升级 DSH 核心到引擎库。
//
// 流程（每一步失败都回滚 staging，绝不留下半个版本）：
//   1. 查 registry 的 dist-tags 与版本列表（默认 npmmirror，失败退 npmjs）
//   2. 在本机引擎自带的 node/npm 上跑 `npm install @deepseek-ai/dsh@<版本>` 到 staging
//   3. 校验装上的版本号
//   4. 跑补丁链：审查过的版本 strict；新版本 best-effort（打不上的记进报告）
//   5. staging 原子改名进引擎库并登记
//
// 这一层只做编排，不做补丁判断（那在 Node 里），也不改用户的 `~/.dsh`。

import 'dart:convert';
import 'dart:io';

import '../desktop/install_trace.dart';
import 'dsh_engines.dart';
import 'dsh_patch_tool.dart';

/// registry 上的版本信息。
class DshVersionInfo {
  const DshVersionInfo({required this.versions, required this.tags});

  final List<String> versions;

  /// `dist-tags`，例如 `{latest: 0.2.2-rc.1, next: …}`。
  final Map<String, String> tags;

  String? get latest => tags['latest'];
}

/// 一次安装的结果。
class DshInstallResult {
  const DshInstallResult({required this.engine, required this.patch, this.note});

  final DshEngine engine;

  /// 补丁链摘要（`ok` / `total` / `lost`）；没跑成为 null。
  final PatchRunResult? patch;
  final String? note;

  bool get patched => patch != null;
  List<String> get lostPatches => patch?.lost ?? const [];
}

class DshNpm {
  DshNpm({
    required this.support,
    required this.store,
    required this.patchTool,
    this.registry = 'https://registry.npmmirror.com',
    this.fallbackRegistry = 'https://registry.npmjs.org',
  });

  final Directory support;
  final DshEngineStore store;
  final DshPatchTool patchTool;
  final String registry;
  final String fallbackRegistry;

  /// 查 registry 上 `@deepseek-ai/dsh` 的版本与 dist-tags。
  Future<DshVersionInfo> fetchVersions({Duration timeout = const Duration(seconds: 20)}) async {
    Object? lastError;
    for (final base in [registry, fallbackRegistry]) {
      final client = HttpClient()..connectionTimeout = timeout;
      try {
        // npm 的完整元数据很大（十几 MB）；用 Accept 头要缩减版。
        final uri = Uri.parse('$base/@deepseek-ai%2Fdsh');
        final request = await client.getUrl(uri).timeout(timeout);
        request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.npm.install-v1+json');
        final response = await request.close().timeout(timeout);
        if (response.statusCode != 200) {
          throw StateError('HTTP ${response.statusCode} from $base');
        }
        final body = await response.transform(utf8.decoder).join().timeout(timeout);
        final decoded = jsonDecode(body);
        final versions = <String>[];
        if (decoded is Map) {
          final rawVersions = decoded['versions'];
          if (rawVersions is Map) versions.addAll(rawVersions.keys.map((k) => '$k'));
          final tags = <String, String>{};
          final rawTags = decoded['dist-tags'];
          if (rawTags is Map) {
            for (final entry in rawTags.entries) {
              tags['${entry.key}'] = '${entry.value}';
            }
          }
          InstallTrace.add('npm', 'versions from $base: ${versions.length} 个，latest=${tags['latest'] ?? '-'}');
          return DshVersionInfo(versions: versions, tags: tags);
        }
        throw StateError('unexpected registry payload');
      } catch (error, stack) {
        lastError = error;
        InstallTrace.error('npm', 'fetch $base failed: $error', stack);
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('查不到版本列表：$lastError');
  }

  /// 安装（或重装）[version] 到引擎库。
  Future<DshInstallResult> install(
    String version, {
    void Function(String line)? onLog,
    /// 装完顺手清理时**必须保留**的版本（当前使用 + 发版绑定版本）。
    Set<String> keepVersions = const {},
  }) async {
    await store.ensure();
    // 先把补丁链与锁文件解压出来：`lockFor()` 依赖它决定用 npm ci 还是 npm install。
    await patchTool.ensureExtracted();
    final staging = Directory('${store.root.path}${Platform.pathSeparator}.staging-$version');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    InstallTrace.add('npm', 'install @deepseek-ai/dsh@$version → ${staging.path}');

    try {
      final npm = await _npmInvocation();
      // 审查过的版本有锁文件：拷进 staging 跑 `npm ci`，得到和发版时**同一棵**
      // 依赖树（补丁是按具体文件哈希钉死的，浮动的依赖会让补丁对不上）。
      final lock = await patchTool.lockFor(version);
      if (lock != null) {
        for (final name in ['package.json', 'package-lock.json']) {
          await File('${lock.path}${Platform.pathSeparator}$name')
              .copy('${staging.path}${Platform.pathSeparator}$name');
        }
        InstallTrace.add('npm', 'using shipped lock ${lock.path}（npm ci）');
      }
      final args = <String>[
        ...npm.arguments,
        if (lock != null) 'ci' else 'install',
        if (lock == null) '@deepseek-ai/dsh@$version',
        '--prefix',
        staging.path,
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
        '--update-notifier=false',
        '--registry',
        registry,
        // 目标平台必须按真实平台给：macOS 是 darwin（不是 linux），且 darwin 没有
        // libc 变体。之前写成 Windows ? win32 : linux，在 Mac 上会装成 linux 的
        // 可选依赖，引擎直接跑不起来。
        '--os',
        _targetOs(),
        '--cpu',
        _cpu(),
        // 注意：`glibc` 必须和 `--libc` 一起出现/一起不出现。
        // 之前只把开关放进条件里，值却总是传入——Windows 上 npm 就把它当成要装的包，
        // 去 registry 拉 `glibc@*`，E404，整次安装失败。
        if (Platform.isLinux) ...['--libc', 'glibc'],
      ];
      InstallTrace.add('npm', 'run ${npm.executable} ${args.join(' ')}');
      onLog?.call('安装 DSH $version（npm，registry=$registry）');
      final result = await Process.run(
        npm.executable,
        args,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final output = '${result.stdout}\n${result.stderr}'.trim();
      InstallTrace.add('npm', 'npm exit=${result.exitCode}\n${InstallTrace.tail(output, max: 30)}');
      if (result.exitCode != 0) {
        throw StateError('npm install 失败（exit ${result.exitCode}）');
      }

      // 校验装上的版本号：registry 说装了什么不算，文件说了算。
      final installed = await _installedVersion(staging);
      if (installed != version) {
        throw StateError('装上的版本是 $installed，不是 $version');
      }

      // 补丁策略：
      //   整批审查过的版本 → strict（一个不打上就失败，这是发版保证）；
      //   其他版本        → 先按**官方原样**装（不打零散补丁：半套补丁的树比不打更危险），
      //                    补丁链的兼容性报告留给用户手动触发。
      final fullyPinned = await patchTool.fullyPinned(version);
      PatchRunResult? patch;
      String? patchNote;
      if (fullyPinned) {
        patch = await patchTool.run(prefix: staging, dshVersion: version, apply: true, allowUnpinned: false);
        patchNote = '审查过的版本（严格补丁链）';
        onLog?.call('补丁：${patch.patchesOk}/${patch.patches} 可用'
            '${patch.lost.isEmpty ? '' : '，失效 ${patch.lost.length} 个'}');
        if (patch.lost.isNotEmpty) {
          // 审查过的版本必须整批打上：缺一个就不是我们验证过的产物。
          throw StateError('审查版本 $version 的补丁失效：${patch.lost.join(', ')}');
        }
      } else {
        patchNote = '官方原样（这个版本没有完整补丁链）';
        onLog?.call('该版本没有完整补丁链，按官方原样安装');
        InstallTrace.add('npm', '$version 不是整批审查版本 → 不打补丁（官方原样）');
      }

      final target = Directory('${store.root.path}${Platform.pathSeparator}$version');
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
      final engine = DshEngine(
        version: version,
        path: target.path,
        source: 'npm',
        installedAt: DateTime.now(),
        patchSummary: patch?.summary,
        note: patchNote,
      );
      await store.register(engine);
      // 装完顺手收敛磁盘：保留 keepVersions + 最新一个，其余删掉。
      // 每个版本约 550 MB，多装几次就会吃掉几 GB。
      try {
        final freed = await store.prune(keep: {...keepVersions, version}, keepNewest: 1);
        if (freed > 0) {
          onLog?.call('清理旧版本，释放 ${(freed / 1048576).round()} MB');
        }
      } catch (error, stack) {
        // 清理失败不影响这次安装。
        InstallTrace.error('npm', 'prune after install failed: $error', stack);
      }
      InstallTrace.add(
        'npm',
        'installed $version → ${target.path}（'
            '${patch == null ? '官方原样' : '补丁 ${patch.patchesOk}/${patch.patches}'}）',
      );
      return DshInstallResult(engine: engine, patch: patch, note: engine.note);
    } catch (error, stack) {
      InstallTrace.error('npm', 'install $version failed: $error', stack);
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<String?> _installedVersion(Directory prefix) async {
    final manifest = File('${prefix.path}${Platform.pathSeparator}node_modules'
        '${Platform.pathSeparator}@deepseek-ai${Platform.pathSeparator}dsh'
        '${Platform.pathSeparator}package.json');
    if (!await manifest.exists()) return null;
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      return decoded is Map ? decoded['version'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  /// 用本机引擎自带的 node 跑 npm 的 CLI（不依赖系统 PATH，也不依赖 npm.cmd）。
  Future<({String executable, List<String> arguments})> _npmInvocation() async {
    final sep = Platform.pathSeparator;
    final node = Platform.isWindows
        ? File('${support.path}${sep}runtime${sep}node${sep}node.exe')
        : File('${support.path}${sep}runtime${sep}node${sep}bin${sep}node');
    final npmCli = Platform.isWindows
        ? File('${support.path}${sep}runtime${sep}node${sep}node_modules${sep}npm${sep}bin${sep}npm-cli.js')
        : File('${support.path}${sep}runtime${sep}node${sep}lib${sep}node_modules${sep}npm${sep}bin${sep}npm-cli.js');
    if (await node.exists() && await npmCli.exists()) {
      return (executable: node.path, arguments: [npmCli.path]);
    }
    // 没有本机引擎（用户跳过了安装）时退到系统 node/npm。
    InstallTrace.add('npm', 'bundled node/npm 不在，退回系统 npm');
    return (
      executable: Platform.isWindows ? 'cmd' : 'npm',
      arguments: Platform.isWindows ? ['/c', 'npm'] : <String>[],
    );
  }

  String _targetOs() {
    if (Platform.isWindows) return 'win32';
    if (Platform.isMacOS) return 'darwin';
    return 'linux';
  }

  String _cpu() {
    final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
    if (arch.toUpperCase().contains('ARM64')) return 'arm64';
    if (Platform.isWindows) return 'x64';
    try {
      final uname = Process.runSync('uname', ['-m']);
      final machine = '${uname.stdout}'.trim().toLowerCase();
      // macOS 报 arm64，Linux 报 aarch64 —— 两种都要认。
      if (machine.contains('arm64') || machine.contains('aarch64')) return 'arm64';
    } catch (_) {}
    return 'x64';
  }
}
