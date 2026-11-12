// 「引擎来源」：App 自带引擎 / 复用这台设备上已装的 DSH / 连正在运行的官方 DSH。
//
// 三种来源的差别只在「用哪个可执行文件、哪份 .dsh 数据」：
//   owned      App 支持目录下的运行时（我们打的补丁、脚本里的 skills 都在）
//   installed  用户自己 npm/pnpm 装的那份（只读复用，数据走 `$HOME/.dsh`）
//   official   已经在跑的 DeepSeek Harness（签 cookie 直连，不迁移数据）
//
// 这个控制器负责：持久化选择、启动时把选择应用到 [MacRuntimeBridge]、扫描候选。
// 所有失败都必须收敛成状态，不能把异常抛给界面（启动路径上没人 await）。

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../desktop/install_trace.dart';
import '../macos/mac_runtime.dart';
import '../macos/macos_support.dart';
import '../macos/official_dsh.dart';
import 'dsh_discovery.dart';
import 'dsh_engines.dart';
import 'runtime_bridge.dart';
import 'runtime_state.dart';

/// 引擎从哪来。
enum EngineSource {
  owned,
  installed,
  official;

  static EngineSource parse(String? wire) =>
      EngineSource.values.firstWhere((s) => s.name == wire, orElse: () => EngineSource.owned);
}

