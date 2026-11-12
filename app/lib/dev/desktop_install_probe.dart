// ignore_for_file: avoid_print
// 桌面端「安装 → 启动」的探针：走与界面**完全同一条** provider 链路。
//
//   flutter build windows --debug -t lib/dev/desktop_install_probe.dart
//   build/windows/x64/runner/Debug/dsh_app.exe
//
// 上一版探针自己 `ProviderContainer()`，没有 main.dart 里那几个 override，
// 于是拿到的桥是默认的 Kotlin 通道实现（`MethodChannel('dsh/runtime')`）——
// Windows 上根本没有接收方，`install()` 抛 MissingPluginException 又被
// `catch (_)` 吃掉，于是「install() returned normally 但没装上」这个结论
// 说的是探针自己的错桥，不是界面的那条路。
//
// 现在容器由 `buildAppContainer()` 搭（跟 main.dart 同一个函数），第一行就打印
// 实际用的是哪个桥；全过程同时落盘到 InstallTrace 的文件里。
//
// 最后一行：PROBE OK（装好且能启动）/ PROBE FAIL（附原因）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;

import '../desktop/install_trace.dart';
import '../main.dart' show buildAppContainer, createDesktopRuntime;
import '../runtime/dsh_discovery.dart';
import '../runtime/dsh_capabilities.dart';
import '../runtime/dsh_engines.dart';
import '../runtime/dsh_import.dart';
import '../runtime/engine_source.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import '../ui/onboarding/setup_progress.dart' show runtimeInstallProvider;

/// 是否顺带验证「安装 → 启动引擎 → 停止」。启动要下载/生成配置，慢一些。
const bool startEngineToo = true;

/// `dsh_app.exe default-bridge`：用**修复前**的容器（不覆盖
/// `runtimeBridgeProvider`，因此落到 Kotlin 通道桥）跑 install，把那个
/// 「install() 正常返回但没装上」的现场记进追踪文件。诊断是否到位就看这一段。
Future<void> main(List<String> args) async {
  // 探针里任何未捕获异常都必须退出进程：否则窗口会一直挂着，看起来像"还在跑"。
  await runZonedGuarded(
    () => _main(args),
    (error, stack) {
      InstallTrace.error('probe', error, stack);
      stderr.writeln('PROBE CRASH: $error');
      exit(2);
    },
  );
}

