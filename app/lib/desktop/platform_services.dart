// 桌面三端（macOS / Windows / Linux）之间的系统命令差异，全部收口在这里。
//
// 为什么需要这一层：引擎运行时的安装与诊断原先直接调 macOS 的绝对路径命令
// （/usr/bin/tar、/usr/bin/du、/usr/bin/xattr、/usr/bin/uname、/usr/sbin/sysctl、
// /usr/sbin/lsof、/usr/bin/open）。在 Windows / Linux 上这些路径不存在，
// 调一次就抛 ProcessException，安装运行时会直接失败。
//
// 设计约定：
//   * 这里只做「平台差异」的收敛，不含任何业务逻辑；
//   * macOS 分支的行为必须与改造前**逐字一致**（命令与参数都不变）；
//   * 每个方法都能在单测里用 [FakePlatformServices] 替换，不需要真机。
//
// 验证状态：macOS 分支是原样搬过来的（未改变行为）；Windows / Linux 分支的
// 命令已在 Windows 11 与 Ubuntu 24.04 上人工核对过用法，见每个方法的注释。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'install_trace.dart';

/// 解压 tar.gz，并把「已解出多少字节」回报给调用方用于进度条。
typedef ExtractProgress = void Function(int bytes);

/// 一个平台上的系统命令差异集合。
abstract class PlatformServices {
  const PlatformServices();

  /// 当前平台对应的默认实现。
  static PlatformServices current() {
    if (Platform.isWindows) return const WindowsPlatformServices();
    if (Platform.isLinux) return const LinuxPlatformServices();
    return const MacosPlatformServices();
  }

  /// 解压 [archive]（tar.gz）到 [destination]，返回解压出的顶层目录。
  ///
  /// 归档里的结构是 `runtime/...`，这里返回 `<destination>/runtime`。
  /// [onProgress] 是尽力而为的字节数回报（拿不到就不报）。
  Future<Directory> extractTarGz(
    File archive,
    Directory destination, {
    int totalBytes = 0,
    ExtractProgress? onProgress,
  });

  /// 目录当前占用的字节数（用于进度估计）。拿不到时返回 null。
  Future<int?> directorySize(Directory dir);

  /// 去掉归档携带的扩展属性 / 隔离标记。
  ///
  /// macOS 上 App 可能被 Gatekeeper 打上 com.apple.quarantine，解出来的 node
  /// 可执行文件会被拦；Windows / Linux 没有这种机制，是空操作。
  Future<void> clearQuarantine(Directory runtimeDir);

  /// 诊断用的机器型号 / 架构描述。
  Future<String> describeMachine();

  /// 找出所有监听 127.0.0.1 的端口里、命令名匹配 [exeNameContains] 的那个。
  ///
  /// 用于「接管正在运行的官方 DSH」。找不到返回空列表。
  Future<List<int>> findListenPorts(String exeNameContains);

  /// 用系统默认程序打开一个 URL 或路径。
  Future<void> openExternally(String target);

  /// 启动 tar 并把 stderr 收集起来。
  ///
  /// 原实现把 stderr 整段丢掉（`listen((_) {})`），于是「tar 退出 2」在日志里
  /// 只是一个数字：分不清是参数不对、归档损坏还是路径没权限。这里把 stderr
  /// 交给调用方写进追踪。
  Future<(Process, StringBuffer)> startTar(String exe, List<String> args) async {
    InstallTrace.add('tar', 'start exe=$exe args=${args.join(' ')}');
    final Process tar;
    try {
      tar = await Process.start(exe, args);
    } catch (error, stack) {
      InstallTrace.error('tar', 'cannot start $exe: $error', stack);
      rethrow;
    }
    final errors = StringBuffer();
    tar.stdout.transform(utf8.decoder).listen((_) {});
    tar.stderr.transform(utf8.decoder).listen(errors.write);
    return (tar, errors);
  }

  /// 记一行 tar 的结果。
  void endTar(int code, StringBuffer errors) {
    final text = errors.toString();
    InstallTrace.add('tar', 'exit=$code${text.trim().isEmpty ? '' : ' stderr=${InstallTrace.tail(text)}'}');
  }
}

/// macOS：与原实现逐字一致。
class MacosPlatformServices extends PlatformServices {
  const MacosPlatformServices();

