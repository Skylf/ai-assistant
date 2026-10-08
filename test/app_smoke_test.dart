import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/main.dart';
import 'package:family_life_assistant/pages/chat.dart';
import 'package:family_life_assistant/pages/expenses.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 冒烟测试：把整个 App 跑起来。
///
/// 旧的 `widget_test.dart` 是 `flutter create` 留下的计数器模板，引用了早已
/// 不存在的 `MyApp`，`flutter test` 直接编译失败。这里替换成对真实入口的验证：
/// 真实 Store + 真实页面树，只把数据库换成内存实现。
/// 同一个标题可能同时出现在首页「最近记录」和账本页，断言时限定在账本页内。
Finder inExpensesPage(Finder finder) =>
    find.descendant(of: find.byType(ExpensesPage), matching: finder);

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

  /// 滚动到目标可见再操作。
  ///
  /// 0.4D 药品详情页新增了「用法与药效 / 安全信息 / 资料出处」几个分区，
  /// 「询问 AI」按钮因此被推到首屏之外 —— 直接 `tap` 会因为「控件存在但
  /// 不在可点位置」而失败（错误信息是 'Found 0 widgets'，很容易误判成控件没了）。
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    if (target.evaluate().isNotEmpty) {
      await tester.ensureVisible(target.first);
      await tester.pumpAndSettle();
      return;
    }
    await tester.scrollUntilVisible(
      target,
      160,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpApp(WidgetTester tester, Store store) async {
    await tester.pumpWidget(FamilyLifeAssistantApp(store: store));
    await tester.pumpAndSettle();
  }

  /// 切到 AI Tab。0.4A 之后这里显示的是两个模块的入口页，不是对话页。
  Future<void> openAiTab(WidgetTester tester) async {
    await tester.tap(find.text('AI').last);
    await tester.pumpAndSettle();
  }

  /// 从 AI 入口页进入某个模块。
  Future<void> enterMode(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
  }

  /// 走到某个模块的对话页（AI Tab → 入口页 → 模块介绍页 → 创建对话）。
  Future<void> openMode(WidgetTester tester, String label) async {
    await openAiTab(tester);
    await enterMode(tester, label);
    await tester.tap(find.text('创建对话'));
    await tester.pumpAndSettle();
  }

  testWidgets('应用能启动并显示首页', (tester) async {
    final store = await openStore();
    await pumpApp(tester, store);

    expect(find.text('家庭生活助手'), findsWidgets);
    expect(find.text('本月概览'), findsOneWidget);
    expect(find.text('本月支出'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('五个 Tab 都可以切换且不报错', (tester) async {
    final store = await openStore();
    await pumpApp(tester, store);

    for (final label in ['账本', '药箱', 'AI', '设置', '首页']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '切换到 $label 时出错');
    }
  });

  testWidgets('空数据状态下给出空状态提示', (tester) async {
    final store = await openStore();
    await pumpApp(tester, store);

    // 首页底部「最近记录」在首屏之外，先滚动到可见位置再断言
    await tester.scrollUntilVisible(
      find.text('暂无记录'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('暂无记录'), findsOneWidget);

    await tester.tap(find.text('药箱').last);
    await tester.pumpAndSettle();
    expect(find.text('还没有药品'), findsOneWidget);

    await tester.tap(find.text('账本').last);
    await tester.pumpAndSettle();
    expect(find.text('当天还没有账目'), findsOneWidget);
  });

  testWidgets('记账后首页本月支出不含收入', (tester) async {
    final store = await openStore();
    await store.expense({
      'title': '买菜',
      'amount': 100.0,
      'category': '日常',
      'entryType': 'expense',
      'spentAt': DateTime.now().toIso8601String(),
    });
    await store.expense({
      'title': '工资',
      'amount': 8000.0,
      'category': '收入',
      'entryType': 'income',
      'spentAt': DateTime.now().toIso8601String(),
    });

    await pumpApp(tester, store);

    // 首页「本月概览」的支出格只统计支出，收入不算进去。旧版把两者加在一起
    // 显示 ¥8100.00。收入金额本身应只出现在账本页的「收入」栏与结余里。
    expect(find.text('¥100.00'), findsWidgets);
    expect(find.text('¥8100.00'), findsNothing);

    await tester.tap(find.text('账本').last);
    await tester.pumpAndSettle();
    // 0.4B：账本第一级显示的是**当天**收支三栏（收入/支出/结余），
    // 不再是旧的「本月收支」卡。这里两笔都记在今天，所以金额相同；
    // 「本月统计只在汇总级出现」由 ledger_levels_test.dart 专门断言。
    expect(inExpensesPage(find.text('¥8000.00')), findsWidgets);
    expect(inExpensesPage(find.text('¥7900.00')), findsWidgets); // 结余
    expect(inExpensesPage(find.text('本月收支')), findsNothing);
  });

  testWidgets('AI Tab 先显示两个模块入口，进入后各自独立', (tester) async {
    final store = await openStore();
    await pumpApp(tester, store);

    await openAiTab(tester);
    // 点 AI 先看到两个入口，而不是直接进对话
    expect(find.text('账本分析'), findsOneWidget);
    expect(find.text('健康科普'), findsOneWidget);
    expect(find.byType(ChatPage), findsNothing);

    // 进入账本分析：先到介绍页，没有输入框
    await enterMode(tester, '账本分析');
    expect(find.text('你好，我是账本分析助手'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(ChatPage), findsNothing);

    // 返回入口页，再进健康科普：介绍卡与安全声明换成健康模块的
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await enterMode(tester, '健康科普');
    expect(find.text('你好，我是健康科普助手'), findsOneWidget);
    expect(find.textContaining('健康科普不构成诊断、处方'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两个模块的对话与消息互不可见', (tester) async {
    final store = await openStore();
    await pumpApp(tester, store);

    // 账本模块里创建一个对话并发一句话
    await openMode(tester, '账本分析');
    final financeChat = tester.state<ChatPageState>(find.byType(ChatPage));
    financeChat.pending.value = '这个月花了多少钱？';
    await tester.pumpAndSettle();
    expect(store.messages.first.content, '这个月花了多少钱？');

    // 退到入口页，再进健康模块
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await enterMode(tester, '健康科普');
    await tester.pumpAndSettle();

    // 健康模块的介绍页上看不到账本模块的任何消息
    expect(find.text('这个月花了多少钱？'), findsNothing);
    expect(find.text('你好，我是健康科普助手'), findsOneWidget);

    // 健康模块里创建一个对话并发一句话，同样不能串回账本模块
    await tester.tap(find.text('创建对话'));
    await tester.pumpAndSettle();
    // 0.4C：点「创建对话」只是打开草稿，不落库（用户要求「确实有消息发送才创建」）。
    // 所以这里先断言「还没有新对话」，再发一句话把它变成真对话。
    expect(
      store.conversations.where((c) => c.topic == Topic.health).length,
      0,
      reason: '只点创建、没发消息，不该在库里留下对话',
    );
    final healthChat = tester.state<ChatPageState>(find.byType(ChatPage));
    healthChat.pending.value = '布洛芬怎么保存？';
    await tester.pumpAndSettle();
    expect(
      store.activeConversation!.topic,
      Topic.health,
      reason: '健康模块里创建的对话必须是健康主题',
    );
    expect(find.text('这个月花了多少钱？'), findsNothing);
    expect(find.text('布洛芬怎么保存？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页快捷入口能进入对应模块', (tester) async {
    final store = await openStore();
    await pumpApp(tester, store);

    final tile = find.text('问问 AI');
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible 只保证「出现在视口里」，可能刚好贴在边缘点不到，
    // 再滚一小段让它的中心进入可点击区域。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -60));
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    // 首页入口切到 AI 模块入口页，由用户选账本分析还是健康科普
    expect(find.byType(ChatPage), findsNothing);
    expect(find.text('账本分析'), findsOneWidget);
    expect(find.text('健康科普'), findsOneWidget);

    await enterMode(tester, '账本分析');
    expect(find.text('你好，我是账本分析助手'), findsOneWidget);
    expect(find.text('创建对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从首页投递问题会直接建对话并给出未配置 Key 的引导', (tester) async {
    final store = await openStore();
    await pumpApp(tester, store);

    await openMode(tester, '账本分析');

    // 首页快捷问题、药品详情页的「询问 AI」都通过 pending 通道投递问题。
    final chat = tester.state<ChatPageState>(find.byType(ChatPage));
    chat.pending.value = '本月花了多少钱？';
    await tester.pumpAndSettle();

    // 没有配置 API Key，store 会写入一条引导语，两步都应该是本地完成的
    expect(store.messages.length, 2);
    expect(store.messages.first.content, '本月花了多少钱？');
    expect(store.messages.last.content, contains('API Key'));
    expect(find.textContaining('API Key'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('药品详情页的「询问 AI」走健康模块，落到健康对话里', (tester) async {
    final store = await openStore();
    await store.med({
      'name': '布洛芬缓释胶囊',
      'ingredient': '布洛芬',
      'spec': '0.3g*20粒',
      'stock': 2,
      'expiry': '2027-05-01',
    });
    // 造一个「用户正在看」的健康对话，以及一个更新时间更晚的健康对话。
    // 旧实现按 `where(topic==health).firstOrNull`（即最近更新）挑对话，于是
    // 用户在 A 对话里提问，问答却落进了 B 对话，界面上完全看不到。
    final watching = await store.createConversation(
      title: '我正在看的对话',
      topic: Topic.health,
    );
    await store.createConversation(title: '另一个健康对话', topic: Topic.health);
    await store.selectConversation(watching.id);
    await pumpApp(tester, store);

    // 药箱 → 药品详情
    await tester.tap(find.text('药箱').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('布洛芬缓释胶囊').first);
    await tester.pumpAndSettle();

    await scrollTo(tester, find.text('询问 AI'));
    await tester.tap(find.text('询问 AI'));
    await tester.pumpAndSettle();

    // 关键：进入的是健康科普模块的对话页，而不是悄悄往别的对话里塞消息
    expect(find.byType(ChatPage), findsOneWidget);
    final chat = tester.state<ChatPageState>(find.byType(ChatPage));
    expect(chat.mode.topic, Topic.health);

    // 0.4C：药品详情页的「询问 AI」现在会**新开一个对话**再提问，
    // 而不是把问题塞进「当前活跃」的那个对话。
    // 旧行为的问题是：用户点「询问 AI」时以为在问这个药，
    // 问答却进了他上次看过的那条对话里，界面上看不出落到了哪。
    expect(
      store.conversations.where((c) => c.topic == Topic.health).length,
      3,
      reason: '原有 2 条健康对话 + 「询问 AI」新建的 1 条',
    );
    expect(
      store.activeConversation!.id,
      isNot(watching.id),
      reason: '不该复用用户之前看的那条对话',
    );
    expect(store.activeConversation!.topic, Topic.health);

    // 提问与回复都在**新对话**里（未配 Key 时回复是引导语），且带上了药品名
    expect(store.messages.length, 2);
    expect(store.messages.first.content, contains('布洛芬缓释胶囊'));
    expect(find.textContaining('布洛芬缓释胶囊'), findsWidgets);

    // 用户原来那两个对话都没有被动过
    await store.selectConversation(watching.id);
    expect(store.messages, isEmpty, reason: '「询问 AI」不该往旧对话里写');
    expect(tester.takeException(), isNull);
  });

  testWidgets('药品详情页点「询问 AI」但不提问时，不会留下空对话', (tester) async {
    // 0.4C 的草稿机制在「询问 AI」这条路径上的边界：
    // 这条路会**自动**把问题投递进去，所以正常情况下一定会创建对话。
    // 但万一投递没发生（例如用户进去后马上返回），也不该留下一条空对话。
    final store = await openStore();
    await store.med({
      'name': '蒙脱石散',
      'spec': '3g*10袋',
      'stock': 1,
      'expiry': '2027-01-02',
    });
    final before = store.conversations.where((c) => c.topic == Topic.health).length;
    await pumpApp(tester, store);

    await tester.tap(find.text('药箱').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('蒙脱石散').first);
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('询问 AI'));
    await tester.tap(find.text('询问 AI'));
    await tester.pumpAndSettle();

    // 自动提问确实发生了：恰好新增 1 条，且里面有消息
    final after = store.conversations.where((c) => c.topic == Topic.health).length;
    expect(after, before + 1, reason: '自动提问应创建且只创建 1 条对话');
    expect(store.messages, isNotEmpty, reason: '新对话里必须有自动投递的提问');
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按账目出现修改菜单且不产生重复记录', (tester) async {
    final store = await openStore();
    await store.expense({
      'title': '买菜',
      'amount': 32.0,
      'category': '日常',
      'entryType': 'expense',
      'spentAt': DateTime.now().toIso8601String(),
    });
    await pumpApp(tester, store);

    await tester.tap(find.text('账本').last);
    await tester.pumpAndSettle();
    expect(inExpensesPage(find.text('买菜')), findsOneWidget);

    await tester.longPress(inExpensesPage(find.text('买菜')));
    await tester.pumpAndSettle();
    expect(find.text('修改'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();

    // 打开的是「修改账目」并回填了原值
    expect(find.text('修改账目'), findsOneWidget);
    expect(find.widgetWithText(TextField, '买菜'), findsOneWidget);

    final save = find.widgetWithText(FilledButton, '保存修改');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    // 关键回归点：修改不应新增第二条记录
    expect(store.expenses.length, 1);
    expect(inExpensesPage(find.text('买菜')), findsOneWidget);
  });

  testWidgets('长按删除会移除账目', (tester) async {
    final store = await openStore();
    await store.expense({
      'title': '打车',
      'amount': 18.0,
      'category': '交通',
      'entryType': 'expense',
      'spentAt': DateTime.now().toIso8601String(),
    });
    await pumpApp(tester, store);

    await tester.tap(find.text('账本').last);
    await tester.pumpAndSettle();

    await tester.longPress(inExpensesPage(find.text('打车')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 删除需要二次确认，弹窗里的按钮是准确的点击目标
    expect(find.text('删除这笔账目？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(store.expenses, isEmpty);
    expect(inExpensesPage(find.text('打车')), findsNothing);
  });
}
