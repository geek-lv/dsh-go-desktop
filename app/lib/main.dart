import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'desktop/install_trace.dart';
import 'dev/frame_probe.dart';
import 'diagnostics/app_error_log.dart';
import 'launch/launch_state.dart';
import 'macos/mac_runtime.dart';
import 'macos/menu_bar.dart';
import 'macos/macos_support.dart';
import 'macos/official_dsh.dart';
import 'runtime/dsh_engines.dart';
import 'runtime/engine_source.dart';
import 'performance/performance_state.dart';
import 'runtime/runtime_state.dart';
import 'state/locale_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/theme/theme.dart';

Future<void> main() => runWithFrameProbe(_startApp);

Future<void> _startApp() async {
  if (!frameProbeEnabled) SteadyFrameBinding();
  WidgetsFlutterBinding.ensureInitialized();
  // 第一时间打开落盘追踪：Windows 的 GUI 进程没有控制台，装不上时这是唯一现场。
  await InstallTrace.open('app/first-run');
  appErrorCapture.install();
  // The first frame is already in the chosen language (设置 → 语言), and is the launch
  // window's own picture (启动画面, lib/launch/launch_state.dart).
  await Future.wait([AppLanguageController.load(), LaunchController.begin()]);
  // MIT / OFL notices must ship with the APK, not just the sources.
  registerThirdPartyLicenses();
  registerFontLicenses();
  // Edge-to-edge with transparent system bars; pages refine the icon brightness
  // through AnnotatedRegion(dshSystemOverlay(...)).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(dshSystemOverlay(PlatformDispatcher.instance.platformBrightness));
  // macOS: 窗口版式。原生缺席时立刻返回。
  await startMacSupport();
  // 本机引擎的服务目录在 macOS 上是原生 Node 实现；Android 保持 Kotlin 原样。
  // 「使用官方 DSH」的开关在启动时读一次（切换时由设置页调用 setOfficial）。
  final macRuntime = await createDesktopRuntime();
  final container = await buildAppContainer(macRuntime: macRuntime);
  // 引擎来源（App 自带 / 这台设备上已装的 DSH / 官方 DSH）必须在首帧决定引导
  // 步骤之前应用：复用已装核心时本来就不需要安装那一步。
  try {
    await container.read(engineSourceProvider.notifier).restore();
  } catch (error, stack) {
    InstallTrace.error('engine-source', error, stack);
  }
  if (isMacDesktop) MacMenuBar(container).start();
  runApp(UncontrolledProviderScope(container: container, child: const DshApp()));
}

/// 本机引擎的桥；Android 上返回 null（继续用 Kotlin 的 `dsh/runtime` 通道）。
///
/// 桌面三端都必须返回 [MacRuntimeBridge]：Windows / Linux 没有 Kotlin 那一侧，
/// `dsh/runtime` 通道没有接收方，`invokeMethod` 会抛 `MissingPluginException`，
/// 表现就是界面上一句「安装未完成」、日志一片空白。
Future<MacRuntimeBridge?> createDesktopRuntime() async {
  if (!isDesktop) {
    InstallTrace.add('bridge', 'no desktop runtime: platform=${Platform.operatingSystem} isDesktop=false');
    return null;
  }
  var officialDsh = false;
  try {
    officialDsh = (await SharedPreferences.getInstance()).getBool(macOfficialDshPref) ?? false;
  } catch (error, stack) {
    InstallTrace.error('bridge', error, stack);
  }
  final runtime = MacRuntimeBridge(official: officialDsh);
  InstallTrace.add('bridge', 'using MacRuntimeBridge (platform=${Platform.operatingSystem}, official=$officialDsh)');
  // 关窗/退出时先停引擎，别留下孤儿 Node 进程占着端口。
  // 监听器由 WidgetsBinding 持有，不需要另外保存。
  AppLifecycleListener(
    onExitRequested: () async {
      InstallTrace.add('lifecycle', 'exit requested: stopping engine');
      await runtime.stop();
      await InstallTrace.flush();
      return AppExitResponse.exit;
    },
  );
  return runtime;
}

/// App 的 provider 容器。`lib/dev/desktop_install_probe.dart` 也用它，
/// 这样探针跑的桥与界面**完全同一条**（上一版探针自己 `ProviderContainer()`，
/// 拿到的是默认的 Kotlin 通道桥，测的根本不是界面那条路）。
Future<ProviderContainer> buildAppContainer({MacRuntimeBridge? macRuntime}) async {
  // 引擎库放在 App 自己的支持目录里：一台设备上可以并存多个核心版本。
  final support = await getApplicationSupportDirectory();
  final engineStore = DshEngineStore(
    Directory('${support.path}${Platform.pathSeparator}engines'),
  );
  InstallTrace.add('engines', 'store at ${engineStore.root.path}');
  final container = ProviderContainer(
    overrides: [
      engineStoreProvider.overrideWithValue(engineStore),
      appSupportDirProvider.overrideWithValue(support),
      if (macRuntime != null) runtimeBridgeProvider.overrideWithValue(macRuntime),
      if (macRuntime != null) macRuntimeBridgeProvider.overrideWithValue(macRuntime),
      // Mac 是桌面性能档：别因为拿不到手机的性能快照就把默认判成「轻量」，
      // 那会关掉自动启动和桌宠。
      if (isDesktop)
        performanceDefaultsProvider.overrideWith((ref) {
          final prefs = ref.watch(performancePrefsProvider);
          return PerformanceDefaults(
            lightweight: false,
            blur: prefs.blur ?? true,
            reduceMotion: !(prefs.animations ?? true),
            fluidMotion: !(prefs.animations ?? true) ? false : (prefs.fluid ?? true),
            petEnabled: true,
            autoStartLocal: true,
            recommendRemote: false,
          );
        }),
    ],
  );
  InstallTrace.add(
    'container',
    'runtimeBridgeProvider=${macRuntime == null ? 'DEFAULT RuntimeBridge (MethodChannel dsh/runtime)' : macRuntime.runtimeType}',
  );
  return container;
}
