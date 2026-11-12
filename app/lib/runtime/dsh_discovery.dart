// 探测「这台设备上已经装好的 DSH 核心」，用于首次运行时跳过安装、直接复用。
//
// 背景：App 也可以不和官方核心捆绑——用户用 npm / pnpm / 官方桌面版装过的 DSH，
// 只要版本合适，就可以直接拿它的 `node_modules/@deepseek-ai/dsh` 来跑，会话、插件、
// 密钥都走用户自己的 `~/.dsh`，什么都不用迁。
//
// 约束（很重要，决定了下面的实现）：
//   * **只读**：绝不写用户的全局树，所以我们只 `package.json` / `lib/bin.js` 探测；
//   * **离线**：纯文件系统扫描，不发网络请求，首次运行时是毫秒级；
//   * **可解释**：每个候选都带 `source` 与不可用原因，界面能把「为什么没选它」说清楚。
//
// 版本比较只处理 npm 语义化版本里 DSH 实际用的形态（`0.2.2-rc.1` / `0.2.1`），
// 预发布版小于同号正式版。

import 'dart:convert';
import 'dart:io';

/// 一个可用的「已安装核心」。
class DiscoveredDsh {
  const DiscoveredDsh({
    required this.prefix,
    required this.dshDir,
    required this.version,
    required this.source,
    this.nodePath,
  });

  /// npm 前缀：其下有 `node_modules/@deepseek-ai/dsh`。
  final String prefix;

  /// `@deepseek-ai/dsh` 包目录。
  final String dshDir;

  final String version;

  /// 从哪发现的：`npm-global` / `path` / `pnpm` / `nvm` / `user` / `bundled` …
  final String source;

  /// 优先使用的 node（找到的 shim 旁边的那个）；null 表示用 PATH 里的 node。
  final String? nodePath;

  /// 引擎入口：`lib/bin.js`。
  String get binScript => '$dshDir${Platform.pathSeparator}lib${Platform.pathSeparator}bin.js';

  Map<String, Object?> toJson() => {
    'prefix': prefix,
    'version': version,
    'source': source,
    if (nodePath != null) 'nodePath': nodePath,
  };

  @override
  String toString() => 'DSH $version @ $prefix ($source)';
}

/// 一个探测过的候选（含不可用的），用于诊断与界面解释。
class DshCandidate {
  const DshCandidate({required this.prefix, required this.source, this.dsh, this.reason});

  final String prefix;
  final String source;

  /// 可用时为探测结果。
  final DiscoveredDsh? dsh;

  /// 不可用原因（`no-package` / `bad-version` / `no-entry` …）。
  final String? reason;

  bool get usable => dsh != null;

  Map<String, Object?> toJson() => {
    'prefix': prefix,
    'source': source,
    'usable': usable,
    if (dsh != null) 'version': dsh!.version,
    if (reason != null) 'reason': reason,
  };
}

/// 与「我们发版绑定的版本」相比，这个核心算什么。
enum CoreCompat {
  /// 就是我们审查过的那个版本（补丁链完整可用）。
  vetted,

  /// 同族但版本不同：可用，未审查的补丁逐条 best-effort。
  otherVersion,

  /// 不可用（缺入口 / 版本读不出来）。
  unusable,
}

/// 已安装核心的探测。全部是纯文件系统判断，可以在单测里注入环境。
abstract final class DshDiscovery {
  /// 扫一遍常见安装位置。
  ///
  /// [environment] 默认取 `Platform.environment`；[userHome] 默认 `HOME`/`USERPROFILE`；
  /// [extraPrefixes] 是用户在设置里手填的前缀（优先返回）。
  static Future<List<DshCandidate>> scan({
    Map<String, String>? environment,
    String? userHome,
    List<String> extraPrefixes = const [],
  }) async {
    final env = environment ?? Platform.environment;
    final home = userHome ?? _home(env);
    final candidates = <DshCandidate>[];

    for (final prefix in extraPrefixes) {
      candidates.add(await probePrefix(prefix, source: 'user'));
    }
    for (final entry in _knownPrefixes(env, home)) {
      candidates.add(await probePrefix(entry.prefix, source: entry.source));
    }

    // 去掉重复前缀（`PATH` 与全局目录经常重叠），保留第一个来源。
    final seen = <String>{};
    final unique = <DshCandidate>[];
    for (final candidate in candidates) {
      final key = _normalize(candidate.prefix);
      if (!seen.add(key)) continue;
      unique.add(candidate);
    }
    return unique;
  }

