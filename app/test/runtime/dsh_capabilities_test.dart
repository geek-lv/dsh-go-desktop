// 补丁 → 功能映射的判定规则：缺哪几个补丁就少哪些功能，不多不少。

import 'package:dsh_app/runtime/dsh_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('没打补丁（复用外部核心 / 官方原样）→ 所有补丁功能都算缺失', () {
    final caps = DshCapabilities.fromSummary(null);
    expect(caps.patched, isFalse);
    expect(caps.complete, isFalse);
    expect(caps.missing.length, kDshCapabilities.length);
    expect(caps.available('session-deletion'), isFalse);
  });

  test('补丁完整 → 没有任何缺失', () {
    final caps = DshCapabilities.fromSummary({'ok': 105, 'total': 105, 'lost': <String>[]});
    expect(caps.complete, isTrue);
    expect(caps.missing, isEmpty);
    expect(caps.available('session-deletion'), isTrue);
  });

  test('只缺会话删除那个补丁 → 只少「删除会话」', () {
    final caps = DshCapabilities.fromSummary({
      'ok': 104,
      'total': 105,
      'lost': ['zzzzzz-session-deletion.diff'],
    });
    expect(caps.complete, isFalse);
    expect(caps.missing.map((c) => c.id), ['session-deletion']);
    expect(caps.available('session-deletion'), isFalse);
    expect(caps.available('plugin-config'), isTrue);
  });

  test('缺一个插件相关补丁 → 整项功能算缺（同一功能的补丁是 AND 关系）', () {
    final caps = DshCapabilities.fromSummary({
      'ok': 103,
      'total': 105,
      'lost': ['zzzzz-plugin-config-bundles.diff'],
    });
    expect(caps.missing.map((c) => c.id), ['plugin-config']);
    expect(caps.available('plugin-config'), isFalse);
    expect(caps.available('plugin-install'), isTrue);
  });

  test('未知功能 id 不受补丁影响', () {
    final caps = DshCapabilities.fromSummary({'ok': 0, 'total': 1, 'lost': ['x.diff']});
    expect(caps.available('something-else'), isTrue);
  });
}