  @override
  Future<Directory> extractTarGz(
    File archive,
    Directory destination, {
    int totalBytes = 0,
    ExtractProgress? onProgress,
  }) async {
    await destination.create(recursive: true);
    final (tar, errors) = await startTar('/usr/bin/tar', <String>['-xzf', archive.path, '-C', destination.path]);
    Timer? poll;
    if (totalBytes > 0 && onProgress != null) {
      poll = Timer.periodic(const Duration(milliseconds: 400), (_) async {
        final size = await directorySize(destination);
        if (size != null) onProgress(size.clamp(0, totalBytes));
      });
    }
    final code = await tar.exitCode;
    poll?.cancel();
    endTar(code, errors);
    if (code != 0) throw StateError('tar exited with $code');
    return Directory('${destination.path}/runtime');
  }

  @override
  Future<int?> directorySize(Directory dir) async {
    try {
      final du = await Process.run('/usr/bin/du', <String>['-sk', dir.path]);
      final kb = int.tryParse((du.stdout as String).trim().split(RegExp(r'\s+')).first) ?? 0;
      return kb * 1024;
    } catch (error) {
      InstallTrace.error('du', 'failed: $error');
      return null;
    }
  }

  @override
  Future<void> clearQuarantine(Directory runtimeDir) async {
    await Process.run('/usr/bin/xattr', <String>['-dr', 'com.apple.quarantine', runtimeDir.path]);
  }

  @override
  Future<String> describeMachine() async {
    try {
      final model = await Process.run('/usr/sbin/sysctl', <String>['-n', 'hw.model']);
      final arch = await Process.run('/usr/bin/uname', <String>['-m']);
      return '${(model.stdout as String).trim()} ${(arch.stdout as String).trim()}';
    } catch (_) {
      return Platform.operatingSystemVersion;
    }
  }

  @override
  Future<List<int>> findListenPorts(String exeNameContains) async {
    try {
      final result = await Process.run('/usr/sbin/lsof', <String>['-nP', '-iTCP', '-sTCP:LISTEN']);
      final ports = <int>[];
      for (final line in (result.stdout as String).split('\n')) {
        if (!line.contains(exeNameContains)) continue;
        final m = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(line);
        if (m != null) ports.add(int.parse(m.group(1)!));
      }
      return ports;
    } catch (_) {
      return const <int>[];
    }
  }

  @override
  Future<void> openExternally(String target) async {
    await Process.run('/usr/bin/open', <String>[target]);
  }
}

/// Windows：用系统自带的 tar.exe（Windows 10 1803+ 内置 bsdtar）。
class WindowsPlatformServices extends PlatformServices {
  const WindowsPlatformServices();

  /// Windows 自带 tar.exe 的绝对路径（System32）；不在时退回 PATH 里的 tar。
  static String get _tarExe {
    final systemTar = '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\tar.exe';
    return File(systemTar).existsSync() ? systemTar : 'tar';
  }

  @override
  Future<Directory> extractTarGz(
    File archive,
    Directory destination, {
    int totalBytes = 0,
    ExtractProgress? onProgress,
  }) async {
    await destination.create(recursive: true);
    // `tar -xzf <archive> -C <dir>`：bsdtar 与 GNU tar 参数一致。
    final (tar, errors) = await startTar(_tarExe, <String>['-xzf', archive.path, '-C', destination.path]);
    Timer? poll;
    if (totalBytes > 0 && onProgress != null) {
      poll = Timer.periodic(const Duration(milliseconds: 400), (_) async {
        final size = await directorySize(destination);
        if (size != null) onProgress(size.clamp(0, totalBytes));
      });
    }
    final code = await tar.exitCode;
    poll?.cancel();
    endTar(code, errors);
    if (code != 0) throw StateError('tar.exe exited with $code');
    return Directory('${destination.path}${Platform.pathSeparator}runtime');
  }

