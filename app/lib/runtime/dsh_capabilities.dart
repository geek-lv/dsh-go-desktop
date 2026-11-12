// 补丁 → 用户可见功能的映射：决定「这个引擎能做什么」。
//
// 为什么需要：复用用户已装的核心，或者装了没审查过的新版本时，我们那 105 个补丁不在，
// 一部分**界面功能**会缺（不是核心跑不起来，而是某几项操作没有底层的修复支撑）。
// 与其让用户撞到莫名其妙的失败，不如把「缺哪几项」直接说出来，并在对应入口给解释。
//
// 判定只看两件事：引擎有没有打补丁（`patchSummary` 为 null = 官方原样/外部核心），
// 以及打了的那批里缺了哪些（`lost`）。没打补丁时，所有依赖补丁的功能都算缺失。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'dsh_engines.dart';
import 'engine_source.dart';

/// 一项依赖补丁的界面功能。
class DshCapability {
  const DshCapability({required this.id, required this.patches, required this.label});

  final String id;

  /// 支撑这项功能的补丁（任意一个缺失 / 未打上，就算缺）。
  final List<String> patches;

  /// 界面上的名字（走 l10n）。
  final String Function(L10n l10n) label;
}

/// 依赖补丁的功能清单（只列**用户看得见**的；其余补丁属于引擎内部健壮性修复）。
const List<DshCapability> kDshCapabilities = [
  DshCapability(
    id: 'session-deletion',
    patches: ['zzzzzz-session-deletion.diff'],
    label: _sessionDeletion,
  ),
  DshCapability(
    id: 'plugin-config',
    patches: ['zzzz-plugin-config-readability.diff', 'zzzzz-plugin-config-bundles.diff', 'zzz-config-editor-path.diff'],
    label: _pluginConfig,
  ),
  DshCapability(
    id: 'plugin-install',
    patches: [
      'install-log-redaction.diff',
      'plugin-manager-active-run-guard.diff',
      'plugin-manager-cancel-tree-confirmation.diff',
      'z-plugin-install-log-utf8.diff',
      'zzzzzzz-plugin-list-index.diff',
      'zzzzzzzzz-plugin-manager-metadata-inventory.diff',
    ],
    label: _pluginInstall,
  ),
  DshCapability(
    id: 'session-title',
    patches: ['session-title-word-prefix.diff', 'zzz-title-cache-refresh.diff'],
    label: _sessionTitle,
  ),
  DshCapability(
    id: 'model-defaults',
    patches: ['zzzzzzzz-model-defaults.diff'],
    label: _modelDefaults,
  ),
  DshCapability(
    id: 'schedules',
    patches: ['zzzzzzzz-schedule-authorization.diff', 'zzzzzzzzz-schedule-run-cancel.diff'],
    label: _schedules,
  ),
  DshCapability(
    id: 'jobs',
    patches: [
      'zzzzzzz-job-ring-trim.diff',
      'zzzzzzz-job-follow-removal.diff',
      'zzzzzzzzz-job-result-bytes.diff',
    ],
    label: _jobs,
  ),
  DshCapability(
    id: 'file-refs',
    patches: [
      'zzzzzzz-file-query-normalization.diff',
      'zzzzzzz-file-reference-owner-dispose.diff',
      'zzzzzzz-reference-drop-size.diff',
      'zzzzzzz-reference-encoding.diff',
      'zzzzzzz-grep-retention-preview.diff',
    ],
    label: _fileRefs,
  ),
];

String _sessionDeletion(L10n l10n) => l10n.engineCapabilitySessionDeletion;
String _pluginConfig(L10n l10n) => l10n.engineCapabilityPluginConfig;
String _pluginInstall(L10n l10n) => l10n.engineCapabilityPluginInstall;
String _sessionTitle(L10n l10n) => l10n.engineCapabilitySessionTitle;
String _modelDefaults(L10n l10n) => l10n.engineCapabilityModelDefaults;
String _schedules(L10n l10n) => l10n.engineCapabilitySchedules;
String _jobs(L10n l10n) => l10n.engineCapabilityJobs;
String _fileRefs(L10n l10n) => l10n.engineCapabilityFileRefs;

/// 一个引擎的能力快照。
class DshCapabilities {
  const DshCapabilities({required this.patched, required this.lostPatches});

  /// 是否打了我们的补丁（false = 官方原样 / 外部核心）。
  final bool patched;

  /// 打补丁时缺了哪些。
  final Set<String> lostPatches;

  /// 补丁完整（打了且一个不缺）。
  bool get complete => patched && lostPatches.isEmpty;

  /// 缺哪些界面功能。
  List<DshCapability> get missing {
    if (complete) return const [];
    if (!patched) return kDshCapabilities;
    return [
      for (final capability in kDshCapabilities)
        if (capability.patches.any(lostPatches.contains)) capability,
    ];
  }

  /// 某个功能能不能用（`id` 见 [kDshCapabilities]）。
  bool available(String id) {
    if (complete) return true;
    final capability = kDshCapabilities.where((c) => c.id == id).firstOrNull;
    if (capability == null) return true;
    return !capability.patches.any(lostPatches.contains) && patched;
  }

  static DshCapabilities fromSummary(Map<String, Object?>? summary) {
    if (summary == null) return const DshCapabilities(patched: false, lostPatches: {});
    return DshCapabilities(
      patched: true,
      lostPatches: {for (final name in (summary['lost'] as List?) ?? const []) '$name'},
    );
  }
}

/// 当前引擎的能力：来源是引擎库里的版本就用它的补丁摘要；复用外部核心 = 未打补丁。
final engineCapabilitiesProvider = Provider<DshCapabilities>((ref) {
  final source = ref.watch(engineSourceProvider);
  final store = ref.watch(engineStoreListProvider).value ?? const <DshEngine>[];
  switch (source.source) {
    case EngineSource.owned:
      // App 自带运行时：补丁是构建时打好的，视为完整。
      return const DshCapabilities(patched: true, lostPatches: {});
    case EngineSource.official:
      // 官方 DSH 自己管理自己，补丁与我们无关；不声称任何缺失。
      return const DshCapabilities(patched: true, lostPatches: {});
    case EngineSource.installed:
      final active = source.activeInstalled;
      final engine = store.where((e) => e.path == active?.prefix).firstOrNull;
      return DshCapabilities.fromSummary(engine?.patchSummary);
  }
});