  /// 只返回可用的，按版本从新到旧。
  static Future<List<DiscoveredDsh>> scanUsable({
    Map<String, String>? environment,
    String? userHome,
    List<String> extraPrefixes = const [],
  }) async {
    final all = await scan(environment: environment, userHome: userHome, extraPrefixes: extraPrefixes);
    final usable = [
      for (final candidate in all) ?candidate.dsh,
    ];
    usable.sort((a, b) => compareVersions(b.version, a.version));
    return usable;
  }

  /// 检查一个 npm 前缀里是否有一份可用的 DSH。
  static Future<DshCandidate> probePrefix(String prefix, {required String source}) async {
    final dshDir = '$prefix${Platform.pathSeparator}node_modules${Platform.pathSeparator}@deepseek-ai'
        '${Platform.pathSeparator}dsh';
    final manifest = File('$dshDir${Platform.pathSeparator}package.json');
    if (!await manifest.exists()) {
      return DshCandidate(prefix: prefix, source: source, reason: 'no-package');
    }
    String? version;
    String? name;
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is Map) {
        name = decoded['name'] as String?;
        version = decoded['version'] as String?;
      }
    } catch (error) {
      return DshCandidate(prefix: prefix, source: source, reason: 'bad-package-json');
    }
    if (name != '@deepseek-ai/dsh') {
      return DshCandidate(prefix: prefix, source: source, reason: 'wrong-package');
    }
    if (version == null || version.isEmpty) {
      return DshCandidate(prefix: prefix, source: source, reason: 'bad-version');
    }
    final bin = File('$dshDir${Platform.pathSeparator}lib${Platform.pathSeparator}bin.js');
    if (!await bin.exists()) {
      return DshCandidate(prefix: prefix, source: source, reason: 'no-entry');
    }
    return DshCandidate(
      prefix: prefix,
      source: source,
      dsh: DiscoveredDsh(
        prefix: prefix,
        dshDir: dshDir,
        version: version,
        source: source,
        nodePath: await _nodeNextTo(prefix),
      ),
    );
  }

  /// 版本兼容判定。[vetted] 是我们审查过的版本集合（含发版绑定版本）。
  static CoreCompat classify(String version, {required Set<String> vetted}) =>
      vetted.contains(version) ? CoreCompat.vetted : CoreCompat.otherVersion;

  // ── 平台相关的位置 ────────────────────────────────────────────────────────

  static List<({String prefix, String source})> _knownPrefixes(Map<String, String> env, String? home) {
    final out = <({String prefix, String source})>[];
    final sep = Platform.pathSeparator;

    if (Platform.isWindows) {
      final appData = env['APPDATA'];
      if (appData != null) {
        // npm 全局：bin 在 %APPDATA%\npm，包在 %APPDATA%\npm\node_modules
        out.add((prefix: appData, source: 'npm-global'));
        out.add((prefix: '$appData${sep}npm', source: 'npm-global'));
        // nvm-windows 每个 node 版本一份全局目录
        out.addAll(_globPrefixes('$appData${sep}nvm', 'node_modules', 'nvm'));
      }
      final localAppData = env['LOCALAPPDATA'];
      if (localAppData != null) {
        out.addAll(_globPrefixes('$localAppData${sep}pnpm${sep}global', 'node_modules', 'pnpm'));
        // volta 的可执行 shim 目录
        out.add((prefix: '$localAppData${sep}Volta${sep}tools${sep}image${sep}packages', source: 'volta'));
      }
      final programFiles = env['ProgramFiles'];
      if (programFiles != null) out.add((prefix: '$programFiles${sep}nodejs', source: 'nodejs'));
    } else {
      for (final prefix in <String>[
        '/usr/local/lib',
        '/usr/lib',
        '/opt/homebrew/lib',
        if (home != null) '$home/.npm-global/lib',
        if (home != null) '$home/.local/lib',
        if (home != null) '$home/.bun/install/global',
      ]) {
        out.add((prefix: prefix, source: 'npm-global'));
      }
      if (home != null) {
        out.addAll(_globPrefixes('$home/.nvm/versions/node', 'lib/node_modules', 'nvm'));
        out.addAll(_globPrefixes('$home/.local/share/fnm/node-versions', 'installation/lib/node_modules', 'fnm'));
        out.addAll(_globPrefixes('$home/.local/share/pnpm/global', 'node_modules', 'pnpm'));
      }
      out.addAll(_globPrefixes('/usr/local/share/nvm/versions/node', 'lib/node_modules', 'nvm'));
    }

    // PATH 里的 node 安装目录（node 全局包就在它旁边）。
    final pathVar = env['PATH'] ?? env['Path'] ?? '';
    for (final entry in pathVar.split(Platform.isWindows ? ';' : ':')) {
      if (entry.trim().isEmpty) continue;
      final dir = Directory(entry.trim());
      final hasDsh = File('${dir.path}${sep}dsh${Platform.isWindows ? '.cmd' : ''}');
      // 只把「有 dsh 可执行文件」的目录当作线索，避免把整个 PATH 都扫一遍。
      if (!hasDsh.existsSync() && !File('${dir.path}${sep}dsh').existsSync()) continue;
      out.add((prefix: dir.path, source: 'path'));
      out.add((prefix: '${dir.path}${sep}node_modules', source: 'path'));
      final parent = dir.parent.path;
      out.add((prefix: parent, source: 'path'));
    }
    return out;
  }

  /// 扫一层通配目录（每个 node 版本 / pnpm 版本一个子目录）。
  static List<({String prefix, String source})> _globPrefixes(String root, String tail, String source) {
    final out = <({String prefix, String source})>[];
    final dir = Directory(root);
    if (!dir.existsSync()) return out;
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final path = tail.replaceAll('/', Platform.pathSeparator);
        out.add((prefix: '${entity.path}${Platform.pathSeparator}$path', source: source));
      }
    } catch (_) {
      // 没权限就当没有。
    }
    return out;
  }

  /// 前缀旁边是否有 node（Windows 上 npm 全局目录旁边常见）。
  static Future<String?> _nodeNextTo(String prefix) async {
    final sep = Platform.pathSeparator;
    final exe = Platform.isWindows ? 'node.exe' : 'node';
    for (final candidate in <String>[
      '$prefix$sep$exe',
      '${Directory(prefix).parent.path}$sep$exe',
      if (Platform.isWindows) '${Platform.environment['ProgramFiles'] ?? r'C:\Program Files'}$sep'
          'nodejs$sep$exe',
    ]) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  static String? _home(Map<String, String> env) {
    if (Platform.isWindows) return env['USERPROFILE'] ?? env['HOME'];
    return env['HOME'];
  }

  static String _normalize(String path) {
    var value = path.replaceAll('\\', '/');
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return Platform.isWindows ? value.toLowerCase() : value;
  }
}