/// 比较两个引擎路径：Windows 上大小写与分隔符都可能不同（持久化时可能写成 `/`）。
bool sameEnginePath(String a, String b) {
  String norm(String path) {
    var value = path.replaceAll('\\', '/');
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  return norm(a) == norm(b);
}

const engineSourcePref = 'dsh.engine_source';
const engineInstalledPrefixPref = 'dsh.engine_installed_prefix';

/// 用户选的引擎来源 + 探测到的候选。
class EngineSourceState {
  const EngineSourceState({
    this.source = EngineSource.owned,
    this.loaded = false,
    this.scanning = false,
    this.installed = const [],
    this.installedPrefix,
    this.official,
    this.error,
    this.storeEngine,
  });

  final EngineSource source;
  final bool loaded;
  final bool scanning;

  /// 这台设备上探测到的可用核心（按版本从新到旧）。
  final List<DiscoveredDsh> installed;

  /// 选中的前缀（持久化下来，版本可以变）。
  final String? installedPrefix;

  /// 正在运行的官方 DSH。
  final OfficialDsh? official;

  /// 最近一次应用来源失败的原因（界面提示，不影响其他功能）。
  final String? error;

  /// 当前用的是引擎库里的哪个版本（选了库版本时才有）。
  final DshEngine? storeEngine;

  /// 当前真正在用的那份已安装核心。
  DiscoveredDsh? get activeInstalled {
    if (storeEngine case final engine?) {
      return DiscoveredDsh(
        prefix: engine.path,
        dshDir: '${engine.path}${Platform.pathSeparator}node_modules${Platform.pathSeparator}'
            '@deepseek-ai${Platform.pathSeparator}dsh',
        version: engine.version,
        source: 'store',
      );
    }
    if (installed.isEmpty) return null;
    final prefix = installedPrefix;
    if (prefix != null) {
      for (final core in installed) {
        if (sameEnginePath(core.prefix, prefix)) return core;
      }
    }
    return installed.first;
  }

  /// 复用模式下没打我们的补丁：功能会降级，界面要说清楚。
  bool get degraded => source == EngineSource.installed;

  EngineSourceState copyWith({
    EngineSource? source,
    bool? loaded,
    bool? scanning,
    List<DiscoveredDsh>? installed,
    String? installedPrefix,
    OfficialDsh? official,
    String? error,
    DshEngine? storeEngine,
    bool clearOfficial = false,
    bool clearError = false,
  }) => EngineSourceState(
    source: source ?? this.source,
    loaded: loaded ?? this.loaded,
    scanning: scanning ?? this.scanning,
    installed: installed ?? this.installed,
    installedPrefix: installedPrefix ?? this.installedPrefix,
    official: clearOfficial ? null : (official ?? this.official),
    error: clearError ? null : (error ?? this.error),
    storeEngine: storeEngine ?? this.storeEngine,
  );
}

class EngineSourceController extends Notifier<EngineSourceState> {
  MacRuntimeBridge get _bridge => ref.read(macRuntimeBridgeProvider);
  bool _restored = false;

  bool _fallingBack = false;

  @override
  EngineSourceState build() {
    // 复用别人的核心时它随时可能被卸载/升级成不兼容版本：一旦启动失败，
    // 自动回落到 App 自带的引擎（只回落一次，避免来回切）。
    ref.listen(localRuntimeProvider.select((s) => s.status.phase), (previous, next) {
      if (next != RuntimePhase.error) return;
      if (state.source != EngineSource.installed || _fallingBack) return;
      _fallingBack = true;
      unawaited(_fallbackToOwned());
    });
    unawaited(restore());
    return const EngineSourceState();
  }

  /// 外部核心起不来：切回 App 自带引擎，并把原因留在状态里给界面显示。
  Future<void> _fallbackToOwned() async {
    final core = state.activeInstalled;
    InstallTrace.add(
      'engine-source',
      'external core failed (${core?.version ?? '?'} @ ${core?.prefix ?? '?'}) → 回落到 App 自带引擎',
    );
    await select(EngineSource.owned);
    state = state.copyWith(error: 'installed-core-failed');
    _fallingBack = false;
  }

  /// 启动时调用一次：读持久化的选择，扫描候选，并把选择应用到桥。
  ///
  /// 幂等：`build()` 会先 fire-and-forget 调一次，main.dart 再 await 一次，
  /// 保证首帧决定引导步骤之前来源已经生效。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    final source = EngineSource.parse(prefs.getString(engineSourcePref));
    final prefix = prefs.getString(engineInstalledPrefixPref);
    InstallTrace.add('engine-source', 'restore: source=${source.name} prefix=${prefix ?? '-'}');
    state = state.copyWith(source: source, installedPrefix: prefix);
    // 先应用、后扫描：引擎的自动启动来自首帧，扫描（含官方 DSH 探测，最长 3 秒）
    // 不能挡在它前面——否则会先用 App 自带引擎启动，再切到外部核心，白白起停一次。
    if (source == EngineSource.installed && prefix != null) {
      try {
        final engines = await ref.read(engineStoreListProvider.future);
        final match = engines.where((e) => sameEnginePath(e.path, prefix)).firstOrNull;
        if (match != null) {
          state = state.copyWith(storeEngine: match);
          await _applyStoreEngine(match);
        } else {
          // 库注册表里没有（可能是用户手填的外部前缀）：扫描后再应用。
          await _apply();
        }
      } catch (error, stack) {
        InstallTrace.error('engine-source', error, stack);
      }
    } else {
      await _apply();
    }
    state = state.copyWith(loaded: true);
    await refresh();
  }

  /// 重新扫描：已安装核心 + 运行中的官方 DSH。不会改变当前选择。
  Future<void> refresh() async {
    if (state.scanning) return;
    state = state.copyWith(scanning: true);
    try {
      final installed = await DshDiscovery.scanUsable(extraPrefixes: _extraPrefixes);
      OfficialDsh? official;
      if (isDesktop) {
        try {
          official = await findOfficialDsh().timeout(const Duration(seconds: 3));
        } catch (_) {
          official = null;
        }
      }
      InstallTrace.add(
        'engine-source',
        'scan: installed=${installed.map((c) => '${c.version}@${c.source}').join(',')} '
            'official=${official?.port ?? '-'}',
      );
      state = state.copyWith(
        installed: installed,
        official: official,
        clearOfficial: official == null,
        scanning: false,
      );
    } catch (error, stack) {
      InstallTrace.error('engine-source', error, stack);
      state = state.copyWith(scanning: false, error: '$error');
    }
  }

  /// 切换来源。[prefix] 用于在多个已安装核心之间选一个。
  Future<void> select(EngineSource source, {String? prefix}) async {
    InstallTrace.add('engine-source', 'select ${source.name}${prefix == null ? '' : ' prefix=$prefix'}');
    state = state.copyWith(source: source, installedPrefix: prefix, clearError: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(engineSourcePref, source.name);
    if (prefix != null) await prefs.setString(engineInstalledPrefixPref, prefix);
    await _apply();
  }

  /// 选引擎库里的某个版本（升级 / 降级 / pin 回发版版本）。
  Future<void> selectEngine(DshEngine engine) async {
    InstallTrace.add('engine-source', 'select store engine ${engine.version} @ ${engine.path}');
    state = state.copyWith(
      source: EngineSource.installed,
      installedPrefix: engine.path,
      storeEngine: engine,
      clearError: true,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(engineSourcePref, EngineSource.installed.name);
    await prefs.setString(engineInstalledPrefixPref, engine.path);
    await _applyStoreEngine(engine);
  }

  /// 直接用库里的版本启动（不走扫描，路径与版本都是确定的）。
  Future<void> _applyStoreEngine(DshEngine engine) async {
    try {
      final bridge = _bridge;
      await bridge.setOfficial(false);
      await bridge.useExternalCore(ref.read(engineStoreProvider).asDiscovered(engine));
      state = state.copyWith(clearError: true);
    } catch (error, stack) {
      InstallTrace.error('engine-source', error, stack);
      state = state.copyWith(error: '$error');
    }
  }

  /// 回到 App 自带的引擎（外部核心起不来时的兜底）。
  Future<void> revertToOwned() => select(EngineSource.owned);

  /// 把当前选择应用到运行时桥。任何失败都只记在 [EngineSourceState.error]。
  Future<void> _apply() async {
    try {
      final bridge = _bridge;
      switch (state.source) {
        case EngineSource.owned:
          await bridge.useExternalCore(null);
          await bridge.setOfficial(false);
        case EngineSource.official:
          await bridge.useExternalCore(null);
          await bridge.setOfficial(true);
        case EngineSource.installed:
          if (state.storeEngine case final engine?) {
            await _applyStoreEngine(engine);
            return;
          }
          final core = state.activeInstalled;
          if (core == null) {
            state = state.copyWith(error: 'installed core not found');
            InstallTrace.add('engine-source', 'apply: 选了「已安装」，但没找到可用核心，保持 App 自带引擎');
            await bridge.useExternalCore(null);
            await bridge.setOfficial(false);
            return;
          }
          await bridge.setOfficial(false);
          await bridge.useExternalCore(core);
      }
      state = state.copyWith(clearError: true);
    } catch (error, stack) {
      InstallTrace.error('engine-source', error, stack);
      state = state.copyWith(error: '$error');
    }
  }

  /// 用户在设置里手填的前缀（可选，暂时只从 prefs 里读一个）。
  List<String> get _extraPrefixes {
    final prefix = state.installedPrefix;
    return prefix == null ? const [] : [prefix];
  }
}

final engineSourceProvider = NotifierProvider<EngineSourceController, EngineSourceState>(
  EngineSourceController.new,
);
