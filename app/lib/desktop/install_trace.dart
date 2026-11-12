// 安装链路现场取证：把「谁在装、装到哪一步、报的什么错」写进一份持久日志。
//
// 为什么一定要落盘：Windows 的 `dsh_app.exe` 是 GUI 子系统程序，没有控制台，
// `stdout` / `stderr` 没有重定向时直接被丢弃；错误在此之前只进内存（界面日志
// 面板最近 300 行）。于是「安装未完成」这种失败在用户那边等于**零线索**——
// 上一轮排查就是被这一点卡住的（日志面板一片空白，只能靠猜）。
//
// 约定：
//   * 只会写文件，不会抛异常，不会拖住界面（写失败就静默放弃）；
//   * 每行都过 [redactDiagnostics]，token / API key 不会落进文件；
//   * 文件位置见 [InstallTrace.file]（拿不到时为 null，界面上会显示）。
//
// 一次安装会在文件里留下一条 `===== trace start =====` 分隔线，读的时候只看
// 最后一段即可；超过 4 MB 自动轮转成 `.1`。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../diagnostics/redact.dart';

/// 安装 / 启动链路的落盘追踪器。全局单例，任意位置调用 [InstallTrace.add]。
abstract final class InstallTrace {
  static const String fileName = 'install-trace.log';
  static const int _maxBytes = 4 * 1024 * 1024;

  static Directory? _base;
  static IOSink? _sink;
  static String? _path;
  static Future<void> _queue = Future<void>.value();
  static bool _failed = false;

  /// 日志文件的绝对路径；[open] 之后才有值。
  static String? get file => _path;

  /// 打开（或复用）日志文件，并写入一段新的分隔头。多次调用是安全的。
  ///
  /// [what] 是这段追踪的来由，例如 `probe/desktop-install` 或 `app/first-run`。
  static Future<void> open(String what) async {
    if (_failed) return;
    try {
      if (_sink == null) {
        final base = await _supportDir();
        final dir = Directory('${base.path}${Platform.pathSeparator}diag');
        await dir.create(recursive: true);
        final log = File('${dir.path}${Platform.pathSeparator}$fileName');
        if (await log.exists() && await log.length() > _maxBytes) {
          final old = File('${log.path}.1');
          if (await old.exists()) await old.delete();
          await log.rename(old.path);
        }
        _path = log.path;
        _sink = log.openWrite(mode: FileMode.append);
      }
      _writeRaw(
        '===== trace start ${_stamp()} =====\n'
        'what=$what\n'
        'os=${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
        'dart=${Platform.version}\n'
        'executable=${Platform.resolvedExecutable}\n',
      );
    } catch (error) {
      _failed = true;
      debugPrint('[dsh-go][trace] cannot open trace file: $error');
    }
  }

  /// 一行普通追踪。[tag] 用来分组（`main` / `install` / `tar` / `bridge` …）。
  static void add(String tag, String message) => _write(tag, message);

  /// 一行异常追踪。`toString()` 之外还带类型与栈，Windows 上的
  /// `MissingPluginException`、`ProcessException` 只能靠这些区分。
  static void error(String tag, Object error, [StackTrace? stack]) {
    final buffer = StringBuffer('ERROR ${error.runtimeType}: $error');
    if (stack != null) buffer.write('\n$stack');
    _write('$tag!', buffer.toString());
  }

  /// 丢弃最前面 [max] 行之后的输出（tar / 子进程的 stderr 常常很长）。
  static String tail(String text, {int max = 40}) {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.length <= max) return lines.join('\n');
    return '…(${lines.length - max} lines dropped)…\n${lines.sublist(lines.length - max).join('\n')}';
  }

  /// 等所有排队中的写入落盘（进程退出前、探针结束前调用）。
  static Future<void> flush() async {
    try {
      await _queue;
      await _sink?.flush();
    } catch (_) {}
  }

  // ── 内部 ──────────────────────────────────────────────────────────────────

  static void _write(String tag, String message) {
    final line = '[${_stamp()}] $tag | $message';
    debugPrint('[dsh-go][trace] $line');
    _writeRaw('$line\n');
  }

  static void _writeRaw(String text) {
    if (_failed) return;
    final sink = _sink;
    if (sink == null) return;
    _queue = _queue.then((_) async {
      try {
        sink.write(redactDiagnostics(text));
        await sink.flush();
      } catch (_) {
        _failed = true;
      }
    });
  }

  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  /// 与 `MacRuntimeBridge._supportDir()` 一致：App 的 Application Support 目录。
  /// 拿不到（插件未注册等）就退到 `%APPDATA%` / `$HOME`，保证日志一定写得出来。
  static Future<Directory> _supportDir() async {
    final cached = _base;
    if (cached != null) return cached;
    try {
      return _base = await getApplicationSupportDirectory();
    } catch (_) {
      final env = Platform.environment;
      final home = Platform.isWindows ? env['APPDATA'] : env['HOME'];
      if (home == null || home.isEmpty) throw StateError('no home directory');
      return _base = Directory(home);
    }
  }
}
