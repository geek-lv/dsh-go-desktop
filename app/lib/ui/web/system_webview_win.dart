// Windows 后端：`webview_windows` 0.4.0 → Microsoft Edge WebView2。
//
// 内核是系统自带的 WebView2 Runtime（Win11 预装；Win10 需要装 Evergreen
// Bootstrapper），本包不在安装包里带任何浏览器内核。
//
// 与 webview_flutter 的语义差异（都在 docs/desktop/webview.md「能力差异表」里）：
// 1. **没有导航前拦截**：WebView2 的事件里没有「这次导航放不放行」。这里用
//    「URL 变了 → 问策略 → 不允许就 goBack」近似。页面可能闪一下，且 `about:blank`
//    这类不可回退的地址无法撤销。业务文件里对外的链接策略因此是「尽力而为」。
// 2. **没有进度百分比**：只有 loadingState（none / loading / navigationCompleted），
//    所以 `onProgress` 永远不触发，进度条在 Windows 上不显示。
// 3. **没有命名 JS 通道**：只有一个 `webMessage` 流。这里在文档创建时注入一层
//    垫片，把 `window.<name>.postMessage(x)` 转成
//    `window.chrome.webview.postMessage(JSON.stringify({c:name,m:x}))`，
//    再按 `c` 分发给各通道回调。垫片用
//    `addScriptToExecuteOnDocumentCreated` 装，所以**必须**在首次加载前注册好通道。
// 4. **canGoBack 没有直接查询**：只能从 historyChanged 流缓存。
//
// 验证状态：API 签名对着 webview_windows 0.4.0 源码核实过（见 docs），
// 但**没有在 Windows 上编译/运行过**（本机没有 Flutter SDK）。垫片脚本与
// `?token= → 303 → dsh-auth cookie` 链路都待真机验证。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_windows/webview_windows.dart' as ww;

import 'system_webview.dart';

class WebView2SystemController extends SystemWebViewController {
  WebView2SystemController() : super(SystemWebViewBackend.webView2);

  final ww.WebviewController _controller = ww.WebviewController();

  final Set<String> _channelNames = <String>{};
  final Map<String, void Function(String)> _handlers = <String, void Function(String)>{};
  final List<StreamSubscription<Object?>> _subscriptions = <StreamSubscription<Object?>>[];

  Future<void>? _initializing;
  bool _shimInstalled = false;
  bool _disposed = false;
  bool _canGoBack = false;
  String? _lastUrl;
  SystemWebViewNavigationDelegate? _delegate;

  // ---------------------------------------------------------------------------
  // 生命周期

  /// WebView2 必须在 load 之前初始化；多个 controller 共享同一个环境。
  Future<void> _ensure() {
    if (_disposed) return Future<void>.error(StateError('WebView2 controller disposed'));
    return _initializing ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    await _controller.initialize();
    _subscriptions
      ..add(_controller.url.listen(_onUrlChanged))
      ..add(_controller.loadingState.listen(_onLoadingState))
      ..add(_controller.onLoadError.listen(_onLoadError))
      ..add(_controller.historyChanged.listen((changed) => _canGoBack = changed.canGoBack))
      // 单订阅流：只订阅一次。
      ..add(_controller.webMessage.listen(_onWebMessage, onError: (Object _) {}));
    if (_channelNames.isNotEmpty) await _installChannelShim();
  }

  // ---------------------------------------------------------------------------
  // 配置

  @override
  Future<void> setJavaScriptModeUnrestricted() async {
    // WebView2 默认开启 JS，也没有关闭它的 API（settings 在 WebView2 侧）。
  }

  @override
  Future<void> setBackgroundColor(Color color) async {
    await _ensure();
    // 半透明被视为不透明；全透明不受支持（包文档原话）。
    await _controller.setBackgroundColor(color);
  }

  @override
  Future<void> setNavigationDelegate(SystemWebViewNavigationDelegate delegate) async {
    // 只记下来：WebView2 没有「导航前」回调，拦截在 _onUrlChanged 里近似。
    _delegate = delegate;
  }

  @override
  Future<void> addJavaScriptChannel(String name, void Function(String message) onMessage) async {
    _channelNames.add(name);
    _handlers[name] = onMessage;
    // 通道必须在文档创建前就位：先确保 controller 初始化（WebView2 的
    // AddScriptToExecuteOnDocumentCreated 只能对**之后的**文档生效），再装垫片。
    await _ensure();
    await _installChannelShim();
  }

