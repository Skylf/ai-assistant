import 'package:family_life_assistant/core/stats.dart';
import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/main.dart';
import 'package:family_life_assistant/pages/expenses.dart';
import 'package:family_life_assistant/widgets/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 账本三级视图（0.4B 改版）。
///
/// 用户提的原话是「账本页面现在的 UI 是所有账本功能都挤在一起，太乱了」。
/// 所以这一组断言的核心是**「什么不该出现在第一级」**：
/// 本月总收支、本月分类统计都必须从第一级消失，只留在汇总/分类级。
/// 只断言「新东西在」而不断言「旧东西不在」，改版就没法证明真的变清爽了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = 'plugins.it_nomads.com/flutter_secure_storage';

  setUp(() {
    // 安全存储没有桌面测试实现，统一返回空值让 Store 落到默认配置。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(secureStorageChannel),
          (call) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(secureStorageChannel),
          null,
        );
  });

  Future<Store> openStore() async {
    final store = Store(db: FakeDb());
    await store.load();
    return store;
  }

  Future<void> pumpApp(WidgetTester tester, Store store) async {
    await tester.pumpWidget(FamilyLifeAssistantApp(store: store));
    await tester.pumpAndSettle();
  }

  /// 造一笔账目。日期用 [dayOffset] 相对今天，便于构造「本周/上月」数据。
  Future<void> add(
    Store store,
    String title,
    double amount, {
    String category = '日常',
    String type = 'expense',
    int dayOffset = 0,
    int hour = 10,
  }) async {
    final at = DateTime.now().add(Duration(days: dayOffset));
    await store.expense({
      'title': title,
      'amount': amount,
      'category': category,
      'entryType': type,
      'spentAt': DateTime(
        at.year,
        at.month,
        at.day,
        hour,
      ).toIso8601String(),
    });
  }

  Future<ExpensesPageState> openLedger(WidgetTester tester, Store store) async {
    await pumpApp(tester, store);
    await tester.tap(find.text('账本').last);
    await tester.pumpAndSettle();
    return tester.state<ExpensesPageState>(find.byType(ExpensesPage));
  }

  /// 点第一级的分区标签（今日/汇总/分类）。
  ///
  /// ⚠️ 必须精确限定范围。踩过两个坑：
  ///  ① 写成 `find.widgetWithText(SegmentedTabs<LedgerLevel>, '汇总')` 会**同时
  ///     匹配到汇总级里 `StatsRange.month`（「月」）那个分组控件** ——
  ///     `widgetWithText` 匹配的是「某个祖先 + 后代文本」，泛型并不会把后代限制住。
  ///     于是 tap 打在汇总级自己的周期标签上，level 一直停在 summary，
  ///     表现为「切回今日失败」这种看起来像产品 bug 的假象。
  ///  ② `find.byType(SegmentedTabs<LedgerLevel>)` 能匹配，但**只能**匹配账本这一个；
  ///     `find.byType(SegmentedTabs)`（裸泛型）则一个都匹配不到。
  ///
  /// 所以页面给分区控件挂了固定 Key，这里按 Key 定位 —— 与产品代码的耦合最小。
  Future<void> switchTo(WidgetTester tester, String label) async {
    final tab = find.descendant(
      of: find.byKey(const Key('ledger-level-tabs')),
      matching: find.text(label),
    );
    expect(tab, findsOneWidget, reason: '第一级标签「$label」应当唯一');
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  /// 点周/月/年周期标签。同理限定在 StatsRange 那个分组控件里。
  Future<void> switchRange(WidgetTester tester, String label) async {
    final tab = find.descendant(
      of: find.byType(SegmentedTabs<StatsRange>),
      matching: find.text(label),
    );
    expect(tab, findsOneWidget, reason: '周期标签「$label」应当唯一');
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  group('第一级：今日', () {
    testWidgets('默认就在第一级，显示当天收支三栏', (tester) async {
      final store = await openStore();
      await add(store, '买菜', 32);
      await add(store, '工资', 8000, type: 'income', category: '收入');

      await openLedger(tester, store);

      expect(find.text('收入'), findsWidgets);
      expect(find.text('支出'), findsWidgets);
      expect(find.text('结余'), findsWidgets);
      // 当天明细里有这笔
      expect(find.text('买菜'), findsOneWidget);
    });

    testWidgets('【关键】第一级不显示本月总收支与本月分类统计', (tester) async {
      final store = await openStore();
      await add(store, '买菜', 32);
      // 上月的一笔，用来让「本月」与「当天」的数字拉开差距
      await add(store, '上月房租', 3000, category: '住房', dayOffset: -40);

      await openLedger(tester, store);

      // 旧版的这几个东西必须消失
      expect(find.text('本月收支'), findsNothing);
      expect(find.text('本月分类统计'), findsNothing);
      expect(find.text('较上月 —'), findsNothing);
      // 当天的支出只有 32，不该出现 3000 这个「本月」数字
      expect(find.textContaining('3000'), findsNothing);
    });

    testWidgets('【关键】不显示大标题与副标题', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);

      expect(find.text('家庭账本'), findsNothing);
      expect(find.text('记录每一笔，过更有规划的生活'), findsNothing);
    });

    testWidgets('第一级有且只有一个记账入口（不重复放按钮）', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);

      // 0.4B：原来 FAB 与页面内整宽按钮是同一个动作的两个入口，同时出现在一屏上。
      // 用户这轮要求的正是「不要挤在一起」，所以只保留页面内那个整宽按钮。
      expect(
        find.text('记一笔'),
        findsOneWidget,
        reason: '记账入口只应有一个（整宽按钮）',
      );
      expect(
        find.byType(FloatingActionButton),
        findsNothing,
        reason: '不应再有重复的悬浮记账按钮',
      );
    });

    testWidgets('空状态文案保留（旧测试依赖）', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);

      expect(find.text('当天还没有账目'), findsOneWidget);
    });

    testWidgets('可以按天往前翻，翻到那天显示那天的账', (tester) async {
      final store = await openStore();
      await add(store, '今天的菜', 10);
      await add(store, '昨天的饭', 20, dayOffset: -1);

      await openLedger(tester, store);
      expect(find.text('今天的菜'), findsOneWidget);
      expect(find.text('昨天的饭'), findsNothing);

      await tester.tap(find.byTooltip('上一个'));
      await tester.pumpAndSettle();

      expect(find.text('昨天的饭'), findsOneWidget);
      expect(find.text('今天的菜'), findsNothing);
      // 不在今天时给出「回到今天」，否则用户可能迷路
      expect(find.text('回到今天'), findsOneWidget);
    });
  });

  group('第二级：汇总', () {
    testWidgets('显示周/月/年三个周期标签', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);
      await switchTo(tester, '汇总');

      for (final label in ['周', '月', '年']) {
        expect(
          find.descendant(
            of: find.byType(SegmentedTabs<StatsRange>),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: '汇总级应有「$label」周期标签',
        );
      }
    });

    testWidgets('给出文字数据：支出、收入、结余、日均', (tester) async {
      final store = await openStore();
      await add(store, '买菜', 100);
      await add(store, '工资', 5000, type: 'income', category: '收入');

      await openLedger(tester, store);
      await switchTo(tester, '汇总');

      expect(find.text('支出'), findsWidgets);
      expect(find.text('收入'), findsWidgets);
      expect(find.text('结余'), findsWidgets);
      expect(find.text('平均每天'), findsOneWidget);
      expect(find.text('¥100.00'), findsWidgets);
      expect(find.text('¥5000.00'), findsWidgets);
    });

    testWidgets('给出图表（柱状图而不是只打印数字）', (tester) async {
      final store = await openStore();
      await add(store, '买菜', 100);

      await openLedger(tester, store);
      await switchTo(tester, '汇总');

      expect(find.byType(SpendBars), findsOneWidget);
    });

    testWidgets('切到「年」会换成各月聚合的标题', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);
      await switchTo(tester, '汇总');

      expect(find.text('每天支出'), findsOneWidget);

      await switchRange(tester, '年');

      expect(find.text('各月支出'), findsOneWidget);
      expect(find.text('每天支出'), findsNothing);
    });

    testWidgets('周期的文字标签跟着走（月显示年月）', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);
      await switchTo(tester, '汇总');

      final now = DateTime.now();
      expect(
        find.text(StatsRange.periodLabel(StatsRange.month, now)),
        findsOneWidget,
      );
    });
  });

  group('第三级：分类', () {
    testWidgets('按分类列出金额与占比', (tester) async {
      final store = await openStore();
      await add(store, '午饭', 60, category: '餐饮');
      await add(store, '打车', 40, category: '交通');

      await openLedger(tester, store);
      await switchTo(tester, '分类');

      expect(find.text('餐饮'), findsWidgets);
      expect(find.text('交通'), findsWidgets);
      expect(find.text('¥60.00'), findsWidgets);
      expect(find.text('¥40.00'), findsWidgets);
      // 60/100 = 60%，40/100 = 40%
      expect(find.text('60%'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      expect(find.byType(CategoryStatRow), findsNWidgets(2));
    });

    testWidgets('分类页也有周/月/年切换', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);
      await switchTo(tester, '分类');

      expect(find.byType(SegmentedTabs<StatsRange>), findsOneWidget);
    });

    testWidgets('没有支出时给出空状态而不是空白页', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);
      await switchTo(tester, '分类');

      expect(find.text('这个周期还没有支出'), findsOneWidget);
      expect(find.byType(CategoryStatRow), findsNothing);
    });

    testWidgets('收入分类单独一组，不混进支出占比', (tester) async {
      final store = await openStore();
      await add(store, '午饭', 60, category: '餐饮');
      await add(store, '工资', 5000, type: 'income', category: '收入');

      await openLedger(tester, store);
      await switchTo(tester, '分类');

      expect(find.text('支出分类'), findsOneWidget);
      expect(find.text('收入分类'), findsOneWidget);

      // 支出占比必须按 60 算（=100%），不能被 5000 的收入稀释成 1.2%。
      // 注意不能断言「100% 只出现一次」：餐饮 60/60 与收入 5000/5000
      // 都合法地显示 100%，那样写会误判成失败（我第一版就这么写的）。
      expect(find.text('合计 ¥60.00'), findsOneWidget);
      // 两个分组各一行，没有互相串组
      expect(find.byType(CategoryStatRow), findsNWidgets(2));
      // 支出那一行的金额是 60
      expect(
        find.descendant(
          of: find.byType(CategoryStatRow),
          matching: find.text('¥60.00'),
        ),
        findsOneWidget,
      );
    });
  });

  group('三级之间互不干扰', () {
    testWidgets('切走再切回，选中的日期与周期都保留', (tester) async {
      final store = await openStore();
      await add(store, '昨天的饭', 20, dayOffset: -1);

      final state = await openLedger(tester, store);
      await tester.tap(find.byTooltip('上一个'));
      await tester.pumpAndSettle();
      final chosen = state.selected;

      await switchTo(tester, '汇总');
      await switchTo(tester, '今日');

      expect(state.selected, chosen, reason: '切走再回来不该重置日期');
      expect(find.text('昨天的饭'), findsOneWidget);
    });

    testWidgets('汇总与分类用同一套周期选择（不会一处改了另一处没变）', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);

      await switchTo(tester, '汇总');
      await switchRange(tester, '年');

      await switchTo(tester, '分类');
      final state = tester.state<ExpensesPageState>(find.byType(ExpensesPage));
      expect(state.range, StatsRange.year, reason: '周期选择是共用的状态');
    });

    testWidgets('切到第二三级时记账入口收起（避免误触与遮挡）', (tester) async {
      final store = await openStore();
      await openLedger(tester, store);
      expect(find.text('记一笔'), findsOneWidget);

      await switchTo(tester, '汇总');
      expect(find.text('记一笔'), findsNothing, reason: '汇总级不该有记账入口');

      await switchTo(tester, '分类');
      expect(find.text('记一笔'), findsNothing, reason: '分类级不该有记账入口');

      await switchTo(tester, '今日');
      expect(find.text('记一笔'), findsOneWidget, reason: '切回第一级要恢复记账入口');
    });
  });
}
