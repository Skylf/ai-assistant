import 'dart:convert';
import 'dart:io';

import 'package:family_life_assistant/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';
import 'support/fake_http.dart';

/// 「模型拿旧消息当依据」与「明确命令被无视」这两类失效。
///
/// 都来自真机实测（用户截图）：
/// 1. 先说「今天买菜50，吃饭250，加到账本里去」，下一句只说「今天买菜20」，
///    模型在「依据」里引用**上一句**，照抄那两笔旧金额，当前这句被完全忽略。
/// 2. 说「帮我把布洛芬和连花清瘟加到药箱里去」，模型回了一段自我介绍 +
///    功能清单，一条药都没加。
///
/// 共同点：模型没有把**最后一条消息**当成要处理的对象。
/// 取出两个标记之间的那一段（标记本身不含在结果里）。
///
/// 用 indexOf 而不是 RegExp：系统提示词里本身含大量正则元字符（`【】`、
/// 竖线、括号），拿去构造正则极易出错；而这里的标记都是独一份的字面量，
/// 直接找下标更简单也更稳。
String _section(String text, String start, String end) {
  final from = text.indexOf(start);
  if (from < 0) return '';
  final begin = from + start.length;
  final to = text.indexOf(end, begin);
  return (to < 0 ? text.substring(begin) : text.substring(begin, to)).trim();
}

