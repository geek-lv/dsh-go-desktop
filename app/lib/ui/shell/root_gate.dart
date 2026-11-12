import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../desktop/install_trace.dart';
import '../../launch/launch_state.dart';
import '../../macos/mac_localizations.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/dsh_discovery.dart';
import '../../runtime/engine_source.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../share_code/guest_fs.dart';
import '../../state/engine_control.dart';
import '../../state/hosts_state.dart';
import '../../state/notify_state.dart';
import '../../state/onboarding_state.dart';
import '../../state/settings_state.dart';
import '../../ui_config/ui_skill.dart';
import '../onboarding/onboarding_flow.dart';
import '../onboarding/setup_progress.dart';
import '../remote/remote_screen.dart';
import '../theme/theme.dart';
import '../web/mode_home.dart';
import 'brand_mark.dart';
import 'usage_upgrade_notice.dart';

/// Where a launch should start, given what is installed and configured.
///
/// - First run on this phone, set up while the runtime unpacked
///   ([OnboardingPrefs.setupStep]) and not over yet → back to that page; the
///   connection page only while nothing is connected, the waiting page only
///   while the runtime is not there.
/// - Runtime mid-install → setup, which carries on.
/// - The app runs without the runtime ([OnboardingPrefs.localDeclined]: a
///   remote host instead, or uninstalled) → home.
/// - Runtime outdated → setup, which upgrades it.
/// - Runtime missing → setup, which first asks 本机 or 远程主机 (welcome
///   first on a truly fresh install).
/// - Runtime ready but nothing to talk to (no DeepSeek key, no custom provider
///   on the local engine), and the user never chose "稍后设置" → key entry.
/// - Otherwise → home (`null`).
OnboardingStep? initialOnboardingStep({
  required RuntimeStatus status,
  required bool hasApiKey,
  required OnboardingPrefs prefs,
  bool hasCustomProvider = false,
}) {
  // 已经在用「本机官方 DSH」：不需要装内置运行时，也不需要再填 Key。
  InstallTrace.add(
    'onboarding',
    'decide step: official=${status.official} phase=${status.phase.name} '
        'installed=${status.installedVersion ?? '-'} bundled=${status.bundledVersion ?? '-'} '
        'hasApiKey=$hasApiKey welcomeSeen=${prefs.welcomeSeen} setupStep=${prefs.setupStep?.name ?? '-'} '
        'localDeclined=${prefs.localDeclined} keySkipped=${prefs.keySkipped}',
  );
  if (status.official) return prefs.welcomeSeen ? null : OnboardingStep.welcome;
  final installedCurrent = status.installedVersion != null && status.installedVersion == status.bundledVersion;
  final needsRuntime = switch (status.phase) {
    RuntimePhase.notInstalled || RuntimePhase.installing => true,
    RuntimePhase.error => !installedCurrent,
    _ => false,
  };
  // Only a first install (nothing older to upgrade) that was not given up for
  // a remote host.
  if (prefs.setupStep case final resume?
      when !prefs.localDeclined && (installedCurrent || status.installedVersion == null)) {
    final connected = hasApiKey || hasCustomProvider || prefs.keySkipped;
    return switch (resume) {
      SetupStep.appearance => OnboardingStep.appearance,
      SetupStep.access => OnboardingStep.access,
      SetupStep.connect when !connected => OnboardingStep.apiKey,
      _ => needsRuntime ? OnboardingStep.finishing : null,
    };
  }
  if (needsRuntime) {
    // An install that was running when the app went away carries on.
    if (status.phase == RuntimePhase.installing) return OnboardingStep.runtime;
    // Runs without it (also after leaving a failed upgrade for a remote host).
    if (prefs.localDeclined) return null;
    // An upgrade (an older rootfs exists) skips the welcome and the choice.
    if (!runtimeStepAsks(status)) return OnboardingStep.runtime;
    return prefs.welcomeSeen ? OnboardingStep.runtime : OnboardingStep.welcome;
  }
  if (!hasApiKey && !hasCustomProvider && !prefs.keySkipped) return OnboardingStep.apiKey;
  return null;
}

/// Whether the setup step asks 本机 or 远程主机 first: nothing to upgrade and
/// no install underway.
bool runtimeStepAsks(RuntimeStatus status) =>
    status.installedVersion == null && status.phase != RuntimePhase.installing;

