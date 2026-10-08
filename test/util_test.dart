import 'package:family_life_assistant/core/util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatDate', () {
    test('解析 ISO 时间', () {
      expect(formatDate('2026-09-18T12:32:57.000'), '2026-09-18');
    });

    test('解析纯日期', () {
      expect(formatDate('2026-09-18'), '2026-09-18');
    });

    test('空值返回占位文案', () {
      expect(formatDate(null), '未填写');
      expect(formatDate('   '), '未填写');
      expect(formatDate(null, unknown: '日期未知'), '日期未知');
    });

    test('无法解析的文本返回占位文案', () {
      expect(formatDate('下个月'), '未填写');
    });
  });

  group('money', () {
    test('始终保留两位小数', () {
      expect(money(78), '¥78.00');
      expect(money(78.5), '¥78.50');
      expect(money(0), '¥0.00');
      expect(money(1234.567), '¥1234.57');
    });
  });

  group('parseAmount', () {
    test('接受合法金额', () {
      expect(parseAmount('12.5'), 12.5);
      expect(parseAmount(' 8 '), 8);
      expect(parseAmount('0'), 0);
    });

    test('拒绝非法输入', () {
      expect(parseAmount(''), isNull);
      expect(parseAmount('abc'), isNull);
      expect(parseAmount('-3'), isNull);
      expect(parseAmount('1e999'), isNull);
    });
  });

  group('parseCount', () {
    test('接受非负整数', () {
      expect(parseCount('3'), 3);
      expect(parseCount('0'), 0);
    });

    test('拒绝小数与非法输入', () {
      expect(parseCount('1.5'), isNull);
      expect(parseCount('-1'), isNull);
      expect(parseCount(''), isNull);
    });
  });

  group('ExpiryInfo', () {
    final now = DateTime(2026, 9, 18);

    test('未填写时不判定过期', () {
      final info = ExpiryInfo.parse('');
      expect(info.hasDate, isFalse);
      expect(info.isExpired(now), isFalse);
      expect(info.daysLeft(now), isNull);
    });

    test('过期当天算已过期', () {
      expect(ExpiryInfo.parse('2026-09-18').isExpired(now), isTrue);
      expect(ExpiryInfo.parse('2026-09-17').isExpired(now), isTrue);
      expect(ExpiryInfo.parse('2026-09-19').isExpired(now), isFalse);
    });

    test('剩余天数按自然日计算', () {
      expect(ExpiryInfo.parse('2026-09-18').daysLeft(now), 0);
      expect(ExpiryInfo.parse('2026-09-28').daysLeft(now), 10);
      expect(ExpiryInfo.parse('2026-09-08').daysLeft(now), -10);
    });

    test('90 天窗口包含今天与边界，不含已过期', () {
      expect(ExpiryInfo.parse('2026-09-18').isExpiringWithin(90, now), isTrue);
      expect(ExpiryInfo.parse('2026-12-17').isExpiringWithin(90, now), isTrue);
      expect(ExpiryInfo.parse('2026-12-18').isExpiringWithin(90, now), isFalse);
      expect(ExpiryInfo.parse('2026-09-17').isExpiringWithin(90, now), isFalse);
    });

    test('到期当天只算已过期，不再重复计入临期列表', () {
      final today = ExpiryInfo.parse('2026-09-18');
      expect(today.isExpired(now), isTrue);
      expect(today.daysLeft(now), 0);
      // 统计页按「已过期」优先展示，临期窗口从明天算起
      expect(ExpiryInfo.parse('2026-09-19').isExpiringWithin(90, now), isTrue);
    });
  });
}
