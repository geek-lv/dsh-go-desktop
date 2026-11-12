// macOS 本机引擎：把 DSH 的原生 Node 运行时跑在这台 Mac 上。
//
// Android 版的 `dsh/runtime` 由 Kotlin 实现，里面是 PRoot + Ubuntu rootfs；macOS 不需要
// 任何 Linux 兼容层——Node 24 有官方 darwin-arm64 构建，DSH 就是普通 npm 包，直接起进程
// 即可。这里实现 `RuntimeBridge` 的同一套契约（同样的状态字段、事件、安全模式语义），
// 所以 `lib/runtime/runtime_state.dart` 及其上的所有界面一行都不用改。
//
// 运行时布局（`~/Library/Application Support/<app>/runtime/`）：
//   node/                 官方 Node 发行版（bin/node）
//   dsh/node_modules/...  npm ci 出来的 DSH 依赖树
//   etc/dsh-app/          启动用的 patch overlay、安全模式 overlay
//   home/                 引擎的 HOME（.dsh、工作区、插件都在里面）
//
// 运行时包由 `runtime/build-runtime-macos.sh` 产出，作为 Flutter asset 打进 App；也可以
// 由 manifest 的 `url` 在首次安装时下载。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../desktop/install_trace.dart';
import '../desktop/platform_services.dart';
import '../runtime/dsh_discovery.dart';
import '../runtime/dsh_import.dart';
import '../runtime/runtime_bridge.dart';
import 'official_dsh.dart';
import 'official_proxy.dart';

/// 桌面三端的本机引擎（macOS / Windows / Linux）。
///
/// 名字里的 Mac 是历史：这套实现原本只跑 macOS，现在三端共用，平台差异
/// （tar / du / xattr / uname / netstat / open）全部收口在 [PlatformServices]。
class MacRuntimeBridge implements RuntimeBridge {
  MacRuntimeBridge({
    String? appSupportPath,
    bool official = false,
    PlatformServices? services,
  }) : _appSupportOverride = appSupportPath,
       _official = official, // ignore: prefer_initializing_formals
       _services = services ?? PlatformServices.current();

  final String? _appSupportOverride;

  /// 平台差异（系统命令、架构描述、外部打开）的唯一来源。单测可注入。
  final PlatformServices _services;

  /// 用「正在运行的官方 DSH」而不是内置运行时。
  bool _official;
  bool get official => _official;
  OfficialDsh? _officialNow;
  DateTime? _officialAt;

  /// 复用的「已安装核心」（用户自己 npm/pnpm 装的那份）。
  ///
  /// 设了就**不装、也不写**那棵树：只用它启动，overlay 写在我们自己的支持目录里，
  /// DSH 数据走用户真实的 `~/.dsh`（会话、插件、密钥都是现成的）。
  DiscoveredDsh? _external;
  DiscoveredDsh? get externalCore => _external;
  bool get isExternal => _external != null;

  /// 与官方 DSH **共用数据目录**（`$HOME/.dsh`）：插件、模型 provider、会话都完全一致，
  /// 也就是"和官方网页行为一样"。代价：App 的「重置/卸载运行时」不能再删数据。
  bool _sharedHome = false;
  bool get sharedDataHome => _sharedHome;

  Future<void> setSharedDataHome(bool value) async {
    if (_sharedHome == value) return;
    _sharedHome = value;
    InstallTrace.add('engine', '数据目录：${value ? '与官方 DSH 共用 \$HOME/.dsh' : 'App 私有'}');
    _emit();
  }

  static const String _officialNotRunning = '官方 DSH 没有在运行：先打开 DeepSeek Harness，再回到这里。';

  /// 运行时资源目录：按平台取（macOS / Windows / Linux 各一份产物）。
  static String get _assetDir {
    if (Platform.isWindows) return 'assets/runtime-windows';
    if (Platform.isLinux) return 'assets/runtime-linux';
    return 'assets/runtime-macos';
  }

  static String get _manifestAsset => '$_assetDir/manifest.json';

  /// 归档文件名随平台/架构不同（macOS 是 runtime-arm64.tar.gz，桌面 x64 是
  /// runtime-x64.tar.gz）。manifest 里的 `archive` 字段才是权威来源；这里的
  /// 默认值只用于 manifest 缺失时（例如目录里只有占位文件）的兜底。
  static String get _archiveAsset {
    if (Platform.isWindows || Platform.isLinux) return '$_assetDir/runtime-x64.tar.gz';
    return '$_assetDir/runtime-arm64.tar.gz';
  }

  static final RegExp _tokenLine = RegExp(r'^dsh web: (http://127\.0\.0\.1:[0-9]+/)\?token=([A-Za-z0-9_-]+)');
  static const int _healthyMs = 120000;

  final StreamController<RuntimeEvent> _events = StreamController<RuntimeEvent>.broadcast();
  final List<String> _logs = <String>[];

  Directory? _support;
  Map<String, Object?>? _manifest;

  RuntimePhase _phase = RuntimePhase.notInstalled;
  String? _installedVersion;
  String? _bundledVersion;
  String? _dshVersion;
  String? _nodeVersion;
  String? _baseUrl;
  String? _token;
  String? _error;
  EngineMode _mode = EngineMode.normal;
  SafeModeState _safeState = SafeModeState.off;
  String? _safeReason;
  int _strikes = 0;
  bool _autoSafe = true;
  RuntimeFailure? _failure;
  DateTime? _healthyAt;
  int _generation = 0;

  Process? _process;
  int? _port;
  bool _stopping = false;
  bool _starting = false;
  Timer? _healthTimer;

  /// 官方模式的手机连接代理（手机连它，它注入官方 cookie）。
  OfficialProxy? _phoneProxy;
  int? _phoneProxyTarget;

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  // ---------------------------------------------------------------------------
  // 位置

  Future<Directory> _supportDir() async {
    final cached = _support;
    if (cached != null) return cached;
    // getApplicationSupportDirectory() 在 macOS 上已经是
    // ~/Library/Application Support/<bundle id>/，不用再套一层。
    final base = _appSupportOverride != null ? Directory(_appSupportOverride) : await getApplicationSupportDirectory();
    await base.create(recursive: true);
    _support = base;
    return base;
  }

  /// 引擎的安装目录：复用模式下是用户自己那份 npm 前缀（只读使用）。
  Future<Directory> _runtimeDir() async =>
      _external != null ? Directory(_external!.prefix) : Directory('${(await _supportDir()).path}/runtime');

  /// 引擎的 `HOME`：App 自有引擎是 `<runtime>/home`；复用模式下是用户真实 home，
  /// 于是 `$HOME/.dsh` 就是用户已经装好插件、登录过模型的那份数据。
  Future<Directory> _homeDir() async {
    if (_sharedHome) {
      final env = Platform.environment;
      final home = Platform.isWindows ? (env['USERPROFILE'] ?? env['HOME']) : env['HOME'];
      if (home != null && home.isNotEmpty) return Directory(home);
    }
    if (_external != null) {
      final env = Platform.environment;
      final home = Platform.isWindows ? (env['USERPROFILE'] ?? env['HOME']) : env['HOME'];
      if (home != null && home.isNotEmpty) return Directory(home);
    }
    return Directory('${(await _runtimeDir()).path}/home');
  }
  Future<Directory> _dshHome() async => Directory('${(await _homeDir()).path}/.dsh');

  Future<File> _stateFile() async => File('${(await _supportDir()).path}/runtime-state.json');

  /// 复用模式下 overlay 的目录（我们自己的，不碰用户的安装）。
  /// 只有 `_ensureRuntimeLayout` 跑过之后才有值；argv 展开在它之后。
  String? get _externalOverlayDir => _externalEtcOverride;

  String? _externalEtcOverride;

  /// 复用模式下 dsh-go-bridge 的位置：优先用 App 自有运行时里那份；
  /// 没有就返回 null（不注入 bridge，引擎照常跑，只是少了 App 的集成能力）。
  Future<String?> _externalBridgePath(Directory runtimeDir) async {
    final managed = File('${(await _supportDir()).path}/runtime/bridge/lib/index.js');
    if (await managed.exists()) return managed.path;
    return null;
  }

  // ---------------------------------------------------------------------------
  // 状态

  @override
  Future<RuntimeStatus> status() async {
    if (_official) {
      final found = await _probeOfficial();
      return RuntimeStatus.fromMap(_officialStatusMap(found));
    }
    await _loadInstalledState();
    return RuntimeStatus.fromMap(_statusMap());
  }

