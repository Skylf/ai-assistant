import 'package:family_life_assistant/ai/chart.dart';
import 'package:family_life_assistant/core/chat_mode.dart';
import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/main.dart';
import 'package:family_life_assistant/pages/chat.dart';
import 'package:family_life_assistant/pages/password_tool.dart';
import 'package:family_life_assistant/pages/settings.dart';
import 'package:family_life_assistant/widgets/chart.dart' as charts;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 新模块（多对话 / 图表 / 设置二级页 / 密码生成器）的界面测试。
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

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// 进入某个 AI 模块（AI Tab → 入口页 → 该模块的介绍页）。
  ///
  /// 0.4A 之后 AI Tab 先是两个模块的入口页，再进模块介绍页；对话页还要再点
  /// 「创建对话」才进得去（介绍页上故意没有输入框）。
  Future<void> openAiMode(WidgetTester tester, String label) async {
    await openTab(tester, 'AI');
    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();
  }

  /// 一直走到对话页：模块介绍页 → 「创建对话」。
  ///
  /// 0.4C 起「创建对话」只打开一个**草稿**，不发消息就不落库。所以这里可以传
  /// [primeWith] 先发一句话，把草稿变成真对话 —— 后面凡是要对
  /// `store.activeConversation` / `store.messages` 断言的测试都需要它，
  /// 否则那些断言会打在**上一个**对话上（或空对话上）。
  Future<void> openChat(
    WidgetTester tester,
    String label, {
    String primeWith = '',
  }) async {
    await openAiMode(tester, label);
    await tester.tap(find.text('创建对话'));
    await tester.pumpAndSettle();
    if (primeWith.isNotEmpty) {
      final chat = tester.state<ChatPageState>(find.byType(ChatPage));
      chat.pending.value = primeWith;
      await tester.pumpAndSettle();
    }
  }

  /// 打开模块介绍页右上角的「历史对话」侧滑抽屉。
  ///
  /// 0.4B 把对话列表从页面主体搬进了抽屉（用户反馈「一旦对话过多，显示很难受」），
  /// 所以凡是要看/点历史对话的测试都必须先开抽屉。
  Future<void> openHistory(WidgetTester tester) async {
    await tester.tap(find.byTooltip('历史对话'));
    await tester.pumpAndSettle();
  }

  /// 返回上一页。
  ///
  /// 不用 `tester.pageBack()`：它要求页面上存在 `BackButton`/AppBar 返回键，
  /// 而这里的返回键是自绘的 IconButton（tooltip「返回」）。而且介绍页的标题栏
  /// 会随列表滚出屏幕，按 tooltip 找也不可靠，所以直接弹当前路由。
  Future<void> goBack(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
  }

  /// 在当前列表里滚动到某个条目。
  ///
  /// 设置页与药箱页都是长列表，目标常常在首屏之外；[scrollUntilVisible] 只能
  /// 向下滚，所以这里在向上找不到时就改用 `ensureVisible` 往回收。
  /// 注意传进来的必须是「原始」Finder：`.first` 在无匹配时会直接抛 StateError。
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

  Future<void> tapSetting(WidgetTester tester, String text) async {
    await scrollTo(tester, find.text(text));
    await tester.tap(find.text(text).first);
    await tester.pumpAndSettle();
  }

  /// 点击 SwitchListTile。
  ///
  /// 先滚到开关可见并停稳，再重新定位 —— 滚动会让之前算出的坐标失效，
  /// 直接 tap 可能落到别的控件上（甚至把当前页面 pop 掉）。
  /// 这里点整行而不是行内的小开关，命中区域更大也更稳定。
  Future<void> tapSwitch(WidgetTester tester, String title) async {
    await scrollTo(tester, find.text(title));
    final tile = find
        .ancestor(
          of: find.text(title),
          matching: find.byType(SwitchListTile),
        )
        .first;
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  /// 把当前页面里最靠上的可滚动列表滚回顶部。
  ///
  /// ListView 会把滚出视口的子项回收掉，所以「往下滚去点开关，再读顶部的
  /// 结果卡」会读不到 —— 必须真的把列表拉回顶部。用 `fling` 而不是 `drag`：
  /// 拖动可能被当成点击，`fling` 是明确的滚动意图。
  Future<void> scrollListToTop(WidgetTester tester) async {
    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, 600),
      1200,
    );
    await tester.pumpAndSettle();
  }

  group('图表渲染', () {
    testWidgets('category 图表画出分类名、占比与金额', (tester) async {
      const chart = ChartBlock(
        type: 'category',
        title: '本月分类占比',
        categories: [
          ChartItem(label: '餐饮', value: 800, display: '¥800.00'),
          ChartItem(label: '购物', value: 200, display: '¥200.00'),
        ],
        totalLabel: '本月支出',
        totalValue: '¥1000.00',
        note: '餐饮占比偏高',
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: charts.AiChart(chart))),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('本月分类占比'), findsOneWidget);
      expect(find.text('¥1000.00'), findsOneWidget);
      expect(find.text('本月支出'), findsOneWidget);
      expect(find.text('餐饮'), findsOneWidget);
      expect(find.text('80%'), findsOneWidget);
      expect(find.text('¥800.00'), findsOneWidget);
      expect(find.text('20%'), findsOneWidget);
      expect(find.textContaining('餐饮占比偏高'), findsOneWidget);
      // 每个分类一条进度条
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    });

    testWidgets('trend 图表按行渲染', (tester) async {
      const chart = ChartBlock(
        type: 'trend',
        title: '近三月支出',
        categories: [
          ChartItem(label: '7 月', value: 1200, display: '¥1200.00'),
          ChartItem(label: '8 月', value: 900, display: '¥900.00'),
        ],
      );      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: charts.AiChart(chart))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('7 月'), findsOneWidget);
      expect(find.text('¥1200.00'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    });

    testWidgets('缺少 display 时用数字兜底，不显示空白', (tester) async {
      const chart = ChartBlock(
        type: 'category',
        title: '交通',
        categories: [ChartItem(label: '交通', value: 50, display: '')],
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: charts.AiChart(chart))),
      );
      await tester.pumpAndSettle();
      expect(find.text('50.00'), findsOneWidget);
    });

    testWidgets('无效图表渲染为空，不抛异常', (tester) async {
      const chart = ChartBlock(type: 'category', categories: [], title: '空的');
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: charts.AiChart(chart))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('AI 模块：介绍页与对话页', () {
    testWidgets('介绍页有介绍卡与创建对话按钮，但没有输入框', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openAiMode(tester, '账本分析');

      expect(find.text('你好，我是账本分析助手'), findsOneWidget);
      expect(find.text('看懂收支结构'), findsOneWidget);
      expect(find.text('创建对话'), findsOneWidget);
      // 0.4B：对话列表不再占页面主体，改为右上角「历史对话」抽屉
      expect(find.text('对话记录'), findsNothing);
      expect(find.byTooltip('历史对话'), findsOneWidget);
      // 关键：介绍页上不能有输入框，必须先创建对话才能开口
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(ChatPage), findsNothing);
    });

    testWidgets('历史对话收在侧滑抽屉里，不在页面主体占位置', (tester) async {
      final store = await openStore();
      await store.createConversation(title: '很久以前的对话', topic: Topic.finance);
      await pumpApp(tester, store);
      await openAiMode(tester, '账本分析');

      // 抽屉没打开时，历史对话不该出现在页面上
      expect(find.text('很久以前的对话'), findsNothing);

      await openHistory(tester);
      expect(find.text('历史对话'), findsOneWidget);
      expect(find.text('很久以前的对话'), findsOneWidget);

      // 抽屉里也能直接建对话
      expect(find.text('创建对话'), findsWidgets);
    });

    testWidgets('创建对话后才进入只有消息与输入框的对话页', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openChat(tester, '账本分析');

      expect(find.byType(ChatPage), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      // 对话页不重复放介绍卡、能力清单与建议问题
      expect(find.text('你好，我是账本分析助手'), findsNothing);
      expect(find.text('看懂收支结构'), findsNothing);
      expect(find.text('创建对话'), findsNothing);
      expect(find.text('查看收支明细'), findsNothing);
    });

    testWidgets('介绍页列出的对话可以点进去，并显示全部历史对话', (tester) async {
      final store = await openStore();
      await store.createConversation(title: '健康专属', topic: Topic.health);
      await store.createConversation(title: '账本专属', topic: Topic.finance);
      await pumpApp(tester, store);

      await openAiMode(tester, '账本分析');
      // 0.4B：对话列表在侧滑抽屉里
      await openHistory(tester);
      // 只列本模块的对话
      expect(find.text('账本专属'), findsOneWidget);
      expect(find.text('健康专属'), findsNothing);

      await tester.tap(find.text('账本专属'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(store.activeConversation!.title, '账本专属');

      // 返回介绍页，再返回入口页，换到健康模块：看到的又是另一批对话
      await goBack(tester);
      expect(find.byType(ChatPage), findsNothing);
      await goBack(tester);
      await tester.tap(find.text('健康科普').first);
      await tester.pumpAndSettle();
      await openHistory(tester);
      expect(find.text('健康专属'), findsOneWidget);
      expect(find.text('账本专属'), findsNothing);
    });

    testWidgets('长按对话可以重命名', (tester) async {
      final store = await openStore();
      await store.createConversation(title: '待改名', topic: Topic.finance);
      await pumpApp(tester, store);
      await openAiMode(tester, '账本分析');
      await openHistory(tester);

      await tester.longPress(find.text('待改名'));
      await tester.pumpAndSettle();
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('删除对话'), findsOneWidget);

      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '新名字');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('新名字'), findsOneWidget);
    });

    testWidgets('助手回复中的图表代码块被渲染成真图表', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      // 先发一句话把草稿落库，后面的 addMessage 才打在同一个对话上
      await openChat(tester, '账本分析', primeWith: '帮我分析本月支出');

      await store.addMessage('user', '帮我分析本月支出');
      await store.addMessage(
        'assistant',
        '本月支出结构如下：\n\n'
            '```chart\n'
            '{"type":"category","title":"本月分类占比",'
            '"categories":[{"label":"餐饮","value":800,"display":"¥800.00"}],'
            '"total":{"label":"本月支出","value":"¥800.00"}}\n'
            '```\n\n建议关注外卖频次。',
      );
      await tester.pumpAndSettle();

      expect(find.byType(charts.AiChart), findsOneWidget);
      expect(find.text('本月分类占比'), findsOneWidget);
      expect(find.text('餐饮'), findsOneWidget);
      // 原始代码块不应作为文本泄露到界面上
      expect(find.textContaining('```chart'), findsNothing);
      expect(find.textContaining('"type"'), findsNothing);
      // 正文仍然保留
      expect(find.textContaining('建议关注外卖频次'), findsOneWidget);
    });

    testWidgets('记忆胶囊会跟着当前对话的设置变化', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openChat(tester, '账本分析', primeWith: '看看这个月的支出');

      // 胶囊应当显示**当前对话**的记忆档位。这里刻意不去断言「默认是哪个」
      // —— 默认值在 2026-10-08 从「仅当前对话」改成了「全局记忆」，
      // 原来这条测试写死了初始值，改默认值时就红了，而功能其实完全正常。
      // 要测的是「胶囊跟着设置走」，所以从当前档位出发、换成另一个档位。
      final initial = store.activeConversation!.memory;
      expect(find.text(initial.shortLabel), findsOneWidget);
      expect(find.text('全局记忆'), initial == MemoryScope.global
          ? findsOneWidget
          : findsNothing);

      final target = initial == MemoryScope.global
          ? MemoryScope.local
          : MemoryScope.global;
      await store.updateConversation(
        store.activeConversationId,
        memory: target,
      );
      await tester.pumpAndSettle();

      expect(find.text(target.shortLabel), findsOneWidget);
      expect(find.text(initial.shortLabel), findsNothing);
    });

    testWidgets('用户气泡与助手气泡的左右布局生效', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openChat(tester, '账本分析', primeWith: '先占个位');

      await store.addMessage('user', '本月花了多少？');
      await store.addMessage('assistant', '一共 1000 元。');
      await tester.pumpAndSettle();

      final userText = tester.getCenter(find.text('本月花了多少？'));
      final assistantText = tester.getCenter(find.text('一共 1000 元。'));
      expect(userText.dx, greaterThan(assistantText.dx));
    });

    testWidgets('两个模块的介绍文案与安全声明各不相同', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);

      await openAiMode(tester, '账本分析');
      expect(find.text('你好，我是账本分析助手'), findsOneWidget);
      expect(find.text('看懂收支结构'), findsOneWidget);
      expect(find.text('整理家庭药箱'), findsNothing);
      expect(find.textContaining('不构成投资或财务建议'), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('健康科普').first);
      await tester.pumpAndSettle();

      expect(find.text('你好，我是健康科普助手'), findsOneWidget);
      expect(find.text('整理家庭药箱'), findsOneWidget);
      expect(find.text('看懂收支结构'), findsNothing);
      expect(find.textContaining('健康科普不构成诊断、处方'), findsOneWidget);
    });

    testWidgets('在账本模块问药品问题不会跳到健康模块', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openChat(tester, '账本分析');

      final chat = tester.state<ChatPageState>(find.byType(ChatPage));
      chat.pending.value = '布洛芬和感冒药能一起吃吗？';
      await tester.pumpAndSettle();

      // 发送消息不推断主题，问题必须留在账本模块的对话里
      expect(store.activeConversation!.topic, Topic.finance);
      expect(store.messages.first.content, '布洛芬和感冒药能一起吃吗？');
      expect(find.text('你好，我是健康科普助手'), findsNothing);
    });
  });

  group('设置多级信息架构', () {
    testWidgets('一级页显示四个分组与版本号', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openTab(tester, '设置');

      expect(find.text('账户与 AI'), findsOneWidget);
      await scrollTo(tester, find.text('数据与隐私'));
      expect(find.text('数据与隐私'), findsOneWidget);
      await scrollTo(tester, find.text('实用工具'));
      expect(find.text('实用工具'), findsOneWidget);
      expect(find.text('密码生成器'), findsOneWidget);
      await scrollTo(tester, find.text('关于'));
      expect(find.text('关于'), findsOneWidget);
      // 「当前版本」那一行的文案随 appVersion 的形态变化：
      // 发行版写「发行版」、带字母的开发版写「开发版」（0.5.1 起已是发行版）。
      // 这里按同一个判据取词，不要写死 —— 写死过一次，版本升级后这条就红了，
      // 而界面其实是对的。判据本身由 `version_consistency_test.dart` 钉住。
      final isRelease = !RegExp(
        r'[A-Za-z]',
      ).hasMatch(appVersion.replaceAll(RegExp(r'^\d+\.\d+'), ''));
      final versionLabel = '$appVersion ${isRelease ? '发行版' : '开发版'}';
      await scrollTo(tester, find.text(versionLabel));
      expect(find.text(versionLabel), findsOneWidget);
    });

    testWidgets('AI 服务二级页可以配置并返回', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openTab(tester, '设置');

      await tapSetting(tester, 'AI 服务');

      expect(find.text('接口地址（Base URL）'), findsOneWidget);
      expect(find.text('API Key'), findsWidgets);
      expect(find.text('测试连接'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'https://api.deepseek.com'),
        'https://api.example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(store.url, 'https://api.example.com');
      expect(find.textContaining('已保存'), findsWidgets);

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('账户与 AI'), findsOneWidget);
    });

    testWidgets('我的提示词二级页保存后写回 Store', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openTab(tester, '设置');

      await tapSetting(tester, '我的提示词');

      await tester.enterText(find.byType(TextField).first, '先说结论');
      await scrollTo(tester, find.text('保存提示词'));
      await tester.tap(find.widgetWithText(FilledButton, '保存提示词'));
      await tester.pumpAndSettle();
      expect(store.customPromptFinance, '先说结论');
    });

    testWidgets('全局记忆二级页可保存与清空', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openTab(tester, '设置');

      await tapSetting(tester, '全局记忆');

      await tester.enterText(find.byType(TextField).first, '家里有 2 位老人');
      await scrollTo(tester, find.text('保存'));
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(store.globalMemory, '家里有 2 位老人');

      // 清空按钮会先弹确认框
      await tester.tap(find.widgetWithText(OutlinedButton, '清空'));
      await tester.pumpAndSettle();
      expect(find.text('清空全局记忆？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '清空'));
      await tester.pumpAndSettle();
      expect(store.globalMemory, isEmpty);
    });

    testWidgets('数据管理二级页显示各表数量', (tester) async {
      final store = await openStore();
      await store.expense({'title': '买菜', 'amount': 10.0});
      await store.med({'name': '布洛芬', 'stock': 1});
      await pumpApp(tester, store);
      await openTab(tester, '设置');

      await tapSetting(tester, '数据管理');

      expect(find.text('1 条'), findsWidgets);
      expect(find.text('导出为 JSON'), findsOneWidget);
      expect(store.dataCounts['expenses'], 1);
    });

    testWidgets('全局记忆页可以把全部老对话一键改成「全局记忆」', (tester) async {
      // 真实现场：用户升级到 0.5.3 后问「为啥我在聊天里看到的还是仅本对话记忆」。
      // 原因是老对话保留自己存的档位（刻意），但没有批量入口就只能一条条点胶囊。
      final store = await openStore();
      // 造一个「老对话」：把当前这条改成 local，它就不是 global 了
      await store.updateConversation(
        store.activeConversationId,
        memory: MemoryScope.local,
      );
      expect(store.countConversationsNotGlobal(), 1);

      await pumpApp(tester, store);
      await openTab(tester, '设置');
      await tapSetting(tester, '全局记忆');

      // 副标题里要出现真实条数，用户才知道会动几条
      await scrollTo(tester, find.textContaining('还有 1 个对话'));
      expect(find.textContaining('还有 1 个对话'), findsOneWidget);

      await tester.tap(find.text('把全部对话改成「全局记忆」'));
      await tester.pumpAndSettle();

      // 先弹确认框，不能点一下就改
      expect(find.text('把全部对话改成「全局记忆」？'), findsOneWidget);
      expect(store.conversations.single.memory, MemoryScope.local,
          reason: '还没确认就不该改动任何对话');

      await tester.tap(find.widgetWithText(FilledButton, '全部改成全局'));
      await tester.pumpAndSettle();

      expect(store.conversations.single.memory, MemoryScope.global);
      expect(store.countConversationsNotGlobal(), 0);
      // 改完副标题应变成「无需改动」，按钮不可再点
      await scrollTo(tester, find.textContaining('无需改动'));
      expect(find.textContaining('无需改动'), findsOneWidget);
    });

    testWidgets('「不记忆」的对话被批量改档位时，确认框要警告历史会被发送', (tester) async {
      // 「不记忆」原本完全不向模型发送历史，改成全局之后历史会开始被发出去 ——
      // 这是本操作里唯一有隐私影响的一类，必须在点之前就写清楚。
      final store = await openStore();
      await store.createConversation(title: '私密', memory: MemoryScope.off);

      await pumpApp(tester, store);
      await openTab(tester, '设置');
      await tapSetting(tester, '全局记忆');
      await scrollTo(tester, find.text('把全部对话改成「全局记忆」'));
      await tester.tap(find.text('把全部对话改成「全局记忆」'));
      await tester.pumpAndSettle();

      expect(find.textContaining('不记忆'), findsOneWidget);
      expect(find.textContaining('历史会开始随提问发送给模型'), findsOneWidget);
    });

    testWidgets('使用说明二级页包含安全提示', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openTab(tester, '设置');

      await tapSetting(tester, '使用说明');
      expect(find.textContaining('四步上手'), findsOneWidget);
      await scrollTo(tester, find.textContaining('拨打 120'));
      expect(find.textContaining('拨打 120'), findsOneWidget);
    });

    testWidgets('AI 对话设置页列出三档记忆', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openTab(tester, '设置');

      await tapSetting(tester, 'AI 对话设置');
      expect(find.text('仅当前对话'), findsOneWidget);
      expect(find.text('存入全局记忆'), findsOneWidget);
      expect(find.text('不记忆'), findsOneWidget);
    });

    testWidgets('检查更新二级页说明版本并列出更新日志', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openTab(tester, '设置');

      await tapSetting(tester, '检查更新');

      // 未配置更新源时要明确说明原因，而不是留一个没反应的按钮
      expect(find.text('检查更新'), findsWidgets);
      expect(find.textContaining('未配置更新源'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重新检查'), findsOneWidget);
      expect(find.text('正在检查…'), findsNothing);

      // 更新日志里应当能找到当前版本
      await scrollTo(tester, find.text('密码生成器模块'));
      expect(find.text('密码生成器模块'), findsOneWidget);
      expect(find.text('0.3A'), findsWidgets);
    });

    testWidgets('检查更新二级页可以重新检查并保持稳定', (tester) async {
      final store = await openStore();
      await pumpApp(tester, store);
      await openTab(tester, '设置');

      await tapSetting(tester, '检查更新');
      await tester.tap(find.widgetWithText(FilledButton, '重新检查'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未配置更新源'), findsOneWidget);
    });
  });

  group('密码生成器', () {
    Future<void> openPasswordTool(WidgetTester tester, Store store) async {
      await pumpApp(tester, store);
      await openTab(tester, '设置');
      await tapSetting(tester, '密码生成器');
    }

    testWidgets('默认生成一个随机密码并展示强度', (tester) async {
      final store = await openStore();
      await openPasswordTool(tester, store);

      expect(find.byType(PasswordToolPage), findsOneWidget);
      expect(find.text('16 位'), findsOneWidget);
      expect(find.textContaining('位熵'), findsOneWidget);
      expect(find.text('重新生成'), findsOneWidget);
    });

    testWidgets('重新生成会换一个密码', (tester) async {
      final store = await openStore();
      await openPasswordTool(tester, store);

      final before = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .data!;
      await tester.tap(find.text('重新生成'));
      await tester.pumpAndSettle();
      final after = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .data!;
      expect(after, isNot(before));
      expect(after.length, 16);
    });

    testWidgets('切换「特殊符号」开关后密码只含字母数字', (tester) async {
      final store = await openStore();
      await openPasswordTool(tester, store);

      await tapSwitch(tester, '特殊符号 !@#\$…');
      // 开关在列表下方，结果卡会被滚出视口并被回收，先把列表拉回顶部
      await scrollListToTop(tester);
      final password = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .data!;
      expect(password, isNotEmpty);
      expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(password), isTrue);
    });

    testWidgets('关闭全部字符类型会给出提示而不是崩溃', (tester) async {
      final store = await openStore();
      await openPasswordTool(tester, store);

      for (final label in ['小写字母 a-z', '大写字母 A-Z', '数字 0-9', '特殊符号 !@#\$…']) {
        await tapSwitch(tester, label);
      }
      expect(find.textContaining('至少要选择一种字符类型'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('助记口令页能生成口令', (tester) async {
      final store = await openStore();
      await openPasswordTool(tester, store);

      await tester.tap(find.text('助记口令'));
      await tester.pumpAndSettle();
      expect(find.text('单词数量'), findsOneWidget);

      final passphrase = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .data!;
      // 4 个单词 + 4 位数字
      expect(passphrase.split('-').length, 5);
    });

    testWidgets('密钥页默认为 32 位并分组显示', (tester) async {
      final store = await openStore();
      await openPasswordTool(tester, store);

      await tester.tap(find.text('密钥'));
      await tester.pumpAndSettle();
      expect(find.text('32 位'), findsOneWidget);

      final key = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .data!;
      expect(key.split('-').length, 4);
      expect(key.replaceAll('-', '').length, 32);
    });

    testWidgets('保存记录只写用途与强度，不含明文', (tester) async {
      final store = await openStore();
      await openPasswordTool(tester, store);

      final password = tester
          .widget<SelectableText>(find.byType(SelectableText).first)
          .data!;

      await tester.tap(find.byTooltip('保存记录'));
      await tester.pumpAndSettle();
      expect(find.text('保存为密码记录'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '邮箱');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(store.savedPasswords.length, 1);
      expect(store.savedPasswords.single.label, '邮箱');
      expect(store.savedPasswords.single.length, password.length);
      // 记录里绝不含明文
      final row = store.savedPasswords.single.toRow();
      for (final value in row.values) {
        expect(value.toString(), isNot(password));
      }
    });

    testWidgets('记录页在没有记录时给出空状态', (tester) async {
      final store = await openStore();
      await openPasswordTool(tester, store);

      await tester.tap(find.text('记录'));
      await tester.pumpAndSettle();
      expect(find.text('还没有密码记录'), findsOneWidget);
    });

    testWidgets('记录页列出已保存的用途并可删除', (tester) async {
      final store = await openStore();
      await store.savePasswordRecord(
        label: '路由器',
        site: '随机密码',
        length: 20,
        strength: 4,
        entropy: 120,
      );
      await openPasswordTool(tester, store);

      await tester.tap(find.text('记录'));
      await tester.pumpAndSettle();
      expect(find.text('路由器'), findsOneWidget);
      expect(find.text('很强'), findsOneWidget);

      await tester.tap(find.byTooltip('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(store.savedPasswords, isEmpty);
    });
  });

  group('小屏布局', () {
    /// 在矮屏 / 窄屏上渲染，确认不会溢出、按钮也在视口内。
    ///
    /// 360×800 是常见的低端机尺寸。曾经「添加药品」抽屉整个内容共用一个
    /// ScrollView，表单字段一多，取消 / 保存就被推到视口之外，用户点不到。
    Future<void> pumpSmall(WidgetTester tester, Store store) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await pumpApp(tester, store);
    }

    testWidgets('添加药品抽屉在小屏上按钮仍可点击', (tester) async {
      final store = await openStore();
      await pumpSmall(tester, store);
      await openTab(tester, '药箱');

      await tester.tap(find.byType(FloatingActionButton).first);
      await tester.pumpAndSettle();

      // 按钮必须完整落在视口内，否则真机上点不到
      final viewport =
          Offset.zero &
          (tester.view.physicalSize / tester.view.devicePixelRatio);
      final cancel = tester.getRect(find.widgetWithText(OutlinedButton, '取消'));
      final submit = tester.getRect(find.widgetWithText(FilledButton, '保存'));
      expect(
        viewport.contains(cancel.center),
        isTrue,
        reason: '「取消」$cancel 落在视口 $viewport 之外',
      );
      expect(
        viewport.contains(submit.center),
        isTrue,
        reason: '「保存」$submit 落在视口 $viewport 之外',
      );

      // 真正点一次，确认能触发（能关掉抽屉）
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(find.text('保存'), findsNothing);
    });

    testWidgets('添加药品抽屉在小屏上可以滚动到被遮挡的字段', (tester) async {
      final store = await openStore();
      await pumpSmall(tester, store);
      await openTab(tester, '药箱');

      await tester.tap(find.byType(FloatingActionButton).first);
      await tester.pumpAndSettle();

      // 注意事项是安全信息组里靠后的字段，小屏上需要滚动才能看到。
      // （0.4D 之前这里查的是「说明书要点 / 备注」，那个字段已改名为「备注」
      //   并挪到表单最后，所以断言也要跟着换成仍然靠后的字段。）
      await scrollTo(tester, find.text('注意事项').first);
      expect(find.text('注意事项'), findsOneWidget);
      // 滚动后按钮依然可见
      expect(find.text('保存'), findsOneWidget);
    });

    testWidgets('记账抽屉在小屏上按钮仍可点击', (tester) async {
      final store = await openStore();
      await pumpSmall(tester, store);
      await openTab(tester, '账本');

      // 0.4B：记账入口改为第一级里的整宽按钮（不再用悬浮按钮）
      await tester.tap(find.text('记一笔'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '42');
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();

      expect(store.monthlyExpense(DateTime.now()), 42.0);
    });

    testWidgets('账本页日期行在小屏上不溢出', (tester) async {
      final store = await openStore();
      await store.expense({'title': '买菜', 'amount': 86.5});
      await store.expense({
        'title': '工资',
        'amount': 8000.0,
        'income': true,
      });
      await pumpSmall(tester, store);
      await openTab(tester, '账本');

      // 溢出会让测试在这一帧直接失败；这里再确认两个数字都在
      expect(find.text('收入'), findsWidgets);
      expect(find.text('支出'), findsWidgets);
    });
  });

  group('模块推断（仅用于决定首页投递的问题进哪个模块）', () {
    test('健康相关词落到健康科普', () {
      expect(inferMode('家里的药过期了怎么办'), ChatMode.health);
      expect(inferMode('孩子发烧能吃退烧药吗'), ChatMode.health);
    });

    test('账本相关词落到账本分析', () {
      expect(inferMode('本月支出最多的分类是什么'), ChatMode.finance);
      expect(inferMode('怎么才能省钱'), ChatMode.finance);
    });

    test('无法判断时默认账本分析', () {
      expect(inferMode('你好'), ChatMode.finance);
    });
  });
}
