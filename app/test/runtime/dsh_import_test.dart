// 从官方 DSH 的 `.dsh` 导入对话/工作区：只做加法、重复执行安全。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/dsh_import.dart';
import 'package:flutter_test/flutter_test.dart';

String _sep = Platform.pathSeparator;

Future<Directory> fakeDsh(Directory root, String name) async {
  final dir = Directory('${root.path}$_sep$name');
  final session = Directory('${dir.path}${_sep}sessions${_sep}--C-Works--');
  await session.create(recursive: true);
  await File('${session.path}${_sep}session-1.jsonl').writeAsString('{"type":"user"}\n');
  final storages = Directory('${dir.path}${_sep}storages');
  await storages.create(recursive: true);
  await File('${storages.path}${_sep}workspace.json').writeAsString(jsonEncode({'schema': 1}));
  return dir;
}

void main() {
  test('导入 sessions/storages，已有文件不覆盖，重复执行幂等', () async {
    final root = await Directory.systemTemp.createTemp('dsh-import-');
    final source = await fakeDsh(root, 'official');
    final target = Directory('${root.path}${_sep}app')..createSync(recursive: true);

    expect(await DshImport.countWorkspaces(source), 1);

    // workspace.json 走合并而不是文件拷贝，所以文件数只算会话文件。
    final first = await DshImport.importFrom(source: source, target: target);
    expect(first.files, 1);
    expect(first.skipped, 0);
    expect(first.sessionWorkspaces, 1);
    expect(
      File('${target.path}${_sep}sessions${_sep}--C-Works--${_sep}session-1.jsonl').existsSync(),
      isTrue,
    );

    // 目标里改过的会话文件不会被源覆盖；workspace.json 单独走合并（不整文件拷）
    await File('${target.path}${_sep}sessions${_sep}--C-Works--${_sep}session-1.jsonl')
        .writeAsString('{"type":"changed"}\n');
    final second = await DshImport.importFrom(source: source, target: target);
    expect(second.files, 0);
    expect(second.skipped, 1);
    expect(
      await File('${target.path}${_sep}sessions${_sep}--C-Works--${_sep}session-1.jsonl').readAsString(),
      '{"type":"changed"}\n',
    );
  });

  test('源里没有 sessions 时不报错，返回 0', () async {
    final root = await Directory.systemTemp.createTemp('dsh-import-');
    final empty = Directory('${root.path}${_sep}empty')..createSync(recursive: true);
    final target = Directory('${root.path}${_sep}app')..createSync(recursive: true);
    final result = await DshImport.importFrom(source: empty, target: target);
    expect(result.files, 0);
    expect(result.sessionWorkspaces, 0);
  });

  test('工作区注册表按 id 合并：两边都不丢，目标已有的行优先', () async {
    final root = await Directory.systemTemp.createTemp('dsh-import-');
    final source = Directory('${root.path}${_sep}official')..createSync(recursive: true);
    final target = Directory('${root.path}${_sep}app')..createSync(recursive: true);
    Directory('${source.path}${_sep}storages').createSync(recursive: true);
    Directory('${target.path}${_sep}storages').createSync(recursive: true);
    await File('${source.path}${_sep}storages${_sep}workspace.json').writeAsString(jsonEncode({
      'unit': {'name': 'workspace', 'version': 2},
      'global': {
        'initialized': true,
        'workspaceIds': ['a', 'b'],
        'archivedSessionIds': ['s2'],
        'pinnedSessionIds': [],
      },
      'tables': {
        'workspaces': {
          'a': {'path': r'C:\Works', 'name': 'official-a'},
          'b': {'path': r'C:\Works\SpaceWalkerForPC'},
        },
      },
    }));
    await File('${target.path}${_sep}storages${_sep}workspace.json').writeAsString(jsonEncode({
      'unit': {'name': 'workspace', 'version': 2},
      'global': {
        'initialized': true,
        'workspaceIds': ['a'],
        'archivedSessionIds': ['s1'],
        'pinnedSessionIds': ['s9'],
      },
      'tables': {
        'workspaces': {
          'a': {'path': r'C:\Works', 'name': 'app-a'},
        },
      },
    }));

    await DshImport.importFrom(source: source, target: target);
    final merged =
        jsonDecode(await File('${target.path}${_sep}storages${_sep}workspace.json').readAsString()) as Map;
    final workspaces = (merged['tables'] as Map)['workspaces'] as Map;
    expect(workspaces.keys.toSet(), {'a', 'b'});
    // 目标里已有的行不被覆盖
    expect((workspaces['a'] as Map)['name'], 'app-a');
    final global = merged['global'] as Map;
    expect((global['workspaceIds'] as List).toSet(), {'a', 'b'});
    expect((global['archivedSessionIds'] as List).toSet(), {'s1', 's2'});
    expect((global['pinnedSessionIds'] as List).toSet(), {'s9'});
  });
}
