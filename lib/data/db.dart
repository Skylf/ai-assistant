import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// 表名常量。UI 层不再出现裸字符串表名。
class T {
  static const expenses = 'expenses';
  static const meds = 'meds';
  static const chats = 'chats';
  static const conversations = 'conversations';
  static const passwords = 'passwords';
}

/// 本地数据访问接口。
///
/// 抽成接口有两个目的：
/// 1. UI 与业务逻辑不再直接依赖 sqflite，测试可以注入内存实现；
/// 2. 排序规则集中在这里，调用方不再各写一套 orderBy。
abstract interface class LocalDb {
  Future<void> open();

  Future<void> close();

  /// 按各表既定顺序返回全部行。
  Future<List<Map<String, dynamic>>> all(String table);

  /// 按主键 upsert。
  Future<void> put(String table, Map<String, dynamic> row);

  Future<void> remove(String table, String id);

  /// 按条件删除，用于「删除对话时清理其消息」这类级联操作。
  Future<void> removeWhere(String table, String where, List<Object?> args);

  /// 按条件查询。
  Future<List<Map<String, dynamic>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  });

  Future<Map<String, dynamic>?> byId(String table, String id);

  /// 数据管理用的清空操作，[tables] 为空表示全部业务表。
  Future<void> clear({List<String>? tables});
}

/// 各表的默认排序规则。
const localDbOrder = <String, String>{
  T.expenses: 'spentAt DESC',
  T.meds:
      "CASE WHEN expiry IS NULL OR expiry = '' THEN 1 ELSE 0 END ASC, expiry ASC",
  T.chats: 'createdAt ASC',
  T.conversations: 'updatedAt DESC',
  T.passwords: 'createdAt DESC',
};

/// 业务表清单，供清空与导出使用。
const localDbTables = <String>[
  T.expenses,
  T.meds,
  T.chats,
  T.conversations,
  T.passwords,
];

/// SQLite 实现（Android / iOS / macOS / Windows）。
class SqfliteDb implements LocalDb {
  SqfliteDb({this.name = 'family_life.db'});

  /// 数据库文件名。
  final String name;

  /// 当前 schema 版本。
  ///
  /// v1 -> 基础三表；v2 -> expenses 增加 entryType；
  /// v3 -> 新增 conversations（多对话框 + 记忆开关）与 passwords（密码生成器）；
  /// v4 -> chats 增加 conversationId；
  /// v5 -> conversations 增加 pinnedAt（对话置顶）。
  ///
  /// v3 有个必须修掉的缺陷：它只建了新表，忘了给既有的 chats 加
  /// `conversationId`。老用户（v1/v2 升上来）启动时 `SELECT * FROM chats
  /// WHERE conversationId=?` 直接抛异常，`Store.load()` 失败，表现为白屏。
  /// 因为已经有人升到过 v3，只改 v3 的迁移代码救不了这些设备，所以补一个 v4：
  /// 迁移逻辑按「实际列是否存在」判断，重复执行也安全。
  static const schemaVersion = 7;

  Database? _raw;

  /// 是否已打开。用于测试与调试观察。
  bool get isOpen => _raw != null;

  @override
  Future<void> open() async {
    if (_raw != null) return;
    final root = (Platform.isAndroid || Platform.isIOS)
        ? await getDatabasesPath()
        : (await getApplicationDocumentsDirectory()).path;
    _raw = await openDatabase(
      join(root, name),
      version: schemaVersion,
      onCreate: _create,
      onUpgrade: _upgrade,
      onDowngrade: _downgrade,
    );
  }

