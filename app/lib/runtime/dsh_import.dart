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

import 'package:yaml/yaml.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/install_trace.dart';
import 'dsh_engines.dart';

/// 一次导入的结果。
class DshImportResult {
  const DshImportResult({
    required this.files,
    required this.skipped,
    required this.bytes,
    required this.sessionWorkspaces,
    this.providers = 0,
    this.plugins = 0,
  });

  /// 新写入的文件数。
  final int files;

  /// 因为目标已存在而跳过的文件数。
  final int skipped;
  final int bytes;

  /// 带进来多少个「工作区目录」（sessions/--xxx--）。
  final int sessionWorkspaces;

  /// 同步了多少个模型 provider（`llm-*` 那几段）。
  final int providers;

  /// 同步了多少个插件（`dsh.profile.bundles` 新增的）。
  final int plugins;

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
    final providers = await importModelProviders(source: source, target: target);
    final plugins = (await importPluginList(source: source, target: target)).length;
    final workspaces = await countWorkspaces(target);
    InstallTrace.add(
      'import',
      '导入完成：$files 个文件（${(bytes / 1048576).toStringAsFixed(1)} MB），跳过 $skipped 个已存在，'
          '合并工作区 $merged 个，模型 provider $providers 个，官方插件清单 $plugins 个，'
          '目标共 $workspaces 个工作区',
    );
    return DshImportResult(
      files: files,
      skipped: skipped,
      bytes: bytes,
      sessionWorkspaces: workspaces,
      providers: providers,
      plugins: plugins,
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
  /// 把官方的**模型 provider**同步过来：`profiles/web/cordis.patch.yml` 里 `id: llm-*`
  /// 的那几段（provider 列表、baseURL、模型清单）按原文搬过来，再带上它引用的密钥。
  ///
  /// 为什么按原文搬而不是解析成 YAML 再序列化：这些片段里可能有 `!!js` 表达式和注释，
  /// 重新序列化会丢掉语义。文本块切分则逐字保留。
  static Future<int> importModelProviders({
    required Directory source,
    required Directory target,
    String profile = 'web',
  }) async {
    final sep = Platform.pathSeparator;
    final from = File('${source.path}${sep}profiles${sep}$profile${sep}cordis.patch.yml');
    final to = File('${target.path}${sep}profiles${sep}$profile${sep}cordis.patch.yml');
    if (!await from.exists()) return 0;

    final blocks = _llmBlocks(await from.readAsString());
    if (blocks.isEmpty) return 0;
    final ids = {for (final b in blocks) b.id};

    final existing = await to.exists() ? await to.readAsString() : '';
    final kept = _stripBlocks(existing, ids);
    const header = '# Your patch layer for this dsh profile, applied after every bundle layer:\n'
        '# a top-level YAML array of loader patch entries (id-targeted config\n'
        '# overrides, disables, and insert lists; `!!js` expressions allowed).\n';
    final body = [
      if (kept.trim().isNotEmpty) kept.trimRight(),
      ...blocks.map((b) => b.text.trimRight()),
    ].join('\n');
    await to.parent.create(recursive: true);
    await to.writeAsString('$header\n$body\n', flush: true);
    InstallTrace.add('import', '同步模型 provider：${ids.join(', ')} → ${to.path}');

    // 这些 provider 用 apiKeyEnv 引用密钥，密钥在 `.credentials.yaml` 的 refs 里。
    final credentials = await _mergeCredentials(
      File('${source.path}$sep.credentials.yaml'),
      File('${target.path}$sep.credentials.yaml'),
    );
    InstallTrace.add('import', '同步凭据引用：$credentials 个');
    return ids.length;
  }

  /// 切出 `- id: llm-…` 的整段（到下一个顶层 `- ` 为止）。
  static List<({String id, String text})> _llmBlocks(String text) {
    final lines = text.split('\n');
    final out = <({String id, String text})>[];
    var i = 0;
    while (i < lines.length) {
      final match = RegExp(r'^-\s+id:\s*([\w.-]+)\s*$').firstMatch(lines[i]);
      if (match == null) {
        i += 1;
        continue;
      }
      final start = i;
      i += 1;
      while (i < lines.length && !RegExp(r'^-\s').hasMatch(lines[i])) {
        i += 1;
      }
      final id = match.group(1)!;
      if (id.startsWith('llm-')) out.add((id: id, text: lines.sublist(start, i).join('\n')));
    }
    return out;
  }

  /// 摘掉目标文件里指定 id 的块（其余内容原样保留）；只剩注释/空数组时返回空。
  static String _stripBlocks(String text, Set<String> ids) {
    if (text.trim().isEmpty) return '';
    final lines = text.split('\n');
    final kept = <String>[];
    var i = 0;
    while (i < lines.length) {
      final match = RegExp(r'^-\s+id:\s*([\w.-]+)\s*$').firstMatch(lines[i]);
      if (match != null && ids.contains(match.group(1))) {
        i += 1;
        while (i < lines.length && !RegExp(r'^-\s').hasMatch(lines[i])) {
          i += 1;
        }
        continue;
      }
      kept.add(lines[i]);
      i += 1;
    }
    final trimmed = kept.join('\n').trim();
    final meaning = trimmed
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#') && l.trim() != '[]')
        .toList();
    return meaning.isEmpty ? '' : '$trimmed\n';
  }

  /// 合并 `.credentials.yaml`：`refs`（环境变量名 → 密钥）取并集、源优先；
  /// `records`（内部 grant）保目标的。写 JSON —— YAML 是 JSON 的超集，DSH 照样能读。
  static Future<int> _mergeCredentials(File from, File to) async {
    if (!await from.exists()) return 0;
    Map<String, Object?> read(Object? decoded) =>
        decoded is Map ? decoded.map((k, v) => MapEntry('$k', v)) : <String, Object?>{};
    final source = read(_tryYaml(await from.readAsString()));
    if (source.isEmpty) return 0;
    final target = await to.exists() ? read(_tryYaml(await to.readAsString())) : <String, Object?>{};
    final sourceRefs = read(source['refs']);
    final merged = <String, Object?>{
      'version': target['version'] ?? source['version'] ?? 1,
      'refs': {...read(target['refs']), ...sourceRefs},
      'records': {...read(source['records']), ...read(target['records'])},
    };
    await to.parent.create(recursive: true);
    await to.writeAsString(const JsonEncoder.withIndent('  ').convert(merged), flush: true);
    return sourceRefs.length;
  }

  static Object? _tryYaml(String text) {
    try {
      return loadYaml(text);
    } catch (error, stack) {
      InstallTrace.error('import', error, stack);
      return null;
    }
  }

  /// 只把官方的**已装插件清单**记下来（不安装、不拷 node_modules）。
  ///
  /// 用途是"提示"：让用户在 App 里知道官方装了哪些插件、哪些还没装。
  /// 直接搬插件树很危险——插件是按官方那个核心版本装的，我们的核心版本不同，
  /// 装上可能把引擎带崩（`profiles/*/node_modules` 里还有提升到根的原生依赖）。
  static Future<List<String>> importPluginList({
    required Directory source,
    required Directory target,
    String profile = 'web',
  }) async {
    final sep = Platform.pathSeparator;
    final from = File('${source.path}${sep}profiles${sep}$profile${sep}package.json');
    if (!await from.exists()) return const [];
    try {
      final decoded = jsonDecode(await from.readAsString());
      final map = decoded is Map ? decoded : const {};
      final dsh = map['dsh'];
      final profileMap = dsh is Map ? dsh['profile'] : null;
      final bundles = profileMap is Map ? profileMap['bundles'] : null;
      final names = [
        if (bundles is List)
          for (final b in bundles)
            if ('$b'.isNotEmpty && !'$b'.startsWith('@deepseek-ai/')) '$b',
      ];
      final dir = Directory('${target.path}${sep}dsh-app');
      await dir.create(recursive: true);
      await File('${dir.path}${sep}official-plugins.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
          'profile': profile,
          'plugins': names,
        }),
        flush: true,
      );
      InstallTrace.add('import', '记录官方插件清单：${names.join(', ')}');
      return names;
    } catch (error, stack) {
      InstallTrace.error('import', error, stack);
      return const [];
    }
  }

  /// 可选：同步 DeepSeek 账号的登录态（`.credentials.yaml` 里 kind=grant 的记录）。
  ///
  /// 默认**不**同步——那是账号凭据，属于用户明确要才搬的东西。
  static Future<int> importAccount({required Directory source, required Directory target}) async {
    final sep = Platform.pathSeparator;
    final from = File('${source.path}${sep}.credentials.yaml');
    final to = File('${target.path}${sep}.credentials.yaml');
    if (!await from.exists()) return 0;
    Map<String, Object?> read(Object? decoded) =>
        decoded is Map ? decoded.map((k, v) => MapEntry('$k', v)) : <String, Object?>{};
    final sourceMap = read(_tryYaml(await from.readAsString()));
    final targetMap = await to.exists() ? read(_tryYaml(await to.readAsString())) : <String, Object?>{};
    final sourceRecords = read(sourceMap['records']);
    final targetRecords = read(targetMap['records']);
    final added = sourceRecords.keys.where((k) => !targetRecords.containsKey(k)).toList();
    if (added.isEmpty) return 0;
    final merged = <String, Object?>{
      'version': targetMap['version'] ?? sourceMap['version'] ?? 1,
      'refs': {...read(sourceMap['refs']), ...read(targetMap['refs'])},
      'records': {...sourceRecords, ...targetRecords},
    };
    await to.parent.create(recursive: true);
    await to.writeAsString(const JsonEncoder.withIndent('  ').convert(merged), flush: true);
    InstallTrace.add('import', '同步账号凭据记录：${added.join(', ')}');
    return added.length;
  }

  /// 切出所有顶层 `- id: …` 段落（没有 id 的段落忽略）。
  static List<({String? id, String text})> _allBlocks(String text) {
    final lines = text.split('\n');
    final out = <({String? id, String text})>[];
    var i = 0;
    while (i < lines.length) {
      final match = RegExp(r'^-\s+id:\s*([\w.-]+)\s*$').firstMatch(lines[i]);
      if (match == null) {
        i += 1;
        continue;
      }
      final start = i;
      i += 1;
      while (i < lines.length && !RegExp(r'^-\s').hasMatch(lines[i])) {
        i += 1;
      }
      out.add((id: match.group(1), text: lines.sublist(start, i).join('\n')));
    }
    return out;
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

/// 官方 DSH 里装过哪些插件（导入时记下的清单；界面用来提示）。
final officialPluginListProvider = FutureProvider<List<String>>((ref) async {
  try {
    final support = ref.watch(appSupportDirProvider);
    final file = File('${support.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}home'
        '${Platform.pathSeparator}.dsh${Platform.pathSeparator}dsh-app'
        '${Platform.pathSeparator}official-plugins.json');
    if (!await file.exists()) return const [];
    final decoded = jsonDecode(await file.readAsString());
    final list = decoded is Map ? decoded['plugins'] : null;
    return [if (list is List) for (final p in list) '$p'];
  } catch (_) {
    return const [];
  }
});
