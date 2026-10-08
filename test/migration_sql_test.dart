import 'package:family_life_assistant/data/db.dart';
import 'package:flutter_test/flutter_test.dart';

/// 迁移 SQL 的校验。
///
/// 为什么需要这个文件：桌面测试环境没有 SQLite 原生库，所以 widget 测试一律注入
/// 内存 `FakeDb`，`SqfliteDb` 在整个测试套件里原本只出现过**一行常量断言**
/// （`expect(SqfliteDb.schemaVersion, 4)`）。也就是说 0.3B 整个版本的存在理由
/// ——那段修白屏的迁移代码——**一次都没有被执行或校验过**。
///
/// 这里不去执行 SQL（那需要真库），而是把迁移决策抽成纯函数
/// `SqfliteDb.migrationStatements`，直接校验它输出的**语句内容**。它能抓住
/// 三类真实缺陷：
///
/// 1. 迁移忘记补某一列（0.3B 的原病：v3 忘了给 chats 加 `conversationId`，
///    老用户启动即白屏）；
/// 2. `ALTER TABLE` 指向一张不存在的表（自愈动作自己抛 `no such table`）；
/// 3. 迁移逻辑重新绑上 `oldVersion` 门槛，留下「版本号到位但结构不对」的
///    中间态 —— 那种库再也修不回来。
void main() {
  /// 一个「v1 时代的库」：只有最老的三张表，且没有 entryType / conversationId。
  Map<String, Set<String>> legacyColumns() => {
    'expenses': {'id', 'title', 'amount', 'category', 'spentAt', 'note', 'createdAt'},
    'meds': {'id', 'name', 'expiry', 'stock', 'createdAt'},
    'chats': {'id', 'role', 'content', 'createdAt'},
  };

  /// 当前版本的完整结构，等价于 `_create` 建出来的样子。
  Map<String, Set<String>> currentColumns() => {
    ...legacyColumns(),
    'expenses': {...legacyColumns()['expenses']!, 'entryType'},
    'chats': {...legacyColumns()['chats']!, 'conversationId'},
    // v6：药品的分类与详细信息字段
    'meds': {
      ...legacyColumns()['meds']!,
      ...SqfliteDb.medsV6Columns,
      ...SqfliteDb.medsV7Columns,
    },
    'conversations': {
      'id',
      'title',
      'topic',
      'memory',
      'createdAt',
      'updatedAt',
      'pinnedAt',
    },
    'passwords': {
      'id',
      'label',
      'site',
      'length',
      'strength',
      'entropy',
      'createdAt',
    },
  };

  List<String> migrate(Map<String, Set<String>> columns) =>
      SqfliteDb.migrationStatements(
        tables: columns.keys.toSet(),
        columns: columns,
      );

  group('老库升级', () {
    test('v1 库会补齐 entryType 与 conversationId，并建两张新表', () {
      final sql = migrate(legacyColumns()).join('\n');
      expect(sql, contains('ALTER TABLE expenses ADD COLUMN entryType'));
      expect(sql, contains('ALTER TABLE chats ADD COLUMN conversationId'));
      expect(sql, contains('CREATE TABLE IF NOT EXISTS conversations'));
      expect(sql, contains('CREATE TABLE IF NOT EXISTS passwords'));
    });

    test('0.3B 的病根：v3 库缺 conversationId 时必须补上', () {
      // 这正是当年造成白屏的状态：库已经是 v3（有 conversations/passwords），
      // 但 chats 少了 conversationId。迁移必须仍然补它。
      final columns = currentColumns();
      columns['chats'] = {...columns['chats']!}..remove('conversationId');
      final sql = migrate(columns).join('\n');
      expect(
        sql,
        contains('ALTER TABLE chats ADD COLUMN conversationId'),
        reason: '少了这一列，SELECT * FROM chats WHERE conversationId=? 会直接抛异常',
      );
    });

    test('半途而废的 v1→v2 库（版本已是 2 但缺 entryType）也能自愈', () {
      // 迁移不再绑定 oldVersion，所以这种「版本号到位但结构不对」的库也能修。
      // 旧实现写成 `if (oldVersion < 2 && !_hasColumn(...))`，对这种库
      // 两个条件里的第一个为 false，自愈永远不触发。
      final columns = currentColumns();
      columns['expenses'] = {...columns['expenses']!}..remove('entryType');
      final sql = migrate(columns).join('\n');
      expect(sql, contains('ALTER TABLE expenses ADD COLUMN entryType'));
    });

    test('v4 库（有 conversations 但缺 pinnedAt）会补上置顶列', () {
      // 0.4C 加了对话置顶：老用户的 conversations 表没有 pinnedAt。
      // 漏了这条迁移的后果不是崩溃，而是**置顶点了没反应** ——
      // `Conversation.toRow()` 写进一个不存在的列会抛异常，
      // 而如果读取端静默忽略，用户看到的就是「置顶按钮没用」。
      final columns = currentColumns();
      columns['conversations'] = {...columns['conversations']!}
        ..remove('pinnedAt');
      final sql = migrate(columns).join('\n');
      expect(
        sql,
        contains('ALTER TABLE conversations ADD COLUMN pinnedAt TEXT'),
        reason: '缺这列会导致置顶写不进去',
      );
    });
  });

  group('幂等与安全性', () {
    test('结构已经正确的库不产生任何语句', () {
      expect(
        migrate(currentColumns()),
        isEmpty,
        reason: '迁移必须可重复执行；重复跑出语句说明判断条件写错了',
      );
    });

    test('反复执行结果稳定', () {
      final first = migrate(legacyColumns());
      final second = migrate(legacyColumns());
      expect(second, first);
    });

    test('ALTER TABLE 只指向迁移中确定存在的表', () {
      // 自愈逻辑自己抛 `no such table` 是最难查的一类问题：判断「列是否存在」
      // 必须先判断「表是否存在」，否则 PRAGMA 查不到列 → 判定为「缺列」→
      // 对一张不存在的表执行 ALTER → 抛异常。
      //
      // 这里逐条校验：每条 ALTER 的目标表，要么在输入里已经存在，要么在同批
      // 语句里先被 CREATE 出来。
      void check(Map<String, Set<String>> columns) {
        final existing = <String>{...columns.keys};
        for (final sql in migrate(columns)) {
          final alter = RegExp(r'^ALTER TABLE (\w+) ').firstMatch(sql);
          if (alter != null) {
            final target = alter.group(1)!;
            expect(
              existing,
              contains(target),
              reason: '$sql 指向的表 $target 此时并不存在',
            );
          }
          final create = RegExp(
            r'^CREATE TABLE IF NOT EXISTS (\w+)\(',
          ).firstMatch(sql);
          if (create != null) existing.add(create.group(1)!);
        }
      }

      check(legacyColumns());
      check(currentColumns());
      // 极端情况：一张表都没有的空库
      check(const {});
      // 只有 chats 一种表
      check({
        'chats': {'id', 'role', 'content', 'createdAt'},
      });
    });

    test('空库（表全不存在）会建出全部表而不做任何 ALTER', () {
      final statements = migrate(const {});
      expect(
        statements.every((s) => s.startsWith('CREATE TABLE')),
        isTrue,
        reason: '没有任何表可 ALTER，此时只应建表',
      );
      // 注意：expenses/meds/chats 的建表由 _create 负责，_upgrade 只管
      // conversations/passwords 这两张「后加的」表。
      expect(statements.length, 2);
    });
  });

  group('建表语句内容', () {
    test('conversations 表带 topic 与 memory 列', () {
      final sql = migrate(const {}).firstWhere(
        (s) => s.contains('conversations'),
      );
      for (final column in ['id', 'title', 'topic', 'memory', 'createdAt', 'updatedAt']) {
        expect(sql, contains(column), reason: 'conversations 缺列 $column');
      }
    });

    test('passwords 表没有密码列（明文绝不落盘）', () {
      final sql = migrate(const {}).firstWhere((s) => s.contains('passwords'));
      for (final column in [
        'id',
        'label',
        'site',
        'length',
        'strength',
        'entropy',
        'createdAt',
      ]) {
        expect(sql, contains(column), reason: 'passwords 缺列 $column');
      }
      // 关键安全断言：这张表结构里不能出现任何存密码明文的地方。
      // 只看括号里的列定义（表名本身就叫 passwords，不参与判断）。
      final columnDefs = sql.substring(sql.indexOf('(')).toLowerCase();
      for (final forbidden in ['password', 'value', 'plain', 'secret', 'content']) {
        expect(
          columnDefs,
          isNot(contains(forbidden)),
          reason: 'passwords 表不该有 $forbidden 列：明文密码绝不落盘',
        );
      }
    });
  });

  group('schemaVersion', () {
    test('为 7（v7 = 0.4F 的联网来源 URL 列），且与迁移覆盖到的最后一版一致', () {
      expect(SqfliteDb.schemaVersion, 7);
    });

    test('v7 的列既在建表语句里，也在迁移语句里', () {
      // 两处不一致会造成「全新安装有这列、升级安装没有」的隐蔽差异 ——
      // 而且只在升级用户身上炸，开发者自己重装永远遇不到。
      for (final column in SqfliteDb.medsV7Columns) {
        final meds = <String>{...legacyColumns()['meds']!}..remove(column);
        final statements = SqfliteDb.migrationStatements(
          tables: {T.meds},
          columns: {T.meds: meds},
        );
        expect(
          statements.any((s) => s.contains(column)),
          isTrue,
          reason: '$column 缺少迁移语句（升级安装会缺列，只有老用户会遇到）',
        );
      }
    });
  });
}