Future<void> _main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await InstallTrace.open('probe/desktop-install');
  InstallTrace.add('probe', 'platform=${Platform.operatingSystem} exe=${Platform.resolvedExecutable} args=$args');
  print('PROBE trace file: ${InstallTrace.file}');

  if (args.contains('default-bridge')) {
    await _reproduceDefaultBridge();
    await InstallTrace.flush();
    return;
  }

  // `--external <npm 前缀>`：不复用 App 自有运行时，直接拿这台设备上已安装的
  // DSH 核心启动（只读）。`--node <path>` 可指定用哪个 node 跑它。
  final externalIndex = args.indexOf('--external');
  final externalPrefix = externalIndex >= 0 && externalIndex + 1 < args.length ? args[externalIndex + 1] : null;
  final nodeIndex = args.indexOf('--node');
  final nodeOverride = nodeIndex >= 0 && nodeIndex + 1 < args.length ? args[nodeIndex + 1] : null;
  // `--import <前缀>`：把探测到的核心复制进引擎库，再从库里启动（验证库/切换路径）。
  final importIndex = args.indexOf('--import');
  final importPrefix = importIndex >= 0 && importIndex + 1 < args.length ? args[importIndex + 1] : null;
  // `--engine-source`：验证「持久化的引擎来源 → 能力矩阵 → 真正启动」这条链路
  // （不点界面，用 prefs 里记的来源）。
  final checkSource = args.contains('--engine-source');
  // `--import-official`：把官方 ~/.dsh 的对话/工作区/模型 provider 同步到 App 自带引擎。
  final importOfficial = args.contains('--import-official');
  // `--npm-install <version>`：走完整链路——npm 下载安装到引擎库 → 打补丁 → 从库里启动。
  final npmIndex = args.indexOf('--npm-install');
  final npmVersion = npmIndex >= 0 && npmIndex + 1 < args.length ? args[npmIndex + 1] : null;

  final runtime = await createDesktopRuntime();
  DiscoveredDsh? external;
  if (externalPrefix != null) {
    final candidate = await DshDiscovery.probePrefix(externalPrefix, source: 'user');
    print('PROBE external candidate: usable=${candidate.usable} reason=${candidate.reason ?? '-'}');
    InstallTrace.add('probe', 'external candidate ${candidate.toJson()}');
    external = candidate.dsh;
    if (external == null) {
      print('PROBE FAIL: 这个前缀里没有可用的 DSH（${candidate.reason}）');
      await InstallTrace.flush();
      exit(1);
    }
    if (nodeOverride != null) {
      external = DiscoveredDsh(
        prefix: external.prefix,
        dshDir: external.dshDir,
        version: external.version,
        source: external.source,
        nodePath: nodeOverride,
      );
    }
  }
  final container = await buildAppContainer(macRuntime: runtime);
  final bridge = container.read(runtimeBridgeProvider);
  print('PROBE bridge: ${bridge.runtimeType}');
  print('PROBE trace file: ${InstallTrace.file}');
  InstallTrace.add('probe', 'bridge=${bridge.runtimeType} notifier=${container.read(localRuntimeProvider.notifier).runtimeType}');

  final before = container.read(localRuntimeProvider).status;
  print('PROBE before: ${_describe(before)}');
  InstallTrace.add('probe', 'before: ${_describe(before)}');

  if (importOfficial) {
    final support = container.read(appSupportDirProvider);
    final target = Directory('${support.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}home'
        '${Platform.pathSeparator}.dsh');
    final result = await DshImport.importFrom(source: DshImport.officialHome(), target: target);
    print('PROBE import: files=${result.files} skipped=${result.skipped} '
        'workspaces=${result.sessionWorkspaces} providers=${result.providers} mb=${result.megabytes}');
    await InstallTrace.flush();
    exit(0);
  }
  if (checkSource) {
    var source = container.read(engineSourceProvider);
    // 等 restore() 跑完（它在 build() 里 fire-and-forget 启动）。
    for (var i = 0; i < 60 && !source.loaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      source = container.read(engineSourceProvider);
    }
    final caps = container.read(engineCapabilitiesProvider);
    final active = source.activeInstalled;
    print('PROBE source: ${source.source.name} active=${active?.version ?? '-'} @ ${active?.prefix ?? '-'}');
    print('PROBE capabilities: patched=${caps.patched} complete=${caps.complete} '
        'missing=${caps.missing.map((c) => c.id).join(',')}');
    InstallTrace.add('probe', 'engine source=${source.source.name} capabilities=${caps.missing.map((c) => c.id).join(',')}');
    await runtime!.stop();
    await runtime.start();
  } else if (npmVersion != null) {
    final npm = container.read(dshNpmProvider);
    final store = container.read(engineStoreProvider);
    final info = await npm.fetchVersions();
    print('PROBE registry: latest=${info.latest} versions=${info.versions.length}');
    final started = DateTime.now();
    final result = await npm.install(npmVersion, onLog: (line) => print('  [npm] $line'));
    print(
      'PROBE installed ${result.engine.version} → ${result.engine.path} '
      '(${DateTime.now().difference(started).inSeconds}s) 补丁 ${result.patch?.patchesOk}/${result.patch?.patches}'
      '${result.lostPatches.isEmpty ? '' : ' 失效=${result.lostPatches.length}'}',
    );
    final list = await store.list();
    print('PROBE store: ${list.map((e) => '${e.version}(${e.source})').join(', ')}');
    await runtime!.setOfficial(false);
    await runtime.useExternalCore(store.asDiscovered(result.engine));
    external = null;
  } else if (importPrefix != null) {
    final store = container.read(engineStoreProvider);
    final probe = await DshDiscovery.probePrefix(importPrefix, source: 'user');
    if (!probe.usable) {
      print('PROBE FAIL: --import 前缀不可用（${probe.reason}）');
      await InstallTrace.flush();
      exit(1);
    }
    final started = DateTime.now();
    final engine = await store.importFrom(
      probe.dsh!,
      onProgress: (files) => InstallTrace.add('engines', 'copied $files files'),
    );
    print('PROBE imported → ${engine.path} (${DateTime.now().difference(started).inSeconds}s)');
    InstallTrace.add('probe', 'imported ${engine.version} → ${engine.path}');
    final list = await store.list();
    print('PROBE store: ${list.map((e) => e.version).join(', ')}');
    await runtime!.setOfficial(false);
    await runtime.useExternalCore(store.asDiscovered(engine));
    print('PROBE using store engine: ${engine.version} @ ${engine.path}');
  } else if (external != null) {
    // 复用模式：不安装，直接把桥切到外部的核心上。
    await runtime!.useExternalCore(external);
    print('PROBE using external core: $external');
    InstallTrace.add('probe', 'use external core $external');
  }

  // 走界面同一条安装入口。
  var failure = '';
  final skippedInstall = external != null || importPrefix != null || npmVersion != null;
  if (!skippedInstall) print('PROBE calling runtimeInstallProvider.install()...');
  try {
    if (skippedInstall) {
      // 复用模式跳过安装。
    } else {
    await container
        .read(runtimeInstallProvider.notifier)
        .install()
        .timeout(const Duration(minutes: 10));
      print('PROBE install() returned');
    }
  } on Object catch (error, stack) {
    failure = 'install threw: $error';
    print('PROBE $failure');
    print(stack.toString().split('\n').take(10).join('\n'));
    InstallTrace.error('probe', error, stack);
  }

  final installed = container.read(localRuntimeProvider).status;
  print('PROBE after install: ${_describe(installed)}');
  InstallTrace.add('probe', 'after install: ${_describe(installed)}');
  if (installed.installedVersion == null) {
    failure = failure.isEmpty ? 'runtime still not installed after install()' : failure;
  }

  if (failure.isEmpty && startEngineToo) {
    print('PROBE starting engine...');
    try {
      await bridge.start().timeout(const Duration(minutes: 5));
      // start() 只负责把进程拉起来；「就绪」要看 baseUrl 是否出现（token 行）。
      var running = await bridge.status();
      for (var i = 0; i < 120; i++) {
        if (running.baseUrl != null && running.phase == RuntimePhase.running) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        running = await bridge.status();
      }
      print('PROBE after start: ${_describe(running)} baseUrl=${running.baseUrl ?? '-'}');
      InstallTrace.add('probe', 'after start: ${_describe(running)} baseUrl=${running.baseUrl ?? '-'}');
      if (running.phase != RuntimePhase.running || running.baseUrl == null) {
        failure =
            'engine not ready (phase=${running.phase.name} baseUrl=${running.baseUrl ?? '-'} error=${running.error ?? '-'})';
      }
      final logs = await bridge.logs(lines: 120);
      print('PROBE engine log tail:\n${InstallTrace.tail(logs.join('\n'), max: 20)}');
      await bridge.stop();
      print('PROBE stopped engine');
    } on Object catch (error, stack) {
      failure = 'start threw: $error';
      print('PROBE $failure');
      InstallTrace.error('probe/start', error, stack);
    }
  }

  await InstallTrace.flush();
  print(failure.isEmpty ? 'PROBE OK' : 'PROBE FAIL: $failure');
  print('PROBE trace: ${InstallTrace.file}');
  container.dispose();
  await runtime?.stop();
  await InstallTrace.flush();
  exit(failure.isEmpty ? 0 : 1);
}

