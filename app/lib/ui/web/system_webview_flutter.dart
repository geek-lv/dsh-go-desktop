// `webview_flutter` 后端：macOS（WKWebView）/ Android（Android WebView）/ iOS。
//
// 这是本仓库原来的唯一实现，行为必须与改动前完全一致：macOS 是当前唯一跑通的桌面
// 平台，任何语义偏移都算回归。所有调用都直接转给 WebViewController。

import 'dart:async';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart' as wf;

import 'system_webview.dart';

/// 包住 `WebViewController` 的适配器。
class WebviewFlutterSystemController extends SystemWebViewController {
  WebviewFlutterSystemController({bool denyPermissionRequests = false})
    : _controller = wf.WebViewController(
        // `WebViewController({void Function(WebViewPermissionRequest)? onPermissionRequest})`
        // 已在 webview_flutter 4.14.1 的 lib/src/webview_controller.dart:59 核实。
        onPermissionRequest: denyPermissionRequests ? _deny : null,
      ),
      super(SystemWebViewBackend.webviewFlutter);

  final wf.WebViewController _controller;

  static void _deny(wf.WebViewPermissionRequest request) => unawaited(request.deny());

  @override
  Future<void> setJavaScriptModeUnrestricted() => _controller.setJavaScriptMode(wf.JavaScriptMode.unrestricted);

  @override
  Future<void> setBackgroundColor(Color color) => _controller.setBackgroundColor(color);

  @override
  Future<void> setNavigationDelegate(SystemWebViewNavigationDelegate delegate) => _controller.setNavigationDelegate(
    wf.NavigationDelegate(
      onNavigationRequest: delegate.onNavigationRequest == null
          ? null
          : (request) async {
              final allow = await delegate.onNavigationRequest!(
                SystemNavigationRequest(url: request.url, isMainFrame: request.isMainFrame),
              );
              return allow ? wf.NavigationDecision.navigate : wf.NavigationDecision.prevent;
            },
      onPageStarted: delegate.onPageStarted == null ? null : (url) => delegate.onPageStarted!(url),
      onProgress: delegate.onProgress == null ? null : (progress) => delegate.onProgress!(progress),
      onPageFinished: delegate.onPageFinished == null ? null : (url) => delegate.onPageFinished!(url),
      onWebResourceError: delegate.onWebResourceError == null
          ? null
          : (error) => delegate.onWebResourceError!(
              SystemWebResourceError(
                errorCode: error.errorCode,
                description: error.description,
                // 安卓上可能为 null；调用方原本按 `?? true` 处理。
                isMainFrame: error.isForMainFrame ?? true,
                errorType: error.errorType?.name,
              ),
            ),
    ),
  );

  @override
  Future<void> addJavaScriptChannel(String name, void Function(String message) onMessage) =>
      _controller.addJavaScriptChannel(name, onMessageReceived: (message) => onMessage(message.message));

  @override
  Future<void> loadRequest(Uri url) => _controller.loadRequest(url);

  @override
  Future<void> loadHtmlString(String html) => _controller.loadHtmlString(html);

  @override
  Future<void> runJavaScript(String script) => _controller.runJavaScript(script);

  @override
  Future<Object?> runJavaScriptReturningResult(String script) => _controller.runJavaScriptReturningResult(script);

  @override
  Future<void> reload() => _controller.reload();

  @override
  Future<bool> canGoBack() => _controller.canGoBack();

  @override
  Future<void> goBack() => _controller.goBack();

  @override
  Future<String?> currentUrl() => _controller.currentUrl();

  @override
  Widget build({Key? key, Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers}) => wf.WebViewWidget(
    key: key,
    controller: _controller,
    // `WebViewWidget` 的 gestureRecognizers 非空（默认 const {}），这里要兜一层。
    gestureRecognizers: gestureRecognizers ?? const <Factory<OneSequenceGestureRecognizer>>{},
  );

  /// webview_flutter_android 的 `AndroidWebViewController.webViewIdentifier`：
  /// 不改依赖、用 dynamic 取（与改动前 `web_view_guard.dart` 的做法一致）。
  @override
  int? get androidWebViewId {
    try {
      final Object? id = (_controller.platform as dynamic).webViewIdentifier;
      return id is int ? id : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Object? get vendorController => _controller;

  @override
  Future<void> dispose() async {
    // WebViewController 没有 dispose：WebView 的生命周期由平台侧随最后一个
    // WebViewWidget 离开而结束（行为同改动前）。
  }
}
