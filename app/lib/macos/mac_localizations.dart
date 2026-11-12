// 桌面端只覆盖「**真的**跨平台不一样」的那几条文案。
//
// 2026-11 之前这里覆盖了 73 个 getter，把 Android 资源里的「手机」换成「Mac」。
// 那层 hook 承担了本该由资源字符串自己负责的事，于是 Windows 上显示成
// 「这台 Mac 上的 DSH」。现在设备指代已经在 **ARB 源头**统一成「设备 / device」
// （lib/l10n/parts/*.arb），本文件只剩三种确实分平台的说法：
//
//   1. 产品名：macOS 版叫「DSH Go Mac」，Windows / Linux 只叫「DSH Go」；
//   2. 安装与密钥存储：macOS 是拖进 Applications、钥匙串；其余平台走系统安装器、
//      系统凭据存储；
//   3. 手机版式与 macOS 系统设置的术语（辅助功能、系统设置里的识别服务）。
//
// 做法仍是继承 gen-l10n 生成的 L10nZh / L10nEn 覆盖 getter，而不是改 ARB：
// 这些字串在 Android 上要的又是不一样的东西，塞进共享 ARB 反而会让 Android 读错。

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../l10n/gen/app_localizations_en.dart';
import '../l10n/gen/app_localizations_zh.dart';

/// 桌面端（macOS / Windows / Linux）的文案覆盖是否生效。
///
/// `flutter test` 里固定为 false：既有测试和 golden 都是按 Android 文案写的。
bool get macTextActive =>
    !kIsWeb &&
    (Platform.isMacOS || Platform.isWindows || Platform.isLinux) &&
    Platform.environment['FLUTTER_TEST'] != 'true';

/// 桌面端是否还需要「运行时权限申请」这一步。
///
/// Android 有一套运行时权限（存储、无障碍、电池优化、通知），首次运行要逐项引导用户
/// 去系统设置里开。macOS 保留这一步（辅助功能 / 屏幕录制仍需要用户授权）。
///
/// **Windows 与 Linux 不需要**：文件、通知、窗口都不要求用户在系统里单独授权，
/// 所以引导流程里整步跳过（见 ui/shell/root_gate.dart 的 _afterAppearance）。
bool get isDesktopWithoutRuntimePermissions => !kIsWeb && (Platform.isWindows || Platform.isLinux);

/// 产品名：macOS 版叫「DSH Go Mac」，三端统一发行后 Windows / Linux 只叫「DSH Go」。
String get desktopProductZh => Platform.isMacOS ? 'DSH Go Mac' : 'DSH Go';
String get desktopProductEn => Platform.isMacOS ? 'DSH Go Mac' : 'DSH Go';

/// 保存私钥、密码的本机存储：macOS 是钥匙串，Windows / Linux 是系统凭据存储。
String get desktopVaultZh => Platform.isMacOS ? '钥匙串' : '系统凭据存储';
String get desktopVaultEn => Platform.isMacOS ? 'the Keychain' : 'the system credential store';

/// 中文 macOS 文案。
class MacL10nZh extends L10nZh {
  MacL10nZh([super.locale = 'zh']);

  // ── 产品名 ────────────────────────────────────────────────────────────────

  @override
  String get hubAbout => '关于 $desktopProductZh';

  @override
  String get starSettingsTitle => '给 $desktopProductZh 点个 star';

  // ── 手机版式（Android 原文说「手机布局」，桌面端说的是竖屏） ──────────────

  @override
  String get hubSettingsWebPhoneLayout => '网页版竖屏布局';

  @override
  String get hubSettingsWebPhoneLayoutHint => '为窄屏重排网页版';

  @override
  String get hubInterfacePhoneLayout => '竖屏版式';

  @override
  String get searchKwWebPhoneLayout => '网页版竖屏布局,布局';

  // ── 安装 ──────────────────────────────────────────────────────────────────

  @override
  String get updateReadyToInstall => Platform.isMacOS
      ? '安装包已下载并校验。打开后把 $desktopProductZh 拖进 Applications 覆盖旧版。'
      : '安装包已下载并校验。打开后按提示覆盖旧版，设置和对话会保留。';

  @override
  String get updateInstallWithSystem => Platform.isMacOS ? '打开安装包' : '运行安装包';

  @override
  String get updateInstallKeepsData => '覆盖安装后对话和设置会保留；内置引擎在 设置 › 引擎 更新。';

  // ── 密钥存储 ──────────────────────────────────────────────────────────────

  @override
  String get remoteKeyStorageHelp => '只保存在本机上，由$desktopVaultZh加密。支持 Ed25519、RSA、ECDSA';

  @override
  String get remotePasswordStorageHelp => '只保存在本机上，由$desktopVaultZh加密';

  // ── macOS 系统设置的术语 ──────────────────────────────────────────────────

  @override
  String get a11yRestoreNotice => '开启后，在系统设置里关掉辅助功能会被自动打开；要关闭设备操控，请在 DSH Go 里关。';

  @override
  String get phoneDisclosureStopBody => '操作时屏幕上有悬浮条，可以暂停、停止或插话。先在系统设置里允许 DSH Go 使用辅助功能。';

  @override
  String get voiceModeSystemHint => '使用系统设置中的语音识别服务';

  // ── 桌面端没有 DS Bot ─────────────────────────────────────────────────────

  @override
  String get botsMobileUnsupportedTitle => 'DS Bot 暂不支持桌面端';

  @override
  String get botsMobileApiMissing => '桌面端暂不支持，可先在网页版中使用';
}

/// English desktop wording.
class MacL10nEn extends L10nEn {
  MacL10nEn([super.locale = 'en']);

  @override
  String get hubAbout => 'About $desktopProductEn';

  @override
  String get starSettingsTitle => 'Star $desktopProductEn';

  @override
  String get hubSettingsWebPhoneLayout => 'Portrait layout for the web view';

  @override
  String get hubSettingsWebPhoneLayoutHint => 'Rearrange the web view for narrow screens';

  @override
  String get hubInterfacePhoneLayout => 'Portrait layout';

  @override
  String get searchKwWebPhoneLayout => 'web portrait layout, layout';

  @override
  String get updateReadyToInstall => Platform.isMacOS
      ? 'The installer is downloaded and verified. Open it, then drag $desktopProductEn into Applications to replace the old version.'
      : 'The installer is downloaded and verified. Open it and follow the steps; settings and chats are kept.';

  @override
  String get updateInstallWithSystem => Platform.isMacOS ? 'Open installer' : 'Run installer';

  @override
  String get updateInstallKeepsData =>
      'Replacing the app keeps your conversations and settings. Update the bundled engine from Settings › Engine.';

  @override
  String get remoteKeyStorageHelp =>
      'Saved only on this device, encrypted by $desktopVaultEn. Supports Ed25519, RSA and ECDSA.';

  @override
  String get remotePasswordStorageHelp => 'Saved only on this device, encrypted by $desktopVaultEn';

  @override
  String get a11yRestoreNotice =>
      'Once on, turning accessibility off in System Settings is switched back on. To stop device control, turn it off in DSH Go.';

  @override
  String get phoneDisclosureStopBody =>
      'A floating bar lets you pause, stop or steer. Allow DSH Go in Accessibility first.';

  @override
  String get voiceModeSystemHint => 'Use the recognition service selected in System Settings';

  @override
  String get botsMobileUnsupportedTitle => 'DS Bot is not supported on desktop yet';

  @override
  String get botsMobileApiMissing => 'Not supported on desktop yet; use it on the web for now';
}
