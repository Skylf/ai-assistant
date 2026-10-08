import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/main.dart';
import 'package:family_life_assistant/pages/meds.dart';
import 'package:family_life_assistant/widgets/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 药箱两级视图（0.4B 改版）。
///
/// 用户要求：「药箱页面分多级显示：第一级显示药箱列表，去除全部药品、已过期
/// 药品、即将过期与常用药的统计显示；第一级右滑显示具体统计信息页面；
/// 去除上方家庭药箱的大标题显示」。
///
/// 与账本那组测试同样的原则：**必须断言「旧东西不在」**。
/// 只断言「药品列表还在」的话，四张统计卡留在原地也照样通过 ——
/// 而那正是用户嫌乱的东西。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = 'plugins.it_nomads.com/flutter_secure_storage';

  setUp(() {
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

  /// 造一个药品。[expiryOffset] 为到期日的天数偏移（负数为已过期）。
  Future<void> addMed(
    Store store,
    String name, {
    int? expiryOffset,
    int stock = 1,
    String? tag,
  }) async {
    final expiry = expiryOffset == null
        ? null
        : DateTime.now().add(Duration(days: expiryOffset));
    await store.med({
      'name': name,
      'stock': stock,
      if (expiry != null)
        'expiry': '${expiry.year.toString().padLeft(4, '0')}-'
            '${expiry.month.toString().padLeft(2, '0')}-'
            '${expiry.day.toString().padLeft(2, '0')}',
      if (tag != null) 'note': '[$tag]',
    });
  }

  /// 断言某条统计行（`StatLine`，形如「已过期 … 1 种」）的数值。
  ///
  /// ⚠️ 不能直接 `find.text('1 种')`：「分类分布」区里每个分类也各显示一个
  /// 「N 种」，两个区域会撞在一起（实测「1 种」有 5 个匹配）。
  /// 所以先用标签文字**向上找到它所在的那一行**，再在这一行里断言数值。
  void expectStat(String label, String value) {
    final row = find.ancestor(
      of: find.text(label),
      matching: find.byType(StatLine),
    );
    expect(row, findsOneWidget, reason: '应当有且只有一条「$label」统计行');
    expect(
      find.descendant(of: row, matching: find.text(value)),
      findsOneWidget,
      reason: '「$label」的值应当是「$value」',
    );
  }

  Future<MedsPageState> openMeds(WidgetTester tester, Store store) async {
    await pumpApp(tester, store);
    await tester.tap(find.text('药箱').last);
    await tester.pumpAndSettle();
    return tester.state<MedsPageState>(find.byType(MedsPage));
  }

  /// 点分区标签。按 `key` 定位，不按类型 —— `SegmentedTabs<MedsLevel>` 是泛型，
  /// `find.byType(SegmentedTabs)` 一个都匹配不到。
  Future<void> switchTo(WidgetTester tester, String label) async {
    final tab = find.descendant(
      of: find.byKey(const Key('meds-level-tabs')),
      matching: find.text(label),
    );
    expect(tab, findsOneWidget, reason: '分区标签「$label」应当唯一');
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  group('第一级：药品列表', () {
    testWidgets('默认停在列表级，显示药品列表与总数', (tester) async {
      final store = await openStore();
      await addMed(store, '布洛芬缓释胶囊', expiryOffset: 300, stock: 2);
      await addMed(store, '蒙脱石散', expiryOffset: 20);

      final state = await openMeds(tester, store);

      expect(state.level, MedsLevel.list, reason: '默认必须停在第一级');
      expect(find.text('药品列表'), findsOneWidget);
      expect(find.text('共 2 种'), findsOneWidget);
      expect(find.text('布洛芬缓释胶囊'), findsOneWidget);
      expect(find.text('蒙脱石散'), findsOneWidget);
    });

    testWidgets('【关键】第一级不再有四张统计卡', (tester) async {
      final store = await openStore();
      await addMed(store, '蒙脱石散', expiryOffset: 20);
      await addMed(store, '过期药', expiryOffset: -5);

      await openMeds(tester, store);

      // 用户嫌乱的正是这四条统计信息，必须从第一级消失
      expect(find.text('药箱概览'), findsNothing);
      expect(find.text('全部药品'), findsNothing);
      expect(find.text('已过期'), findsNothing);
      expect(find.text('即将过期'), findsNothing);
      expect(find.text('常用药'), findsNothing);
      expect(find.textContaining('30 天内到期'), findsNothing);
    });

    testWidgets('【关键】第一级不再有大标题「家庭药箱」', (tester) async {
      final store = await openStore();
      await addMed(store, '蒙脱石散');

      await openMeds(tester, store);

      expect(find.text('家庭药箱'), findsNothing);
      expect(find.text('科学用药，守护家人健康'), findsNothing);
    });

    testWidgets('第一级保留搜索与筛选（不是把功能也一起删了）', (tester) async {
      final store = await openStore();
      await addMed(store, '蒙脱石散');

      await openMeds(tester, store);

      expect(find.text('搜索药品名称 / 通用名 / 成分'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('常用'), findsOneWidget);
    });

    testWidgets('列表级才显示「添加药品」按钮，统计级不显示', (tester) async {
      final store = await openStore();
      await addMed(store, '蒙脱石散');

      await openMeds(tester, store);
      expect(find.byType(FloatingActionButton), findsOneWidget);

      await switchTo(tester, '统计');
      expect(
        find.byType(FloatingActionButton),
        findsNothing,
        reason: '统计级不该有添加入口，避免误触',
      );

      await switchTo(tester, '药品');
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('空药箱显示引导文案，不是空白页', (tester) async {
      final store = await openStore();

      await openMeds(tester, store);

      expect(find.text('还没有药品'), findsOneWidget);
    });
  });

  group('第二级：统计', () {
    testWidgets('【关键】统计级显示四类数量，数字正确', (tester) async {
      final store = await openStore();
      await addMed(store, '过期药', expiryOffset: -5);
      await addMed(store, '快过期药', expiryOffset: 10);
      await addMed(store, '很久以后过期', expiryOffset: 400);
      await addMed(store, '常用药片', tag: '常用');

      await openMeds(tester, store);
      await switchTo(tester, '统计');

      expect(find.text('药箱概览'), findsOneWidget);
      expect(find.text('全部药品'), findsOneWidget);
      expect(find.text('已过期'), findsOneWidget);
      expect(find.text('即将过期'), findsOneWidget);
      expect(find.text('常用药'), findsOneWidget);

      // 4 种、1 种过期、1 种即将过期、1 种常用 —— 逐行断言，避免与
      // 「分类分布」里的「N 种」互相干扰
      expectStat('全部药品', '4 种');
      expectStat('已过期', '1 种');
      expectStat('即将过期', '1 种');
      expectStat('常用药', '1 种');
      expect(find.text('30 天内到期'), findsOneWidget);
    });

    testWidgets('统计级给出保质期完整性与分类分布', (tester) async {
      final store = await openStore();
      await addMed(store, '有保质期', expiryOffset: 100);
      await addMed(store, '没填保质期');

      await openMeds(tester, store);
      await switchTo(tester, '统计');

      expect(find.text('保质期完整性'), findsOneWidget);
      expect(find.textContaining('种已填保质期'), findsOneWidget);
      expect(find.text('分类分布'), findsOneWidget);
    });

    testWidgets('切换分区不丢数据，来回切都正确', (tester) async {
      final store = await openStore();
      await addMed(store, '蒙脱石散', expiryOffset: 20);

      final state = await openMeds(tester, store);
      expect(state.level, MedsLevel.list);

      await switchTo(tester, '统计');
      expect(state.level, MedsLevel.stats);
      expect(find.text('药箱概览'), findsOneWidget);

      await switchTo(tester, '药品');
      expect(state.level, MedsLevel.list);
      expect(find.text('蒙脱石散'), findsOneWidget);
      expect(find.text('药箱概览'), findsNothing);
    });

    testWidgets('没有药品时统计级也不崩（空数据边界）', (tester) async {
      final store = await openStore();

      await openMeds(tester, store);
      await switchTo(tester, '统计');

      expect(find.text('药箱概览'), findsOneWidget);
      expect(find.text('0 种'), findsWidgets);
      // 全空时不能出现除零导致的 NaN
      expect(find.textContaining('NaN'), findsNothing);
      expect(find.textContaining('Infinity'), findsNothing);
    });
  });
}
