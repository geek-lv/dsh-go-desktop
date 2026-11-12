// 引擎库：一台设备上并存多个 DSH 核心版本，随时切换（升级 / 降级 / pin 回发版版本）。
//
// 为什么需要它：核心不该和 App 的发布节奏绑死。库里的每一项就是一份完整的 npm 前缀
// （`<store>/<version>/node_modules/@deepseek-ai/dsh`），所以「切换版本」等价于换个
// 前缀启动——不需要重新下载，也不可能半个版本地混着跑。
//
// 来源有三种，落在同一个库里：
//   npm      从 npm 装下来的官方版本（可选打我们的补丁）
//   imported 从这台设备上已装的 DSH 复制进来的（不动原来那份，之后可以自由升级）
//   bundled  发版绑定的版本（我们审查过补丁链的那个）：永远保留、可一键 pin 回
//
// 注册表写在 `<support>/engines/engines.json`；删除某个版本不影响其他版本，也不会
// 动用户的 `~/.dsh`（数据在用户 home 里，和引擎库无关）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/install_trace.dart';
import 'dsh_discovery.dart';
import 'dsh_npm.dart';
import 'dsh_patch_tool.dart';

/// 库里的一个引擎版本。
class DshEngine {
  const DshEngine({
    required this.version,
    required this.path,
    required this.source,
    required this.installedAt,
    this.patchSummary,
    this.note,
  });

  final String version;

  /// npm 前缀目录（`<store>/<version>/`）。
  final String path;

  /// `npm` / `imported` / `bundled`。
  final String source;
  final DateTime installedAt;

  /// 补丁链结果摘要：`{ok, total, lost: [名字]}`；没打过为 null（= 原样官方）。
  final Map<String, Object?>? patchSummary;

  /// 额外说明（例如「从这台设备上已装的 0.2.2-rc.1 复制」）。
  final String? note;

  bool get patched => patchSummary != null;
  int? get patchesOk => (patchSummary?['ok'] as num?)?.toInt();
  int? get patchesTotal => (patchSummary?['total'] as num?)?.toInt();
  List<String> get lostPatches =>
      [for (final name in (patchSummary?['lost'] as List?) ?? const []) '$name'];

  Map<String, Object?> toJson() => {
    'version': version,
    'path': path,
    'source': source,
    'installedAt': installedAt.toIso8601String(),
    if (patchSummary != null) 'patchSummary': patchSummary,
    if (note != null) 'note': note,
  };

  static DshEngine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = raw['version'];
    final path = raw['path'];
    if (version is! String || path is! String) return null;
    return DshEngine(
      version: version,
      path: path,
      source: '${raw['source'] ?? 'npm'}',
      installedAt: DateTime.tryParse('${raw['installedAt']}') ?? DateTime.now(),
      patchSummary: raw['patchSummary'] is Map ? (raw['patchSummary'] as Map).cast<String, Object?>() : null,
      note: raw['note'] as String?,
    );
  }
}

/// 引擎库。所有磁盘操作都在这里，失败只抛给调用方（由界面决定怎么提示）。
class DshEngineStore {
  DshEngineStore(this.root);

  /// `<app support>/engines`
  final Directory root;

  File get _registry => File('${root.path}${Platform.pathSeparator}engines.json');

  Future<void> ensure() async {
    if (!await root.exists()) await root.create(recursive: true);
  }