  @override
  Future<int?> directorySize(Directory dir) async {
    // Windows 没有 du；递归求和。目录很大时有点慢，但 400ms 一次可接受。
    try {
      var total = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // 被占用的文件跳过。
          }
        }
      }
      return total;
    } catch (error) {
      InstallTrace.error('size', 'directorySize(${dir.path}) failed: $error');
      return null;
    }
  }

  @override
  Future<void> clearQuarantine(Directory runtimeDir) async {
    // Windows 没有 quarantine 扩展属性机制（SmartScreen 是另一条路径，且
    // 只作用于下载来的文件，我们自己拷出来的不受影响）。
  }

  @override
  Future<String> describeMachine() async {
    final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'x64';
    return '${Platform.operatingSystemVersion} $arch';
  }

  @override
  Future<List<int>> findListenPorts(String exeNameContains) async {
    try {
      // netstat -ano 的 LISTENING 行形如：
      //   TCP    127.0.0.1:62680        0.0.0.0:0              LISTENING       12345
      final result = await Process.run('netstat', <String>['-ano', '-p', 'TCP']);
      final listeners = _parseNetstatWithPid(result.stdout as String);
      if (listeners.isEmpty) return const <int>[];
      // 必须按进程名过滤：以前这里把所有回环端口都返回了，于是随便一个监听
      // 127.0.0.1 的进程（实测是 adb 的 5037）都会被当成「正在运行的官方 DSH」，
      // 接着签 cookie 去连它，最后报「官方 DSH 初始化失败」。
      final names = await _processNames();
      final want = exeNameContains.toLowerCase();
      return <int>[
        for (final entry in listeners)
          if ((names[entry.pid] ?? '').toLowerCase().contains(want)) entry.port,
      ];
    } catch (error) {
      InstallTrace.error('ports', 'findListenPorts failed: $error');
      return const <int>[];
    }
  }

  /// PID → 进程名（一次 tasklist，比逐个查快）。
  static Future<Map<int, String>> _processNames() async {
    final out = <int, String>{};
    try {
      final result = await Process.run('tasklist', <String>['/FO', 'CSV', '/NH']);
      for (final line in (result.stdout as String).split('\n')) {
        final cols = RegExp(r'"([^"]*)"').allMatches(line).map((m) => m.group(1)!).toList();
        if (cols.length < 2) continue;
        final pid = int.tryParse(cols[1]);
        if (pid != null) out[pid] = cols[0];
      }
    } catch (_) {}
    return out;
  }

  /// 端口 + 所属 PID。
  static List<({int port, int pid})> _parseNetstatWithPid(String output) {
    final out = <({int port, int pid})>[];
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('TCP')) continue;
      if (!trimmed.contains('LISTENING')) continue;
      final m = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(trimmed);
      final pid = int.tryParse(trimmed.split(RegExp(r'\s+')).last);
      if (m != null && pid != null) out.add((port: int.parse(m.group(1)!), pid: pid));
    }
    return out;
  }

  @override
  Future<void> openExternally(String target) async {
    await Process.run('cmd', <String>['/c', 'start', '', target]);
  }
}

/// Linux：与 macOS 同样的 daemon 等价物（GNU coreutils / iproute2 / xdg-utils）。
class LinuxPlatformServices extends PlatformServices {
  const LinuxPlatformServices();

  @override
  Future<Directory> extractTarGz(
    File archive,
    Directory destination, {
    int totalBytes = 0,
    ExtractProgress? onProgress,
  }) async {
    await destination.create(recursive: true);
    final (tar, errors) = await startTar('tar', <String>['-xzf', archive.path, '-C', destination.path]);
    Timer? poll;
    if (totalBytes > 0 && onProgress != null) {
      poll = Timer.periodic(const Duration(milliseconds: 400), (_) async {
        final size = await directorySize(destination);
        if (size != null) onProgress(size.clamp(0, totalBytes));
      });
    }
    final code = await tar.exitCode;
    poll?.cancel();
    endTar(code, errors);
    if (code != 0) throw StateError('tar exited with $code');
    return Directory('${destination.path}/runtime');
  }

  @override
  Future<int?> directorySize(Directory dir) async {
    try {
      final du = await Process.run('du', <String>['-sk', dir.path]);
      final kb = int.tryParse((du.stdout as String).trim().split(RegExp(r'\s+')).first) ?? 0;
      return kb * 1024;
    } catch (error) {
      InstallTrace.error('du', 'failed: $error');
      return null;
    }
  }

  @override
  Future<void> clearQuarantine(Directory runtimeDir) async {
    // Linux 上没有 quarantine 标记。
  }

  @override
  Future<String> describeMachine() async {
    try {
      final arch = await Process.run('uname', <String>['-m']);
      return '${Platform.operatingSystemVersion} ${(arch.stdout as String).trim()}';
    } catch (_) {
      return Platform.operatingSystemVersion;
    }
  }

  @override
  Future<List<int>> findListenPorts(String exeNameContains) async {
    try {
      // `ss -ltnp` 的进程信息在尖括号里：users:(("node",pid=123,fd=20))
      final result = await Process.run('ss', <String>['-ltnp']);
      final ports = <int>[];
      for (final line in (result.stdout as String).split('\n')) {
        if (!line.contains(exeNameContains)) continue;
        final m = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(line);
        if (m != null) ports.add(int.parse(m.group(1)!));
      }
      return ports;
    } catch (_) {
      return const <int>[];
    }
  }

  @override
  Future<void> openExternally(String target) async {
    await Process.run('xdg-open', <String>[target]);
  }
}
