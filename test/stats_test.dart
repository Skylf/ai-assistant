import 'package:family_life_assistant/core/stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> row(
    String title,
    num amount,
    String spentAt, {
    String type = 'expense',
  }) => {
    'id': title,
    'title': title,
    'amount': amount,
    'spentAt': spentAt,
    'entryType': type,
    'category': '日常',
  };

  final entries = [
    row('买菜', 100, '2026-09-18T10:00:00.000'),
    row('打车', 20.5, '2026-09-01T08:00:00.000'),
    row('工资', 8000, '2026-09-10T09:00:00.000', type: 'income'),
    row('上月房租', 3000, '2026-08-31T09:00:00.000'),
    row('坏数据', 999, '不是日期'),
  ];

  final september = DateTime(2026, 9, 18);

  group('sumEntries', () {
    test('当月支出不含收入（旧版首页把收入算进了支出）', () {
      expect(sumEntries(entries, september, income: false), 120.5);
    });

    test('当月收入单独统计', () {
      expect(sumEntries(entries, september, income: true), 8000);
    });

    test('不传 income 时统计全部', () {
      expect(sumEntries(entries, september), 8120.5);
    });

    test('不跨月也不跨年', () {
      expect(sumEntries(entries, DateTime(2026, 8, 18), income: false), 3000);
      expect(sumEntries(entries, DateTime(2025, 9, 18)), 0);
    });

    test('时间无法解析的账目被忽略', () {
      final withBadDate = [...entries, row('坏数据2', 500, '')];
      expect(sumEntries(withBadDate, september), 8120.5);
      expect(countEntries(withBadDate, september), 3);
    });

    test('按日统计', () {
      expect(
        sumEntries(entries, DateTime(2026, 9, 18), income: false, month: false),
        100,
      );
      expect(
        sumEntries(entries, DateTime(2026, 9, 1), income: false, month: false),
        20.5,
      );
      expect(
        sumEntries(entries, DateTime(2026, 9, 10), income: true, month: false),
        8000,
      );
    });
  });

  group('expenseByCategory', () {
    test('只统计支出且按金额降序', () {
      final rows = [
        row('买菜', 100, '2026-09-18T10:00:00.000')..['category'] = '餐饮',
        row('打车', 60, '2026-09-18T11:00:00.000')..['category'] = '交通',
        row('水果', 40, '2026-09-19T11:00:00.000')..['category'] = '餐饮',
        row('工资', 8000, '2026-09-10T09:00:00.000', type: 'income')
          ..['category'] = '收入',
      ];
      final ranked = expenseByCategory(rows, september);
      expect(ranked.length, 2);
      expect(ranked.first.key, '餐饮');
      expect(ranked.first.value, 140);
      expect(ranked.last.key, '交通');
    });

    test('空分类归入未分类', () {
      final rows = [
        row('杂项', 5, '2026-09-18T10:00:00.000')..['category'] = '',
      ];
      expect(expenseByCategory(rows, september).first.key, '未分类');
    });
  });

  group('countEntries', () {
    test('当月条数', () {
      expect(countEntries(entries, september), 3);
    });

    test('当日条数', () {
      expect(countEntries(entries, september, month: false), 1);
    });
  });
}
