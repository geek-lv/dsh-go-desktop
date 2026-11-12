// WebView 平台差异的唯一收口处。
//
// 全仓的 WebView 都用 `webview_all`：一套 API 覆盖 Android / iOS / macOS /
// Windows / Linux / Web，各平台一律**使用系统自带内核**（Android WebView /
// WKWebView / WebView2 / WebKitGTK），不打包任何浏览器内核。
//
// 这里只放两件 webview_all 不直接提供、但本仓业务需要的东西：
//   * [androidWebViewIdOf]：取出 Android WebView 的原生 id。`dsh/islands` 与
//     `WebViewGuard` 的原生接管要用它（桌面上永远是 null）。
//   * [denyAllPermissions]：统一的权限回调（DSH Web / 插件面板都不需要摄像头、
//     麦克风、定位，否则会在一轮对话中间弹系统授权框）。
//
// 其余类型（WebViewController / WebViewWidget / NavigationDelegate /
// NavigationRequest / WebResourceError / JavaScriptMessage …）请直接用
// `package:webview_all/webview_all.dart` 里的，不要再包一层。

import 'dart:async';

import 'package:webview_all/webview_all.dart';
import 'package:webview_all_android/webview_all_android.dart';

/// Android WebView 的原生 id；非 Android 平台或还没建出来时是 null。
///
/// `webview_all_android` 的 `AndroidWebViewController.webViewIdentifier` 与
/// `webview_flutter_android` 的同名 getter 语义一致（已对照
/// webview_all_android 1.5.0 源码核实）。
int? androidWebViewIdOf(WebViewController controller) {
  final platform = controller.platform;
  return platform is AndroidWebViewController ? platform.webViewIdentifier : null;
}

/// 一律拒绝网页发起的权限请求。
void denyAllPermissions(WebViewPermissionRequest request) => unawaited(request.deny());

/// `NavigationDelegate.onNavigationRequest` 的返回值适配：本仓的业务判定函数
/// 习惯返回 bool，而 webview_all 要求 [NavigationDecision]。
NavigationDecision decisionFrom(bool allow) =>
    allow ? NavigationDecision.navigate : NavigationDecision.prevent;