/// 比较两个 npm 版本（`0.2.2-rc.1` 形态）。返回 <0 / 0 / >0。
///
/// 规则与 semver 一致：数字段逐个比较；同号时正式版大于预发布版；
/// 预发布段之间按「数字 < 字母」比较（`rc.2` > `rc.1`，`beta` < `rc`）。
int compareVersions(String a, String b) {
  final pa = _parse(a);
  final pb = _parse(b);
  for (var i = 0; i < 3; i++) {
    final diff = pa.numbers[i].compareTo(pb.numbers[i]);
    if (diff != 0) return diff;
  }
  if (pa.pre.isEmpty && pb.pre.isEmpty) return 0;
  if (pa.pre.isEmpty) return 1;
  if (pb.pre.isEmpty) return -1;
  final len = pa.pre.length < pb.pre.length ? pa.pre.length : pb.pre.length;
  for (var i = 0; i < len; i++) {
    final x = pa.pre[i];
    final y = pb.pre[i];
    final xn = int.tryParse(x);
    final yn = int.tryParse(y);
    if (xn != null && yn != null) {
      final diff = xn.compareTo(yn);
      if (diff != 0) return diff;
    } else if (xn != null) {
      return -1;
    } else if (yn != null) {
      return 1;
    } else {
      final diff = x.compareTo(y);
      if (diff != 0) return diff;
    }
  }
  return pa.pre.length.compareTo(pb.pre.length);
}

({List<int> numbers, List<String> pre}) _parse(String version) {
  final cleaned = version.trim().replaceFirst(RegExp(r'^[v=]+'), '').split('+').first;
  final dash = cleaned.indexOf('-');
  final core = dash >= 0 ? cleaned.substring(0, dash) : cleaned;
  final pre = dash >= 0 ? cleaned.substring(dash + 1).split('.') : const <String>[];
  final numbers = <int>[0, 0, 0];
  final parts = core.split('.');
  for (var i = 0; i < 3 && i < parts.length; i++) {
    numbers[i] = int.tryParse(parts[i].replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  }
  return (numbers: numbers, pre: pre);
}