  /// 切换到「复用这台设备上已安装的 DSH 核心」，或切回 App 自有的引擎（传 null）。
  ///
  /// 全程只读用户的安装：不安装、不打补丁、不写它的目录；起不来就报错，由上层回退。
  Future<void> useExternalCore(DiscoveredDsh? core) async {
    InstallTrace.add(
      'engine',
      'useExternalCore(${core?.version ?? 'null'}) ← 当前=${_external?.version ?? 'null'}',
    );
    if (identical(_external, core)) return;
    if (_process != null) await stop();
    _external = core;
    _installedVersion = core?.version;
    _phase = core == null ? RuntimePhase.notInstalled : RuntimePhase.installed;
    if (core == null) {
      // 切回 App 自有引擎：版本要从我们自己的 state 文件重新读，别留着外部的。
      await _loadInstalledState();
    }
    _error = null;
    _failure = null;
    _baseUrl = null;
    _token = null;
    InstallTrace.add(
      'engine',
      core == null
          ? 'engine source: app-owned runtime'
          : 'engine source: 复用已安装核心 ${core.version} @ ${core.prefix}（${core.source}，只读）',
    );
    _emit();
  }

  /// 切换「内置运行时 / 官方 DSH」。
  Future<void> setOfficial(bool value) async {
    // 切回官方时即使已经是 official 也重新探测：官方 App 的端口和会话密钥
    // 每次启动都变，用户点了「官方」就是在请求刷新。
    if (_official == value && !value) return;
    _official = value;
    _officialAt = null;
    _officialNow = null;
    if (value) {
      // 官方 DSH 与内置引擎是两套数据：切过去时清掉手机握手，避免指错实例。
      await _clearPhoneAttach();
      final found = await _probeOfficial(force: true);
      _emitMap(_officialStatusMap(found));
    } else {
      await _stopPhoneProxy();
      await _clearPhoneAttach();
      await _loadInstalledState();
      _emitMap(_statusMap());
    }
  }

  /// 官方 DSH 的本地端口 / 密钥可能每次启动都变，缓存几秒即可。
  Future<OfficialDsh?> _probeOfficial({bool force = false}) async {
    final at = _officialAt;
    // 只缓存探测成功的结果：没找到通常只是官方 App 还没开始监听端口，
    // 把它缓存 3 秒会让用户刚启动官方 App 后的切换像是没反应。
    if (!force && _officialNow != null && at != null && DateTime.now().difference(at) < const Duration(seconds: 3)) {
      return _officialNow;
    }
    final found = await findOfficialDsh();
    _officialAt = DateTime.now();
    _officialNow = found;
    if (found != null) {
      _log('[dsh-go] official DSH at ${found.authority}${found.version == null ? '' : ' (v${found.version})'}');
      await _ensurePhoneProxy(found);
    } else {
      await _stopPhoneProxy();
    }
    return found;
  }

  Map<String, Object?> _officialStatusMap(OfficialDsh? found) => <String, Object?>{
    'phase': found == null ? RuntimePhase.error.name : RuntimePhase.running.name,
    'abi': 'arm64',
    'bundledVersion': found?.version,
    'installedVersion': found?.version,
    'dshVersion': found?.version,
    'nodeVersion': null,
    'baseUrl': found?.baseUri.toString(),
    'token': null,
    'cookie': found == null
        ? null
        : <String, Object?>{
            'name': found.cookie.name,
            'value': found.cookie.value,
            'authority': found.cookie.authority,
            'expiresAt': found.cookie.expiresAt?.millisecondsSinceEpoch,
          },
    'official': true,
    'error': found == null ? _officialNotRunning : null,
    'mode': 'normal',
    'safeState': 'off',
    'safeReason': null,
    'strikes': 0,
    'autoSafe': true,
    'failure': null,
    'mainFailure': null,
    'healthyAt': null,
    'networkBlocked': false,
    'networkBlockedAt': null,
    'directEngineEnabled': false,
    'directEngineAvailable': false,
    'directEngineActive': false,
    'directEngineFallbackReason': null,
    'currentExecutionMode': 'official',
    'launchSelectedMode': 'official',
    'launchSpawned': found != null,
    'launchFailureReason': found == null ? _officialNotRunning : null,
    'tidyingFiles': false,
  };

  void _emitMap(Map<String, Object?> map) {
    if (!_events.isClosed) _events.add(RuntimeStatusEvent(RuntimeStatus.fromMap(map)));
  }

  Map<String, Object?> _statusMap() => <String, Object?>{
    'phase': _phase.name,
    'abi': 'arm64',
    'bundledVersion': _bundledVersion,
    'installedVersion': _installedVersion,
    'dshVersion': _dshVersion,
    'nodeVersion': _nodeVersion,
    'baseUrl': _baseUrl,
    'token': _token,
    'external': _external != null,
    'sharedHome': _sharedHome,
    'externalPath': _external?.prefix,
    'externalSource': _external?.source,
    'managedSkillGeneration': _generation > 0 ? _generation : null,
    'error': _error,
    'mode': _mode.name,
    'safeState': _safeState.name,
    'safeReason': _safeReason,
    'strikes': _strikes,
    'autoSafe': _autoSafe,
    'failure': _failure == null ? null : _failureToMap(_failure!),
    'mainFailure': null,
    'healthyAt': _healthyAt?.millisecondsSinceEpoch,
    'networkBlocked': false,
    'networkBlockedAt': null,
    'directEngineEnabled': false,
    'directEngineAvailable': false,
    'directEngineActive': false,
    'directEngineFallbackReason': null,
    'currentExecutionMode': 'native',
    'launchSelectedMode': 'native',
    'launchSpawned': _process != null,
    'launchFailureReason': null,
    'tidyingFiles': false,
  };

  static Map<String, Object?> _failureToMap(RuntimeFailure f) => <String, Object?>{
    'kind': f.kind.name,
    'at': f.at.millisecondsSinceEpoch,
    'exitCode': f.exitCode,
    'safeMode': f.safeMode,
    'summary': f.summary,
    'requiredRows': f.requiredRows,
    'suspects': f.suspects,
    'recent': f.recent,
    'diagnostics': f.diagnostics,
    'upSeconds': f.upSeconds,
  };

  void _emit([RuntimeEvent? event]) {
    if (!_events.isClosed) {
      _events.add(event ?? RuntimeStatusEvent(RuntimeStatus.fromMap(_statusMap())));
    }
  }

  void _log(String line, [String stream = 'stdout']) {
    if (line.isEmpty) return;
    _logs.add(line);
    if (_logs.length > 1000) _logs.removeRange(0, _logs.length - 1000);
    _emit(RuntimeLogEvent(line, stream));
  }

  void _progress(String step, int done, int total) => _emit(RuntimeProgressEvent(step: step, done: done, total: total));

  void _notice(String text) => _emit(RuntimeNoticeEvent(text));

  // ---------------------------------------------------------------------------
  // manifest / 已安装状态

  Future<Map<String, Object?>?> _loadManifest() async {
    if (_external case final core?) {
      // 复用模式没有我们的 manifest：按用户那棵树的实际布局合成一份。
      // node 优先用探测到的（npm 全局目录旁边那个），否则用 PATH 里的。
      return {
        'runtimeVersion': 'external-${core.version}',
        'dshVersion': core.version,
        'launch': {
          'argv': <String>[
            core.nodePath ?? (Platform.isWindows ? 'node.exe' : 'node'),
            core.binScript,
            '{DSH_PROFILE_ARGS}',
            '--host',
            '127.0.0.1',
            '--port',
            '{PORT}',
            '--no-open',
          ],
        },
        // 不复用我们 manifest 的 launchEnv：里面的 {RUNTIME}/tmp 会写进用户的树。
        'launchEnv': <String, Object?>{},
      };
    }
    if (_manifest != null) return _manifest;
    try {
      final raw = await rootBundle.loadString(_manifestAsset);
      final decoded = jsonDecode(raw);
      if (decoded is Map) _manifest = decoded.cast<String, Object?>();
      _bundledVersion = (_manifest?['runtimeVersion'] as String?) ?? 'macos';
      _dshVersion = _manifest?['dshVersion'] as String?;
      _nodeVersion = _manifest?['nodeVersion'] as String?;
      InstallTrace.add(
        'manifest',
        '$_manifestAsset → runtimeVersion=$_bundledVersion dsh=$_dshVersion node=$_nodeVersion '
            'archive=${_manifest?['archive'] ?? '-'} uncompressed=${_manifest?['uncompressedBytes'] ?? '-'}',
      );
    } catch (error, stack) {
      // 以前这里是 `catch (_)`：manifest 读不到和「读到了但解析失败」看起来一样。
      InstallTrace.error('manifest', 'load $_manifestAsset failed: $error', stack);
      _manifest = null;
    }
    return _manifest;
  }

