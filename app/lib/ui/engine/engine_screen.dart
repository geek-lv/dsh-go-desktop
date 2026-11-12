import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../macos/macos_support.dart';
import '../../macos/phone_link_page.dart';
import '../../desktop/install_trace.dart';
import '../../runtime/dsh_discovery.dart';
import '../../runtime/dsh_capabilities.dart';
import '../../runtime/dsh_engines.dart';
import '../../runtime/dsh_import.dart';
import '../plugins/plugins_screen.dart';
import '../../runtime/dsh_npm.dart';
import '../../runtime/engine_source.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../runtime/local_footprint.dart';
import '../../state/app_info.dart';
import '../../state/engine_control.dart';
import '../../state/sessions_state.dart';
import '../../state/safe_mode_state.dart';
import '../../state/settings_state.dart';
import '../common/app_dialog.dart';
import '../common/page_hero.dart';
import '../onboarding/local_install.dart';
import '../safe_mode/engine_failure_card.dart';
import '../safe_mode/safe_mode_card.dart';
import '../safe_mode/safe_mode_settings.dart';
import '../settings/background_guide_page.dart';
import '../settings/diagnostics_page.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/local_web_screen.dart';
import 'engine_status.dart';
import 'local_uninstall.dart';
import 'log_view.dart';

/// `rN-dsh…-HASH` → `rN · HASH8`; anything else is shown as is.
String shortRuntimeVersion(String? v) {
  if (v == null || v.isEmpty) return '—';
  final m = RegExp(r'^(r\d+)-.*-([0-9a-f]{8,})$').firstMatch(v);
  return m == null ? v : '${m.group(1)} · ${m.group(2)!.substring(0, 8)}';
}

/// One line under the engine's name: what it is doing right now.
String engineDetail(RuntimeStatus status) => switch (status.phase) {
  RuntimePhase.running =>
    status.inSafeMode
        ? appL10n.phoneEngineSafeAt(Uri.tryParse(status.baseUrl ?? '')?.authority ?? appL10n.commonThisPhone)
        : appL10n.phoneEngineRunningAt(Uri.tryParse(status.baseUrl ?? '')?.authority ?? appL10n.commonThisPhone),
  RuntimePhase.starting =>
    status.inSafeMode
        ? appL10n.phoneEngineStartingSafeEllipsis
        : status.tidyingFiles
        ? appL10n.phoneEngineTidyingFilesEllipsis
        : appL10n.phoneEngineStartingEllipsis,
  RuntimePhase.stopping => appL10n.phoneEngineStoppingEllipsis,
  RuntimePhase.installed => status.inSafeMode ? appL10n.phoneEngineStoppedNextSafe : appL10n.commonStopped,
  RuntimePhase.installing => appL10n.phoneEngineInstallingRuntime,
  RuntimePhase.notInstalled => appL10n.phoneEngineRuntimeNotInstalled,
  RuntimePhase.error =>
    status.failure != null
        ? failureOneLiner(status.failure!)
        : humanizeRuntimeError(status.error) ?? appL10n.phoneEngineErrorSeeLogs,
};

/// The local engine: a status ring with the
/// versions, start / stop / restart, the live log in a dark terminal card, and
/// the engine's own settings.
class EngineScreen extends ConsumerWidget {
  const EngineScreen({super.key});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(localRuntimeProvider);
    final status = state.status;
    final view = EngineStatusView.of(state);
    final settings = ref.watch(settingsProvider);
    final colors = DshColors.of(context);
    final logHeight = (MediaQuery.sizeOf(context).height * 0.42).clamp(260.0, 520.0);
    final failureCard = EngineFailureCard.visibleFor(status);
    final error = status.phase == RuntimePhase.error;
    // Nothing on this phone yet: no log to show, nothing to reset.
    final missing = status.runtimeMissing;

