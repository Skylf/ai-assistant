/// 纯函数统计口径。
///
/// 0.2C 之前首页的「本月支出」直接对所有账目求和，把收入也算进了支出。
/// 统计规则集中到这里，并且不依赖数据库与 Flutter，方便直接用单测锁住。
library;

/// 判断一条账目是否为收入。除 `income` 之外一律按支出处理。
bool isIncome(Map<String, dynamic> entry) => entry['entryType'] == 'income';

/// 解析账目时间，失败返回 null。
DateTime? entryTime(Map<String, dynamic> entry) =>
    DateTime.tryParse(entry['spentAt']?.toString() ?? '');

/// 读取金额，缺省或非法按 0 计。
double entryAmount(Map<String, dynamic> entry) {
  final value = entry['amount'];
  return value is num ? value.toDouble() : 0;
}

/// 汇总指定月份/日期的账目金额。
///
/// [income] 为 null 时统计全部；true 只统计收入；false 只统计支出。
/// [month] 为 true 时按「年月」匹配，否则按「年月日」匹配。
double sumEntries(
  List<Map<String, dynamic>> entries,
  DateTime when, {
  bool? income,
  bool month = true,
}) {
  var total = 0.0;
  for (final entry in entries) {
    if (income != null && isIncome(entry) != income) continue;
    final at = entryTime(entry);
    if (at == null) continue;
    if (at.year != when.year || at.month != when.month) continue;
    if (!month && at.day != when.day) continue;
    total += entryAmount(entry);
  }
  return total;
}

/// 统计某月各分类的支出，从高到低排列。用于 AI 摘要与后续图表。
List<MapEntry<String, double>> expenseByCategory(
  List<Map<String, dynamic>> entries,
  DateTime when,
) {
  final buckets = <String, double>{};
  for (final entry in entries) {
    if (isIncome(entry)) continue;
    final at = entryTime(entry);
    if (at == null || at.year != when.year || at.month != when.month) continue;
    final category = entry['category']?.toString().trim() ?? '';
    final key = category.isEmpty ? '未分类' : category;
    buckets[key] = (buckets[key] ?? 0) + entryAmount(entry);
  }
  final ranked = buckets.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return ranked;
}

/// 账目条数统计（用于「共 N 条」这类文案）。
int countEntries(
  List<Map<String, dynamic>> entries,
  DateTime when, {
  bool month = true,
}) {
  var count = 0;
  for (final entry in entries) {
    final at = entryTime(entry);
    if (at == null) continue;
    if (at.year != when.year || at.month != when.month) continue;
    if (!month && at.day != when.day) continue;
    count++;
  }
  return count;
}

// ---------------------------------------------------------------- 统计周期

/// 统计周期。账本的「汇总」「分类」两级都按它切换。
///
/// 口径一律用**自然周期**（用户明确要求）：
///  - [week] 自然周，**周一为一周开始**（国内习惯，不是周日）；
///  - [month] 自然月；
///  - [year] 自然年。
///
/// 为什么不用「最近 7 天」这类滚动区间：滚动区间与日历上的月份对不上，
/// 用户看到「本月支出」时会拿它和账单核对，对不上就会认为数字是错的。
enum StatsRange {
  week('周'),
  month('月'),
  year('年');

  const StatsRange(this.label);

  /// 分段标签上的字。
  final String label;

  /// 该周期的起始日（含）。
  ///
  /// 周起点取 [DateTime.monday]：`weekday` 里周一是 1、周日是 7，
  /// 直接减 `weekday - 1` 天即可回到本周一。
  static DateTime startOf(StatsRange range, DateTime when) {
    final day = DateTime(when.year, when.month, when.day);
    switch (range) {
      case StatsRange.week:
        return day.subtract(Duration(days: day.weekday - DateTime.monday));
      case StatsRange.month:
        return DateTime(when.year, when.month);
      case StatsRange.year:
        return DateTime(when.year);
    }
  }

  /// 该周期的结束日（**不含**，即下一天的零点）。
  ///
  /// 用「左闭右开」而不是「含最后一天」：区间比较写成 `!before(start) &&
  /// before(end)` 就不会出现「末日 23:59:59.999 算不进去」这种边界错。
  static DateTime endOf(StatsRange range, DateTime when) {
    final start = startOf(range, when);
    switch (range) {
      case StatsRange.week:
        return start.add(const Duration(days: 7));
      case StatsRange.month:
        // 用 day:0 的下月表示下月 1 号，自动处理 12 月与闰年
        return DateTime(start.year, start.month + 1);
      case StatsRange.year:
        return DateTime(start.year + 1);
    }
  }

  /// 用于显示的中文周期名，例如「2026 年 9 月」「9 月 22 日 – 9 月 28 日」。
  ///
  /// 注意不能叫 `label`：枚举本身已有 `label` 实例字段（分段标签用），
  /// 静态与实例同名会编译不过。
  static String periodLabel(StatsRange range, DateTime when) {
    final start = startOf(range, when);
    switch (range) {
      case StatsRange.week:
        final end = start.add(const Duration(days: 6));
        return '${start.month} 月 ${start.day} 日 – ${end.month} 月 ${end.day} 日';
      case StatsRange.month:
        return '${start.year} 年 ${start.month} 月';
      case StatsRange.year:
        return '${start.year} 年';
    }
  }
}

