import 'package:family_life_assistant/data/db.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 内存版数据库与真实实现的语义一致性。
///
/// 存在理由：widget 测试一律注入 [FakeDb]（桌面没有 SQLite 原生库），所以
/// **测试里跑的是 FakeDb，用户手机上跑的是 SqfliteDb**。两者语义一旦不一致，
/// 测试就在为一份不存在的实现盖章。
///
/// 这不是假想风险：`FakeDb` 曾经把 [T.passwords] 和 [T.conversations] 合并成
/// 同一个排序分支，按 `updatedAt` 排序，而 `passwords` 表**根本没有这一列**
/// （真实排序是 `createdAt DESC`）。读不存在的键返回 `''`，所有记录比较结果都
/// 相等，断言照样通过 —— **不一致的方向恰好让测试永远绿**，是最坏的一种失效。
///
/// 现在 FakeDb 的排序直接由 [localDbOrder] 推导，这些测试守住推导结果。
void main() {
  group('FakeDb 排序复刻真实 ORDER BY', () {
    test('expenses 按 spentAt 倒序（最新的在最前）', () {
      final db = FakeDb();
      final cmp = db.comparatorFor(T.expenses);
      final older = {'id': '1', 'spentAt': '2026-01-01T00:00:00.000'};
      final newer = {'id': '2', 'spentAt': '2026-06-01T00:00:00.000'};
      expect(cmp(older, newer), greaterThan(0), reason: '旧的应排在后面');
      expect(cmp(newer, older), lessThan(0));
    });

    test('passwords 按 createdAt 倒序，且不读不存在的 updatedAt 列', () {
      final db = FakeDb();
      final cmp = db.comparatorFor(T.passwords);
      // 只给 createdAt：如果实现还在按 updatedAt 排序，两条会被判为相等
      final older = {'id': '1', 'createdAt': '2026-01-01T00:00:00.000'};
      final newer = {'id': '2', 'createdAt': '2026-06-01T00:00:00.000'};
      expect(
        cmp(older, newer),
        greaterThan(0),
        reason: '按 createdAt 倒序时旧的排后面；返回 0 说明读错了列',
      );
      expect(cmp(newer, older), lessThan(0));
    });

    test('conversations 按 updatedAt 倒序', () {
      final db = FakeDb();
      final cmp = db.comparatorFor(T.conversations);
      final older = {'id': '1', 'updatedAt': '2026-01-01T00:00:00.000'};
      final newer = {'id': '2', 'updatedAt': '2026-06-01T00:00:00.000'};
      expect(cmp(older, newer), greaterThan(0));
    });

    test('chats 按 createdAt 正序（消息按时间从上往下）', () {
      final db = FakeDb();
      final cmp = db.comparatorFor(T.chats);
      final first = {'id': '1', 'createdAt': '2026-01-01T00:00:00.000'};
      final second = {'id': '2', 'createdAt': '2026-06-01T00:00:00.000'};
      expect(cmp(first, second), lessThan(0));
    });

    test('meds 空过期日排最后，其余按过期日正序', () {
      final db = FakeDb();
      final cmp = db.comparatorFor(T.meds);
      final noExpiry = {'id': '1', 'expiry': ''};
      final soon = {'id': '2', 'expiry': '2026-06-01'};
      final later = {'id': '3', 'expiry': '2027-01-01'};
      expect(cmp(soon, later), lessThan(0), reason: '快到期的排前面');
      expect(cmp(noExpiry, soon), greaterThan(0), reason: '没有过期日的排最后');
      expect(cmp(noExpiry, later), greaterThan(0));
    });
  });

  group('排序来源是真实的 localDbOrder', () {
    test('每张业务表都有排序定义，FakeDb 不会退回默认分支', () {
      // 没有定义时 comparatorFor 会退化成「全部相等」——那正是让测试永远绿的
      // 失效模式。所以这里要求每张表都必须显式定义。
      for (final table in localDbTables) {
        expect(
          localDbOrder[table],
          isNotNull,
          reason: '$table 没有 ORDER BY 定义，FakeDb 会退化成无序',
        );
      }
    });

    test('无法解析的 ORDER BY 段会被跳过，而不是按错列排序', () {
      final db = FakeDb();
      // chats 的定义是 'createdAt ASC'，解析出来必须是用 createdAt 比较
      final cmp = db.comparatorFor(T.chats);
      final a = {'id': '1', 'createdAt': '2026-01-01', 'updatedAt': '2030-01-01'};
      final b = {'id': '2', 'createdAt': '2026-02-01', 'updatedAt': '2020-01-01'};
      expect(
        cmp(a, b),
        lessThan(0),
        reason: '必须用 createdAt 比较；若用了 updatedAt，结果会反过来',
      );
    });
  });
}