/// 把「【对话】」段拆成一条条 `用户：…` / `助手：…`，返回内容部分。
List<String> _historyLines(String block) {
  final lines = <String>[];
  for (final raw in block.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('用户：')) {
      lines.add(line.substring(3).trim());
    } else if (line.startsWith('助手：')) {
      lines.add(line.substring(3).trim());
    }
  }
  return lines;
}

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

  Future<Store> openStore(Topic topic) async {
    final store = Store(db: FakeDb());
    await store.load();
    await store.saveSettings(
      url: 'https://api.example.com/v1',
      model: 'test-model',
      apiKey: 'sk-test',
    );
    await store.saveActionMode(ActionInputMode.aiOnly);
    await store.createConversation(title: '测试', topic: topic);
    return store;
  }

  /// 发送一次提问，返回「回复」与「真正发出的请求体」。
  ///
  /// ⚠️ **0.4F 起对话走联网端点**（Anthropic 兼容 `/messages`，SSE 流式），
  /// 请求形状与原来的 OpenAI `messages` 数组**完全不同**：
  /// 现在只有**一条 user 消息**，内容是一个大字符串，分为三段
  /// （见 `Store.buildChatSearchQuery`）：
  ///   `【系统设定】…` / `【对话】用户：… 助手：…` / `【要求】…`
  ///
  /// 所以这里改成**把那段文本切回来**再断言。这一组的测试意图没变
  /// （「历史有没有被正确裁剪 / 当前提问在不在最后」），只是取值方式变了。
  Future<({String reply, List<String> sent, String system})> ask(
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

    final bodies = fake.bodies
        .map((b) => jsonDecode(b) as Map<String, dynamic>)
        .toList();
    expect(bodies, isNotEmpty, reason: '一次请求都没发出去，测试意图没被覆盖');
    final last = bodies.last;

    // content 是数组，取所有 text 片段拼起来
    final contentParts = (last['messages'] as List)
        .cast<Map<String, dynamic>>()
        .expand((m) => (m['content'] as List).cast<Map<String, dynamic>>())
        .map((c) => c['text'] as String? ?? '')
        .join();
    return (
      reply: reply,
      system: _section(contentParts, '【系统设定】', '【对话】'),
      sent: _historyLines(_section(contentParts, '【对话】', '【要求】')),
    );
  }

  group('历史裁剪：不让模型翻旧账', () {
    test('历史很短时原样发送', () async {
      final store = await openStore(Topic.finance);
      final r = await ask(store, '今天买菜20', '好的。');

      // 只有「今天买菜20」这一条用户消息
      expect(r.sent.length, 1);
      expect(r.sent.single, '今天买菜20');
    });

    test('历史超长时被裁剪，且注明省略了多少条', () async {
      final store = await openStore(Topic.finance);
      // 先灌入一批历史
      for (var i = 1; i <= 12; i++) {
        await store.addMessage('user', '历史问题 $i');
        await store.addMessage('assistant', '历史回答 $i');
      }
      final r = await ask(store, '今天买菜20', '好的。');

      expect(
        r.sent.length,
        lessThanOrEqualTo(Store.historyLimit + 1),
        reason: '历史必须被裁剪，否则模型容易翻出陈年消息当依据',
      );
      // 最后一条必须是本次提问
      expect(r.sent.last, '今天买菜20');
      // 首条保留（最初意图）
      expect(r.sent.first, '历史问题 1');
      // 中间要有省略说明
      expect(
        r.sent.any((m) => m.contains('省略')),
        isTrue,
        reason: '要让模型知道有更早的对话被省略了',
      );
    });

    test('裁剪后只有「首条 + 省略说明 + 最近的轮次」', () async {
      final store = await openStore(Topic.finance);
      await store.addMessage('user', '今天买菜50，吃饭250，加到账本里去');
      await store.addMessage('assistant', '已加入账本（共 2 项）');
      for (var i = 1; i <= 12; i++) {
        await store.addMessage('user', '闲聊 $i');
        await store.addMessage('assistant', '回应 $i');
      }
      final r = await ask(store, '今天买菜20', '好的。');

      final contents = r.sent;
      // 中间那些「闲聊/回应」必须被砍掉，只留最近的
      expect(contents.contains('闲聊 1'), isFalse, reason: '中段的旧消息应被裁掉');
      expect(contents.contains('闲聊 12'), isTrue, reason: '最近一轮要保留');
      expect(contents.last, '今天买菜20', reason: '最后一条必须是本次提问');
      // 首条按设计保留（它是最初的请求），但只能出现一次
      expect(contents.where((c) => c.contains('吃饭250')).length, 1);
    });

    test('【回归】当前提问必须在请求里，且排在最后', () async {
      // 这里原本有个严重缺陷：历史快照取在 addMessage **之前**，
      // 于是发出去的请求里根本没有当前这条提问，模型只能照着上一轮回答。
      // 真机表现就是「又问了一句，它却把上一句的内容又录了一遍」。
      final store = await openStore(Topic.finance);
      await store.addMessage('user', '今天买菜50，吃饭250，加到账本里去');
      await store.addMessage('assistant', '已加入账本（共 2 项）');

      final r = await ask(store, '今天买菜20', '好的。');

      expect(
        r.sent.contains('今天买菜20'),
        isTrue,
        reason: '当前提问必须真的发出去',
      );
      expect(r.sent.last, '今天买菜20');
    });

    test('当前提问只出现一次（没有重复发送）', () async {
      final store = await openStore(Topic.finance);
      final r = await ask(store, '今天买菜20', '好的。');
      expect(
        r.sent.where((m) => m == '今天买菜20').length,
        1,
        reason: '同一条提问重复发送会让模型认为用户说了两遍',
      );
    });

    test('没有历史可省略时不加省略说明', () async {
      final store = await openStore(Topic.finance);
      final r = await ask(store, '今天买菜20', '好的。');
      expect(r.sent.any((m) => m.contains('省略')), isFalse);
    });
  });

  group('提示词里必须写明「只处理最后一条」', () {
    test('账本主题', () async {
      final store = await openStore(Topic.finance);
      final r = await ask(store, '今天买菜20', '好的。');

      expect(r.system, contains('【只处理最后一条用户消息】'));
      expect(r.system, contains('都已经处理过了'));
      expect(r.system, contains('重复记账'));
      expect(r.system, contains('不要**把上一句的「吃饭250」'));
    });

    test('健康主题', () async {
      final store = await openStore(Topic.health);
      final r = await ask(store, '我有两盒护肝片', '好的。');

      expect(r.system, contains('【只处理最后一条用户消息，且祈使句必须执行】'));
      expect(r.system, contains('重复加药'));
    });

    test('健康主题明确禁止用自我介绍/功能清单回答祈使句', () async {
      // 真机实测：「帮我把布洛芬和连花清瘟加到药箱里去」
      // 被回成了「你好，我是你的家庭健康与用药信息助手……我可以帮你做这些事」
      final store = await openStore(Topic.health);
      final r = await ask(store, '帮我把布洛芬加到药箱里去', '好的。');

      expect(r.system, contains('严禁在这种情况下回复自我介绍'));
      expect(r.system, contains('功能介绍'));
      expect(r.system, contains('想先加点什么'));
      expect(r.system, contains('工具性回复等于没干活'));
    });

    test('「只处理最后一条」必须写在药箱概览之前', () async {
      final store = await openStore(Topic.health);
      final r = await ask(store, '我有两盒护肝片', '好的。');

      final ruleAt = r.system.indexOf('【只处理最后一条用户消息，且祈使句必须执行】');
      final overviewAt = r.system.indexOf('【药箱概览】');
      expect(ruleAt, greaterThanOrEqualTo(0));
      expect(ruleAt, lessThan(overviewAt));
    });
  });

  group('端到端：模型照抄历史时，落库结果不应翻倍', () {
    test('当前只说了买菜20，就不会多出一笔吃饭250', () async {
      // 模型这次「听话」照抄了历史里那两笔 —— 真机上正是这样。
      // 硬编码的护栏拦不住这种（模型完全可以说「用户说了买菜」），
      // 但至少能证明：**只给当前这一条动作**时账面是对的。
      final store = await openStore(Topic.finance);
      await store.addMessage('user', '今天买菜50，吃饭250，加到账本里去');
      await store.addMessage('assistant', '账目已加入账本（共 2 项）');

      await ask(
        store,
        '今天买菜20',
        '```actions\n'
            '${jsonEncode({'actions': [
              {'type': 'expense_add', 'title': '买菜', 'amount': 20},
            ]})}\n```',
      );

      expect(store.expenses.length, 1);
      expect(store.expenses.single['amount'], 20.0);
      expect(store.expenses.single['title'], '买菜');
    });

    test('祈使句得到正常执行（护栏没误伤命令）', () async {
      final store = await openStore(Topic.health);

      final r = await ask(
        store,
        '帮我把布洛芬和连花清瘟加到药箱里去',
        '```actions\n'
            '${jsonEncode({'actions': [
              {'type': 'med_add', 'name': '布洛芬', 'stock': 1},
              {'type': 'med_add', 'name': '连花清瘟', 'stock': 1},
            ]})}\n```',
      );

      expect(store.meds.length, 2);
      expect(store.meds.map((m) => m['name']).toSet(), {'布洛芬', '连花清瘟'});
      expect(r.reply, contains('药品已加入药箱'));
      expect(r.reply, contains('共 2 项'));
    });
  });
}