  Future<void> _loadInstalledState() async {
    if (_external != null) {
      // 复用模式：版本来自探测结果，不看我们自己的 state 文件。
      _installedVersion = _external!.version;
      _phase = _process != null ? RuntimePhase.running : RuntimePhase.installed;
      return;
    }
    await _loadManifest();
    final file = await _stateFile();
    final dir = await _runtimeDir();
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          _installedVersion = decoded['installedVersion'] as String?;
          _dshVersion = (decoded['dshVersion'] as String?) ?? _dshVersion;
          _nodeVersion = (decoded['nodeVersion'] as String?) ?? _nodeVersion;
          _safeState = SafeStateStateNames.parse(decoded['safeState'] as String?);
          _safeReason = decoded['safeReason'] as String?;
          _strikes = (decoded['strikes'] as num?)?.toInt() ?? 0;
          _autoSafe = decoded['autoSafe'] != false;
          _mode = EngineMode.parse(decoded['mode']);
          _generation = (decoded['managedSkillGeneration'] as num?)?.toInt() ?? 0;
        }
      }
    } catch (_) {
      // 坏掉的 state 文件按未安装处理。
    }
    // 运行时的 node 可执行文件位置随平台不同：
    //   macOS / Linux  <runtime>/node/bin/node
    //   Windows        <runtime>/node/node.exe   （Node 的 Windows 发行版没有 bin/）
    // 以前只认 bin/node，Windows 上装好了也会被判成「未安装」。
    final nodeBin = File(
      Platform.isWindows ? '${dir.path}/node/node.exe' : '${dir.path}/node/bin/node',
    );
    if (_installedVersion == null && await nodeBin.exists()) {
      // 没有 state 文件但运行时在：当作已装，版本取 manifest。
      _installedVersion = _bundledVersion;
    }
    if (_installedVersion != null && !await nodeBin.exists()) {
      _installedVersion = null;
    }
    if (_process != null) {
      // 进程在，但可能还没就绪（starting 中）或正在收尾（stopping）。
      // 以前这里无条件写 running：只要引擎还在启动、任意一次 status() 就会把
      // 状态报成「运行中」，而这时 baseUrl / token 还是 null——界面拿不到地址，
      // 表现就是引擎「在跑」但页面空白。
      if (_phase != RuntimePhase.starting && _phase != RuntimePhase.stopping) {
        _phase = RuntimePhase.running;
      }
    } else if (_installedVersion != null) {
      _phase = RuntimePhase.installed;
    } else {
      _phase = RuntimePhase.notInstalled;
    }
  }

  /// 诊断里显示的产品名，按平台区分（macOS 版叫 DSH Go Mac）。
  static String get _productName {
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'Mac';
  }

  /// 引擎进程的 PATH。
  ///
  /// 把运行时自带的 node 目录排在最前，这样引擎里的 `node` / `npm` / `pnpm`
  /// 调用走我们打包的那一份。后面的系统目录按平台给：
  ///   macOS / Linux  /usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
  ///   Windows        System32 / PowerShell / 系统 Node 所在目录（分隔符是分号）
  String _enginePath(Directory runtimeDir) {
    final separator = Platform.isWindows ? ';' : ':';
    if (_external case final core?) {
      // 复用模式：用户那棵树里没有我们的 node。用探测到的 node 所在目录
      // （npm 全局目录旁边那个），没有就交给系统 PATH。
      final nodeDir = core.nodePath == null ? null : File(core.nodePath!).parent.path;
      if (Platform.isWindows) {
        final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        return <String>[
          ?nodeDir,
          '$systemRoot\\System32',
          systemRoot,
          '$systemRoot\\System32\\WindowsPowerShell\\v1.0',
          Platform.environment['PATH'] ?? '',
        ].where((p) => p.isNotEmpty).join(separator);
      }
      return <String>[
        ?nodeDir,
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
        '/usr/sbin',
        '/sbin',
      ].join(separator);
    }
    if (Platform.isWindows) {
      final runtimeNode = '${runtimeDir.path}\\node';
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final profile = Platform.environment['USERPROFILE'];
      final appData = Platform.environment['APPDATA'];
      final localAppData = Platform.environment['LOCALAPPDATA'];
      final parts = <String>[
        runtimeNode,
        '$systemRoot\\System32',
        systemRoot,
        '$systemRoot\\System32\\WindowsPowerShell\\v1.0',
        // 系统里已经装的 Node（有些插件会调 npm），追加即可。
        if (Platform.environment['ProgramFiles'] case final programFiles?) '$programFiles\\nodejs',
        // 用户级 CLI：插件型 provider（如 dsh-oh-my-claude 要 spawn `claude`）靠它
        // 找到可执行文件。官方 DSH 继承用户完整 PATH，这里必须同样放行。
        if (profile != null) '$profile\\.local\\bin',
        if (appData != null) '$appData\\npm',
        if (localAppData != null) '$localAppData\\Microsoft\\WindowsApps',
        // 保留用户原本的 PATH（官方行为）：插件/工具链常常依赖它。
        Platform.environment['PATH'] ?? '',
      ].where((p) => p.isNotEmpty).join(separator);
      return parts;
    }
    // Unix：运行时 node 在前，其余交给用户原本的 PATH（官方同样继承）。
    final path = Platform.environment['PATH'] ?? '';
    return [
      '${runtimeDir.path}/node/bin',
      if (path.isNotEmpty) path else '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
    ].join(separator);
  }

  Future<void> _saveState() async {
    // 复用别人的核心时绝不写我们自己的 state：它的版本号会污染 App 自有运行时的
    // 记录（实测过：外部 0.2.1-rc.4 启动后，`runtime-state.json` 被写成 0.2.1-rc.4，
    // 于是切回自带引擎时界面显示的还是外部版本）。
    if (_external != null) return;
    try {
      final file = await _stateFile();
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'installedVersion': _installedVersion,
          'dshVersion': _dshVersion,
          'nodeVersion': _nodeVersion,
          'safeState': _safeState.name,
          'safeReason': _safeReason,
          'strikes': _strikes,
          'autoSafe': _autoSafe,
          'mode': _mode.name,
          'managedSkillGeneration': _generation,
        }),
      );
    } catch (_) {
      // 状态存不下来不影响运行。
    }
  }

  // ---------------------------------------------------------------------------
  // 安装

  @override
  Future<void> install({bool dropKept = false}) async {
    InstallTrace.add(
      'install',
      'bridge.install ENTER phase=${_phase.name} official=$_official dropKept=$dropKept '
          'assetDir=$_assetDir platform=${Platform.operatingSystem}',
    );
    if (_official) {
      InstallTrace.add('install', 'refused: official DSH owns its own runtime');
      throw PlatformException(code: 'official', message: '官方 DSH 由它自己管理，不需要安装运行环境。');
    }
    if (_external != null) {
      InstallTrace.add('install', 'refused: 正在复用已安装核心 ${_external!.version}，不安装');
      throw PlatformException(
        code: 'external',
        message: '正在复用这台设备上已安装的 DSH（${_external!.version}），不需要安装运行环境。',
      );
    }
    if (_phase == RuntimePhase.installing) {
      InstallTrace.add('install', 'refused: install_busy');
      throw PlatformException(code: 'install_busy');
    }
    final manifest = await _loadManifest();
    if (manifest == null) {
      _phase = RuntimePhase.error;
      _error = 'install failed: runtime manifest missing ($_manifestAsset)';
      _emit();
      InstallTrace.add('install', 'aborted: manifest missing ($_manifestAsset)');
      throw PlatformException(code: 'install_failed', message: _error);
    }
    _phase = RuntimePhase.installing;
    _error = null;
    _emit();
    final runtimeDir = await _runtimeDir();
    final staging = Directory('${runtimeDir.path}.staging');
    final backup = Directory('${runtimeDir.path}.old');
    InstallTrace.add(
      'install',
      'dirs runtime=${runtimeDir.path} staging=${staging.path} backup=${backup.path}',
    );
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);

      final archive = File('${staging.path}/runtime.tar.gz');
      await _materializeArchive(manifest, archive);
      final expected = (manifest['archiveSha256'] as String?) ?? '';
      if (expected.isNotEmpty) {
        _log('[dsh-go] verifying runtime archive');
        final digest = await sha256.bind(archive.openRead()).first;
        InstallTrace.add('install', 'checksum expected=$expected actual=$digest');
        if (digest.toString() != expected) {
          throw StateError('archive checksum mismatch');
        }
      } else {
        InstallTrace.add('install', 'checksum skipped: manifest has no archiveSha256');
      }

      final unpack = Directory('${staging.path}/unpack');
      await unpack.create(recursive: true);
      final total = (manifest['uncompressedBytes'] as num?)?.toInt() ?? 0;
      _progress('extract', 0, total);
      InstallTrace.add('install', 'extract → ${unpack.path} (expected $total bytes)');
      // 平台差异（tar / du）收口在 PlatformServices 里：macOS 用 /usr/bin/tar，
      // Windows 用系统自带 tar.exe，Linux 用 PATH 里的 tar。原实现硬编码
      // /usr/bin/tar，在 Windows 上会抛 ProcessException，安装直接失败。
      final extracted = await _services.extractTarGz(
        archive,
        unpack,
        totalBytes: total,
        onProgress: (bytes) => _progress('extract', bytes, total),
      );

      // tar 里有一个顶层目录 runtime/；把它挪成正式的 runtime/。
      final source = await extracted.exists() ? extracted : unpack;
      final unpackedBytes = await _services.directorySize(source);
      InstallTrace.add(
        'install',
        'extracted ${extracted.path} exists=${await extracted.exists()} '
            'bytes=${unpackedBytes ?? '-'}',
      );

      // A crash between moving the old runtime aside and installing the new
      // one leaves only the backup. Put it back before doing anything else.
      if (await backup.exists()) {
        InstallTrace.add('install', 'leftover backup found: ${await runtimeDir.exists() ? 'deleting it' : 'restoring it'}');
        if (await runtimeDir.exists()) {
          await backup.delete(recursive: true);
        } else {
          await _moveDirectory(backup, runtimeDir);
        }
      }
      final hadRuntime = await runtimeDir.exists();
      InstallTrace.add('install', 'hadRuntime=$hadRuntime');
      Directory? homeKeep;
      if (hadRuntime) {
        // Move the old runtime aside and delete it only after the new one is in place.
        await _moveDirectory(runtimeDir, backup);
        final oldHome = Directory('${backup.path}/home');
        if (await oldHome.exists()) {
          // Keep only home; the old node/dsh binaries are disposable.
          // APFS clone keeps this nearly free.
          homeKeep = Directory('${staging.path}/old-home');
          await _cloneDirectory(oldHome, homeKeep);
          InstallTrace.add('install', 'kept previous home → ${homeKeep.path}');
        }
      }
      InstallTrace.add('install', 'moving ${source.path} → ${runtimeDir.path}');
      await _moveDirectory(source, runtimeDir);

      if (homeKeep != null) {
        final newHome = Directory('${runtimeDir.path}/home');
        if (await newHome.exists()) await newHome.delete(recursive: true);
        await _moveDirectory(homeKeep, newHome);
        _log('[dsh-go] kept the previous engine home');
      }

      // Put reset-kept UI, skills, plugins and settings back into .dsh.
      final pending = Directory('${(await _supportDir()).path}/pending-keep');
      if (await pending.exists()) {
        if (dropKept) {
          await pending.delete(recursive: true);
        } else {
          try {
            final dshHome = Directory('${runtimeDir.path}/home/.dsh');
            await dshHome.create(recursive: true);
            await _copyDirectory(pending, dshHome);
            await pending.delete(recursive: true);
          } catch (error) {
            throw StateError('keep: $error');
          }
        }
      }

      _progress('extract', total, total);
      await _ensureRuntimeLayout(runtimeDir, manifest);
      InstallTrace.add('install', 'runtime layout ensured (etc/home/.dsh)');
      _installedVersion = _bundledVersion ?? (manifest['runtimeVersion'] as String?) ?? 'macos';
      _dshVersion = manifest['dshVersion'] as String?;
      _nodeVersion = manifest['nodeVersion'] as String?;
      _phase = RuntimePhase.installed;
      _safeState = SafeModeState.off;
      _strikes = 0;
      await _saveState();
      _emit();
      _log('[dsh-go] runtime $_installedVersion installed');
      InstallTrace.add(
        'install',
        'OK installed=$_installedVersion dsh=$_dshVersion node=$_nodeVersion',
      );
      // 安装成功后 staging 里还躺着 184 MB 的归档副本（原实现在 macOS 上也一样，
      // 只是没人去看）。留着没意义，删掉——装两次多占 184 MB。
      try {
        if (await backup.exists()) await backup.delete(recursive: true);
        if (await staging.exists()) await staging.delete(recursive: true);
        InstallTrace.add('install', 'staging/backup cleaned');
      } catch (error) {
        InstallTrace.error('install', 'cleanup after install failed: $error');
      }
    } catch (error, stack) {
      // The new runtime did not install: remove the partial tree and restore the old one.
      InstallTrace.error('install', 'FAILED: $error', stack);
      try {
        if (await runtimeDir.exists()) await runtimeDir.delete(recursive: true);
        if (await backup.exists()) await _moveDirectory(backup, runtimeDir);
        InstallTrace.add('install', 'rolled back (old runtime ${await runtimeDir.exists() ? 'restored' : 'absent'})');
      } catch (rollback) {
        InstallTrace.error('install', 'rollback failed: $rollback');
      }
      _phase = RuntimePhase.error;
      _error = 'install failed: $error';
      _emit();
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
      throw PlatformException(code: 'install_failed', message: '$error');
    }
  }

  /// Flutter 把 asset 放在可执行文件旁边的固定位置；直接拷文件，避免把 200 MB
  /// 读进内存。三个平台的布局不同：
  ///
  ///   macOS   `<App>.app/Contents/{Frameworks/App.framework/Resources,Resources}/flutter_assets/`
  ///   Windows `<exe目录>/data/flutter_assets/`          （Flutter Windows runner 的布局）
  ///   Linux   `<bundle>/data/flutter_assets/`
  ///
  /// 找不到就返回 null，由调用方回退到 manifest 的 `url` 下载。
  Future<File?> _bundledArchiveOnDisk() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      if (Platform.isMacOS) ...<String>[
        '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/App.framework/Resources/flutter_assets/$_archiveAsset',
        '${File(Platform.resolvedExecutable).parent.parent.path}/Resources/flutter_assets/$_archiveAsset',
      ],
      // Windows 与 Linux：exe 旁边的 data/flutter_assets。
      '$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}$_archiveAsset',
    ];
    for (final path in candidates) {
      final file = File(path);
      final exists = await file.exists();
      InstallTrace.add('archive', 'candidate $path exists=$exists${exists ? ' bytes=${await file.length()}' : ''}');
      if (exists) return file;
    }
    InstallTrace.add('archive', 'no bundled archive on disk (expected asset key $_archiveAsset)');
    return null;
  }

  Future<void> _materializeArchive(Map<String, Object?> manifest, File target) async {
    // 优先用 App 里带的包；没有就看 manifest 有没有下载地址。
    final onDisk = await _bundledArchiveOnDisk();
    if (onDisk != null) {
      InstallTrace.add('archive', 'copying bundled ${onDisk.path} → ${target.path}');
      await onDisk.copy(target.path);
      _log('[dsh-go] using bundled runtime archive (${((await target.length()) / 1048576).toStringAsFixed(1)} MiB)');
      return;
    }
    try {
      final data = await rootBundle.load(_archiveAsset);
      await target.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      InstallTrace.add('archive', 'wrote from asset bundle ${data.lengthInBytes} bytes');
      _log('[dsh-go] using bundled runtime archive (${(data.lengthInBytes / 1048576).toStringAsFixed(1)} MiB)');
      return;
    } catch (error) {
      // 没有内置包。
      InstallTrace.error('archive', 'rootBundle.load($_archiveAsset) failed: $error');
    }
    final url = manifest['url'] as String?;
    if (url == null || url.isEmpty) {
      InstallTrace.add('archive', 'no bundled archive and no manifest url → cannot install');
      throw StateError('no runtime archive bundled and no download url in manifest');
    }
    InstallTrace.add('archive', 'downloading $url');
    _log('[dsh-go] downloading runtime from $url');
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) throw StateError('HTTP ${response.statusCode}');
      final total = response.contentLength > 0 ? response.contentLength : 0;
      var done = 0;
      final sink = target.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        done += chunk.length;
        _progress('download', done, total);
      }
      await sink.close();
    } finally {
      client.close(force: true);
    }
  }

  /// 移动目录。以前调 `/bin/mv`，在 Windows 上不存在这条命令（安装会挂在
  /// ProcessException 上）。改为纯 Dart：
  ///   * 先试 [Directory.rename]（同一卷上是原子的、瞬时完成）；
  ///   * 跨卷时 rename 会失败，退化成「递归复制 + 删源」。
  Future<void> _moveDirectory(Directory from, Directory to) async {
    try {
      await from.rename(to.path);
      return;
    } on FileSystemException {
      // 跨卷 / 目标已存在：走复制路径。
    }
    if (await to.exists()) await to.delete(recursive: true);
    await _copyDirectory(from, to);
    await from.delete(recursive: true);
  }

  /// 递归复制目录内容（目标目录需已存在或由本方法创建）。
  ///
  /// 以前调 `/bin/cp -R`；Windows 上没有 cp，且 Dart 自己遍历更可控
  /// （能保留可执行位以外的结构，且不依赖外部命令）。macOS 上原本用
  /// `cp -R`，语义一致。
  Future<void> _copyDirectory(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: false, followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      final target = '${to.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
      } else if (entity is Link) {
        // 符号链接：尽量保留链接本身，失败时退化为复制目标内容。
        try {
          await Link(target).create(await entity.target(), recursive: true);
        } on FileSystemException {
          final targetPath = await entity.resolveSymbolicLinks();
          final file = File(targetPath);
          if (await file.exists()) await file.copy(target);
        }
      }
    }
  }

  /// Clone a directory. macOS 上原本用 `cp -cR`（APFS clonefile，秒级且不占额外
  /// 空间），其他平台没有等价物，直接走完整复制。
  Future<void> _cloneDirectory(Directory from, Directory to) async {
    if (Platform.isMacOS) {
      await to.create(recursive: true);
      final clone = await Process.run('/bin/cp', <String>['-cR', '${from.path}/.', to.path]);
      if (clone.exitCode == 0) return;
    }
    await _copyDirectory(from, to);
  }

  /// 补齐启动需要、但 tar 里可能没有的目录与安全模式 overlay。
  Future<void> _ensureRuntimeLayout(Directory runtimeDir, Map<String, Object?> manifest) async {
    if (_external != null) {
      // 只读地复用用户的安装：overlay 与安全模式 patch 写在我们自己的目录里。
      final etc = Directory('${(await _supportDir()).path}/external-etc');
      await etc.create(recursive: true);
      _externalEtcOverride = etc.path;
      await File('${etc.path}/dsh-web.patch.yml').writeAsString(
        macLaunchOverlay(runtimeDir.path, bridgePath: await _externalBridgePath(runtimeDir)),
      );
      await File('${etc.path}/safe-mode.patch.yml').writeAsString(macSafeOverlay);
      return;
    }
    final home = Directory('${runtimeDir.path}/home');
    final dshHome = Directory('${home.path}/.dsh');
    await dshHome.create(recursive: true);
    final etc = Directory('${runtimeDir.path}/etc/dsh-app');
    await etc.create(recursive: true);
    // overlay 里是绝对路径（bridge 在运行时的安装位置），所以每次启动前重写。
    final patch = File('${etc.path}/dsh-web.patch.yml');
    await patch.writeAsString(macLaunchOverlay(runtimeDir.path, peekaboo: await peekabooHelperPath(runtimeDir)));
    final safe = File('${etc.path}/safe-mode.patch.yml');
    await safe.writeAsString(macSafeOverlay);
  }

  // ---------------------------------------------------------------------------
  // 启动 / 停止

  @override
  Future<void> start({
    Map<String, String> env = const {},
    bool phoneStorage = false,
    EngineMode? mode,
    bool visualReplies = true,
  }) async {
    if (_official) {
      // 官方模式下 start() 只刷新连接：官方 App 没开时发出 error 状态即可。
      // 这里抛异常会让 EngineControl.ensureStarted 变成未捕获异常——它从
      // RootGate 的自动启动调用，返回值没人等，UI 就会卡在 error 上。
      final found = await _probeOfficial(force: true);
      _emitMap(_officialStatusMap(found));
      return;
    }
    if (_starting || _process != null) return;
    // 占位必须在第一个 await 之前：自动启动可能从 build 和 listener 各来一次。
    _starting = true;
    await _loadInstalledState();
    if (_installedVersion == null) {
      _starting = false;
      throw PlatformException(code: 'not_installed', message: 'runtime is not installed');
    }
    if (mode != null) _mode = mode;
    _phase = RuntimePhase.starting;
    _error = null;
    _failure = null;
    _baseUrl = null;
    _token = null;
    _emit();
    try {
      final manifest = await _loadManifest();
      if (manifest == null) throw StateError('runtime manifest missing');
      final runtimeDir = await _runtimeDir();
      final home = await _homeDir();
      await home.create(recursive: true);
      // 覆盖层里写的是绝对路径：App 被移动、运行时被手工替换后，启动前都要重写，
      // 否则 dsh-app-boot 会因读不到 overlay 直接崩溃。
      await _ensureRuntimeLayout(runtimeDir, manifest);
      if (_external == null) {
        // App 私有数据目录：启动前把官方 DSH 的环境自动补齐（会话/工作区/provider/
        // 无依赖插件）。用户不需要手动点任何"导入"——幂等、只补缺、失败只记 trace。
        if (!_sharedHome) {
          try {
            await DshImport.autoSync(source: DshImport.officialHome(), target: await _dshHome())
                .timeout(const Duration(seconds: 45));
          } catch (error, stack) {
            InstallTrace.error('import/auto', error, stack);
          }
        }
        // 上次退出没能收掉的引擎（崩溃、强制退出）不能占着端口。
        await _reapStale(runtimeDir);
        // 共用官方数据目录时不往里写我们自己的 skill（那是 App 私有产物）。
        if (!_sharedHome) await _ensureSupportSkill(await _dshHome());
      }
      final port = await _pickPort();
      _port = port;

      final safe = _safeState != SafeModeState.off;
      final argv = _expandArgs(manifest, runtimeDir: runtimeDir.path, home: home.path, port: port, safe: safe);
      // 继承用户环境（官方 DSH 就是这样跑的）：插件/CLI provider 常常依赖
      // 用户环境里的变量（PATH、API key、代理…）。下面再覆盖我们必须改的那几个。
      final launchEnv = <String, String>{
        ...Platform.environment,
        'HOME': home.path,
        'DSH_HOME': '${home.path}/.dsh',
        'USER': Platform.environment['USER'] ?? 'dsh',
        'LOGNAME': Platform.environment['LOGNAME'] ?? 'dsh',
        // PATH 必须按平台拼：Windows 用分号分隔，且目录布局不同（node.exe 在根，
        // 没有 /usr/bin 这些），沿用 Unix 的 PATH 会让引擎找不到 node / pnpm。
        'PATH': _enginePath(runtimeDir),
        'TMPDIR': '${(await _supportDir()).path}/tmp',
        'LANG': 'en_US.UTF-8',
        'TERM': 'xterm-256color',
        'NODE_OPTIONS': '--dns-result-order=ipv4first',
        ...env,
      };
      if (safe) launchEnv['DSH_APP_SAFE_MODE'] = '1';
      final manifestEnv = (manifest['launchEnv'] as Map?) ?? const {};
      for (final entry in manifestEnv.entries) {
        final value = '${entry.value}'.replaceAll('{RUNTIME}', runtimeDir.path).replaceAll('{HOME}', home.path);
        launchEnv['${entry.key}'] = value;
      }
      await Directory(launchEnv['TMPDIR']!).create(recursive: true);
      await _services.clearQuarantine(runtimeDir);

      InstallTrace.add(
        'engine',
        'start: external=${_external?.version ?? 'null'} home=${home.path} '
            'runtime=${runtimeDir.path}',
      );
      _log('[dsh-go] starting ${argv.join(' ')}');
      final process = await Process.start(
        argv.first,
        argv.sublist(1),
        environment: launchEnv,
        workingDirectory: home.path,
      );
      _process = process;
      if (_external == null) {
        try {
          await File('${runtimeDir.path}/tmp/dsh-web.pid').writeAsString('${process.pid}');
        } catch (_) {}
      }
      _starting = false;
      _stopping = false;

      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (identical(_process, process)) _onLine(line, 'stdout');
      }, onError: (Object e) => _log('[dsh-go] stdout: $e', 'stderr'));
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (identical(_process, process)) _onLine(line, 'stderr');
      }, onError: (Object e) => _log('[dsh-go] stderr: $e', 'stderr'));
      unawaited(
        process.exitCode.then((code) {
          if (identical(_process, process)) _onExit(code);
        }),
      );
    } catch (error) {
      _starting = false;
      _process = null;
      _phase = RuntimePhase.error;
      _error = 'start failed: $error';
      _emit();
      rethrow;
    }
  }

  List<String> _expandArgs(
    Map<String, Object?> manifest, {
    required String runtimeDir,
    required String home,
    required int port,
    required bool safe,
  }) => expandMacLaunchArgs(
    manifest,
    runtimeDir: runtimeDir,
    home: home,
    port: port,
    safe: safe,
    // 复用模式：overlay 在我们自己的目录里（绝不写用户的安装）。
    overlayDir: _external != null ? _externalOverlayDir : null,
  );

  void _onLine(String line, String stream) {
    _log(line, stream);
    if (_token != null) return;
    final match = _tokenLine.firstMatch(line);
    if (match == null) return;
    _baseUrl = match.group(1);
    _token = match.group(2);
    unawaited(_becameReady());
  }

  Future<void> _becameReady() async {
    final port = _port;
    if (port == null) return;
    // token 行意味着服务已经在监听；先把手机握手写好，别被后面的探活超时拖累。
    if (!_official) {
      await _publishPhoneAttach(processId: _process!.pid, base: Uri.parse(_baseUrl!), token: _token!);
    }
    await _writeDiagnostics();
    for (var i = 0; i < 120; i++) {
      try {
        final socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 500));
        socket.destroy();
        _healthyAt = DateTime.now();
        _phase = RuntimePhase.running;
        _strikes = 0;
        if (_safeState == SafeModeState.probation) _safeState = SafeModeState.off;
        _emit();
        await _saveState();
        await _writeDiagnostics();
        _healthTimer?.cancel();
        _healthTimer = Timer(const Duration(milliseconds: _healthyMs), () {
          _log('[dsh-go] engine stayed healthy for ${_healthyMs ~/ 1000}s');
        });
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    _log('[dsh-go] token seen but port $port never accepted connections', 'stderr');
    await _fail(kind: FailureKind.startupFailed, exitCode: 0, summary: 'engine did not listen');
  }

  Future<void> _onExit(int code) async {
    final expected = _stopping;
    _process = null;
    _healthTimer?.cancel();
    final upSeconds = _healthyAt == null ? null : DateTime.now().difference(_healthyAt!).inSeconds;
    _baseUrl = null;
    _token = null;
    if (expected) {
      _phase = RuntimePhase.installed;
      _emit();
      await _saveState();
      return;
    }
    _log('[dsh-go] engine exited ($code)', 'stderr');
    final kind = switch (code) {
      0 => FailureKind.killed,
      _ => upSeconds != null && upSeconds < 120 ? FailureKind.crashedEarly : FailureKind.crashedLate,
    };
    await _fail(kind: kind, exitCode: code, summary: 'engine exited with $code', upSeconds: upSeconds);
  }

  Future<void> _fail({required FailureKind kind, required int exitCode, String? summary, int? upSeconds}) async {
    final safeMode = _safeState != SafeModeState.off;
    final failure = RuntimeFailure(
      kind: kind,
      at: DateTime.now(),
      exitCode: exitCode,
      safeMode: safeMode,
      summary: summary,
      recent: _logs.length > 40 ? _logs.sublist(_logs.length - 40) : List<String>.of(_logs),
      upSeconds: upSeconds,
    );
    _failure = failure;
    _phase = RuntimePhase.error;
    _error = 'engine failed: ${summary ?? kind.name}';
    if (!safeMode && kind.counts) {
      _strikes += 1;
      if (_safeState == SafeModeState.probation) {
        _safeState = SafeModeState.on;
        _safeReason = 'probation';
        _notice('正常模式还是起不来，已回到安全模式。');
      } else if (_strikes >= 2 && _autoSafe) {
        _safeState = SafeModeState.on;
        _safeReason = 'auto';
        _notice('DSH 连续两次启动失败，已用安全模式启动。你的对话都在。');
      }
    }
    _emit();
    await _saveState();
  }

  @override
  Future<void> stop() async {
    if (_official) {
      // 官方 DSH 由它自己的 App 管理，这里只是断开连接。
      _log('[dsh-go] official DSH keeps running; quit DeepSeek Harness to stop it');
      return;
    }
    final process = _process;
    if (process == null) {
      if (_phase != RuntimePhase.notInstalled) _phase = RuntimePhase.installed;
      _emit();
      return;
    }
    _stopping = true;
    _phase = RuntimePhase.stopping;
    _emit();
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      _log('[dsh-go] engine did not stop in 8s, killing it', 'stderr');
      process.kill(ProcessSignal.sigkill);
    }
    _stopping = false;
    await _clearPidFile();
    await _stopPhoneProxy();
    await _clearPhoneAttach();
  }

  /// 收掉上一次运行残留的引擎（pid 文件里的进程仍是本运行时启动的才动）。
  Future<void> _reapStale(Directory runtimeDir) async {
    final file = File('${runtimeDir.path}/tmp/dsh-web.pid');
    try {
      if (!await file.exists()) return;
      final pid = int.tryParse((await file.readAsString()).trim());
      if (pid == null || pid <= 0) {
        await file.delete();
        return;
      }
      // `ps` / `kill` 是 Unix 命令。Windows 上改用 taskkill，并按窗口标题/进程名
      // 判断——这里保守处理：只在确认命令行里含 runtime 路径时才动它。
      if (Platform.isWindows) {
        await _reapStaleEngineWindows(pid, runtimeDir);
      } else {
        final ps = await Process.run('/bin/ps', <String>['-o', 'command=', '-p', '$pid']);
        final command = ps.exitCode == 0 ? '${ps.stdout}' : '';
        if (command.contains(runtimeDir.path)) {
          await Process.run('/bin/kill', <String>['-TERM', '$pid']);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          await Process.run('/bin/kill', <String>['-KILL', '$pid']);
          _log('[dsh-go] reaped stale engine (pid $pid)', 'stderr');
        }
      }
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清不掉就算了，下一次启动还会再试。
    }
  }

  /// Windows 上回收残留的引擎进程。
  ///
  /// 用 `wmic process where processid=<pid> get commandline` 读命令行（Windows 11
  /// 上 wmic 已弃用，所以退回到 PowerShell 的 Get-CimInstance）。只有命令行里确实
  /// 含本运行时的路径时才 kill，避免误杀别的 node。
  Future<void> _reapStaleEngineWindows(int pid, Directory runtimeDir) async {
    String command = '';
    try {
      final ps = await Process.run('powershell', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "(Get-CimInstance Win32_Process -Filter 'ProcessId=$pid').CommandLine",
      ]);
      if (ps.exitCode == 0) command = '${ps.stdout}';
    } catch (_) {
      return;
    }
    if (!command.contains(runtimeDir.path)) return;
    try {
      await Process.run('taskkill', <String>['/PID', '$pid', '/T', '/F']);
      _log('[dsh-go] reaped stale engine (pid $pid)', 'stderr');
    } catch (_) {}
  }

  Future<void> _clearPidFile() async {
    try {
      final file = File('${(await _runtimeDir()).path}/tmp/dsh-web.pid');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 手机端（DSH Go）用 SSH 连这台 Mac 时，会读 `~/.dsh-app-remote/` 里 dsh-app 的握手文件
  /// 来复用已在运行的 `dsh web`（web.pid / web.st / web.cmd / web.log）。这里把内置引擎的
  /// pid、启动时间、默认启动命令和带 token 的地址写进去——手机就不会再起第二个 DSH，
  /// 也不会碰到官方 DSH 的 `~/.dsh`。
  Future<void> _publishPhoneAttach({required int processId, required Uri base, required String token}) async {
    // 这套握手文件是给「手机通过 SSH 复用本机引擎」用的，依赖 Unix 的
    // ps / chmod / ~/.dsh-app-remote 约定。Windows 上没有 SSH 服务器这一前提，
    // 手机也不会按这套路径来读，直接跳过（不是降级，是平台不适用）。
    if (Platform.isWindows) return;
    final home = Platform.environment['HOME'];
    if (home == null) return;
    try {
      final dir = Directory('$home/.dsh-app-remote');
      await dir.create(recursive: true);
      await Process.run('/bin/chmod', <String>['700', dir.path]);
      final st = await Process.run('/bin/ps', <String>['-p', '$processId', '-o', 'lstart=']);
      await File('${dir.path}/web.pid').writeAsString('$processId');
      // 手机端用 $(ps -p PID -o lstart=) 比较，保留列宽空格，只去掉行尾换行。
      await File('${dir.path}/web.st').writeAsString('${st.stdout}'.replaceFirst(RegExp(r'\n+$'), ''));
      await File('${dir.path}/web.cmd').writeAsString('dsh web');
      await File('${dir.path}/web.log').writeAsString('dsh web: $base?token=$token\n');
      for (final name in <String>['web.pid', 'web.st', 'web.cmd', 'web.log']) {
        await Process.run('/bin/chmod', <String>['600', '${dir.path}/$name']);
      }
      _log('[dsh-go] phone attach ready: ~/.dsh-app-remote (SSH reuses this engine)');
    } catch (error) {
      _log('[dsh-go] phone attach failed: $error', 'stderr');
    }
  }

  /// 1.0.7：引擎起来后写一份脱敏诊断，供 AI（dsh-go-support 技能）排查。
  Future<void> _writeDiagnostics() async {
    try {
      final dshHome = await _dshHome();
      final dir = Directory('${dshHome.path}/dsh-app');
      await dir.create(recursive: true);
      final machine = await _services.describeMachine();
      final tail = _logs.length > 60 ? _logs.sublist(_logs.length - 60) : List<String>.of(_logs);
      final archText = machine;
      final modelText = machine;
      String clean(String line) => line
          .replaceAll(RegExp(r'token=[A-Za-z0-9._~-]+'), 'token=<redacted>')
          .replaceAllMapped(
            RegExp(r'(key|secret|password)=\S+', caseSensitive: false),
            (match) => '${match[1]}=<redacted>',
          );
      final buffer = StringBuffer()
        ..writeln('# DSH Go diagnostics')
        ..writeln()
        ..writeln('- app: DSH Go $_productName 1.0.7')
        ..writeln('- platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln('- arch: $archText')
        ..writeln('- model: $modelText')
        ..writeln('- engine: bundled (DSH ${_dshVersion ?? '?'}, Node ${_nodeVersion ?? '?'})')
        ..writeln('- runtime: ${_installedVersion ?? 'not installed'}')
        ..writeln('- phase: ${_phase.name}')
        ..writeln('- baseUrl: ${_baseUrl ?? '-'}')
        ..writeln('- safe mode: ${_safeState.name}${_safeReason == null ? '' : ' ($_safeReason)'}')
        ..writeln('- strikes: $_strikes')
        ..writeln('- recent failure: ${_failure?.summary ?? '-'}')
        ..writeln()
        ..writeln('## Log tail')
        ..writeln('```')
        ..writeAll(tail.map(clean), '\n')
        ..writeln()
        ..writeln('```');
      final file = File('${dir.path}/diagnostics.md');
      await file.writeAsString(buffer.toString());
      // chmod 是 Unix 概念；Windows 上靠 ACL 继承即可（诊断文件不含 token，
      // 且已用 clean() 脱敏）。
      if (!Platform.isWindows) {
        await Process.run('/bin/chmod', <String>['600', file.path]);
      }
      await _ensureSupportSkill(dshHome);
    } catch (_) {
      // 诊断写不出来不影响引擎。
    }
  }

  /// 内置技能：告诉模型先读诊断，再按症状回答。
  Future<void> _ensureSupportSkill(Directory dshHome) async {
    final dir = Directory('${dshHome.path}/skills/dsh-go-support');
    final file = File('${dir.path}/SKILL.md');
    if (await file.exists()) return;
    await dir.create(recursive: true);
    await file.writeAsString('''---
name: dsh-go-support
description: DSH Go Mac 的排障。用户说 App 连不上、引擎起不来、手机连不上、更新异常，或要你「看下诊断」时，先读 \$DSH_HOME/dsh-app/diagnostics.md（脱敏的版本、设备、运行时、启动方式、最近错误和日志尾部），再按症状给出结论和可直接粘贴的 issue 草稿。
whenToUse: 用户在 DSH Go Mac 上遇到连接、引擎、手机连接或更新问题，或直接要求排查这个 App。
---

# DSH Go Mac 排障

1. 先读 `\$DSH_HOME/dsh-app/diagnostics.md`。里面已有版本、macOS 版本与机型、引擎类型、启动方式、
   连接地址、安全模式、最近失败和日志尾部；不要重复问用户这些。
2. 日志里的 token 已被替换为 `<redacted>`，不要尝试恢复。
3. 手机连接问题：确认 App 在「本地 DSH · 自带」模式、内置引擎运行中，且 `~/.dsh-app-remote/`
   里有 `web.pid`、`web.st`、`web.cmd`、`web.log`；再检查 Mac 的「远程登录」是否开启。
4. 官方 DSH 与内置引擎是两套数据：官方用 `~/.dsh`，内置引擎用 App 自己的数据目录；不要把两者混在一起排查。
5. 结论要短：现象 → 原因 → 下一步。需要报 issue 时给一段可以直接粘贴的中文草稿，附上诊断里的版本与错误行。
''');
  }

  /// 官方模式下给手机一个可复用的本地代理；端口或 cookie 变了就重建。
  Future<void> _ensurePhoneProxy(OfficialDsh official) async {
    if (_phoneProxy != null && _phoneProxyTarget == official.port) return;
    await _stopPhoneProxy();
    try {
      final proxy = OfficialProxy(
        upstream: official.baseUri,
        cookie: official.cookie,
        onLog: (message) => _log('[dsh-go] $message'),
      );
      final started = await proxy.start();
      _phoneProxy = proxy;
      _phoneProxyTarget = official.port;
      await _publishPhoneAttach(
        processId: pid,
        base: Uri.parse('http://127.0.0.1:${started.port}/'),
        token: started.token,
      );
    } catch (error) {
      _log('[dsh-go] official phone proxy failed: $error', 'stderr');
      await _clearPhoneAttach();
    }
  }

  Future<void> _stopPhoneProxy() async {
    await _phoneProxy?.stop();
    _phoneProxy = null;
    _phoneProxyTarget = null;
  }

  Future<void> _clearPhoneAttach() async {
    final home = Platform.environment['HOME'];
    if (home == null) return;
    for (final name in <String>['web.pid', 'web.st']) {
      try {
        final file = File('$home/.dsh-app-remote/$name');
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<int> _pickPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  // ---------------------------------------------------------------------------
  // 其余契约

  @override
  Future<List<String>> logs({int lines = 500}) async {
    if (_logs.length <= lines) return List<String>.of(_logs);
    return _logs.sublist(_logs.length - lines);
  }

  @override
  Future<void> reset({ResetKeep keep = const ResetKeep()}) async {
    if (_sharedHome) {
      throw PlatformException(
        code: 'shared_home',
        message: '正在与官方 DSH 共用数据目录，重置会删掉官方的会话与插件。先切回 App 私有数据再重置。',
      );
    }
    await stop();
    final runtimeDir = await _runtimeDir();
    Directory? stash;
    try {
      final home = Directory('${runtimeDir.path}/home/.dsh');
      if (await home.exists() && (keep.uiAndSkills || keep.pluginsAndSettings)) {
        stash = Directory('${(await _supportDir()).path}/kept');
        if (await stash.exists()) await stash.delete(recursive: true);
        await stash.create(recursive: true);
        if (keep.uiAndSkills) {
          for (final name in <String>['dsh-go', 'skills']) {
            final from = Directory('${home.path}/$name');
            if (await from.exists()) await _copyDirectory(from, Directory('${stash.path}/$name'));
          }
        }
        if (keep.pluginsAndSettings) {
          for (final name in <String>['cordis.patch.yml', '.env', 'plugins', 'package.json']) {
            final from = File('${home.path}/$name');
            final dir = Directory('${home.path}/$name');
            if (await from.exists()) {
              await File('${stash.path}/$name').writeAsBytes(await from.readAsBytes());
            } else if (await dir.exists()) {
              await _copyDirectory(dir, Directory('${stash.path}/$name'));
            }
          }
        }
      }
      if (await runtimeDir.exists()) await runtimeDir.delete(recursive: true);
      final staging = Directory('${runtimeDir.path}.staging');
      if (await staging.exists()) await staging.delete(recursive: true);
    } finally {
      _installedVersion = null;
      _phase = RuntimePhase.notInstalled;
      _baseUrl = null;
      _token = null;
      _failure = null;
      _error = null;
      _strikes = 0;
      _safeState = SafeModeState.off;
      await _saveState();
      _emit();
    }
    if (stash != null && await stash.exists()) {
      try {
        // 放回去：先装好运行时，下一次 install 前恢复。
        // reset 之后 App 会自动重装，这里把保留下来的东西挪到 support 下等 install 取。
        final kept = Directory('${(await _supportDir()).path}/pending-keep');
        if (await kept.exists()) await kept.delete(recursive: true);
        await stash.rename(kept.path);
      } catch (_) {}
    }
  }

  @override
  Future<ManagedSkillInstallResponse> installManagedSkill({
    required String requestId,
    required String expectedRoot,
    required String expectedToken,
    required int? expectedGeneration,
    required String name,
    required Map<String, String> files,
  }) async {
    if (expectedToken != 'macos') {
      return const ManagedSkillInstallResponse(result: null, current: false, reason: 'stale');
    }
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty) {
      return const ManagedSkillInstallResponse(result: null, current: false, reason: 'invalid');
    }
    final dir = Directory('${(await _dshHome()).path}/skills/$safe');
    await dir.create(recursive: true);
    for (final entry in files.entries) {
      final path = '${dir.path}/${entry.key}';
      final target = File(path);
      await target.parent.create(recursive: true);
      await target.writeAsString(entry.value);
    }
    _generation += 1;
    await _saveState();
    return ManagedSkillInstallResponse(result: dir.path, current: true);
  }

  @override
  Future<void> cancelManagedSkill(String requestId) async {}

  @override
  Future<LastKnownGood> lastKnownGood() async => const LastKnownGood.none();

  @override
  Future<LastKnownGood> restoreLastKnownGood() async => const LastKnownGood.none();

  @override
  Future<List<SafeHazard>> safePreflight() async => const <SafeHazard>[];

  @override
  Future<List<String>> moveAside(List<String> paths) async => const <String>[];

  @override
  Future<void> clearFailure() async {
    _failure = null;
    if (_phase == RuntimePhase.error) {
      _phase = _installedVersion == null ? RuntimePhase.notInstalled : RuntimePhase.installed;
    }
    _emit();
  }

  @override
  Future<void> setAutoSafe(bool enabled) async {
    _autoSafe = enabled;
    await _saveState();
    _emit();
  }

  @override
  Future<void> setDirectEngine(bool enabled) async {
    // macOS 没有 PRoot / 直启之分，这个开关原样保留但不生效。
  }

  @override
  Future<List<String>> failureLog() async =>
      _failure?.recent ?? (_logs.length > 40 ? _logs.sublist(_logs.length - 40) : List<String>.of(_logs));

  @override
  Future<StorageAccess> storageStatus() async => const StorageAccess(granted: true, permission: true, legacy: false);

  @override
  Future<StorageAccess> requestStorage() async => const StorageAccess(granted: true, permission: true, legacy: false);

  @override
  Future<bool> openAllFilesAccess() async => true;

  @override
  Future<bool?> batteryExempt() async => null;

  @override
  Future<bool?> requestBatteryExempt() async => null;

  @override
  Future<BackgroundSettingsInfo?> backgroundSettings() async => null;

  @override
  Future<String?> openBackgroundSettings() async => null;

  @override
  Future<String?> openVendorSettings(String vendorSwitch) async => null;

  @override
  Future<bool?> networkMetered() async => false;
}

/// 存进 state 文件的安全模式状态名。
abstract final class SafeStateStateNames {
  static SafeModeState parse(String? wire) => switch (wire) {
    'on' => SafeModeState.on,
    'probation' => SafeModeState.probation,
    _ => SafeModeState.off,
  };
}

/// 展开运行时清单里的启动 argv（`{RUNTIME}` / `{HOME}` / `{PORT}` / `{DSH_PROFILE_ARGS}`）。
///
/// 单独拿出来是为了能在 `flutter test` 里验证，不需要真的装一份运行时。
List<String> expandMacLaunchArgs(
  Map<String, Object?> manifest, {
  required String runtimeDir,
  required String home,
  required int port,
  required bool safe,
  String? overlayDir,
}) {
  final overlay = overlayDir ?? '$runtimeDir/etc/dsh-app';
  final launch = manifest['launch'];
  final raw = (launch is Map ? launch['argv'] as List? : null)?.cast<Object?>() ?? const <Object?>[];
  final args = <String>[];
  for (final item in raw) {
    var value = '$item'.replaceAll('{RUNTIME}', runtimeDir).replaceAll('{HOME}', home).replaceAll('{PORT}', '$port');
    if (value == '{DSH_PROFILE_ARGS}') {
      args.addAll(
        safe
            ? <String>[
                '--profile',
                'dsh-app-safe',
                '--from-default-profile',
                'web',
                '--patch',
                '$overlay/safe-mode.patch.yml',
              ]
            : <String>['web', '--patch', '$overlay/dsh-web.patch.yml'],
      );
      continue;
    }
    if (value == '{SAFE_PATCH}') {
      value = '$overlay/safe-mode.patch.yml';
    }
    args.add(value);
  }
  return args;
}

/// Peekaboo's Mac control helper, when this Mac can run it and the person
/// turned Mac control on. The file sits next to the runtime directory.
Future<String?> peekabooHelperPath(Directory runtimeDir) async {
  if (!Platform.isMacOS) return null;
  final major =
      int.tryParse(RegExp(r'^Version\s+(\d+)').firstMatch(Platform.operatingSystemVersion)?.group(1) ?? '') ?? 0;
  if (major < 15) return null;
  final config = File('${runtimeDir.parent.path}/mac-peekaboo.json');
  if (!await config.exists()) return null;
  try {
    final json = jsonDecode(await config.readAsString());
    if (json is! Map || json['enabled'] != true) return null;
  } catch (_) {
    return null;
  }
  final helper = File('${runtimeDir.parent.path}/peekaboo/peekaboo');
  if (!await helper.exists()) return null;
  return helper.path;
}

/// 正常启动的 overlay：插件安装走镜像 + 官方源，并加载 dsh-go-bridge。
String macLaunchOverlay(String runtimeDir, {String? peekaboo, String? bridgePath}) {
  final helper = peekaboo;
  final home = File(runtimeDir).parent.path;
  final extra = helper == null
      ? ''
      : '''
    - id: mcp-peekaboo
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: peekaboo
        transport: stdio
        command: '$helper'
        args: [mcp]
        env:
          PEEKABOO_ALLOW_TOOLS: 'see,app,window,menu,click,type,set_value,action,scroll,press,verify_state,sleep'
          PEEKABOO_DISABLE_TOOLS: 'shell,browser,agent,dialog_click,dialog_input,capture,paste,clipboard'
          PEEKABOO_AI_PROVIDERS: ''
          PEEKABOO_LOG_LEVEL: 'error'
          PEEKABOO_CONFIG_DIR: '$home/peekaboo/config'
          PEEKABOO_DAEMON_SOCKET: '$home/peekaboo/daemon.sock'
        failOnStartupError: false
''';
  return '''
# dsh-app: overlay for `dsh web`, written by DSH Go for macOS (edits here do not survive a restart).
- id: plugin-manager
  config:
    fallbackRegistries:
      - https://registry.npmmirror.com
      - https://registry.npmjs.org
- insert:
    - id: dsh-go-bridge
      name: ${bridgePath ?? '$runtimeDir/bridge/lib/index.js'}
$extra''';
}

/// 安全模式 overlay：不加载插件管理。
const String macSafeOverlay = '''
# dsh-app safe mode overlay (written by DSH Go for macOS on every safe start).
- id: plugin-manager
  disabled: true
- id: tool-plugin-manager
  disabled: true
''';