/// 判断某条账目是否落在 [start, end) 内。
bool inRange(Map<String, dynamic> entry, DateTime start, DateTime end) {
  final at = entryTime(entry);
  if (at == null) return false;
  return !at.isBefore(start) && at.isBefore(end);
}

/// 汇率无关的区间汇总结果。
///
/// 做成一个不可变对象而不是让调用方分别调四个函数：界面上这四个数字是
/// **一起显示**的，分开算既重复遍历，又容易在某处漏掉一个条件而对不上。
class RangeSummary {
  const RangeSummary({
    required this.range,
    required this.start,
    required this.end,
    required this.expense,
    required this.income,
    required this.count,
    required this.entryCount,
  });

  factory RangeSummary.of(
    List<Map<String, dynamic>> entries,
    StatsRange range,
    DateTime when,
  ) {
    final start = StatsRange.startOf(range, when);
    final end = StatsRange.endOf(range, when);
    var expense = 0.0;
    var income = 0.0;
    var count = 0;
    for (final entry in entries) {
      if (!inRange(entry, start, end)) continue;
      count++;
      if (isIncome(entry)) {
        income += entryAmount(entry);
      } else {
        expense += entryAmount(entry);
      }
    }
    return RangeSummary(
      range: range,
      start: start,
      end: end,
      expense: expense,
      income: income,
      count: count,
      entryCount: entries.length,
    );
  }

  final StatsRange range;
  final DateTime start;

  /// 结束时间（不含）。
  final DateTime end;

  final double expense;
  final double income;

  /// 区间内的账目条数。
  final int count;

  /// 全部账目条数（用于「共 N 条」的对照）。
  final int entryCount;

  /// 结余。负数表示这个周期花超了。
  double get balance => income - expense;

  /// 日均支出。按周期**已过去的天数**算，而不是整个周期的天数 ——
  /// 本月才过 5 天就除以 30，日均会低得离谱，用户会以为算错了。
  double dailyAverage(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final lastDay = end.subtract(const Duration(days: 1));
    final effectiveEnd = today.isBefore(lastDay) ? today : lastDay;
    final days = effectiveEnd.difference(start).inDays + 1;
    if (days <= 0) return 0;
    return expense / days;
  }
}

/// 区间内各分类的支出，从高到低。
///
/// 与 [expenseByCategory] 的区别：那个只支持自然月，这个支持任意区间。
/// 保留旧函数是因为 AI 摘要（`PromptBuilder`）按自然月取数，口径不能变。
List<MapEntry<String, double>> categoryTotals(
  List<Map<String, dynamic>> entries,
  StatsRange range,
  DateTime when, {
  bool income = false,
}) {
  final start = StatsRange.startOf(range, when);
  final end = StatsRange.endOf(range, when);
  final buckets = <String, double>{};
  for (final entry in entries) {
    if (!inRange(entry, start, end)) continue;
    if (isIncome(entry) != income) continue;
    final category = entry['category']?.toString().trim() ?? '';
    final key = category.isEmpty ? '未分类' : category;
    buckets[key] = (buckets[key] ?? 0) + entryAmount(entry);
  }
  final ranked = buckets.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return ranked;
}

/// 按天汇总区间内的支出，用于柱状图。
///
/// 返回的每项是「某天 → 当天支出」。**包含没有账目的天（值为 0）** ——
/// 图表上必须能看出「哪几天没花钱」，跳过空天会把 7 根柱子画成 3 根，
/// 看上去像是那几天不存在。
///
/// 年视图按 [bucket] 聚合（默认按天会得到 365 根柱子，图上没法看）。
List<({DateTime at, String label, double value})> dailyTotals(
  List<Map<String, dynamic>> entries,
  StatsRange range,
  DateTime when,
) {
  final start = StatsRange.startOf(range, when);
  final end = StatsRange.endOf(range, when);

  if (range == StatsRange.year) {
    // 年视图按月聚合，12 根柱子
    final out = <({DateTime at, String label, double value})>[];
    for (var m = 1; m <= 12; m++) {
      final bucketStart = DateTime(start.year, m);
      final bucketEnd = DateTime(start.year, m + 1);
      var total = 0.0;
      for (final entry in entries) {
        if (isIncome(entry)) continue;
        if (!inRange(entry, bucketStart, bucketEnd)) continue;
        total += entryAmount(entry);
      }
      out.add((at: bucketStart, label: '$m', value: total));
    }
    return out;
  }

  final out = <({DateTime at, String label, double value})>[];
  var cursor = start;
  while (cursor.isBefore(end)) {
    final next = cursor.add(const Duration(days: 1));
    var total = 0.0;
    for (final entry in entries) {
      if (isIncome(entry)) continue;
      if (!inRange(entry, cursor, next)) continue;
      total += entryAmount(entry);
    }
    out.add((
      at: cursor,
      label: range == StatsRange.week
          ? const ['一', '二', '三', '四', '五', '六', '日'][cursor.weekday - 1]
          : '${cursor.day}',
      value: total,
    ));
    cursor = next;
  }
  return out;
}
