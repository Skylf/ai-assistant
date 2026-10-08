import 'package:family_life_assistant/core/stats.dart';
import 'package:flutter_test/flutter_test.dart';

/// 统计周期（自然周/月/年）。
///
/// 这一层是账本「汇总」「分类」两级的唯一数据来源，数字错了会让用户
/// 对整本账失去信任 —— 所以边界必须逐条锁死，尤其是：
///  · 周起点是**周一**还是周日（国内习惯是周一，写错会整周错位）；
///  · 跨月/跨年的周怎么算（9 月 30 日属于哪一周）；
///  · 区间比较是左闭右开（末日 23:59 的账目必须算得进去）。
void main() {
  Map<String, dynamic> entry(
    String at,
    num amount, {
    String type = 'expense',
    String category = '日常',
  }) => {
    'id': '$at-$amount',
    'title': 't',
    'amount': amount,
    'category': category,
    'spentAt': at,
    'entryType': type,
  };

  group('周期起止（自然周期）', () {
    test('自然周从周一开始', () {
      // 2026-09-28 是周一
      final monday = DateTime(2026, 9, 28);
      expect(monday.weekday, DateTime.monday, reason: '前提：这天确实是周一');

      final start = StatsRange.startOf(StatsRange.week, monday);
      expect(start, DateTime(2026, 9, 28));
      expect(StatsRange.endOf(StatsRange.week, monday), DateTime(2026, 10, 5));
    });

    test('周日属于「刚过去的那个周一」开始的那一周', () {
      // 2026-10-04 是周日，它属于 9-28 那一周，而不是 10-05 那一周。
      // 若把周起点写成周日，这里会算出 10-04，整周错位。
      final sunday = DateTime(2026, 10, 4);
      expect(sunday.weekday, DateTime.sunday, reason: '前提：这天确实是周日');
      expect(StatsRange.startOf(StatsRange.week, sunday), DateTime(2026, 9, 28));
    });

    test('周内的每一天都归到同一个周一', () {
      for (var d = 28; d <= 30; d++) {
        expect(
          StatsRange.startOf(StatsRange.week, DateTime(2026, 9, d)),
          DateTime(2026, 9, 28),
          reason: '9 月 $d 日应在同一周',
        );
      }
      for (var d = 1; d <= 4; d++) {
        expect(
          StatsRange.startOf(StatsRange.week, DateTime(2026, 10, d)),
          DateTime(2026, 9, 28),
          reason: '10 月 $d 日应在同一周（跨月）',
        );
      }
      // 10-05 是新的一周
      expect(
        StatsRange.startOf(StatsRange.week, DateTime(2026, 10, 5)),
        DateTime(2026, 10, 5),
      );
    });

    test('自然月起止，含 12 月进位', () {
      expect(
        StatsRange.startOf(StatsRange.month, DateTime(2026, 9, 18)),
        DateTime(2026, 9, 1),
      );
      expect(
        StatsRange.endOf(StatsRange.month, DateTime(2026, 9, 18)),
        DateTime(2026, 10, 1),
      );
      // 12 月 -> 次年 1 月
      expect(
        StatsRange.endOf(StatsRange.month, DateTime(2026, 12, 5)),
        DateTime(2027, 1, 1),
      );
    });

    test('自然年起止', () {
      expect(
        StatsRange.startOf(StatsRange.year, DateTime(2026, 9, 18)),
        DateTime(2026, 1, 1),
      );
      expect(
        StatsRange.endOf(StatsRange.year, DateTime(2026, 9, 18)),
        DateTime(2027, 1, 1),
      );
    });

    test('闰年 2 月的月末正确（2 月 29 日存在）', () {
      // 2028 是闰年
      expect(
        StatsRange.endOf(StatsRange.month, DateTime(2028, 2, 10)),
        DateTime(2028, 3, 1),
      );
      // 2026 不是闰年
      expect(
        StatsRange.endOf(StatsRange.month, DateTime(2026, 2, 10)),
        DateTime(2026, 3, 1),
      );
    });
  });

  group('周期显示名', () {
    test('周显示日期范围', () {
      expect(
        StatsRange.periodLabel(StatsRange.week, DateTime(2026, 9, 30)),
        '9 月 28 日 – 10 月 4 日',
      );
    });

    test('月与年', () {
      expect(
        StatsRange.periodLabel(StatsRange.month, DateTime(2026, 9, 30)),
        '2026 年 9 月',
      );
      expect(
        StatsRange.periodLabel(StatsRange.year, DateTime(2026, 9, 30)),
        '2026 年',
      );
    });
  });

  group('区间汇总 RangeSummary', () {
    final entries = [
      entry('2026-09-28T10:00:00', 50), // 周一 支出
      entry('2026-09-30T10:00:00', 30), // 周三 支出
      entry('2026-10-01T10:00:00', 20), // 下周四 支出（新的一周）
      entry('2026-09-29T09:00:00', 8000, type: 'income'), // 周二 收入
      entry('2026-08-15T10:00:00', 999), // 上月，不该进本月/本周
    ];

    test('周汇总只算本周（周一~周日）', () {
      // 2026-09-30 是周三，本周 = 9/28(一) ~ 10/4(日)
      final s = RangeSummary.of(entries, StatsRange.week, DateTime(2026, 9, 30));
      expect(s.expense, 100, reason: '50 + 30 + 20（10-01 周四仍属本周）');
      expect(s.income, 8000);
      expect(s.balance, 7900);
      expect(s.count, 4);
    });

    test('跨月的那一笔仍算在本周内（周不按自然月切）', () {
      // 这是「自然周」的关键语义：9/28~10/4 这一周横跨 9 月与 10 月，
      // 10-01 的账目属于**本周**，不属于「上一周」。
      // 站在 10-05（下周一）看，它才落到上一周里去。
      final rows = [entry('2026-10-01T10:00:00', 20)];
      expect(
        RangeSummary.of(rows, StatsRange.week, DateTime(2026, 9, 30)).expense,
        20,
        reason: '9-30 所在周包含 10-01',
      );
      expect(
        RangeSummary.of(rows, StatsRange.week, DateTime(2026, 10, 5)).expense,
        0,
        reason: '10-05 是新的一周，不含 10-01',
      );
    });

    test('月汇总算整月，含跨到 10 月的那笔吗？不含', () {
      final s = RangeSummary.of(
        entries,
        StatsRange.month,
        DateTime(2026, 9, 30),
      );
      expect(s.expense, 80, reason: '9 月只有 50 与 30');
      expect(s.count, 3);
    });

    test('年汇总把 8 月与 9、10 月都算进来', () {
      final s = RangeSummary.of(
        entries,
        StatsRange.year,
        DateTime(2026, 9, 30),
      );
      expect(s.expense, 999 + 50 + 30 + 20);
      expect(s.income, 8000);
      expect(s.count, 5);
    });

    test('【回归】区间是左闭右开：周期最后一天 23:59 的账目要算进去', () {
      // 这是最容易错的边界：写成 at.isBefore(end) 且 end 用「最后一天 00:00」
      // 会把末日全天的账目漏掉，用户看到「今天记的没进本月统计」
      final edge = [
        entry('2026-09-30T23:59:59', 100),
        entry('2026-10-01T00:00:00', 999), // 下月第一天零点，不算
      ];
      final s = RangeSummary.of(edge, StatsRange.month, DateTime(2026, 9, 30));
      expect(s.expense, 100);
      expect(s.count, 1);
    });

    test('起始日 00:00 的账目算进去', () {
      final edge = [entry('2026-09-01T00:00:00', 42)];
      final s = RangeSummary.of(edge, StatsRange.month, DateTime(2026, 9, 30));
      expect(s.expense, 42);
    });

    test('空数据不崩，全为 0', () {
      final s = RangeSummary.of(const [], StatsRange.month, DateTime(2026, 9, 30));
      expect(s.expense, 0);
      expect(s.income, 0);
      expect(s.balance, 0);
      expect(s.count, 0);
    });

    test('时间无法解析的账目被跳过，而不是当成 0 或崩掉', () {
      final bad = [
        {'id': 'x', 'amount': 10, 'spentAt': '不是日期'},
        entry('2026-09-10T10:00:00', 5),
      ];
      final s = RangeSummary.of(bad, StatsRange.month, DateTime(2026, 9, 30));
      expect(s.expense, 5);
      expect(s.count, 1);
    });

    test('结余为负表示花超了', () {
      final rows = [
        entry('2026-09-10T10:00:00', 500),
        entry('2026-09-11T10:00:00', 100, type: 'income'),
      ];
      final s = RangeSummary.of(rows, StatsRange.month, DateTime(2026, 9, 30));
      expect(s.balance, -400);
    });
  });

  group('日均支出', () {
    test('本月才过几天就除以几天，而不是除以 30', () {
      final rows = [entry('2026-09-01T10:00:00', 300)];
      final s = RangeSummary.of(rows, StatsRange.month, DateTime(2026, 9, 3));
      // 9 月 1 日到 3 日共 3 天
      expect(s.dailyAverage(DateTime(2026, 9, 3)), 100);
    });

    test('已过去的周期用全周期天数', () {
      final rows = [entry('2026-08-01T10:00:00', 310)];
      final s = RangeSummary.of(rows, StatsRange.month, DateTime(2026, 8, 1));
      // 站在 9 月看 8 月，8 月已结束（31 天），不该按「今天」截断
      expect(s.dailyAverage(DateTime(2026, 9, 15)), 10);
    });

    test('没有账目时返回 0，不产生除零', () {
      final s = RangeSummary.of(
        const [],
        StatsRange.month,
        DateTime(2026, 9, 30),
      );
      expect(s.dailyAverage(DateTime(2026, 9, 30)), 0);
    });
  });

  group('分类统计', () {
    final rows = [
      entry('2026-09-28T10:00:00', 50, category: '餐饮'),
      entry('2026-09-29T10:00:00', 30, category: '餐饮'),
      entry('2026-09-30T10:00:00', 20, category: '交通'),
      entry('2026-09-30T11:00:00', 70, category: ''), // 空分类 -> 未分类
      entry('2026-09-30T12:00:00', 500, type: 'income', category: '工资'),
      entry('2026-10-02T10:00:00', 999, category: '下月'),
    ];

    test('按区间聚合，从高到低', () {
      final ranked = categoryTotals(rows, StatsRange.month, DateTime(2026, 9, 30));
      expect(ranked.map((e) => e.key).toList(), ['餐饮', '未分类', '交通']);
      expect(ranked.first.value, 80, reason: '餐饮 50+30');
      expect(ranked[1].value, 70);
      expect(ranked[2].value, 20);
    });

    test('默认只统计支出，收入不进分类', () {
      final ranked = categoryTotals(rows, StatsRange.month, DateTime(2026, 9, 30));
      expect(ranked.map((e) => e.key), isNot(contains('工资')));
    });

    test('可以单独要收入分类', () {
      final ranked = categoryTotals(
        rows,
        StatsRange.month,
        DateTime(2026, 9, 30),
        income: true,
      );
      expect(ranked.map((e) => e.key).toList(), ['工资']);
      expect(ranked.single.value, 500);
    });

    test('空分类归到「未分类」，不丢金额', () {
      final ranked = categoryTotals(rows, StatsRange.month, DateTime(2026, 9, 30));
      final total = ranked.fold<double>(0, (a, b) => a + b.value);
      expect(total, 170, reason: '50+30+20+70，一分都不能丢');
    });

    test('周区间不包含别的周那笔', () {
      // 10-02 在 9/28~10/4 这一周里；站在 10-07（下周三）看就不该包含它
      final ranked = categoryTotals(rows, StatsRange.week, DateTime(2026, 10, 7));
      expect(ranked.map((e) => e.key), isNot(contains('下月')));
    });
  });

  group('按天/按月取数（图表用）', () {
    test('周视图给出 7 根柱子，含没有账目的 0', () {
      final rows = [entry('2026-09-30T10:00:00', 30)];
      final bars = dailyTotals(rows, StatsRange.week, DateTime(2026, 9, 30));
      expect(bars.length, 7, reason: '一周 7 天，空天也要有柱子');
      expect(bars.map((b) => b.label).toList(), ['一', '二', '三', '四', '五', '六', '日']);
      // 9-28 周一、9-30 周三
      expect(bars[0].value, 0);
      expect(bars[2].value, 30);
      expect(bars.where((b) => b.value == 0).length, 6);
    });

    test('月视图给出当月天数根柱子', () {
      final bars = dailyTotals(const [], StatsRange.month, DateTime(2026, 9, 30));
      expect(bars.length, 30, reason: '9 月有 30 天');
      expect(bars.first.label, '1');
      expect(bars.last.label, '30');
    });

    test('2 月在闰年是 29 天', () {
      expect(
        dailyTotals(const [], StatsRange.month, DateTime(2028, 2, 10)).length,
        29,
      );
      expect(
        dailyTotals(const [], StatsRange.month, DateTime(2026, 2, 10)).length,
        28,
      );
    });

    test('年视图按月聚合成 12 根柱子', () {
      final rows = [
        entry('2026-01-15T10:00:00', 10),
        entry('2026-12-15T10:00:00', 20),
      ];
      final bars = dailyTotals(rows, StatsRange.year, DateTime(2026, 9, 30));
      expect(bars.length, 12);
      expect(bars[0].value, 10);
      expect(bars[11].value, 20);
      expect(bars[5].value, 0);
    });

    test('图表只统计支出，收入不参与', () {
      final rows = [
        entry('2026-09-30T10:00:00', 30),
        entry('2026-09-30T11:00:00', 5000, type: 'income'),
      ];
      final bars = dailyTotals(rows, StatsRange.week, DateTime(2026, 9, 30));
      expect(bars[2].value, 30, reason: '收入不该进支出柱状图');
    });
  });

  group('与旧口径一致（不能悄悄改变已有语义）', () {
    test('categoryTotals 的月结果 == expenseByCategory 的结果', () {
      // AI 摘要用的是 expenseByCategory（只支持自然月）。
      // 新的区间版必须与之完全一致，否则界面与 AI 说的数字会对不上。
      final rows = [
        entry('2026-09-01T10:00:00', 10, category: 'A'),
        entry('2026-09-02T10:00:00', 25, category: 'B'),
        entry('2026-09-03T10:00:00', 5, category: 'A'),
        entry('2026-09-04T10:00:00', 7, category: ''),
      ];
      final old = expenseByCategory(rows, DateTime(2026, 9, 15));
      final fresh = categoryTotals(rows, StatsRange.month, DateTime(2026, 9, 15));
      expect(
        fresh.map((e) => '${e.key}=${e.value}').toList(),
        old.map((e) => '${e.key}=${e.value}').toList(),
      );
    });
  });
}
