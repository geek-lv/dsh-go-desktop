// 把「官方 DSH 环境」（`~/.dsh`）里的对话与工作区导入 App 自带的运行时。
//
// 为什么需要：App 自带的引擎有自己的 HOME（`<support>/runtime/home`），数据与用户已经在用的
// 官方 DSH 完全隔离。切换引擎来源（复用已装核心）能直接共用那份数据，但如果用户就是想用
// App 自带的那套，至少要把历史对话和工作区搬过来。
//
// 拷贝策略（宁可少拷，不可覆盖）：
//   * 只拷 sessions/（按工作区分目录的会话文件）、storages/（工作区注册表 + 会话索引缓存）、
//     skills/；`profiles/`（上百 MB 的插件树）与凭据**不动**；
//   * 目标已存在的文件一律跳过——导入只做加法，重复执行是安全的；
//   * 每步都记 trace，界面只报「新增了多少文件 / 多少 MB」。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/install_trace.dart';

/// 一次导入的结果。
class DshImportResult {
  const DshImportResult({
    required this.files,
    required this.skipped,
    required this.bytes,
    required this.sessionWorkspaces,
  });

  /// 新写入的文件数。
  final int files;

  /// 因为目标已存在而跳过的文件数。
  final int skipped;
  final int bytes;

  /// 带进来多少个「工作区目录」（sessions/--xxx--）。
  final int sessionWorkspaces;

  String get megabytes => (bytes / 1048576).toStringAsFixed(1);
}

abstract final class DshImport {
  /// 官方 DSH 的数据目录（`$HOME/.dsh`）。
  static Directory officialHome() {
    final env = Platform.environment;
    final home = Platform.isWindows ? (env['USERPROFILE'] ?? env['HOME']) : env['HOME'];
    if (home == null) throw StateError('找不到用户目录');
    return Directory('$home${Platform.pathSeparator}.dsh');
  }

  /// 这个 `.dsh` 里有多少个带会话的工作区目录（用来判断「值不值得导入」）。
  static Future<int> countWorkspaces(Directory dsh) async {
    final sessions = Directory('${dsh.path}${Platform.pathSeparator}sessions');
    if (!await sessions.exists()) return 0;
    var count = 0;
    await for (final entity in sessions.list()) {
      if (entity is! Directory) continue;
      var hasFile = false;
      await for (final child in entity.list(recursive: true)) {
        if (child is File) {
          hasFile = true;
          break;
        }
      }
      if (hasFile) count += 1;
    }
    return count;
  }

  /// 从 [source] 导入到 [target]（两者都是 `.dsh` 目录）。
  static Future<DshImportResult> importFrom({
    required Directory source,
    required Directory target,
    bool includeSkills = true,
  }) async {
    if (source.path == target.path) {
      throw StateError('源与目标是同一个目录');
    }
    final dirs = <String>[
      'sessions',
      'storages',
      if (includeSkills) 'skills',
    ];
    var files = 0;
    var skipped = 0;
    var bytes = 0;
    InstallTrace.add('import', '从 ${source.path} 导入到 ${target.path}（${dirs.join(', ')}）');
    for (final name in dirs) {
      final from = Directory('${source.path}${Platform.pathSeparator}$name');
      if (!await from.exists()) continue;
      await for (final entity in from.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        // 工作区注册表要**合并**（两边可能各自有置顶/归档），不能整文件覆盖或跳过。
        if (name == 'storages' && entity.path.endsWith('workspace.json')) continue;
        final relative = entity.path.substring(from.path.length).replaceFirst(RegExp(r'^[\\/]'), '');
        final to = File('${target.path}${Platform.pathSeparator}$name${Platform.pathSeparator}$relative');
        if (await to.exists()) {
          skipped += 1;
          continue;
        }
        await to.parent.create(recursive: true);
        await entity.copy(to.path);
        files += 1;
        try {
          bytes += await to.length();
        } catch (_) {}
      }
    }
    final merged = await _mergeWorkspaceRegistry(source, target);
    final workspaces = await countWorkspaces(target);
    InstallTrace.add(
      'import',
      '导入完成：$files 个文件（${(bytes / 1048576).toStringAsFixed(1)} MB），跳过 $skipped 个已存在，'
          '合并工作区 $merged 个，目标共 $workspaces 个工作区',
    );
    return DshImportResult(
      files: files,
      skipped: skipped,
      bytes: bytes,
      sessionWorkspaces: workspaces,
    );
  }

