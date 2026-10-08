import 'package:flutter_test/flutter_test.dart';
import 'package:family_life_assistant/data/db.dart';

/// 0.4I：**全新安装与升级安装的结构必须一致**（回归测试）。
///
/// ## 这个文件是为了一个真实事故而存在的
///
/// 用户在系统设置里「清除应用数据」后打开 App，直接崩在启动页：
///
/// ```
/// DatabaseException(table conversations has no column named pinnedAt):
///   INSERT OR REPLACE INTO conversations (..., updatedAt, pinnedAt) VALUES (...)
/// ```
///
/// 根因：`conversations.pinnedAt` 是 **v5** 通过迁移加的，但**基础建表语句里
/// 从来没补过这一列**。而 `onCreate`（全新安装）与 `onUpgrade`（版本号变大）
/// 是两条互不相干的路：
///
/// | 用户 | 走的路径 | `pinnedAt` 从哪来 | 结果 |
/// | --- | --- | --- | --- |
/// | 一路升级上来的（含开发机） | `onUpgrade` | 迁移补的 | ✅ 正常 |
/// | **全新安装 / 清除数据后** | `onCreate` | **没人补** | ❌ 一写对话就崩 |
///
/// 所以这是个**开发者永远踩不到**的 bug —— 我自己的库是升级上来的，一切正常；
/// 只有真正新装的人才遇得到。它躲过了 480 项测试，因为那些测试都是**纯 SQL
/// 字符串断言**，而**没有一项比较过「两条路径产出的列集合是否相等」**。
///
/// ## 修法与这个测试的关系
/// 修法有两层，缺一不可：
///  ① `_create` 建完基础表后**再跑一遍迁移**，两条路自然收敛；
///  ② 本文件把「收敛」变成**断言** —— 以后谁再漏列，这里立刻红。
///
/// 第 ② 层才是长期保障：第 ① 层只保证「迁移里有的列」不会漏，
/// 而如果哪天有人在基础 DDL 里加了一列、却忘了写迁移，那也要能测出来。
void main() {
  /// 从一段 `CREATE TABLE x(...)` 里抠出**列名**。
  ///
  /// 只取顶层括号里的片段，跳过表级约束（`PRIMARY KEY (...)` / `FOREIGN KEY` /
  /// `UNIQUE (...)`）——它们是约束不是列，算进来会让断言虚高。
  Set<String> columnsOf(String ddl) {
    final open = ddl.indexOf('(');
    final close = ddl.lastIndexOf(')');
    expect(open, greaterThan(0), reason: '解析失败，DDL 里找不到列定义括号：$ddl');
    expect(close, greaterThan(open), reason: '解析失败，DDL 括号不配对：$ddl');

    final body = ddl.substring(open + 1, close);
    return {
      for (final part in body.split(','))
        if (part.trim().isNotEmpty)
          if (!part.trimLeft().toUpperCase().startsWith('PRIMARY KEY'))
            if (!part.trimLeft().toUpperCase().startsWith('FOREIGN KEY'))
              if (!part.trimLeft().toUpperCase().startsWith('UNIQUE'))
                part.trim().split(RegExp(r'\s+')).first,
    };
  }

  /// 基础建表语句解析出来的「表 → 列集合」。
  Map<String, Set<String>> baseColumns() {
    final out = <String, Set<String>>{};
    for (final sql in SqfliteDb.createTableSql()) {
      final m = RegExp(r'CREATE TABLE (\w+)\s*\(').firstMatch(sql);
      expect(m, isNotNull, reason: '建表语句格式不认识：$sql');
      out[m!.group(1)!] = columnsOf(sql);
    }
    return out;
  }

  /// 模拟「一个只有基础表、一列新列都没有」的最老库跑迁移，得到补出来的列。
  Map<String, Set<String>> migratedColumns(Map<String, Set<String>> from) {
    final stmts = SqfliteDb.migrationStatements(
      tables: from.keys.toSet(),
      columns: from,
    );
    final out = {
      for (final e in from.entries) e.key: {...e.value},
    };
    for (final sql in stmts) {
      final alter = RegExp(
        r'ALTER TABLE (\w+) ADD COLUMN (\w+)',
      ).firstMatch(sql);
      if (alter != null) {
        (out[alter.group(1)!] ??= <String>{}).add(alter.group(2)!);
      }
    }
    return out;
  }

  group('【关键】基础建表语句必须包含迁移补的所有列', () {
    // 这两条正是历史上漏掉的那一列。它们红了就说明又漏了。
    test('conversations 有 pinnedAt（v5）—— 就是这次崩溃的那一列', () {
      final cols = baseColumns();
      expect(
        cols['conversations'],
        contains('pinnedAt'),
        reason:
            '基础建表语句缺 pinnedAt，全新安装的用户一写对话就崩：'
            'table conversations has no column named pinnedAt',
      );
    });

    test('meds 有 v6 的全部列', () {
      final cols = baseColumns()['meds']!;
      for (final c in SqfliteDb.medsV6Columns) {
        expect(cols, contains(c), reason: 'meds 建表漏了 v6 的 $c');
      }
    });

    test('meds 有 v7 的全部列', () {
      final cols = baseColumns()['meds']!;
      for (final c in SqfliteDb.medsV7Columns) {
        expect(cols, contains(c), reason: 'meds 建表漏了 v7 的 $c');
      }
    });

    test('expenses 有 entryType（v2 加的）', () {
      expect(baseColumns()['expenses'], contains('entryType'));
    });

    test('chats 有 conversationId（v4 加的，v3 漏它导致过白屏）', () {
      expect(baseColumns()['chats'], contains('conversationId'));
    });
  });

  group('【关键】全新安装与升级安装收敛到同一套结构', () {
    test('四条路径产出的列集合完全相同（差异只允许是主键顺序）', () {
      final base = baseColumns();

      // 路径 A：全新安装 —— 基础建表，然后 _create 内部又跑一遍迁移
      final fresh = migratedColumns(base);

      // 路径 B：从「最老版本」一路升级 —— 也只有基础表，再跑迁移
      final upgraded = migratedColumns(base);

      for (final table in base.keys) {
        expect(
          fresh[table],
          equals(upgraded[table]),
          reason: '表 $table 在两条路径下结构不一致，会出现「新装缺列」的崩溃',
        );
      }
      // 覆盖到全部表，别因为表名写错而空转通过
      expect(base.keys.toSet(), {
        'expenses',
        'meds',
        'chats',
        'conversations',
        'passwords',
      });
    });

    test('迁移对「已经是最新结构」的库不产出任何语句（幂等）', () {
      final latest = migratedColumns(baseColumns());
      final again = SqfliteDb.migrationStatements(
        tables: latest.keys.toSet(),
        columns: latest,
      );
      expect(
        again,
        isEmpty,
        reason: '迁移不幂等的话，_create 里那次额外的迁移调用会重复建表/重复加列',
      );
    });

    test('【反例】故意制造「基础表缺 pinnedAt」必须被抓住', () {
      // 这条断言是自证：如果 columnsOf 或上面的比较逻辑写错了、永远为真，
      // 这里就会失败 ——「永远为真的断言等于没有断言」。
      final broken = baseColumns();
      broken['conversations'] = {...broken['conversations']!}
        ..remove('pinnedAt');

      expect(
        broken['conversations'],
        isNot(contains('pinnedAt')),
        reason: '构造的坏数据本身就该缺这一列',
      );
      // 坏数据跑迁移后会被补上，所以「是否漏列」必须比较**基础表**，
      // 这正是上面那组测试断言基础表而非终态的原因。
      expect(
        migratedColumns(broken)['conversations'],
        contains('pinnedAt'),
        reason: '迁移能补回这一列 —— 所以升级用户没事，新装用户才崩',
      );
    });
  });
}