    return AppPage(
      title: l10n.phoneEngineTitle,
      actions: [
        GlassIconButton(
          icon: AppIcons.webApp,
          tooltip: l10n.commonWeb,
          onPressed: status.phase == RuntimePhase.running && status.token != null
              ? () => _push(context, const LocalWebScreen())
              : null,
        ),
      ],
      hero: PageHero(
        leading: EngineRing(tone: view.tone),
        title: l10n.phoneEngineLocal,
        subtitle: AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.standard),
          layoutBuilder: (current, previous) =>
              Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
          child: Text(
            engineDetail(status),
            key: ValueKey(engineDetail(status)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: error ? TextStyle(color: colors.danger) : null,
          ),
        ),
        // Leading letters keep the figures whole (a bare number would be read
        // as "number + unit").
        stats: [
          (status.dshVersion == null ? '—' : 'v${status.dshVersion}', 'DSH'),
          (status.nodeVersion == null ? '—' : 'v${status.nodeVersion}', 'Node.js'),
        ],
      ),
      slivers: [
        SliverList.list(
          children: [
            // 官方 DSH 的启停由它自己的 App 管理；复用别人的核心也一样（那是它的进程）。
            if (!failureCard && !status.official)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: EngineActions(phase: status.phase),
              ),
            if (!missing) const _EngineSourceSection(),
            if (!missing) const _EngineCapabilitiesSection(),
            const EngineFailureCard(padding: EdgeInsets.fromLTRB(16, 0, 16, 16)),
            const SafeModeCard(padding: EdgeInsets.fromLTRB(16, 0, 16, 16)),
            SettingsSection(
              title: l10n.hubEngineStartup,
              children: [
                SettingsSwitchTile(
                  spot: Spots.autoStart,
                  value: settings.autoStartLocal,
                  onChanged: (v) => unawaited(ref.read(settingsProvider.notifier).setAutoStartLocal(v)),
                ),
                const SafeModeAutoSwitch(icon: null),
                const SafeModeSettingsTiles(showAutoSwitch: false, icon: false),
              ],
            ),
            if (!missing)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: TerminalCard(title: l10n.phoneEngineLogs, lines: state.logs, height: logHeight),
              ),
            // Their home is 设置; the way in from here keeps the name.
            SettingsSection(
              title: l10n.commonMore,
              children: [
                SettingsTile(
                  spot: SettingsIndex.entry(SettingsPageId.background),
                  subtitle: l10n.phoneEngineKeepAliveHint,
                  onTap: () => _push(context, const BackgroundGuidePage()),
                ),
                SettingsTile(
                  spot: SettingsIndex.entry(SettingsPageId.diagnostics),
                  subtitle: l10n.phoneEngineDiagnosticsHint,
                  onTap: () => _push(context, const DiagnosticsPage()),
                ),
              ],
            ),
            if (isMacDesktop && !status.official)
              SettingsSection(
                children: [
                  SettingsTile(
                    icon: AppIcons.phoneStorage,
                    title: AppLocale.isEnglish ? 'Phone link' : '手机连接',
                    subtitle: AppLocale.isEnglish
                        ? 'Use this Mac’s built-in DSH from your phone over SSH'
                        : '用手机 SSH 连这台 Mac 的内置 DSH',
                    onTap: () => _push(context, const PhoneLinkPage()),
                  ),
                ],
              ),
            SettingsSection(
              title: l10n.phoneEngineRuntime,
              children: [
                InfoRow(
                  label: l10n.commonVersion,
                  value: shortRuntimeVersion(status.installedVersion ?? status.bundledVersion),
                  mono: true,
                ),
                InfoRow(label: l10n.phoneEngineArchitecture, value: status.abi ?? '—', mono: true),
              ],
            ),
            if (status.runtimeOutdated) SettingsSection(children: [_RuntimeUpdateRow(status: status)]),
            if (!missing && !status.official && !status.external)
              SettingsSection(
                children: [
                  _ResetRow(enabled: !status.phase.isBusy),
                  LocalUninstallRow(enabled: !status.phase.isBusy),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// 「启动 · 停止 · 重启」: three equal-width capsules. Starting is the one
/// primary action when the engine is down; while it runs all three are quiet.
class EngineActions extends ConsumerWidget {
  const EngineActions({super.key, required this.phase});

  final RuntimePhase phase;

  /// Capsule height.
  static const height = 44.0;
  static const gap = 10.0;

  Future<void> _confirmStop(BuildContext context, WidgetRef ref) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.phoneEngineStopTitle),
        content: Text(context.l10n.phoneEngineStopBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonStop),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(localRuntimeProvider.notifier).stop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final container = ProviderScope.containerOf(context, listen: false);
    if (phase == RuntimePhase.notInstalled) {
      return _Capsule(
        icon: AppIcons.download,
        label: l10n.phoneEngineInstallRuntime,
        primary: true,
        onTap: () => unawaited(openLocalInstall(context)),
      );
    }
    final running = phase == RuntimePhase.running;
    final down = phase == RuntimePhase.installed || phase == RuntimePhase.error;
    return Row(
      children: [
        Expanded(
          child: _Capsule(
            icon: AppIcons.play,
            label: phase == RuntimePhase.error ? l10n.phoneEngineStartAgain : l10n.phoneEngineStart,
            busy: phase == RuntimePhase.starting || phase == RuntimePhase.installing,
            primary: down,
            onTap: down ? () => unawaited(EngineControl.restart(container)) : null,
          ),
        ),
        const SizedBox(width: gap),
        Expanded(
          child: _Capsule(
            icon: AppIcons.stop,
            label: l10n.commonStop,
            busy: phase == RuntimePhase.stopping,
            onTap: running ? () => _confirmStop(context, ref) : null,
          ),
        ),
        const SizedBox(width: gap),
        Expanded(
          child: _Capsule(
            icon: AppIcons.restart,
            label: l10n.phoneEngineRestart,
            onTap: running ? () => unawaited(EngineControl.restart(container)) : null,
          ),
        ),
      ],
    );
  }
}

/// One engine action: a stadium with an icon and a short label. Quiet (a soft
/// neutral fill) unless [primary]; dims when disabled; [busy] swaps the icon
/// for a small ring.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.icon, required this.label, this.onTap, this.primary = false, this.busy = false});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final enabled = onTap != null;
    final bg = primary && enabled
        ? scheme.primary
        : (dark ? Colors.white.withValues(alpha: 0.08) : scheme.onSurface.withValues(alpha: 0.06));
    final fg = primary && enabled ? scheme.onPrimary : scheme.onSurface;
    final duration = AppMotion.of(context, AppMotion.standard);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: enabled || busy ? 1 : 0.42,
        duration: duration,
        child: Material(
          color: Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: AnimatedContainer(
            duration: duration,
            curve: AppMotion.std,
            constraints: const BoxConstraints(minHeight: EngineActions.height),
            decoration: ShapeDecoration(color: bg, shape: const StadiumBorder()),
            child: InkWell(
              onTap: onTap,
              splashFactory: rowSplash(context),
              highlightColor: fg.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox.square(
                      dimension: 20,
                      child: busy
                          ? Padding(
                              padding: const EdgeInsets.all(2.5),
                              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                            )
                          : Icon(icon, size: 20, color: fg),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(color: fg),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Offers the runtime shipped with this app when an older one is installed.
/// The install path keeps `home` and any reset-kept files, so conversations,
/// plugins and settings survive the engine upgrade.
class _RuntimeUpdateRow extends ConsumerStatefulWidget {
  const _RuntimeUpdateRow({required this.status});

  final RuntimeStatus status;

  @override
  ConsumerState<_RuntimeUpdateRow> createState() => _RuntimeUpdateRowState();
}

class _RuntimeUpdateRowState extends ConsumerState<_RuntimeUpdateRow> {
  bool _busy = false;

  Future<void> _update() async {
    final en = AppLocale.isEnglish;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(en ? 'Update bundled engine' : '更新内置引擎'),
        content: Text(
          en
              ? '${widget.status.installedVersion} will be replaced with ${widget.status.bundledVersion} '
                    '(DSH ${AppInfo.bundledEngineVersion}). Conversations, plugins and settings are kept. '
                    'Packages installed inside the old runtime need to be reinstalled.'
              : '${widget.status.installedVersion} 将替换为 ${widget.status.bundledVersion}'
                    '（DSH ${AppInfo.bundledEngineVersion}）。对话、插件和设置会保留；'
                    '旧运行时里手动安装的依赖需要重装。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(en ? 'Cancel' : '取消')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(en ? 'Update' : '更新')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final runtime = ref.read(localRuntimeProvider.notifier);
      await runtime.stop();
      await runtime.install();
      await EngineControl.ensureStarted(container);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(en ? 'Bundled engine updated.' : '内置引擎已更新。')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(en ? 'Engine update failed: $error' : '内置引擎更新失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = AppLocale.isEnglish;
    final status = widget.status;
    return SettingsTile(
      icon: AppIcons.download,
      title: en ? 'Bundled engine update available' : '内置引擎可更新',
      subtitle: '${status.installedVersion} → ${status.bundledVersion} · DSH ${AppInfo.bundledEngineVersion}',
      trailing: _busy || status.phase == RuntimePhase.installing
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
      onTap: _busy || status.phase == RuntimePhase.installing ? null : () => unawaited(_update()),
    );
  }
}

/// 「重置运行环境」: the dialog says what goes and offers to keep the parts
/// the user wrote (界面配置和技能, on by default) or installed (插件和设置).
class _ResetRow extends ConsumerWidget {
  const _ResetRow({required this.enabled});

  final bool enabled;

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final keep = await showAppDialog<ResetKeep>(context: context, builder: (_) => const _ResetDialog());
    if (keep == null || !context.mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(localRuntimeProvider.notifier).resetKeeping(keep);
      // The root gate shows setup again once the phase reads notInstalled.
      navigator.popUntil((r) => r.isFirst);
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.phoneEngineResetFailed)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return SettingsTile(
      icon: AppIcons.clearAll,
      tinted: false,
      danger: enabled,
      spot: Spots.engineReset,
      subtitle: l10n.phoneEngineResetHint,
      chevron: false,
      onTap: enabled ? () => _reset(context, ref) : null,
    );
  }
}

/// What a reset with [keep] deletes, as one phrase: 「对话、工作区、插件和设置」.
@visibleForTesting
String resetDeletes(ResetKeep keep) {
  return switch ((keep.uiAndSkills, keep.pluginsAndSettings)) {
    (true, true) => appL10n.phoneResetDeletesChatsWorkspaces,
    (true, false) => appL10n.phoneResetDeletesWithPlugins,
    (false, true) => appL10n.phoneResetDeletesWithUi,
    (false, false) => appL10n.phoneResetDeletesEverything,
  };
}

/// Pops the chosen [ResetKeep], or null on 取消.
class _ResetDialog extends StatefulWidget {
  const _ResetDialog();

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  ResetKeep _keep = ResetKeep.suggested;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return AlertDialog(
      title: Text(l10n.phoneEngineResetTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(switch ((_keep.uiAndSkills, _keep.pluginsAndSettings)) {
            (true, true) => l10n.phoneResetBodyChatsWorkspaces,
            (true, false) => l10n.phoneResetBodyWithPlugins,
            (false, true) => l10n.phoneResetBodyWithUi,
            (false, false) => l10n.phoneResetBodyEverything,
          }),
          const SizedBox(height: 8),
          Text(l10n.phoneResetAlsoDeletes),
          const SizedBox(height: 12),
          _KeepOption(
            label: l10n.phoneEngineKeepUiSkills,
            value: _keep.uiAndSkills,
            onChanged: (v) => setState(() => _keep = _keep.copyWith(uiAndSkills: v)),
          ),
          _KeepOption(
            label: l10n.phoneEngineKeepPluginsSettings,
            value: _keep.pluginsAndSettings,
            onChanged: (v) => setState(() => _keep = _keep.copyWith(pluginsAndSettings: v)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
          onPressed: () => Navigator.pop(context, _keep),
          child: Text(l10n.phoneEngineDeleteReset),
        ),
      ],
    );
  }
}

/// A whole-row checkbox: the box's edge lines up with the text above it, and
/// it stays neutral so the danger button is the dialog's one colour.
class _KeepOption extends StatelessWidget {
  const _KeepOption({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  static const box = 18.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: AppShape.radiusXs,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              // The box paints centred in its own tap area: lay out just the box.
              SizedBox.square(
                dimension: box,
                child: OverflowBox(
                  maxWidth: kMinInteractiveDimension,
                  maxHeight: kMinInteractiveDimension,
                  child: Checkbox(
                    value: value,
                    onChanged: (v) => onChanged(v ?? false),
                    fillColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected) ? scheme.onSurface : Colors.transparent,
                    ),
                    checkColor: scheme.surface,
                    side: BorderSide(color: colors.textTertiary, width: 1.5),
                    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 引擎来源：App 自带 / 这台设备上已装的 DSH / 正在运行的官方 DSH。
///
/// 复用别人的核心时**没有**我们的补丁，所以在 footer 里明确说明会降级；
/// 起不来时给一个「改用 App 自带的引擎」的出口（[EngineSourceController.revertToOwned]）。
class _EngineSourceSection extends ConsumerStatefulWidget {
  const _EngineSourceSection();

  @override
  ConsumerState<_EngineSourceSection> createState() => _EngineSourceSectionState();
}

class _EngineSourceSectionState extends ConsumerState<_EngineSourceSection> {
  /// 正在安装的版本（null = 空闲）。
  String? _installing;

  Future<void> _install(DshVersionInfo info, String version) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    setState(() => _installing = version);
    try {
      final result = await ref.read(dshNpmProvider).install(
        version,
        onLog: (line) => InstallTrace.add('npm', line),
        keepVersions: {
          // 当前在用的 + 发版绑定的，清理时不能删。
          ?ref.read(engineSourceProvider).activeInstalled?.version,
          ?ref.read(localRuntimeProvider).status.dshVersion,
        },
      );
      ref.invalidate(engineStoreListProvider);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            l10n.engineSourceInstalledDetail(version) +
                (result.lostPatches.isEmpty ? '' : ' · ${l10n.engineSourceDegraded}'),
          ),
        ),
      );
    } catch (error) {
      InstallTrace.error('npm/ui', error);
      messenger?.showSnackBar(SnackBar(content: Text('${l10n.engineSourceNotFound} ($error)')));
    } finally {
      if (mounted) setState(() => _installing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final l10n = context.l10n;
    final state = ref.watch(engineSourceProvider);
    final notifier = ref.read(engineSourceProvider.notifier);
    final installed = state.activeInstalled;
    final official = state.official;
    // 引擎库里已经装好的多个版本：选哪个就是升级/降级（不用重新下载）。
    final store = ref.watch(engineStoreListProvider).value ?? const <DshEngine>[];
    final selectedPrefix = state.source == EngineSource.installed ? installed?.prefix : null;
    final selectedMark = Icon(AppIcons.selected, size: 18, color: Theme.of(context).colorScheme.primary);

    return SettingsSection(
      title: l10n.engineSourceTitle,
      footer: Text(
        state.source == EngineSource.installed ? l10n.engineSourceDegraded : l10n.engineSourceSwitchNote,
      ),
      children: [
        SettingsTile(
          icon: AppIcons.engine,
          title: l10n.engineSourceOwned,
          subtitle: l10n.engineSourceOwnedDetail,
          trailing: state.source == EngineSource.owned ? selectedMark : null,
          onTap: () => unawaited(notifier.select(EngineSource.owned)),
        ),
        if (state.scanning)
          SettingsTile(
            icon: AppIcons.thisPhone,
            title: l10n.engineSourceInstalled,
            subtitle: l10n.engineSourceScanning,
          )
        else if (installed != null)
          SettingsTile(
            icon: AppIcons.thisPhone,
            title: l10n.engineSourceInstalled,
            subtitle: l10n.engineSourceInstalledDetail(installed.version),
            trailing: state.source == EngineSource.installed ? selectedMark : null,
            onTap: () => unawaited(notifier.select(EngineSource.installed, prefix: installed.prefix)),
          )
        else
          SettingsTile(
            icon: AppIcons.thisPhone,
            title: l10n.engineSourceInstalled,
            subtitle: l10n.engineSourceNotFound,
            onTap: () => unawaited(notifier.refresh()),
          ),
        if (official case final running?)
          SettingsTile(
            icon: AppIcons.computer,
            title: l10n.engineSourceOfficial,
            subtitle: l10n.engineSourceOfficialDetail(running.port),
            trailing: state.source == EngineSource.official ? selectedMark : null,
            onTap: () => unawaited(notifier.select(EngineSource.official)),
          ),
        for (final engine in store)
          SettingsTile(
            icon: AppIcons.engine,
            title: 'DSH ${engine.version}',
            subtitle: engine.patched
                ? '${engine.source} · 补丁 ${engine.patchesOk}/${engine.patchesTotal}'
                : '${engine.source} · 官方原样',
            trailing: engine.path == selectedPrefix ? selectedMark : null,
            onTap: () => unawaited(notifier.selectEngine(engine)),
          ),
        if (state.source != EngineSource.owned)
          SettingsTile(
            icon: AppIcons.back,
            title: l10n.engineSourceRevert,
            onTap: () => unawaited(notifier.revertToOwned()),
          ),
        _updateTile(context, ref),
        _pruneTile(context, ref),
        _importTile(context, ref),
        SettingsSwitchTile(
          icon: AppIcons.workspace,
          value: state.sharedHome,
          title: l10n.engineSharedHomeTitle,
          subtitle: l10n.engineSharedHomeHint,
          onChanged: (value) => unawaited(notifier.setSharedHome(value)),
        ),
        _pluginListTile(context, ref),
        _accountTile(context, ref),
      ],
    );
  }

  /// 「从官方 DSH 导入」：App 自带引擎与官方 DSH 用两套数据目录，这里把对话与工作区搬过来。
  Widget _importTile(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(localRuntimeProvider).status;
    // 只在用 App 自带引擎、且官方那份真的有会话时才出现。
    if (status.external || status.official) return const SizedBox.shrink();
    final official = DshImport.officialHome();
    final workspaces = ref.watch(officialDshWorkspacesProvider).value ?? 0;
    if (workspaces == 0) return const SizedBox.shrink();
    return SettingsTile(
      icon: AppIcons.download,
      title: l10n.engineImportTitle,
      subtitle: l10n.engineImportHint(workspaces),
      onTap: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        final target = Directory('${ref.read(appSupportDirProvider).path}${Platform.pathSeparator}'
            'runtime${Platform.pathSeparator}home${Platform.pathSeparator}.dsh');
        try {
          final result = await DshImport.importFrom(source: official, target: target);
          ref.invalidate(officialDshWorkspacesProvider);
          // 会话列表读的是 host 的数据，导入后让它重新拉一次。
          ref.invalidate(sessionsProvider);
          messenger?.showSnackBar(
            SnackBar(
              content: Text(
                result.files == 0
                    ? l10n.engineImportNothing
                    : l10n.engineImportDone(result.files, result.megabytes),
              ),
            ),
          );
        } catch (error) {
          InstallTrace.error('import/ui', error);
          messenger?.showSnackBar(SnackBar(content: Text(l10n.engineImportFailed('$error'))));
        }
      },
    );
  }

  /// 官方 DSH 的插件清单：只做提示，不安装（版本依赖不同，直接搬会把引擎带崩）。
  Widget _pluginListTile(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final plugins = ref.watch(officialPluginListProvider).value ?? const <String>[];
    if (plugins.isEmpty) return const SizedBox.shrink();
    return SettingsTile(
      icon: AppIcons.pluginInventory,
      title: l10n.enginePluginListTitle,
      subtitle: l10n.enginePluginListHint(plugins.length, plugins.join('、')),
      // 点进去就是插件页，可以搜索并安装（比如 dsh-oh-my-claude）。
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const PluginsScreen()),
      ),
    );
  }

  /// 可选：同步 DeepSeek 账号登录态（账号凭据记录）。默认不同步，点之前会确认。
  Widget _accountTile(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = ref.watch(localRuntimeProvider).status;
    if (status.official) return const SizedBox.shrink();
    return SettingsTile(
      icon: AppIcons.account,
      title: l10n.engineImportAccountTitle,
      subtitle: l10n.engineImportAccountHint,
      onTap: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        final target = Directory('${ref.read(appSupportDirProvider).path}${Platform.pathSeparator}'
            'runtime${Platform.pathSeparator}home${Platform.pathSeparator}.dsh');
        try {
          final count = await DshImport.importAccount(
            source: DshImport.officialHome(),
            target: target,
          );
          messenger?.showSnackBar(
            SnackBar(
              content: Text(
                count == 0 ? l10n.engineImportAccountNothing : l10n.engineImportAccountDone(count),
              ),
            ),
          );
        } catch (error) {
          InstallTrace.error('import/ui', error);
          messenger?.showSnackBar(SnackBar(content: Text(l10n.engineImportFailed('$error'))));
        }
      },
    );
  }

  /// 「清理旧版本」：保留当前使用 + 发版绑定 + 最新一个，其余删除并显示释放的空间。
  Widget _pruneTile(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final store = ref.watch(engineStoreListProvider).value ?? const <DshEngine>[];
    if (store.length < 2) return const SizedBox.shrink();
    return SettingsTile(
      icon: AppIcons.delete,
      title: l10n.engineStorePruneTitle,
      subtitle: l10n.engineStorePruneDetail(2),
      onTap: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        final state = ref.read(engineSourceProvider);
        final bundled = ref.read(localRuntimeProvider).status.dshVersion;
        final freed = await ref.read(engineStoreProvider).prune(
          keep: {
            ?state.activeInstalled?.version,
            ?bundled,
          },
        );
        ref.invalidate(engineStoreListProvider);
        messenger?.showSnackBar(
          SnackBar(content: Text(l10n.engineStoreFreed((freed / 1048576).round()))),
        );
      },
    );
  }

  /// 「检查更新 / 安装新版本」：查 registry 的 dist-tags，比库里的版本新就给一行。
  Widget _updateTile(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final info = ref.watch(availableDshVersionsProvider);
    final store = ref.watch(engineStoreListProvider).value ?? const <DshEngine>[];
    final installedNewest = store.isEmpty ? null : store.first.version;
    return info.when(
      loading: () => SettingsTile(
        icon: AppIcons.download,
        title: l10n.engineSourceTitle,
        subtitle: l10n.engineSourceScanning,
      ),
      error: (error, _) => SettingsTile(
        icon: AppIcons.download,
        title: l10n.engineSourceTitle,
        subtitle: '$error',
        onTap: () => ref.invalidate(availableDshVersionsProvider),
      ),
      data: (versions) {
        final latest = versions.latest;
        if (latest == null) return const SizedBox.shrink();
        final newer = installedNewest == null || compareVersions(latest, installedNewest) > 0;
        if (_installing != null) {
          return SettingsTile(
            icon: AppIcons.download,
            title: 'DSH $_installing',
            subtitle: l10n.engineSourceScanning,
          );
        }
        if (!newer) {
          return SettingsTile(
            icon: AppIcons.download,
            title: l10n.engineSourceTitle,
            subtitle: 'v$installedNewest',
            onTap: () => ref.invalidate(availableDshVersionsProvider),
          );
        }
        return SettingsTile(
          icon: AppIcons.download,
          title: l10n.engineSourceUseInstalled,
          subtitle: 'v$latest',
          onTap: () => unawaited(_install(versions, latest)),
        );
      },
    );
  }
}

/// 「补丁带来的功能」：缺哪些就列哪些，让用户知道哪些操作在当前引擎上不可用。
class _EngineCapabilitiesSection extends ConsumerWidget {
  const _EngineCapabilitiesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final capabilities = ref.watch(engineCapabilitiesProvider);
    final missing = capabilities.missing;
    if (capabilities.complete) {
      return SettingsSection(
        title: l10n.engineCapabilitySection,
        children: [
          SettingsTile(icon: AppIcons.completed, title: l10n.engineCapabilityAllOk),
        ],
      );
    }
    return SettingsSection(
      title: l10n.engineCapabilitySection,
      footer: Text(l10n.engineSourceDegraded),
      children: [
        SettingsTile(
          icon: AppIcons.warning,
          title: l10n.engineCapabilityLost(missing.length),
          subtitle: missing.map((c) => c.label(l10n)).join(' · '),
        ),
      ],
    );
  }
}