  /// 库版本比代码新时的处理。
  ///
  /// 不实现它的话 sqflite 会直接抛异常，`open()` 失败 → `Store.load()` 失败 →
  /// 启动错误页。而那条路径**无解**：重试必然失败（版本号不会自己降回去），
  /// 错误页建议的「导出数据」在启动失败时根本进不去，用户唯一出路是清除应用数据
  /// —— 账本、药箱、对话、密码记录全部丢失，且没有任何导出机会。
  ///
  /// 触发场景是真实的：装了旧版 APK 覆盖新版（`versionCode` 不递增时系统会拒装，
  /// 但用 `adb install -r` 或第三方渠道仍可装上）、或从备份恢复了更高版本的库文件。
  ///
  /// 处理策略：**原样保留数据继续用**，不删表、不重建。更高版本带来的新列我们读
  /// 不到（`SELECT *` 会多出几列，各表读取都是按列名取值，多余的列会被忽略），
  /// 但既有数据一条不丢 —— 这比「打不开」好得多。真需要降级迁移时再补具体逻辑。
  static Future<void> _downgrade(Database db, int oldVersion, int newVersion) async {
    debugPrint('[db] 库版本($oldVersion) 高于代码版本($newVersion)，保留原数据继续运行');
  }

  @override
  Future<void> close() async {
    await _raw?.close();
    _raw = null;
  }

  Database get _db {
    final db = _raw;
    if (db == null) {
      throw StateError('数据库尚未打开，请先调用 open()。');
    }
    return db;
  }

  Future<void> _create(Database db, int version) async {
    await db.execute(
      'CREATE TABLE ${T.expenses}('
      'id TEXT PRIMARY KEY,'
      'title TEXT,'
      'category TEXT,'
      'amount REAL,'
      'spentAt TEXT,'
      'note TEXT,'
      "entryType TEXT DEFAULT 'expense')",
    );
    await db.execute(
      'CREATE TABLE ${T.meds}('
      'id TEXT PRIMARY KEY,'
      'name TEXT,'
      'ingredient TEXT,'
      'spec TEXT,'
      'stock INTEGER,'
      'expiry TEXT,'
      'storage TEXT,'
      'note TEXT,'
      // ---- v6（0.4D）：分类与详细信息 ----
      'form TEXT,'
      'usage TEXT,'
      'indications TEXT,'
      'efficacy TEXT,'
      'adverse TEXT,'
      'contraindications TEXT,'
      'precautions TEXT,'
      'infoSource TEXT,'
      // ---- v7（0.4F）：联网来源 URL，换行分隔 ----
      'infoUrls TEXT,'
      'infoCheckedAt TEXT)',
    );
    await db.execute(
      'CREATE TABLE ${T.chats}('
      'id TEXT PRIMARY KEY,'
      'role TEXT,'
      'content TEXT,'
      'topic TEXT,'
      'conversationId TEXT,'
      'createdAt TEXT)',
    );
    await db.execute(
      'CREATE TABLE ${T.conversations}('
      'id TEXT PRIMARY KEY,'
      'title TEXT,'
      'topic TEXT,'
      'memory TEXT DEFAULT \'local\','
      'createdAt TEXT,'
      'updatedAt TEXT)',
    );
    await db.execute(
      'CREATE TABLE ${T.passwords}('
      'id TEXT PRIMARY KEY,'
      'label TEXT,'
      'site TEXT,'
      'length INTEGER,'
      'strength INTEGER,'
      'entropy REAL,'
      'createdAt TEXT)',
    );
  }