/// App root: waits for settings and the native runtime to report in, then shows
/// onboarding or the home shell, and auto-starts the local engine once per launch
/// (设置 › 引擎 › 打开 App 时自动启动).
class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key, this.home});

  /// Stands in for [ModeHome] (tests).
  @visibleForTesting
  final Widget? home;

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate> {
  bool _decided = false;
  bool _launchReady = false;
  OnboardingStep? _step;
  bool _autoStartDone = false;

  /// The setup step asks 本机 or 远程主机 first ([runtimeStepAsks]).
  bool _chooseRuntime = false;

  /// The host list is open over the setup step.
  bool _pickingRemote = false;

  /// First run on this phone, setting up while the runtime unpacks
  /// (docs/design/onboarding-parallel-setup.md).
  bool _beside = false;

  /// The engine was asked to start for it, once.
  bool _besideEngine = false;

  ProviderContainer get _container => ProviderScope.containerOf(context, listen: false);

  void _goTo(OnboardingStep? step) {
    if (!mounted) return;
    setState(() => _step = step);
  }

  void _afterRuntime() {
    // Boot DSH in the background while the user deals with the key.
    _autoStartDone = true;
    unawaited(EngineControl.ensureStarted(_container));
    final settings = ref.read(settingsProvider);
    final prefs = ref.read(onboardingPrefsProvider);
    final official = ref.read(localRuntimeProvider).status.official;
    _goTo(settings.hasModelAccess || prefs.keySkipped || official ? null : OnboardingStep.apiKey);
  }

  void _afterKey() {
    if (_beside) return _finishBeside();
    _autoStartDone = true;
    unawaited(EngineControl.ensureStarted(_container));
    _goTo(null);
  }

  // ── Set up beside the unpack ──

  OnboardingPrefsController get _prefs => ref.read(onboardingPrefsProvider.notifier);

  /// The unpack, through the one entry (a second request is the first one).
  void _startUnpack() {
    // Time left is estimated from the first progress report on.
    InstallTrace.add('onboarding', '_startUnpack: runtimeInstallProvider.install()');
    ref.read(installEtaProvider);
    unawaited(ref.read(runtimeInstallProvider.notifier).install());
    // Android 13 asks about notifications once the channels exist: now, as the
    // unpack (and its notification) starts, not over a later step.
    unawaited(ref.read(notifyChannelProvider).status().then<void>((_) {}, onError: (_) {}));
  }

  /// The engine for the sign-in (and a custom provider's save), as soon as
  /// the runtime is there.
  void _startEngineBeside() {
    if (_besideEngine) return;
    _besideEngine = true;
    _autoStartDone = true;
    unawaited(EngineControl.ensureStarted(_container));
  }

  /// 「用这台设备上已装的 DSH」：不下载、不解压，直接把引擎来源切过去，然后当作
  /// 运行时已经就绪继续引导（会话与插件都来自用户自己的 `~/.dsh`）。
  Future<void> _useInstalled(DiscoveredDsh core) async {
    InstallTrace.add('onboarding', 'runtime choice: 复用已安装核心 ${core.version} @ ${core.prefix}');
    await ref.read(engineSourceProvider.notifier).select(EngineSource.installed, prefix: core.prefix);
    if (!mounted) return;
    _afterRuntime();
  }

  /// 「本机」: unpack in the background, set up meanwhile.
  void _chooseLocal() {
    InstallTrace.add('onboarding', 'runtime choice: 本机 → start unpack beside setup');
    _beside = true;
    unawaited(_prefs.setSetupStep(SetupStep.appearance));
    _startUnpack();
    _goTo(OnboardingStep.appearance);
  }

  void _afterAppearance() {
    // 「权限申请」这一步是 Android 专属流程（存储 / 无障碍 / 电池优化 / 通知）。
    // 桌面端（Windows / Linux）没有运行时权限概念：文件、通知、屏幕都不需要
    // 用户在系统设置里单独开启，因此整步跳过，直接走「连接模型」。
    // macOS 保留这一步——它的辅助功能 / 屏幕录制仍需要用户授权。
    InstallTrace.add('onboarding', '_afterAppearance: skipPermissions=$isDesktopWithoutRuntimePermissions');
    if (isDesktopWithoutRuntimePermissions) {
      _afterAccess();
      return;
    }
    unawaited(_prefs.setSetupStep(SetupStep.access));
    _goTo(OnboardingStep.access);
  }

  void _afterAccess() {
    final connected = ref.read(settingsProvider).hasModelAccess || ref.read(onboardingPrefsProvider).keySkipped;
    if (connected) return _finishBeside();
    unawaited(_prefs.setSetupStep(SetupStep.connect));
    _goTo(OnboardingStep.apiKey);
  }

  /// Everything set: home if the runtime is there, else wait for it.
  void _finishBeside() {
    final setupRuntime = ref.read(setupRuntimeProvider);
    InstallTrace.add('onboarding', '_finishBeside: setupRuntime=${setupRuntime.name}');
    if (ref.read(setupRuntimeProvider) != SetupRuntime.ready) {
      unawaited(_prefs.setSetupStep(SetupStep.finishing));
      _goTo(OnboardingStep.finishing);
      return;
    }
    _startEngineBeside();
    _leaveBeside();
    _goTo(null);
  }

  /// The unpack the waiting page showed is done.
  void _afterFinishing() {
    _startEngineBeside();
    _leaveBeside();
    final settings = ref.read(settingsProvider);
    final prefs = ref.read(onboardingPrefsProvider);
    final official = ref.read(localRuntimeProvider).status.official;
    _goTo(settings.hasModelAccess || prefs.keySkipped || official ? null : OnboardingStep.apiKey);
  }

  void _leaveBeside() {
    _beside = false;
    unawaited(_prefs.setSetupStep(null));
  }

  /// 「远程主机」: the host list over the setup step. Picking a host there
  /// (it closes itself) finishes first run without the runtime; coming back
  /// without one returns to the choice.
  Future<void> _useRemote() async {
    if (_pickingRemote) return;
    _pickingRemote = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen()));
    } finally {
      _pickingRemote = false;
    }
    if (!mounted || ref.read(activeHostProvider).isLocal) return;
    if (_beside) _leaveBeside();
    await ref.read(onboardingPrefsProvider.notifier).setLocalDeclined(true);
    // What installing does on the other path: Android 13 asks about
    // notifications once the channels exist, before the first reply lands.
    unawaited(ref.read(notifyChannelProvider).status().then<void>((_) {}, onError: (_) {}));
    _autoStartDone = true;
    _goTo(null);
  }

  void _maybeAutoStart() {
    if (_autoStartDone) return;
    // 首帧时运行时的第一份状态可能还没到：等 loaded 再决定，别把这个机会丢掉。
    if (!ref.read(localRuntimeProvider).loaded) return;
    _autoStartDone = true;
    final settings = ref.read(settingsProvider);
    if (!settings.autoStartLocal) return;
    final status = ref.read(localRuntimeProvider).status;
    // After repeated crashes with automatic safe mode off, the failure card
    // waits for the user instead of starting again.
    if (status.phase == RuntimePhase.installed && EngineControl.shouldAutoStart(status)) {
      unawaited(ref.read(localRuntimeProvider.notifier).start());
    }
  }

  /// Back to first run's set-up-beside-the-unpack after the app went away:
  /// an unpack that died with the process starts again (from scratch, as
  /// Android always does); one that is done gets the engine going.
  void _resumeBeside(SetupStep? saved, RuntimeStatus status) {
    if (saved == null) return;
    _beside = switch (_step) {
      OnboardingStep.appearance || OnboardingStep.access || OnboardingStep.apiKey || OnboardingStep.finishing => true,
      _ => false,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // First run is over (finished while away, or a remote host instead).
      if (!_beside) return unawaited(_prefs.setSetupStep(null));
      switch (setupRuntimeOf(status)) {
        case SetupRuntime.absent:
          _startUnpack();
        case SetupRuntime.ready when _step != OnboardingStep.finishing:
          _startEngineBeside();
        case _:
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final runtime = ref.watch(localRuntimeProvider);
    final prefs = ref.watch(onboardingPrefsProvider);
    // The last host comes back while the splash shows, so a phone without
    // the runtime doesn't open on 本机 for a frame before its remote host.
    ref.read(activeHostProvider);

    // "重置运行环境" sends the user back through setup; 「卸载运行环境」
    // (localDeclined) stays home.
    ref.listen(localRuntimeProvider.select((s) => s.status.phase), (prev, next) {
      if (_decided &&
          _step == null &&
          next == RuntimePhase.notInstalled &&
          prev != RuntimePhase.notInstalled &&
          !ref.read(onboardingPrefsProvider).localDeclined) {
        _chooseRuntime = false;
        _goTo(OnboardingStep.runtime);
      }
    });
    // Setting up beside the unpack: the engine starts the moment the runtime
    // is there (the waiting page goes on by itself and starts it then).
    ref.listen(setupRuntimeProvider, (prev, next) {
      if (_beside && next == SetupRuntime.ready && prev != SetupRuntime.ready && _step != OnboardingStep.finishing) {
        _startEngineBeside();
      }
    });
    // Each start of the on-device engine writes the bundled skills (dsh-go-ui,
    // dsh-go-plugin) into its skills folder, while they are still the app's.
    ref.listen(uiSkillAutoInstallProvider, (_, _) {});
    // The rootfs came or went: files read straight from it look again.
    ref.listen(localRuntimeProvider.select((s) => s.status.installedVersion), (prev, next) {
      if (prev != next) ref.invalidate(guestFsProvider);
    });

    final Widget child;
    // 引擎来源（自有 / 复用已装核心 / 官方）没应用完就别往下走：自动启动会用错引擎。
    final engineSourceReady = ref.watch(engineSourceProvider).loaded;
    if (!settings.loaded || !runtime.loaded || !prefs.loaded || !engineSourceReady) {
      child = const _Splash();
    } else {
      if (!_decided) {
        _decided = true;
        _step = initialOnboardingStep(
          status: runtime.status,
          hasApiKey: settings.hasApiKey,
          hasCustomProvider: settings.customProviderIds.isNotEmpty,
          prefs: prefs,
        );
        _chooseRuntime = runtimeStepAsks(runtime.status);
        // The choice shows what installing costs: read it before it opens.
        if (_chooseRuntime && _step != null) ref.read(localFootprintProvider);
        _resumeBeside(prefs.setupStep, runtime.status);
      }
      if (_step case final step?) {
        child = OnboardingFlow(
          step: step,
          chooseRuntime: _chooseRuntime,
          beside: _beside,
          onLocal: _chooseRuntime ? _chooseLocal : null,
          onAppearanceDone: _afterAppearance,
          onAccessDone: _afterAccess,
          onFinished: _afterFinishing,
          onRemote: _useRemote,
          onInstalled: _useInstalled,
          onWelcomeDone: () {
            unawaited(ref.read(onboardingPrefsProvider.notifier).markWelcomeSeen());
            _chooseRuntime = runtimeStepAsks(ref.read(localRuntimeProvider).status);
            _goTo(OnboardingStep.runtime);
          },
          onRuntimeDone: _afterRuntime,
          onKeyDone: _afterKey,
        );
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybeAutoStart();
        });
        // The native shell or the web page, by 界面 (ui_mode_state.dart); an
        // install from before usage statistics is told about them there, once.
        child = UsageUpgradeNotice(child: widget.home ?? const ModeHome());
      }
    }
    if (child is! _Splash && !_launchReady) {
      // 启动画面: the first page is up. A warm start's launch screen goes now; a cold start of
      // this phone's engine finishes its motion first (or goes when the engine is up).
      _launchReady = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => LaunchController.active.value?.ready(waitsForEngine: ref.read(activeHostProvider).isLocal),
      );
    }
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.page),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      child: KeyedSubtree(
        key: ValueKey(child is _Splash ? 'splash' : (_step == null ? 'home' : 'onboarding')),
        child: child,
      ),
    );
  }
}

/// Shown for the few hundred ms before settings and runtime status arrive. Same
/// colour as the Android launch window; the mark fades in only if loading is slow.
class _Splash extends StatefulWidget {
  const _Splash();

  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> {
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(Theme.of(context).brightness),
      child: AppBackdrop(
        child: Center(
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: AppMotion.of(context, AppMotion.slow),
            child: const BrandMark(size: 64, tile: true),
          ),
        ),
      ),
    );
  }
}
