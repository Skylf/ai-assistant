import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 桌面组件（Android App Widget）与 App 之间的数据交接。
///
/// ## 为什么要单独一层
///
/// 桌面组件跑在**原生进程**里，数据却存在 **Flutter 的 sqflite** 里。用户在桌面上
/// 记的一笔账，必须先落到某个两边都能读写的地方，再进数据库。
///
/// 选的是「一个 JSON Lines 文件」，理由见原生侧 `WidgetBridge.kt` 的注释；
/// 要点是**不引入任何新依赖**：Android 上 `context.filesDir` 就是
/// [getApplicationDocumentsDirectory] 指向的目录，而 `path_provider` 是既有依赖。
///
/// ## 本文件的分工
///
/// 为了能**离线测试**，这里刻意分成两层：
///  · 纯函数（[fileName] 常量、[parseQueue]、[encodeQueue]、[buildSummary]）——
///    只做字符串与 Map 的转换，测试直接喂输入断言输出；
///  · 副作用（[readPending]、[writePending]、[drainPending]）—— 碰文件与数据库。
///
/// 如果把解析逻辑埋在 `readPending` 里，测试就必须先造一个真实文件与真实 Store，
/// 而桌面组件的核心风险恰恰是**解析**（原生写的 JSON 形状对不对、脏数据怎么办）。
class WidgetBridge {
  const WidgetBridge._();

  /// 待入库队列的文件名。
  ///
  /// ⚠️ **必须与原生 `WidgetBridge.kt` 的 `QUEUE_FILE` 逐字一致** ——
  /// 不一致的表现是「桌面记完了、App 永远读不到」，而且两边都不报错。
  /// `test/widget_bridge_test.dart` 会去读那个 .kt 文件做断言，防止改一边忘另一边。
  static const queueFileName = 'widget_pending.jsonl';

  /// 桌面组件展示用的汇总文件名。同样与原生侧常量对齐。
  static const summaryFileName = 'widget_summary.json';

  /// 记录类型。
  static const kindExpense = 'expense';
  static const kindMed = 'med';

  /// 原生侧表单的字段名。这些名字**与 App 内完全一致**（见 `Store.expense` /
  /// `Store.med` 接收的键），所以入库时不需要任何翻译表。
  static const keyId = 'id';
  static const keyKind = 'kind';
  static const keyTitle = 'title';
  static const keyAmount = 'amount';
  static const keyCategory = 'category';
  static const keyNote = 'note';
  static const keyEntryType = 'entryType';
  static const keySpentAt = 'spentAt';
  static const keyName = 'name';
  static const keyStock = 'stock';
  static const keySpec = 'spec';
  static const keyExpiry = 'expiry';
  static const keyStorage = 'storage';
  static const keyCreatedAt = 'createdAt';

  /// 桌面组件要展示的汇总键。原生侧 `summaryText()` 按这些键取值。
  static const keyTodayExpense = 'todayExpense';
  static const keyTodayCount = 'todayCount';
  static const keyMedTotal = 'medTotal';
  static const keyMedAttention = 'medAttention';