  /// 注入 `window.<name>.postMessage` → WebView2 消息通道的垫片。
  Future<void> _installChannelShim() async {
    if (_channelNames.isEmpty || _shimInstalled || !_controller.value.isInitialized) return;
    _shimInstalled = true;
    await _controller.addScriptToExecuteOnDocumentCreated(_shimSource(_channelNames));
  }

  static String _shimSource(Iterable<String> names) {
    final list = jsonEncode(names.toList());
    return '''
(function () {
  try {
    var names = $list;
    for (var i = 0; i < names.length; i++) {
      (function (name) {
        window[name] = window[name] || {};
        window[name].postMessage = function (message) {
          try {
            window.chrome.webview.postMessage(JSON.stringify({ c: name, m: message }));
          } catch (e) {}
        };
      })(names[i]);
    }
  } catch (e) {}
})();
''';
  }

  // ---------------------------------------------------------------------------
  // 事件

  void _onUrlChanged(String url) {
    _lastUrl = url;
    final delegate = _delegate;
    final policy = delegate?.onNavigationRequest;
    if (policy == null) return;
    final request = SystemNavigationRequest(url: url, isMainFrame: true);
    final decision = policy(request);
    if (decision is bool) {
      if (!decision) unawaited(_revert());
    } else {
      unawaited(decision.then((allow) {
        if (!allow) unawaited(_revert());
      }).catchError((Object _) {}));
    }
  }

  /// 导航已经发生了才说不允许：能回退就回退（近似「拦截」）。
  Future<void> _revert() async {
    try {
      if (_controller.value.isInitialized) await _controller.goBack();
    } catch (_) {
      // about:blank / 首个文档没有历史可退：忽略。
    }
  }

  void _onLoadingState(ww.LoadingState state) {
    final delegate = _delegate;
    switch (state) {
      case ww.LoadingState.loading:
        delegate?.onPageStarted?.call(_lastUrl ?? '');
      case ww.LoadingState.navigationCompleted:
        delegate?.onPageFinished?.call(_lastUrl ?? '');
      case ww.LoadingState.none:
        break;
    }
  }

  void _onLoadError(ww.WebErrorStatus status) {
    // WebView2 只给状态码，没有「是否主框架」，按主框架处理（与旧行为一致：主框架
    // 错误才显示错误页；这里多报一些，交给调用方判断）。
    _delegate?.onWebResourceError?.call(
      SystemWebResourceError(errorCode: status.index, description: status.name, isMainFrame: true),
    );
  }

  void _onWebMessage(dynamic message) {
    // 垫片发的是 {c: <channel>, m: <原始 payload>} 的 JSON。
    if (message is! Map) return;
    final channel = message['c'];
    if (channel is! String) return;
    final handler = _handlers[channel];
    if (handler == null) return;
    final payload = message['m'];
    handler(payload is String ? payload : jsonEncode(payload));
  }

  // ---------------------------------------------------------------------------
  // 加载与脚本

  @override
  Future<void> loadRequest(Uri url) async {
    await _ensure();
    await _controller.loadUrl(url.toString());
  }

  @override
  Future<void> loadHtmlString(String html) async {
    await _ensure();
    await _controller.loadStringContent(html);
  }

  @override
  Future<void> runJavaScript(String script) async {
    await _ensure();
    await _controller.executeScript(script);
  }

  @override
  Future<Object?> runJavaScriptReturningResult(String script) async {
    await _ensure();
    // executeScript 已把 WebView2 的 JSON 字符串 jsonDecode 过（webview.dart:362-371）。
    return _controller.executeScript(script);
  }

  @override
  Future<void> reload() async {
    await _ensure();
    await _controller.reload();
  }

  @override
  Future<bool> canGoBack() async => _canGoBack;

  @override
  Future<void> goBack() async {
    await _ensure();
    await _controller.goBack();
  }

  @override
  Future<String?> currentUrl() async => _lastUrl;

  @override
  Widget build({Key? key, Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers}) {
    // `Webview` 的构造函数只有位置参数（没有 super.key），所以 key 挂在
    // KeyedSubtree 上：key 变 → 整棵子树重建 → 新的 texture 绑定。
    return KeyedSubtree(key: key, child: ww.Webview(_controller));
  }

  @override
  int? get androidWebViewId => null;

  @override
  Object? get vendorController => null;

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _handlers.clear();
    try {
      await _controller.dispose();
    } catch (_) {
      // 未初始化或已被平台销毁：忽略。
    }
  }
}
