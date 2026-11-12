// 引擎库的磁盘策略：只留该留的版本，删掉的要真的释放空间，注册表要跟着更新。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/dsh_engines.dart';
import 'package:flutter_test/flutter_test.dart';

String _sep = Platform.pathSeparator;

Future<DshEngine> fakeEngine(Directory root, String version, {int payloadBytes = 4096}) async {
  final dir = Directory('${root.path}$_sep$version');
  final dsh = Directory('${dir.path}${_sep}node_modules${_sep}@deepseek-ai${_sep}dsh${_sep}lib');
  await dsh.create(recursive: true);
  await File('${dsh.parent.path}${_sep}package.json').writeAsString(
    jsonEncode({'name': '@deepseek-ai/dsh', 'version': version}),
  );
  await File('${dsh.path}${_sep}bin.js').writeAsString('// entry\n');
  await File('${dir.path}${_sep}payload.bin').writeAsBytes(List<int>.filled(payloadBytes, 0x41));
  return DshEngine(
    version: version,
    path: dir.path,
    source: 'npm',
    installedAt: DateTime.now(),
    patchSummary: {'ok': 105, 'total': 105, 'lost': <String>[]},
  );
}

void main() {
  test('list() 读注册表，并按版本从新到旧', () async {
    final root = await Directory.systemTemp.createTemp('dsh-store-');
    final store = DshEngineStore(root);
    await store.ensure();
    await store.register(await fakeEngine(root, '0.2.1-rc.4'));
    await store.register(await fakeEngine(root, '0.2.2-rc.1'));
    final engines = await store.list();
    expect(engines.map((e) => e.version).toList(), ['0.2.2-rc.1', '0.2.1-rc.4']);
  });

  test('prune 只留点名 + 最新 N 个，并报告释放的字节数', () async {
    final root = await Directory.systemTemp.createTemp('dsh-store-');
    final store = DshEngineStore(root);
    await store.ensure();
    for (final version in ['0.2.0', '0.2.1', '0.2.2']) {
      await store.register(await fakeEngine(root, version, payloadBytes: 8192));
    }
    // 保留点名的一版 + 最新一版
    final freed = await store.prune(keep: {'0.2.0'}, keepNewest: 1);
    final left = (await store.list()).map((e) => e.version).toList();
    expect(left, containsAll(['0.2.0', '0.2.2']));
    expect(left, isNot(contains('0.2.1')));
    expect(freed, greaterThan(0));
    expect(Directory('${root.path}$_sep' '0.2.1').existsSync(), isFalse);
  });

  test('目录里躺着但没登记的版本会被补登记，便于清理', () async {
    final root = await Directory.systemTemp.createTemp('dsh-store-');
    final store = DshEngineStore(root);
    await store.ensure();
    final engine = await fakeEngine(root, '0.2.3-rc.1');
    final listed = await store.list();
    expect(listed.single.version, '0.2.3-rc.1');
    expect(listed.single.path, engine.path);
  });
}
