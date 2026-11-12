// `lib/runtime/dsh_discovery.dart` 的单测：探测规则、版本比较、兼容判定。
//
// 全部在临时目录里造假前缀，不依赖本机真的装了 DSH。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/dsh_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

String _sep = Platform.pathSeparator;

/// 造一个 npm 前缀，里面放一份 `@deepseek-ai/dsh`。
Future<String> fakePrefix(
  Directory root,
  String name, {
  String version = '0.2.2-rc.1',
  String packageName = '@deepseek-ai/dsh',
  bool entry = true,
  bool manifest = true,
}) async {
  final prefix = '${root.path}$_sep$name';
  final dir = Directory('$prefix${_sep}node_modules${_sep}@deepseek-ai${_sep}dsh');
  await Directory('${dir.path}${_sep}lib').create(recursive: true);
  if (manifest) {
    await File('${dir.path}${_sep}package.json').writeAsString(
      jsonEncode({'name': packageName, 'version': version}),
    );
  }
  if (entry) await File('${dir.path}${_sep}lib${_sep}bin.js').writeAsString('// entry\n');
  return prefix;
}

void main() {
  test('探测到 npm 全局目录里的核心，并读出版本与入口', () async {
    final root = await Directory.systemTemp.createTemp('dsh-disc-');
    final appData = Directory('${root.path}${_sep}appdata');
    await fakePrefix(appData, 'npm'); // %APPDATA%\npm\node_modules

    final candidates = await DshDiscovery.scan(environment: {'APPDATA': appData.path}, userHome: root.path);
    final usable = candidates.where((c) => c.usable).toList();
    expect(usable, isNotEmpty);
    final dsh = usable.first.dsh!;
    expect(dsh.version, '0.2.2-rc.1');
    expect(dsh.source, 'npm-global');
    expect(File(dsh.binScript).existsSync(), isTrue);
  });

  test('不可用的前缀要给出原因，而不是静默丢弃', () async {
    final root = await Directory.systemTemp.createTemp('dsh-disc-');
    final appData = Directory('${root.path}${_sep}appdata');
    await fakePrefix(appData, 'npm', entry: false); // 缺 lib/bin.js

    final candidates = await DshDiscovery.scan(environment: {'APPDATA': appData.path}, userHome: root.path);
    final mine = candidates.where((c) => c.prefix.contains('npm')).toList();
    expect(mine, isNotEmpty);
    expect(mine.every((c) => !c.usable), isTrue);
    expect(mine.first.reason, 'no-entry');
  });

  test('包名不对时不算可用', () async {
    final root = await Directory.systemTemp.createTemp('dsh-disc-');
    final prefix = await fakePrefix(root, 'weird', packageName: 'other-pkg');
    final candidate = await DshDiscovery.probePrefix(prefix, source: 'user');
    expect(candidate.usable, isFalse);
    expect(candidate.reason, 'wrong-package');
  });

  test('用户手填的前缀优先，且扫描结果去重', () async {
    final root = await Directory.systemTemp.createTemp('dsh-disc-');
    final appData = Directory('${root.path}${_sep}appdata');
    final prefix = await fakePrefix(appData, 'npm');
    final candidates = await DshDiscovery.scan(
      environment: {'APPDATA': appData.path},
      userHome: root.path,
      extraPrefixes: [prefix],
    );
    expect(candidates.first.source, 'user');
    final keys = candidates.map((c) => c.prefix.toLowerCase()).toList();
    expect(keys.toSet().length, keys.length, reason: '前缀不应重复');
  });

  test('多个候选按版本从新到旧', () async {
    final root = await Directory.systemTemp.createTemp('dsh-disc-');
    final older = await fakePrefix(Directory('${root.path}${_sep}a'), 'p', version: '0.2.1-rc.4');
    final newer = await fakePrefix(Directory('${root.path}${_sep}b'), 'p', version: '0.2.2');
    final usable = await DshDiscovery.scanUsable(
      environment: const {},
      userHome: root.path,
      extraPrefixes: [older, newer],
    );
    expect(usable.map((d) => d.version).toList(), ['0.2.2', '0.2.1-rc.4']);
  });

  test('版本比较：数字段、预发布、正式版', () {
    expect(compareVersions('0.2.2', '0.2.1'), greaterThan(0));
    expect(compareVersions('0.2.10', '0.2.9'), greaterThan(0));
    expect(compareVersions('0.2.2-rc.1', '0.2.2'), lessThan(0));
    expect(compareVersions('0.2.2-rc.2', '0.2.2-rc.1'), greaterThan(0));
    expect(compareVersions('0.2.2-rc.1', '0.2.2-rc.1'), 0);
    expect(compareVersions('v0.2.2', '0.2.2'), 0);
    expect(compareVersions('0.2.2-beta.1', '0.2.2-rc.1'), lessThan(0));
  });

  test('兼容判定：审查过的版本才算 vetted', () {
    expect(DshDiscovery.classify('0.2.2-rc.1', vetted: {'0.2.2-rc.1'}), CoreCompat.vetted);
    expect(DshDiscovery.classify('0.2.3-rc.1', vetted: {'0.2.2-rc.1'}), CoreCompat.otherVersion);
  });
}
