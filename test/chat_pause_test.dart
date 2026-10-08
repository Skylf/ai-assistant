import 'dart:io';

import 'package:family_life_assistant/ai/client.dart';
import 'package:family_life_assistant/core/chat_mode.dart';
import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/main.dart';
import 'package:family_life_assistant/pages/chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';
import 'support/fake_http.dart';

/// 「暂停 AI 回复」（0.4B 新增）。
///
/// 用户要求：「在用户发送消息后，发送按钮变为暂停按钮，点击后可暂停 ai 回复」。
///
/// 这一组测试要证明两件**不同**的事，缺一不可：
///  1. 界面层：等待时按钮真的变成可点的暂停按钮；
///  2. 数据层：暂停之后**那条回复不会补上来**。
///
/// 只测第 1 条是不够的 —— 按钮能点但回复照旧落库，用户会看到「暂停了却又冒出
/// 一条回复」，比没有这个功能更糟。第 2 条用「先取消再问」的方式测，
/// 不依赖时序，因此是确定性的。
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
    await store.saveSettings(
      url: 'https://api.example.com/v1',
      model: 'test-model',
      apiKey: 'sk-test',
    );
    await store.createConversation(title: '测试对话', topic: Topic.finance);
    return store;
  }

  group('取消令牌本身', () {
    test('默认未取消，cancel 之后为已取消，重复 cancel 无副作用', () {
      final token = AskCancelToken();
      expect(token.cancelled, isFalse);
      token.cancel();
      expect(token.cancelled, isTrue);
      token.cancel();
      expect(token.cancelled, isTrue, reason: '重复取消不该出问题');
    });

    test('AiResult.cancelled 不是失败，不会显示成报错', () {
      const result = AiResult.cancelled();
      expect(result.ok, isFalse);
      expect(result.cancelled, isTrue);
      expect(result.text, isEmpty);
      // 关键：不能把它当失败渲染成「AI 服务调用失败」——
      // 用户自己点的暂停，不该收到一条报错。
      expect(result.error, isNull);
    });

    test('success 与 failure 的 cancelled 都是 false（没有误标）', () {
      expect(const AiResult.success('hi').cancelled, isFalse);
      expect(const AiResult.failure('boom').cancelled, isFalse);
    });
  });

  group('数据层：暂停后回复不落库', () {
    test('【关键】已取消的令牌 → 不写入助手回复', () async {
      final store = await openStore();
      final fake = FakeHttpClient.routed(
        {},
        chatText: '这是模型算出来的回复',
      );

      late String reply;
      await HttpOverrides.runZoned(() async {
        final token = AskCancelToken()..cancel();
        reply = await store.ask('这个月花了多少？', cancel: token);
      }, createHttpClient: (_) => fake);

      expect(reply, isEmpty, reason: '被暂停时应返回空串，而不是模型正文');
      // 提问本身要保留：用户确实说过这句话，暂停不该让它消失
      expect(
        store.messages.where((m) => m.role == 'user').length,
        1,
        reason: '用户的提问必须已经落库',
      );
      // 关键断言：助手回复一个字都不能写进去
      expect(
        store.messages.where((m) => m.role == 'assistant'),
        isEmpty,
        reason: '暂停后回复不能补上来，否则用户会以为暂停没生效',
      );
      expect(
        store.messages.any((m) => m.content.contains('这是模型算出来的回复')),
        isFalse,
      );
    });

    test('不传令牌时行为不变（回归：暂停功能不能影响正常提问）', () async {
      final store = await openStore();
      final fake = FakeHttpClient.routed(
        {},
        chatText: '正常回复',
      );

      late String reply;
      await HttpOverrides.runZoned(() async {
        reply = await store.ask('这个月花了多少？');
      }, createHttpClient: (_) => fake);

      expect(reply, '正常回复');
      expect(store.messages.where((m) => m.role == 'assistant').length, 1);
    });

    test('传了但没取消的令牌 → 正常写入回复', () async {
      final store = await openStore();
      final fake = FakeHttpClient.routed(
        {},
        chatText: '正常回复',
      );

      late String reply;
      await HttpOverrides.runZoned(() async {
        reply = await store.ask('这个月花了多少？', cancel: AskCancelToken());
      }, createHttpClient: (_) => fake);

      expect(reply, '正常回复');
      expect(store.messages.where((m) => m.role == 'assistant').length, 1);
    });

    test('暂停不影响紧急分流的硬性回复（安全逻辑优先于暂停）', () async {
      // 紧急就医提示是本地短路、不走网络，且属于安全底线。
      // 它发生在检查暂停之前，所以即使令牌已取消也必须给出提示 ——
      // 宁可多提示一次，也不能因为「暂停」把 120 提醒吞掉。
      final store = await openStore();
      await store.createConversation(title: '健康对话', topic: Topic.health);
      final token = AskCancelToken()..cancel();
      // 用「胸口剧痛」这种口语说法：它一开始**不**在关键词表里（原表只有
      // 「胸痛」「呼吸困难」），是本轮补词时加上的。用书面词测会掩盖漏检。
      final reply = await store.ask('胸口剧痛还喘不上气', cancel: token);

      expect(reply, isNotEmpty, reason: '紧急提示不能被暂停吞掉');
      expect(reply.contains('120'), isTrue);
    });
  });

  group('界面层：发送按钮变暂停按钮', () {
    /// 起 App 并直接推到对话页。
    ///
    /// 直接 push `ChatPage` 而不是走「AI Tab → 模块 → 创建对话」那条长路径：
    /// 这里要测的是输入栏的按钮状态，路径越长越容易被别的改动碰坏。
    /// `openStore()` 里 `createConversation` 已经自动选中该对话，
    /// 所以 `store.messages` 指向的就是这个对话。
    Future<void> openChat(WidgetTester tester, Store store) async {
      await tester.pumpWidget(FamilyLifeAssistantApp(store: store));
      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator).first).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(store: store, mode: ChatMode.finance),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('空闲时是发送按钮，没有暂停', (tester) async {
      final store = await openStore();
      await openChat(tester, store);

      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
    });

    testWidgets('【关键】等待回复时出现可点的暂停按钮', (tester) async {
      // 用带延时的假网络制造「正在等待」这个窗口。
      // 没有延时的话请求瞬间返回，暂停按钮根本来不及出现在任何一帧里
      // —— 这个测试就会变成永远为真的空断言。
      final store = await openStore();
      final slow = FakeHttpClient(
        statusCode: 200,
        body: FakeHttpClient.chatReply('慢回复'),
        delay: const Duration(seconds: 5),
      );
      expect(slow.delay, greaterThan(Duration.zero), reason: '必须有延时才有忙态');

      await tester.pumpWidget(FamilyLifeAssistantApp(store: store));
      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator).first).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(store: store, mode: ChatMode.finance),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '这个月花了多少？');

      // 在带延时的假网络里发送；期间只用 pump，不用 pumpAndSettle
      //（settle 会一直等到请求返回，那就观察不到忙态了）
      await HttpOverrides.runZoned(() async {
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // 等待期间：发送图标变成暂停图标
        expect(
          find.byIcon(Icons.stop_rounded),
          findsOneWidget,
          reason: '等待回复时必须出现暂停按钮',
        );
        expect(find.byIcon(Icons.send), findsNothing);
        // 并且提示用户这个按钮可以点
        expect(find.textContaining('可暂停'), findsOneWidget);

        // 点暂停
        await tester.tap(find.byIcon(Icons.stop_rounded));
        await tester.pump();

        expect(find.byIcon(Icons.send), findsOneWidget, reason: '暂停后回到发送按钮');
        expect(find.byIcon(Icons.stop_rounded), findsNothing);
        expect(find.textContaining('已暂停'), findsOneWidget);
      }, createHttpClient: (_) => slow);

      // 让那个 5 秒的假请求跑完好收尾（避免测试结束时留下未完成的定时器）
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      // 收尾之后仍然不能冒出回复
      expect(find.text('慢回复'), findsNothing);
    });
  });
}