  /// 迁移：老版本升级时补齐新表与新列，并保留既有数据。
  ///
  /// 每一步都先查实际表 / 列是否存在再动手，因此重复执行、或遇到「已经处于
  /// 目标版本但结构不对」的库都能自愈。
  /// 迁移要执行的 SQL，由 [migrationStatements] 纯函数算出。
  ///
  /// 抽成「先算 SQL、再执行」两步，是为了让迁移逻辑**可以被测试**。原先它是一段
  /// 直接操作 [Database] 的代码，而桌面测试环境没有 SQLite 原生库，`SqfliteDb`
  /// 在整个测试套件里只出现过一行常量断言 —— 也就是说 0.3B 整个版本的存在理由
  /// （修白屏的那段迁移）**一次都没有被执行或校验过**。现在 SQL 是纯函数的输出，
  /// `test/migration_sql_test.dart` 可以在不碰数据库的情况下校验它。
  Future<void> _upgrade(Database db, int oldVersion, int newVersion) async {
    final columns = <String, Set<String>>{};
    final tables = <String>{};
    for (final table in localDbOrder.keys) {
      if (await _hasTable(db, table)) {
        tables.add(table);
        columns[table] = await _columnNames(db, table);
      }
    }
    for (final sql in migrationStatements(tables: tables, columns: columns)) {
      await db.execute(sql);
    }
    // 老消息没有归属对话，交给 Store.ensureConversations() 按主题认领：
    // 它会把 conversationId 为空的行挂到对应的「默认对话」上。
  }

  static const _conversationsDdl =
      'CREATE TABLE IF NOT EXISTS ${T.conversations}('
      'id TEXT PRIMARY KEY,'
      'title TEXT,'
      'topic TEXT,'
      'memory TEXT DEFAULT \'local\','
      'createdAt TEXT,'
      'updatedAt TEXT,'
      'pinnedAt TEXT)';

  static const _passwordsDdl =
      'CREATE TABLE IF NOT EXISTS ${T.passwords}('
      'id TEXT PRIMARY KEY,'
      'label TEXT,'
      'site TEXT,'
      'length INTEGER,'
      'strength INTEGER,'
      'entropy REAL,'
      'createdAt TEXT)';

  /// 算出「让一个旧库变成当前结构」需要执行的全部 SQL。
  ///
  /// **纯函数：只根据传入的既有表 / 列信息决定，不碰数据库。** 因此可以用假想的
  /// 库结构直接测试各条边界，包括那些真机上很难复现的中间态（v1→v2 写到一半被
  /// 打断、表存在但缺列、表本身不存在）。
  ///
  /// 两条硬约束，测试会守住：
  /// 1. **不绑定 `oldVersion`**：只按「实际结构是否符合预期」判断。绑定版本号会留
  ///    下救不回来的边 —— 库版本已是 2 但 `expenses` 缺 `entryType` 时，
  ///    `oldVersion < 2` 为 false，自愈永远不触发。
  /// 2. **`ALTER TABLE` 之前必须确认表存在**：否则「补列」这个自愈动作本身会抛
  ///    `no such table`，自愈逻辑自己炸掉是最难查的一类问题。
  @visibleForTesting
  static List<String> migrationStatements({
    required Set<String> tables,
    required Map<String, Set<String>> columns,
  }) {
    bool hasColumn(String table, String column) =>
        tables.contains(table) && (columns[table] ?? const {}).contains(column);

    final statements = <String>[];
    // 表本身不存在时不能 ALTER —— 那是 `no such table`。这种情况下建表交给
    // _create；_upgrade 只在表确实存在、但缺列时补列。
    if (tables.contains(T.expenses) && !hasColumn(T.expenses, 'entryType')) {
      statements.add(
        "ALTER TABLE ${T.expenses} ADD COLUMN entryType TEXT DEFAULT 'expense'",
      );
    }
    if (!tables.contains(T.conversations)) {
      statements.add(_conversationsDdl);
    }
    if (!tables.contains(T.passwords)) {
      statements.add(_passwordsDdl);
    }
    // v4：给 chats 补 conversationId。v3 漏了这一步，是白屏的直接原因。
    if (tables.contains(T.chats) && !hasColumn(T.chats, 'conversationId')) {
      statements.add('ALTER TABLE ${T.chats} ADD COLUMN conversationId TEXT');
    }
    // v5：给 conversations 补 pinnedAt（对话置顶）。
    // 默认 NULL = 未置顶，所以老对话升上来天然都是「未置顶」，无需回填。
    if (tables.contains(T.conversations) &&
        !hasColumn(T.conversations, 'pinnedAt')) {
      statements.add(
        'ALTER TABLE ${T.conversations} ADD COLUMN pinnedAt TEXT',
      );
    }
    // v6：给 meds 补分类与详细信息字段（0.4D）。
    //
    // 全部默认 NULL，老药品升上来就是「这些字段还没填」——与「新加的药品没填」
    // 是同一种状态，界面无需区分。**故意不回填任何内容**：
    // 用法用量/禁忌这类字段一旦用猜测去回填，用户就再也分不清哪条是抄来的、
    // 哪条是编的。宁可空着显示「未填写」。
    //
    // 循环而不是手抄 8 条：手抄时漏一条不会有任何提示（列缺失要到用户
    // 点开某个药品才炸），而循环里少写一个名字同样会立刻被下面的测试抓住。
    for (final column in _medsV6Columns) {
      if (tables.contains(T.meds) && !hasColumn(T.meds, column)) {
        statements.add('ALTER TABLE ${T.meds} ADD COLUMN $column TEXT');
      }
    }
    // v7：给 meds 补「联网来源 URL」（0.4F）。
    //
    // 单独一列而不是塞进 infoSource：来源描述是**给人看的一句话**，
    // URL 是**给程序用的列表**（将来要把某条打开/复制）。混在一起就得
    // 在字符串里做解析，那正是「用正则解析本该结构化的东西」的老毛病。
    //
    // 默认 NULL 或空串都表示「没有来源 URL」—— 0.4D/0.4E 存下来的记录
    // 本来就没有 URL（那时根本没联网），升上来显示空是对的，**不回填**。
    if (tables.contains(T.meds) && !hasColumn(T.meds, 'infoUrls')) {
      statements.add('ALTER TABLE ${T.meds} ADD COLUMN infoUrls TEXT');
    }
    return statements;
  }

