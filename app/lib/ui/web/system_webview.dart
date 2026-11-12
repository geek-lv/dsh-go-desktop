// 系统 WebView 的薄抽象（桌面端适配层）。
//
// 为什么需要这一层：`webview_flutter` 只有 Android / iOS / macOS 的实现（macOS 由
// 传递依赖 `webview_flutter_wkwebview` 提供）。Windows 的系统内核是 WebView2，
// Linux 是 WebKitGTK，两者都不在 `webview_flutter` 的覆盖范围里。这里把「业务代码
// 实际用到的 WebView 能力」收成一个接口，按平台分发：
//
//   macOS / Android / iOS   webview_flutter（各平台系统内核）
//   Windows                 webview_windows → WebView2
//   Linux                   flutter_inappwebview（+ flutter_inappwebview_linux）
//
// 边界：
// * 只做平台分发与 API 适配，不含任何 UI 或业务逻辑；调用方仍然拿「controller +
//   widget」两样东西，语义与 `WebViewController` / `WebViewWidget` 一一对应。
// * 三个后端能力不同，差异集中在 docs/desktop/webview.md「能力差异表」；
//   业务文件不按平台分叉，只按能力降级。
//
// 验证状态：本机没有 Flutter SDK，**没有编译过、没有运行过**。
// 每个后端引用的 API 签名都是对着 pub 上的包源码逐个核对的（见
// docs/desktop/webview.md「签名核实」一节），但「能编译」这句话不成立。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'system_webview_flutter.dart';
import 'system_webview_win.dart';

/// 这一层下面真正干活的系统内核。
enum SystemWebViewBackend {
  /// `webview_flutter`：Android WebView / WKWebView。
  webviewFlutter,

  /// `webview_windows`：Microsoft Edge WebView2（Windows 系统自带）。
  webView2,

  /// Linux：暂无可用的「系统 WebKitGTK」内嵌实现，业务层退化为外部浏览器。
  ///
  /// 见 [SystemWebViewCapability.unavailable] 与 docs/desktop/webview.md。
  unavailable,
}

/// 一次导航请求，等价于 `webview_flutter` 的 `NavigationRequest`。
class SystemNavigationRequest {
  const SystemNavigationRequest({required this.url, required this.isMainFrame});

  /// 目标地址（原样字符串，页面可能给出 `about:blank` / `data:` 之类）。
  final String url;

  /// 是否主框架导航。
  final bool isMainFrame;
}

/// 一条资源加载错误，等价于 `webview_flutter` 的 `WebResourceError` 里业务用到的部分。
class SystemWebResourceError {
  const SystemWebResourceError({
    required this.errorCode,
    required this.description,
    required this.isMainFrame,
    this.errorType,
  });

  final int errorCode;
  final String description;
  final bool isMainFrame;
  final String? errorType;

  @override
  String toString() => 'SystemWebResourceError($errorCode $description mainFrame=$isMainFrame ${errorType ?? ''})';
}

/// 导航/加载回调，等价于 `webview_flutter` 的 `NavigationDelegate`。
///
/// 各后端支持程度不同（`null` 的回调不注册，不支持的回调永远不触发）：
/// * [onNavigationRequest]：webview_flutter / Linux 支持「导航前拦截」；
///   Windows 只能在 URL 变化后回退（见 docs/desktop/webview.md）。
/// * [onProgress]：Windows 后端拿不到百分比，永远不触发。
class SystemWebViewNavigationDelegate {
  const SystemWebViewNavigationDelegate({
    this.onNavigationRequest,
    this.onPageStarted,
    this.onProgress,
    this.onPageFinished,
    this.onWebResourceError,
  });

  /// 返回 true 表示放行这次导航。
  final FutureOr<bool> Function(SystemNavigationRequest request)? onNavigationRequest;
  final void Function(String url)? onPageStarted;
  final void Function(int progress)? onProgress;
  final void Function(String url)? onPageFinished;
  final void Function(SystemWebResourceError error)? onWebResourceError;
}

/// 一个系统 WebView 的控制器。
///
/// 生命周期与 `webview_flutter` 的 `WebViewController` 一致：先创建，配置，然后
/// [build] 出 widget 交给界面；重新打开就是新建一个 controller 并换 key。
abstract class SystemWebViewController {
  SystemWebViewController(this.backend);

  final SystemWebViewBackend backend;

  /// 不限制 JavaScript（业务代码里每个页面都这么设）。
  Future<void> setJavaScriptModeUnrestricted();

  /// 页面背景色。不支持的平台（Linux）只认得「全透明」，其余颜色是空操作。
  Future<void> setBackgroundColor(Color color);

  Future<void> setNavigationDelegate(SystemWebViewNavigationDelegate delegate);

  /// 注册一个 `name.postMessage(...)` 形式的 JS 通道。
  ///
  /// 与 webview_flutter 一样：通道要在第一次加载前注册才生效。
  Future<void> addJavaScriptChannel(String name, void Function(String message) onMessage);

  Future<void> loadRequest(Uri url);

  Future<void> loadHtmlString(String html);

  Future<void> runJavaScript(String script);

  /// 与 `WebViewController.runJavaScriptReturningResult` 同义。
  Future<Object?> runJavaScriptReturningResult(String script);

  Future<void> reload();

  Future<bool> canGoBack();

  Future<void> goBack();

  Future<String?> currentUrl();

  /// WebView 本体。每次重建（新 controller）都应换一个新的 [key]。
  Widget build({Key? key, Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers});

  /// Android 专用：`AndroidWebViewController.webViewIdentifier`，其它平台返回 null。
  ///
  /// 给 `ui/web/web_view_guard.dart` 与 `ui/plugins/islands/` 的原生接管用。
  int? get androidWebViewId;

  /// 底层厂商 controller（Android 的文件选择器要用），桌面后端没有。
  Object? get vendorController;

  Future<void> dispose();
}

/// 当前平台用哪个后端。
SystemWebViewBackend get systemWebViewBackend {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return SystemWebViewBackend.webView2;
    case TargetPlatform.linux:
      // Linux 目前没有满足「只用系统 WebKitGTK、不打包内核」约束的内嵌实现。
      // `flutter_inappwebview_linux` 用的是 WPE WebKit，构建时会把约 160 MB 的
      // libWPEWebKit 拷进 App 的 lib/，等于随包带内核，因此不采用。
      // 业务层调用方在拿不到 controller 时退化为「用系统浏览器打开」。
      return SystemWebViewBackend.unavailable;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.fuchsia:
      return SystemWebViewBackend.webviewFlutter;
  }
}

/// 当前平台是否有可用的内嵌 WebView。
bool get systemWebViewAvailable => systemWebViewBackend != SystemWebViewBackend.unavailable;

/// 建一个当前平台可用的 WebView 控制器。
///
/// [denyPermissionRequests] 与 `WebViewController(onPermissionRequest: ...)` 同义，
/// 只有 webview_flutter 后端有对应开关；桌面后端默认就是拒绝（WebView2 的权限请求
/// 不注册回调）。
///
/// 返回 null 表示本平台没有内嵌 WebView，调用方应退化为外部浏览器。
SystemWebViewController? createSystemWebViewController({bool denyPermissionRequests = false}) {
  switch (systemWebViewBackend) {
    case SystemWebViewBackend.webView2:
      return WebView2SystemController();
    case SystemWebViewBackend.unavailable:
      return null;
    case SystemWebViewBackend.webviewFlutter:
      return WebviewFlutterSystemController(denyPermissionRequests: denyPermissionRequests);
  }
}
