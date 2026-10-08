import 'package:intl/intl.dart';

/// 统一日期展示，避免各页面各写一套 tryParse。
///
/// 解析失败时返回 [unknown]（默认「未填写」），而不是抛出异常。
String formatDate(dynamic raw, {String unknown = '未填写'}) {
  final text = raw?.toString().trim() ?? '';
  if (text.isEmpty) return unknown;
  final parsed = DateTime.tryParse(text);
  return parsed == null ? unknown : DateFormat('yyyy-MM-dd').format(parsed);
}

/// 账目按「当日」归组的键，用于同一天内比较。
bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 药品有效期的解析结果，集中处理空值与非日期文本。
class ExpiryInfo {
  const ExpiryInfo(this.date, this.hasDate);

  /// 解析成功时的有效期；失败为 null。
  final DateTime? date;

  /// 是否填写了可识别的有效期。
  final bool hasDate;

  /// 是否已经过期。过期当天即视为过期，避免「今天到期」的药品被算成安全。
  bool isExpired(DateTime now) {
    final d = date;
    if (d == null) return false;
    final day = DateTime(d.year, d.month, d.day);
    final today = DateTime(now.year, now.month, now.day);
    return !day.isAfter(today);
  }

  /// 距离到期还有多少天；未填写有效期时为 null。
  int? daysLeft(DateTime now) {
    final d = date;
    if (d == null) return null;
    final today = DateTime(now.year, now.month, now.day);
    return DateTime(d.year, d.month, d.day).difference(today).inDays;
  }

  /// 是否在 [days] 天内到期（不含已过期）。
  bool isExpiringWithin(int days, DateTime now) {
    final left = daysLeft(now);
    return left != null && left >= 0 && left <= days;
  }

  factory ExpiryInfo.parse(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return const ExpiryInfo(null, false);
    final parsed = DateTime.tryParse(text);
    return ExpiryInfo(parsed, parsed != null);
  }
}

/// 金额展示：始终两位小数，避免出现 `¥78.0` 这种不齐的排版。
String money(num value) => '¥${value.toStringAsFixed(2)}';

/// 把用户输入解析成金额；非法或负数返回 null。
double? parseAmount(String raw) {
  final value = double.tryParse(raw.trim());
  if (value == null || value.isNaN || value.isInfinite || value < 0) return null;
  return value;
}

/// 把用户输入解析成非负整数库存；非法返回 null。
int? parseCount(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final value = int.tryParse(text);
  if (value == null || value < 0) return null;
  return value;
}