String _describe(RuntimeStatus status) =>
    'phase=${status.phase.name} installed=${status.installedVersion ?? '-'} '
    'bundled=${status.bundledVersion ?? '-'} error=${status.error ?? '-'}';

/// 旧行为复现：自己建一个空的 `ProviderContainer()`（不传 main.dart 的那几个
/// override），于是 `runtimeBridgeProvider` 落到默认的 Kotlin 通道桥。
Future<void> _reproduceDefaultBridge() async {
  final container = ProviderContainer();
  final bridge = container.read(runtimeBridgeProvider);
  print('PROBE(default bridge) bridge=${bridge.runtimeType}');
  InstallTrace.add('probe', 'default-bridge repro: bridge=${bridge.runtimeType}');
  try {
    await container.read(runtimeInstallProvider.notifier).install().timeout(const Duration(seconds: 60));
    print('PROBE(default bridge) install() returned normally (本次修复前就是这个样子)');
  } on Object catch (error, stack) {
    print('PROBE(default bridge) install() threw: $error');
    InstallTrace.error('probe', error, stack);
  }
  final status = container.read(localRuntimeProvider).status;
  print('PROBE(default bridge) after: ${_describe(status)}');
  InstallTrace.add('probe', 'default-bridge repro after: ${_describe(status)}');
  container.dispose();
  await InstallTrace.flush();
  print('PROBE trace: ${InstallTrace.file}');
  exit(1);
}