  /// 队列文件。目录取自 [getApplicationDocumentsDirectory]。
  static Future<File> queueFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, queueFileName));
  }

  /// 汇总文件。
  static Future<File> summaryFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, summaryFileName));
  }

  /// 解析队列文件的内容。
  ///
  /// **逐行容错**，这是选 JSON Lines 的全部理由：原生侧是「追加一行」写入的，
  /// 如果写到一半被系统杀掉，**最坏只损坏最后一行**。整份 JSON 数组做不到这点
  /// ——一个字节坏掉就整份读不出来，用户的记录全丢。
  ///
  /// 因此这里的策略是「能救一条是一条」：
  ///  · 空行跳过；
  ///  · 非 JSON 的行跳过；
  ///  · 缺 `id` 或 `kind` 的行跳过（没有 id 就没法去重，没有 kind 不知道进哪张表）；
  ///  · **其余字段一律不在这里校验**，交给 [normalize] 按类型处理 ——
  ///    在这里顺手丢掉「字段可疑」的行，会把「用户填了一半的表单」也丢掉，
  ///    而那种情况本该保留能用的部分。
  @visibleForTesting
  static List<Map<String, dynamic>> parseQueue(String content) {
    final out = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(content)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        continue; // 半截写入的那一行
      }
      if (decoded is! Map) continue;
      final map = Map<String, dynamic>.from(decoded);
      final id = map[keyId]?.toString().trim() ?? '';
      final kind = map[keyKind]?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      if (kind != kindExpense && kind != kindMed) continue;
      out.add(map);
    }
    return out;
  }

  /// 把待入库记录编码回队列文件内容（每行一条 JSON）。
  ///
  /// 保留 [toKeep] 中记录**原始的那份 Map**，不重新组装：万一某条记录里有
  /// 我们还不认识的字段（比如将来原生侧加了新键、而 App 还没升级），
  /// 重新组装会把它悄悄抹掉。
  @visibleForTesting
  static String encodeQueue(List<Map<String, dynamic>> toKeep) =>
      toKeep.map(jsonEncode).join('\n') + (toKeep.isEmpty ? '' : '\n');

  /// 读回待入库记录（只读）。
  static Future<List<Map<String, dynamic>>> readPending() async {
    final file = await queueFile();
    if (!file.existsSync()) return const [];
    try {
      return parseQueue(await file.readAsString());
    } on FileSystemException catch (error) {
      debugPrint('[widget] 读取待入库队列失败：$error');
      return const [];
    }
  }

  /// 覆盖写入队列文件（用于删掉已入库的行）。
  ///
  /// **先写临时文件再 rename**：直接覆盖时若被中断，队列会变成半截内容，
  /// 而队列是**唯一的**交接通道，写坏了就是用户丢记录。
  static Future<void> writePending(List<Map<String, dynamic>> keep) async {
    try {
      final file = await queueFile();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(encodeQueue(keep), flush: true);
      if (file.existsSync()) await file.delete();
      await tmp.rename(file.path);
    } on FileSystemException catch (error) {
      debugPrint('[widget] 写回待入库队列失败：$error');
    }
  }

  /// 把一条待入库记录规整成「可以直接交给 Store」的字段表。
  ///
  /// 返回 `null` 表示这条记录没救了（比如金额非法），调用方应当**丢弃并继续**，
  /// 而不是整批中止 —— 一条坏记录不该堵住后面所有好记录。
  ///
  /// 各字段的处理规则：
  ///  · 金额：必须是有限的非负数；`12.5` 可以，`abc` / 空 / `NaN` 不行。
  ///    金额为 0 也放行（原生侧已经拦了，这里不重复拦，避免两处规则不一致）。
  ///  · 数量：非负整数，缺省按 1（与 App 表单的默认值一致）。
  ///  · 日期：解析失败就回落到**现在**，并在返回值里体现 ——
  ///    宁可时间不准也不要丢掉这笔账。
  static Map<String, dynamic>? normalize(Map<String, dynamic> record) {
    final kind = record[keyKind]?.toString().trim() ?? '';
    final id = record[keyId]?.toString().trim() ?? '';
    if (id.isEmpty) return null;

    if (kind == kindExpense) {
      final amount = _toAmount(record[keyAmount]);
      if (amount == null) return null;
      final spentAt = _toIso(record[keySpentAt]) ?? DateTime.now().toIso8601String();
      return <String, dynamic>{
        'id': id,
        keyTitle: _str(record[keyTitle]),
        keyAmount: amount,
        keyCategory: _str(record[keyCategory]),
        keyNote: _str(record[keyNote]),
        keyEntryType:
            _str(record[keyEntryType]) == 'income' ? 'income' : 'expense',
        keySpentAt: spentAt,
      };
    }

    if (kind == kindMed) {
      final name = _str(record[keyName]);
      if (name.isEmpty) return null;
      return <String, dynamic>{
        'id': id,
        keyName: name,
        keySpec: _str(record[keySpec]),
        keyStock: _toStock(record[keyStock]),
        keyExpiry: _str(record[keyExpiry]),
        keyStorage: _str(record[keyStorage]),
      };
    }

    return null;
  }

  static String _str(Object? value) => value?.toString().trim() ?? '';

  /// 金额：只接受有限数字。字符串形式的 `"12.5"` 也接受（原生 `JSONObject`
  /// 在某些路径上会把数字写成字符串）。
  @visibleForTesting
  static double? toAmount(Object? value) => _toAmount(value);

  static double? _toAmount(Object? value) {
    double? parsed;
    if (value is num) {
      parsed = value.toDouble();
    } else {
      parsed = double.tryParse(value?.toString().trim() ?? '');
    }
    if (parsed == null) return null;
    if (parsed.isNaN || parsed.isInfinite) return null;
    if (parsed < 0) return null;
    return parsed;
  }

  static int _toStock(Object? value) {
    if (value is num) {
      final asInt = value.toInt();
      return asInt < 0 ? 1 : asInt;
    }
    final parsed = int.tryParse(value?.toString().trim() ?? '');
    if (parsed == null || parsed < 0) return 1; // 与 App 表单默认值一致
    return parsed;
  }

  /// 解析 ISO 时间串；失败返回 null（由调用方决定回落到什么）。
  static String? _toIso(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    return parsed?.toIso8601String();
  }

  /// 组装桌面组件要展示的汇总数据。
  ///
  /// 抽成纯函数，是为了让「今天」有确定的含义：测试可以传 [now]，
  /// 不必依赖运行时刻（否则跨零点就会随机红）。
  ///
  /// [expenses] / [meds] 就是 `Store.expenses` / `Store.meds` 那两份原始行。
  static Map<String, dynamic> buildSummary({
    required List<Map<String, dynamic>> expenses,
    required List<Map<String, dynamic>> meds,
    required DateTime now,
  }) {
    var todayTotal = 0.0;
    var todayCount = 0;
    for (final row in expenses) {
      // 只统计支出：把收入算进「今日支出」会让这个数字失去意义，
      // 用户看到的是「今天花了多少」。
      if (_str(row[keyEntryType]) == 'income') continue;
      final when = DateTime.tryParse(_str(row[keySpentAt]));
      if (when == null) continue;
      if (when.year != now.year ||
          when.month != now.month ||
          when.day != now.day) {
        continue;
      }
      final amount = _toAmount(row[keyAmount]) ?? 0;
      todayTotal += amount;
      todayCount += 1;
    }

    // 需关注的药品：已过期 + 30 天内到期 + 库存为 0。
    // 与 App 内药箱页的判定条件保持一致（那边也是这三类）。
    final attention = meds.where(_needsAttention).length;

    return <String, dynamic>{
      keyTodayExpense: todayTotal == todayTotal.roundToDouble()
          ? todayTotal.round().toString()
          : todayTotal.toStringAsFixed(2),
      keyTodayCount: todayCount,
      keyMedTotal: meds.length,
      keyMedAttention: attention,
    };
  }

  /// 是否「需要关注」：过期、临期（30 天内）或没库存。
  static bool _needsAttention(Map<String, dynamic> med) {
    final stock = _toStockOrNull(med[keyStock]);
    if (stock != null && stock <= 0) return true;

    final expiry = DateTime.tryParse(_str(med[keyExpiry]));
    if (expiry == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(expiry.year, expiry.month, expiry.day);
    return day.difference(today).inDays <= 30;
  }

  static int? _toStockOrNull(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  /// 把汇总数据写给原生组件。
  ///
  /// 失败**只记日志**：组件显示不出汇总数字不是严重问题，绝不能因为它
  /// 让记账/记药这种主流程报错。
  static Future<void> writeSummary(Map<String, dynamic> summary) async {
    try {
      final file = await summaryFile();
      // 与原生侧 writeSummary 一样用「临时文件 + rename」，避免组件读到半截 JSON。
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(summary), flush: true);
      if (file.existsSync()) await file.delete();
      await tmp.rename(file.path);
    } on FileSystemException catch (error) {
      debugPrint('[widget] 写汇总失败：$error');
    }
  }
}
