// macOS 接入层的入口：把原版里由 Android 原生提供的那几块，换成 Mac 上的实现。
//
// 用法（main.dart）：
//   await startMacSupport();
//   runApp(ProviderScope(overrides: [...], child: const DshApp()));
//
// 非 macOS 时两个函数都不做任何事，返回空列表。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mac_runtime.dart';
import 'window_mode.dart';

/// 本机引擎的实例：main.dart 创建并通过 ProviderScope 覆盖，界面用它切换模式。
final macRuntimeBridgeProvider = Provider<MacRuntimeBridge>(
  (ref) => throw UnimplementedError('macRuntimeBridgeProvider 只在 macOS 上覆盖'),
);

/// 这个进程是不是 macOS 桌面版。
bool get isMacDesktop => !kIsWeb && Platform.isMacOS;

/// 这个进程是不是桌面端（macOS / Windows / Linux）。
///
/// 本机引擎（[MacRuntimeBridge]）在桌面三端共用，所以「要不要覆盖
/// `runtimeBridgeProvider`」要看它而不是 [isMacDesktop]：Windows / Linux 上
/// 没有 Kotlin 那侧的 `dsh/runtime` 通道，不覆盖就会抛 `MissingPluginException`，
/// 界面只会显示「安装未完成」、日志一片空白。
/// 仍然只属于 macOS 的功能（菜单栏、窗口版式、Peekaboo）继续用 [isMacDesktop]。
bool get isDesktop => !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// 启动前的准备：窗口版式订阅。失败不影响启动。
Future<void> startMacSupport() async {
  if (!isMacDesktop) return;
  await MacWindow.start();
}

