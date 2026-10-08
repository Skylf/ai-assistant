import 'dart:convert';
import 'dart:io';

import 'package:family_life_assistant/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';
import 'support/fake_http.dart';

/// 「让模型理解人话」的端到端验证。
///
/// 为什么必须有这一层：`ActionPlan.parse` 的单元测试只能证明「给定 JSON 能解析
/// 对」，证明不了 `Store.ask` 真的会去调模型、真的会执行动作、真的会落库。
/// 中间任何一环没接上（比如忘了传 `allowActions`、忘了执行第二个动作），
/// 单元测试都是绿的。
///
/// 这里的假服务商回答的是**正则永远不可能覆盖的说法**：
/// 「还有两盒」「下个月过期」——那正是这套机制存在的理由。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  /// 造一个已配置 Key 的 Store，并指定反向录入模式。
  Future<Store> openStore(ActionInputMode mode) async {
    final store = Store(db: FakeDb());
    await store.load();
    await store.saveSettings(
      url: 'https://api.example.com/v1',
      model: 'test-model',
      apiKey: 'sk-test',
    );
    await store.saveActionMode(mode);
    return store;
  }

  /// 在「模型会这样回答」的假网络下执行一次提问。
  Future<String> askWith(
    Store store,
    String question,
    String modelReply,
  ) async {
    final fake = FakeHttpClient.routed(
      {},
      chatText: modelReply,
    );
    late String reply;
    await HttpOverrides.runZoned(() async {
      reply = await store.ask(question);
    }, createHttpClient: (_) => fake);
    return reply;
  }

  group('口语说法由模型理解', () {
    test('「还有两盒，下个月过期」被理解成 stock=2 与归一化日期', () async {
      final store = await openStore(ActionInputMode.aiOnly);
      await store.createConversation(title: '药箱', topic: Topic.health);

      // 这句话本地正则完全无能为力：没有「库存」二字，日期是相对时间
      final reply = await askWith(
        store,
        '帮我加三个药：护肝片、维生素B、钙片，都还有两盒，下个月过期',
        '好的，我按「库存 2、有效期 2026-10-27」加了这三样。\n'
            '```actions\n'
            '${jsonEncode({
              'actions': [
                {'type': 'med_add', 'name': '护肝片', 'stock': 2, 'expiry': '2026-10-27'},
                {'type': 'med_add', 'name': '维生素B', 'stock': 2, 'expiry': '2026-10-27'},
                {'type': 'med_add', 'name': '钙片', 'stock': 2, 'expiry': '2026-10-27'},
              ],
            })}\n'
            '```',
      );

      expect(store.meds.length, 3, reason: '三个药都要真的落库');
      expect(
        store.meds.map((m) => m['name']).toList()..sort(),
        ['维生素B', '钙片', '护肝片']..sort(),
      );
      for (final m in store.meds) {
        expect(m['stock'], 2, reason: '「还有两盒」要变成 2');
        expect(m['expiry'], '2026-10-27');
      }
      expect(reply, contains('共 3 项'));
      // 回复里逐条列出，用户能核对
      expect(reply, contains('护肝片'));
      expect(reply, contains('维生素B'));
      expect(reply, contains('钙片'));
    });

    test('账目：口语化的收入被理解成 income', () async {
      final store = await openStore(ActionInputMode.aiOnly);
      await store.createConversation(title: '记账', topic: Topic.finance);

      await askWith(
        store,
        '发了工资八千，另外打车花了十八',
        '```actions\n'
            '${jsonEncode({
              'actions': [
                {'type': 'expense_add', 'title': '工资', 'amount': 8000, 'entryType': 'income'},
                {'type': 'expense_add', 'title': '打车', 'amount': 18, 'entryType': 'expense'},
              ],
            })}\n'
            '```',
      );

      expect(store.expenses.length, 2);
      final wage = store.expenses.firstWhere((e) => e['title'] == '工资');
      expect(wage['entryType'], 'income');
      expect(wage['amount'], 8000.0);
      final taxi = store.expenses.firstWhere((e) => e['title'] == '打车');
      expect(taxi['entryType'], 'expense');
    });
  });

  group('模式开关真的生效', () {
    test('仅本地模式不把动作协议发给模型，模型给了也不执行', () async {
      final store = await openStore(ActionInputMode.localOnly);
      await store.createConversation(title: '药箱', topic: Topic.health);

      await askWith(
        store,
        '帮我加个药叫测试药',
        '```actions\n{"actions":[{"type":"med_add","name":"测试药"}]}\n```',
      );

      expect(
        store.meds,
        isEmpty,
        reason: '「仅本地」模式不该执行模型给的动作',
      );
      // 而且模型回复应被当普通文本落库（用户至少能看到它说了什么）
      expect(store.messages.last.content, contains('测试药'));
    });

    test('智能模式：本地能解析时不调模型', () async {
      final store = await openStore(ActionInputMode.smart);
      await store.createConversation(title: '药箱', topic: Topic.health);

      // 服务端故意返回 500：本地正则已命中，不该有任何网络调用。
      // 0.4F 起对话走 `/messages`（联网端点），所以这个「坏服务端」要挂在它上面，
      // 否则测试会因为端点不匹配而落到 404，测不到「本地命中时不发请求」这件事。
      final fake = FakeHttpClient.routed(
        {},
        chatText: '',
        searchStatus: 500,
      );
      late String reply;
      await HttpOverrides.runZoned(() async {
        reply = await store.ask('添加药品 a,b,c');
      }, createHttpClient: (_) => fake);

      expect(store.meds.length, 3);
      expect(
        fake.requests.where((u) => u.path.contains('messages')),
        isEmpty,
        reason: '本地正则命中时不应产生网络调用（否则每次都白花一次 token）',
      );
      expect(reply, contains('共 3 项'));
    });

    test('智能模式：本地解析不出来时才交给模型', () async {
      final store = await openStore(ActionInputMode.smart);
      await store.createConversation(title: '药箱', topic: Topic.health);

      final fake = FakeHttpClient.routed(
        {},
        chatText:
            '```actions\n{"actions":[{"type":"med_add","name":"护肝片","stock":2}]}\n```',
      );
      await HttpOverrides.runZoned(() async {
        await store.ask('帮我记一下还有两盒护肝片');
      }, createHttpClient: (_) => fake);

      expect(store.meds.length, 1);
      expect(store.meds.single['name'], '护肝片');
      expect(store.meds.single['stock'], 2);
      expect(fake.requests, isNotEmpty, reason: '这时应该真的调了模型');
    });
  });

  group('模型回复畸形时退化成普通对话', () {
    test('模型只说了话、没给动作 → 当普通回复', () async {
      final store = await openStore(ActionInputMode.smart);
      await store.createConversation(title: '药箱', topic: Topic.health);

      final reply = await askWith(
        store,
        '帮我记一下还有两盒护肝片',
        '抱歉，我不太确定你说的是哪种药，能说下完整名称吗？',
      );

      expect(store.meds, isEmpty);
      expect(reply, contains('不太确定'));
    });

    test('动作 JSON 非法 → 原文照常显示，不报错', () async {
      final store = await openStore(ActionInputMode.smart);
      await store.createConversation(title: '药箱', topic: Topic.health);

      final reply = await askWith(
        store,
        '帮我记一下还有两盒护肝片',
        '好的。\n```actions\n{"actions":[{"type":\n```',
      );

      expect(store.meds, isEmpty);
      expect(reply, isNotEmpty);
      expect(reply, isNot(contains('```')), reason: '不该把裸代码块显示给用户');
      expect(reply, contains('好的。'), reason: '模型说的话要保留');
    });

    test('API 失败时不执行任何动作，显示可读错误', () async {
      final store = await openStore(ActionInputMode.smart);
      await store.createConversation(title: '药箱', topic: Topic.health);

      // 401：联网端点报「没配 Key / Key 不对」，界面要给可读提示。
      final fake = FakeHttpClient.routed(
        {},
        chatText: '',
        searchStatus: 401,
      );
      late String reply;
      await HttpOverrides.runZoned(() async {
        reply = await store.ask('帮我记一下还有两盒护肝片');
      }, createHttpClient: (_) => fake);

      expect(store.meds, isEmpty);
      // 用户看到的是**可读说明**，不是裸状态码 —— 状态码被 `AiResult.display`
      // 翻译成「该去哪儿改」了，这是有意的（见 `AiClient._describe`）。
      expect(reply, contains('API Key'));
      expect(reply, isNot(contains('401')), reason: '不该把裸状态码丢给用户');
    });
  });

  group('本地模式仍然可用（没配 Key 时的退路）', () {
    test('没有 API Key 时固定写法照样能录入', () async {
      final store = Store(db: FakeDb());
      await store.load();
      await store.createConversation(title: '药箱', topic: Topic.health);
      expect(store.hasApiKey, isFalse);

      final reply = await store.ask('添加药品 a,b,c 库存 2');

      expect(store.meds.length, 3);
      for (final m in store.meds) {
        expect(m['stock'], 2);
      }
      expect(reply, contains('共 3 项'));
    });
  });
}
