import 'package:family_life_assistant/data/db.dart';

/// 内存版 [LocalDb]，供测试注入。
///
/// 用真实的 sqflite 需要桌面原生 SQLite 动态库（测试环境里没有），所以冒烟
/// 测试用这个实现替换数据库：它复刻了各表的排序规则与 upsert 语义，让 UI 与
/// 业务逻辑可以完全离线地跑起来。SQL 语句本身仍由 [SqfliteDb] 承担。
class FakeDb implements LocalDb {
  final Map<String, Map<String, Map<String, dynamic>>> _tables = {
    T.expenses: {},
    T.meds: {},
    T.chats: {},
    T.conversations: {},
    T.passwords: {},
  };

  bool opened = false;

  @override
  Future<void> open() async => opened = true;

  @override
  Future<void> close() async {
    opened = false;
    for (final table in _tables.values) {
      table.clear();
    }
  }

  Map<String, Map<String, dynamic>> _table(String table) =>
      _tables.putIfAbsent(table, () => {});

  @override
  Future<List<Map<String, dynamic>>> all(String table) async {
    final rows = _table(table).values
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    rows.sort(comparatorFor(table));
    return rows;
  }

  /// 复刻 `SqfliteDb` 的排序。
  ///
  /// **直接从真实的 [localDbOrder] 表达式推导，不再手抄一份。** 手抄出过一次
  /// 事故：[T.passwords] 的真实排序是 `createdAt DESC`，而这里原先和
  /// [T.conversations] 合并成同一个分支，按 **`updatedAt`** 排序 ——
  /// `passwords` 表根本没有 `updatedAt` 列。`_text()` 读不存在的键返回 `''`，
  /// 于是所有记录比较结果都是相等，断言照样通过：**内存实现与真实实现语义不一致，
  /// 而不一致的方向恰好让测试永远绿**。这是最坏的一种测试失效 —— 绿灯在撒谎。
  ///
  /// 支持 [localDbOrder] 里实际用到的形式：`列 (ASC|DESC)`，以及 meds 那条
  /// `CASE WHEN ... THEN 1 ELSE 0 END ASC, 列 ASC`（空值排最后）。
  Comparator<Map<String, dynamic>> comparatorFor(String table) {
    final spec = localDbOrder[table] ?? '';
    final caseColumns = _caseNullFirstColumns(spec);
    return (a, b) {
      // CASE 前缀：把「值为空」的记录挑出来排到最后（SQL 里 CASE 表达式返回 1
      // 表示「不是有效值」，配合 ASC 就落到末尾）。必须先做这一步再比大小，
      // 否则空串按字符串比较会跑到**最前面** —— 与真实实现相反。
      for (final column in caseColumns) {
        final ae = _text(a[column]).isEmpty;
        final be = _text(b[column]).isEmpty;
        if (ae != be) return ae ? 1 : -1;
      }
      // 多段排序：逗号分隔，逐段比较，第一段不等就出结果。
      for (final rawPart in spec.split(',')) {
        final part = rawPart.trim();
        if (part.isEmpty) continue;
        final desc = part.toUpperCase().endsWith('DESC');
        final column = _sortColumn(part);
        if (column == null) continue;
        final cmp = _text(a[column]).compareTo(_text(b[column]));
        if (cmp != 0) return desc ? -cmp : cmp;
      }
      return 0;
    };
  }

  /// 取出 `CASE WHEN <列> IS NULL OR <列> = '' THEN 1 ELSE 0 END` 里那个列。
  ///
  /// [localDbOrder] 里只有 meds 用了这种「空值排最后」的写法。抽出来单独处理，
  /// 是因为它不是普通的按列比较：`expiry` 为空时要排最后，而空串在字符串比较里
  /// 天然排最前，语义正好相反。
  List<String> _caseNullFirstColumns(String spec) {
    final match = RegExp(
      r'CASE\s+WHEN\s+(\w+)\s+IS\s+NULL',
      caseSensitive: false,
    ).firstMatch(spec);
    return match == null ? const [] : [match.group(1)!];
  }

  /// 从一段 ORDER BY 里取出参与排序的列名。
  ///
  /// 形如 `updatedAt DESC`、`expiry ASC`。CASE 段由
  /// [_caseNullFirstColumns] 单独处理，这里跳过不含列名的片段。
  String? _sortColumn(String part) {
    if (part.toUpperCase().startsWith('CASE')) {
      // CASE 段的排序键是它条件里的列，已在 _caseNullFirstColumns 处理过
      final match = RegExp(
        r'CASE\s+WHEN\s+(\w+)\s+IS\s+NULL',
        caseSensitive: false,
      ).firstMatch(part);
      return match?.group(1);
    }
    final plain = RegExp(r'^(\w+)').firstMatch(part);
    return plain?.group(1);
  }

  /// 复刻 `SqfliteDb.query` 的 `where column=?` 语义。
  ///
  /// 只支持等值条件：这是 [Store] 目前唯一用到的形式，测试里也不需要更复杂的
  /// 表达式；遇到不认识的语句直接抛错，避免静默给出错误结果。
  @override
  Future<List<Map<String, dynamic>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final rows = await all(table);
    if (where == null || where.trim().isEmpty) return rows;
    final match = RegExp(r'^\s*(\w+)\s*=\s*\?\s*$').firstMatch(where);
    if (match == null) {
      throw UnsupportedError('FakeDb.query 仅支持 "column=?" 形式的条件：$where');
    }
    final column = match.group(1)!;
    final expected = (whereArgs ?? const []).firstOrNull?.toString();
    return rows
        .where((row) => _text(row[column]) == expected)
        .toList();
  }

  @override
  Future<void> removeWhere(
    String table,
    String where,
    List<Object?> whereArgs,
  ) async {
    final rows = await query(table, where: where, whereArgs: whereArgs);
    for (final row in rows) {
      _table(table).remove(_text(row['id']));
    }
  }

  /// 复刻 [LocalDb.clear]：`tables` 为空时清空全部业务表。
  @override
  Future<void> clear({List<String>? tables}) async {
    final targets = tables == null || tables.isEmpty
        ? localDbTables
        : tables;
    for (final table in targets) {
      _table(table).clear();
    }
  }

  @override
  Future<void> put(String table, Map<String, dynamic> row) async {
    final id = _text(row['id']);
    if (id.isEmpty) {
      throw ArgumentError('缺少主键 id：$row');
    }
    // 复刻 ConflictAlgorithm.replace 的语义：整行替换，不做字段合并。
    _table(table)[id] = Map<String, dynamic>.from(row);
  }

  @override
  Future<void> remove(String table, String id) async {
    _table(table).remove(id);
  }

  @override
  Future<Map<String, dynamic>?> byId(String table, String id) async {
    final row = _table(table)[id];
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  static String _text(dynamic value) => value?.toString() ?? '';
}

/// 复刻「v3 那次漏加 conversationId 的迁移」留下的坏结构。
///
/// `chats` 表没有 `conversationId` 这一列，任何按该列过滤的查询都会失败，
/// 就像真实设备上抛 `no such column: conversationId` 一样。用来验证：
/// 这类设备启动时不会再白屏，而是能看到错误页。
class LegacyChatsDb extends FakeDb {
  @override
  Future<List<Map<String, dynamic>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) {
    if (table == T.chats && (where ?? '').contains('conversationId')) {
      throw StateError(
        'no such column: conversationId in "SELECT * FROM $table WHERE $where"',
      );
    }
    return super.query(table, where: where, whereArgs: whereArgs);
  }
}