  /// 读注册表。目录里存在但注册表里没有的版本会被补登记（例如手工拷进来的）。
  Future<List<DshEngine>> list() async {
    await ensure();
    final engines = <DshEngine>[];
    if (await _registry.exists()) {
      try {
        final decoded = jsonDecode(await _registry.readAsString());
        final items = decoded is Map ? decoded['engines'] : null;
        if (items is List) {
          for (final item in items) {
            final engine = DshEngine.fromJson(item);
            if (engine != null) engines.add(engine);
          }
        }
      } catch (error, stack) {
        InstallTrace.error('engines', error, stack);
      }
    }
    // 目录扫描兜底：库里躺着但没登记的，按文件夹名当版本登记上。
    try {
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;
        if (engines.any((e) => e.path == entity.path)) continue;
        final probe = await DshDiscovery.probePrefix(entity.path, source: 'store');
        if (!probe.usable) continue;
        engines.add(
          DshEngine(
            version: probe.dsh!.version,
            path: entity.path,
            source: 'store',
            installedAt: await entity.stat().then((s) => s.modified),
            note: '未登记，按目录补齐',
          ),
        );
      }
    } catch (error, stack) {
      InstallTrace.error('engines', error, stack);
    }
    engines.sort((a, b) => compareVersions(b.version, a.version));
    return engines;
  }

  Future<void> _save(List<DshEngine> engines) async {
    await ensure();
    await _registry.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 1,
        'engines': [for (final engine in engines) engine.toJson()],
      }),
      flush: true,
    );
  }

  /// 把一个已安装的核心**复制**进库（原树不动）。
  ///
  /// 之后升级/降级都只在库里切，用户那份仍然是它自己的，互不影响。
  Future<DshEngine> importFrom(DiscoveredDsh core, {void Function(int files)? onProgress}) async {
    await ensure();
    final target = Directory('${root.path}${Platform.pathSeparator}${core.version}');
    if (await target.exists()) {
      InstallTrace.add('engines', 'import ${core.version}: 库里已有，直接复用');
      final existing = (await list()).where((e) => e.version == core.version).firstOrNull;
      if (existing != null) return existing;
    }
    final staging = Directory('${target.path}.staging');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    InstallTrace.add('engines', 'import ${core.version}: ${core.prefix} → ${target.path}');
    var files = 0;
    await for (final entity in Directory(core.prefix).list(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(core.prefix.length).replaceFirst(RegExp(r'^[\\/]'), '');
      final destination = '${staging.path}${Platform.pathSeparator}$relative';
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await File(destination).parent.create(recursive: true);
        await entity.copy(destination);
        files++;
        if (files % 500 == 0) onProgress?.call(files);
      }
    }
    onProgress?.call(files);
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
    final engine = DshEngine(
      version: core.version,
      path: target.path,
      source: 'imported',
      installedAt: DateTime.now(),
      note: '从 ${core.source} 的 ${core.prefix} 复制',
    );
    final engines = await list()..removeWhere((e) => e.version == engine.version);
    await _save([engine, ...engines]);
    InstallTrace.add('engines', 'import ${core.version}: 完成（$files 个文件）');
    return engine;
  }

  /// 登记一个已经在库目录里的版本（npm 安装流程完成后调用）。
  Future<void> register(DshEngine engine) async {
    final engines = await list()..removeWhere((e) => e.version == engine.version);
    await _save([engine, ...engines]);
  }

  Future<void> remove(String version) async {
    final engines = await list();
    final engine = engines.where((e) => e.version == version).firstOrNull;
    if (engine == null) return;
    final dir = Directory(engine.path);
    if (await dir.exists()) await dir.delete(recursive: true);
    engines.removeWhere((e) => e.version == version);
    await _save(engines);
    InstallTrace.add('engines', 'remove $version');
  }

  /// 磁盘策略：只保留该留的版本，其余删掉。返回释放的字节数。
  ///
  /// 保留规则（按优先级）：[keep] 里点名的（当前使用 + 发版绑定版本）、最新的
  /// [keepNewest] 个。每个版本约 550 MB，库无限长下去会吃掉几 GB。
  Future<int> bytesOf(String version) async {
    final engines = await list();
    final engine = engines.where((e) => e.version == version).firstOrNull;
    if (engine == null) return 0;
    return _directorySize(Directory(engine.path));
  }

  Future<int> prune({Set<String> keep = const {}, int keepNewest = 1}) async {
    final engines = await list();
    if (engines.length <= keep.length) return 0;
    final protected = <String>{...keep};
    var newest = 0;
    for (final engine in engines) {
      if (newest < keepNewest) {
        protected.add(engine.version);
        newest += 1;
      }
    }
    var freed = 0;
    for (final engine in engines) {
      if (protected.contains(engine.version)) continue;
      final dir = Directory(engine.path);
      if (await dir.exists()) freed += await _directorySize(dir);
      await dir.delete(recursive: true);
      InstallTrace.add('engines', 'prune ${engine.version}（保留 ${protected.join(', ')}）');
    }
    final remaining = [
      for (final engine in engines)
        if (protected.contains(engine.version)) engine,
    ];
    await _save(remaining);
    InstallTrace.add('engines', 'prune 完成：释放 ${(freed / 1048576).round()} MB');
    return freed;
  }

  Future<int> _directorySize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 把库里的某个版本变成「当前使用的引擎」（走 [DiscoveredDsh] 的同一条启动路径）。
  DiscoveredDsh asDiscovered(DshEngine engine) => DiscoveredDsh(
    prefix: engine.path,
    dshDir: '${engine.path}${Platform.pathSeparator}node_modules${Platform.pathSeparator}'
        '@deepseek-ai${Platform.pathSeparator}dsh',
    version: engine.version,
    source: 'store',
  );
}

/// App 自己的支持目录（`main.dart` 里覆盖；补丁链与引擎库都在它下面）。
final appSupportDirProvider = Provider<Directory>((ref) => throw UnimplementedError());

final engineStoreProvider = Provider<DshEngineStore>((ref) => throw UnimplementedError());

/// 用户机上的补丁链执行器（资源解压 + 调 node）。
final patchToolProvider = Provider<DshPatchTool>((ref) => DshPatchTool(ref.read(appSupportDirProvider)));

/// 从 npm 装核心的编排器。
final dshNpmProvider = Provider<DshNpm>(
  (ref) => DshNpm(
    support: ref.read(appSupportDirProvider),
    store: ref.read(engineStoreProvider),
    patchTool: ref.read(patchToolProvider),
  ),
);

/// registry 上可用的版本（界面「检查更新」用）。
final availableDshVersionsProvider = FutureProvider<DshVersionInfo>(
  (ref) => ref.read(dshNpmProvider).fetchVersions(),
);

/// 引擎库的列表（界面用；`refresh()` 后自动更新）。
final engineStoreListProvider = FutureProvider<List<DshEngine>>((ref) async {
  final store = ref.watch(engineStoreProvider);
  return store.list();
});