  /// 合并 `storages/workspace.json`：工作区按 id 取并集（目标里已有的优先），
  /// 置顶/归档列表也取并集。返回新增的工作区数。
  ///
  /// 为什么不是整文件拷：两边的注册表都会各自演进（用户在这台机器上置顶过、归档过），
  /// 覆盖会把这些状态弄丢；跳过又会让 App 里看不到工作区（就这么踩过一次）。
  static Future<int> _mergeWorkspaceRegistry(Directory source, Directory target) async {
    final from = File('${source.path}${Platform.pathSeparator}storages${Platform.pathSeparator}workspace.json');
    if (!await from.exists()) return 0;
    final Map<String, Object?> incoming;
    try {
      final decoded = jsonDecode(await from.readAsString());
      if (decoded is! Map) return 0;
      incoming = decoded.cast<String, Object?>();
    } catch (error, stack) {
      InstallTrace.error('import', error, stack);
      return 0;
    }
    final to = File('${target.path}${Platform.pathSeparator}storages${Platform.pathSeparator}workspace.json');
    Map<String, Object?> existing = {};
    if (await to.exists()) {
      try {
        final decoded = jsonDecode(await to.readAsString());
        if (decoded is Map) existing = decoded.cast<String, Object?>();
      } catch (_) {}
    }
    Map<String, Object?> asMap(Object? value) =>
        value is Map ? value.map((k, v) => MapEntry('$k', v)) : <String, Object?>{};
    List<String> asList(Object? value) => value is List ? [for (final v in value) '$v'] : <String>[];

    final incomingTables = asMap(incoming['tables']);
    final existingTables = asMap(existing['tables']);
    final mergedTables = <String, Object?>{...existingTables};
    var added = 0;
    for (final entry in incomingTables.entries) {
      final a = asMap(existingTables[entry.key]);
      final b = asMap(entry.value);
      added += b.keys.where((k) => !a.containsKey(k)).length;
      mergedTables[entry.key] = {...b, ...a}; // 目标里已有的行优先
    }

    final incomingGlobal = asMap(incoming['global']);
    final existingGlobal = asMap(existing['global']);
    final mergedGlobal = <String, Object?>{
      ...incomingGlobal,
      ...existingGlobal,
      'workspaceIds': <String>{
        ...asList(existingGlobal['workspaceIds']),
        ...asList(incomingGlobal['workspaceIds']),
      }.toList(),
      'archivedSessionIds': <String>{
        ...asList(existingGlobal['archivedSessionIds']),
        ...asList(incomingGlobal['archivedSessionIds']),
      }.toList(),
      'pinnedSessionIds': <String>{
        ...asList(existingGlobal['pinnedSessionIds']),
        ...asList(incomingGlobal['pinnedSessionIds']),
      }.toList(),
      'initialized': existingGlobal['initialized'] == true || incomingGlobal['initialized'] == true,
    };

    final merged = <String, Object?>{
      'unit': existing['unit'] ?? incoming['unit'],
      'global': mergedGlobal,
      'tables': mergedTables,
    };
    await to.parent.create(recursive: true);
    await to.writeAsString(const JsonEncoder.withIndent('  ').convert(merged), flush: true);
    InstallTrace.add('import', '合并工作区注册表：新增 $added 个');
    return added;
  }
}

/// 官方 DSH 里有几个带会话的工作区（界面用它决定要不要显示「导入」）。
final officialDshWorkspacesProvider = FutureProvider<int>((ref) async {
  try {
    return await DshImport.countWorkspaces(DshImport.officialHome());
  } catch (_) {
    return 0;
  }
});