  /// v6 给 `meds` 新增的列。
  ///
  /// 提成常量是为了让测试能逐个断言「建表语句里有、迁移语句里也有」——
  /// 两处不一致会造成「全新安装有这列、升级安装没有」的隐蔽差异。
  @visibleForTesting
  static const medsV6Columns = <String>[
    'form',
    'usage',
    'indications',
    'efficacy',
    'adverse',
    'contraindications',
    'precautions',
    'infoSource',
    'infoCheckedAt',
  ];

  static const _medsV6Columns = medsV6Columns;

  /// v7 给 `meds` 新增的列。
  @visibleForTesting
  static const medsV7Columns = <String>['infoUrls'];

  /// 读出某张表的列名集合。
  Future<Set<String>> _columnNames(Database db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return {
      for (final row in info)
        if (row['name'] != null) row['name'].toString(),
    };
  }

  /// 判断某张表是否存在。
  ///
  /// [all] 等读取路径都会先假设表存在，所以 `ALTER TABLE` 之前必须先确认表在，
  /// 否则「补列」这个自愈动作本身会抛 `no such table` —— 自愈逻辑自己炸掉是最
  /// 难查的一类问题。
  Future<bool> _hasTable(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [table],
    );
    return rows.isNotEmpty;
  }

  @override
  Future<List<Map<String, dynamic>>> all(String table) =>
      _db.query(table, orderBy: localDbOrder[table]);

  @override
  Future<List<Map<String, dynamic>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) => _db.query(table, where: where, whereArgs: whereArgs);

  @override
  Future<void> put(String table, Map<String, dynamic> row) =>
      _db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> remove(String table, String id) =>
      _db.delete(table, where: 'id=?', whereArgs: [id]);

  @override
  Future<void> removeWhere(
    String table,
    String where,
    List<Object?> args,
  ) => _db.delete(table, where: where, whereArgs: args);

  @override
  Future<Map<String, dynamic>?> byId(String table, String id) async {
    final rows = await _db.query(
      table,
      where: 'id=?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<void> clear({List<String>? tables}) async {
    for (final table in tables ?? localDbTables) {
      await _db.delete(table);
    }
  }
}
