import 'package:family_life_assistant/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 0.4D 需求 1.1：**消息修改后重新发送，且不能与前一次的消息重复**。
///
/// 用户在两个方案里选定了：
/// 「原地替换：改的那条就是最终提问，旧回答删掉，再自动重问一次」。
///
/// 这一组把那个选择的**四条含义**分别钉住：
///  ① 时间轴上只有一条提问（原地改写，不是新增）；
///  ② 旧回答被删掉（它回答的是旧问题）；
///  ③ 真的重新问了模型（产生一条新回复）；
///  ④ 后续的用户消息不能被误删（只删助手回复）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = 'plugins.it_nomads.com/flutter_secure_storage';

  setUp(() {
    // ⚠️ 这个 mock **必须有**，而且是本文件里最容易被漏掉的一行。
    //
    // 没有它时，`Store` 读设置会走真实插件通道 → 拿不到值 → 落到默认配置，
    // 也就是说 `hasApiKey` 是 false，走的是「未配 Key」的本地兜底路径。
    // 单跑这个文件时看起来一切正常，但**整个套件一起跑**时，
    // 别的测试文件装过的 storage mock（返回一个假 Key）还留在通道上，
    // 于是这里 `hasApiKey` 变成 true → 去发真实 HTTP → 超时/失败，
    // 消息条数与回复内容全变了。
    //
    // 实测症状：单跑 `flutter test test/message_resend_test.dart` 时
    // 「4 条消息」通过，整套跑却变成 5 条。**同一个测试两种结果**，
    // 排查成本极高。所以这里显式装、显式拆，不依赖任何别的文件。
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
    // 不传 title，走默认的「新对话」。
    //
    // 这一点很关键：`addMessage` 只在标题**仍是默认值**时才用首条消息命名对话
    // （见 store.dart 的 shouldRename）。如果这里传了 title: '测试'，
    // 标题联动就永远不会触发，测「改首条消息标题跟着改」时会看到一个
    // 与产品行为无关的失败。
    await store.createConversation(topic: Topic.finance);
    return store;
  }

  /// 未配 API Key 时，模型路径会写一条固定的引导语作为助手回复。
  /// 用它来判断「有没有真的重问」—— 只要出现新的助手回复就说明走了模型路径。
  const noKeyReply = '请先在「设置 → AI 服务 → API 配置」中填写 API Key。数据仍然只保存在本机。';

  group('【关键】原地替换：不产生重复消息', () {
    test('修改并重发后，用户消息仍然只有一条', () async {
      final store = await openStore();
      await store.ask('买菜 32');
      final before = store.messages.length;
      expect(before, 2, reason: '一条提问 + 一条回复');

      final id = store.messages.first.id;
      await store.resendEditedMessage(id, '买菜 35');

      final userMessages = store.messages.where((m) => m.isUser).toList();
      expect(
        userMessages.length,
        1,
        reason: '「不能与前一次的消息重复」—— 时间轴上只能留一条提问',
      );
      expect(userMessages.first.content, '买菜 35');
      expect(userMessages.first.id, id, reason: 'id 必须不变，否则就是新增而非替换');
    });

    test('时间戳不变：替换不会让消息在时间轴上跳位', () async {
      final store = await openStore();
      await store.ask('原始问题');
      final original = store.messages.first.createdAt;

      await store.resendEditedMessage(store.messages.first.id, '改后的问题');

      expect(store.messages.first.createdAt, original);
    });

    test('助手消息最终只剩一条（旧的被删、新的补上）', () async {
      final store = await openStore();
      await store.ask('原始问题');
      expect(store.messages.where((m) => !m.isUser).length, 1);

      await store.resendEditedMessage(store.messages.first.id, '改后的问题');

      expect(
        store.messages.where((m) => !m.isUser).length,
        1,
        reason: '旧回答必须删掉，否则新旧两个答案并存，用户分不清哪个对',
      );
      expect(store.messages.length, 2, reason: '一问一答，没有多余的消息');
    });

    test('旧回复的内容不会残留', () async {
      final store = await openStore();
      await store.ask('原始问题');
      final oldReplyId = store.messages.last.id;

      await store.resendEditedMessage(store.messages.first.id, '改后的问题');

      expect(
        store.messages.any((m) => m.id == oldReplyId),
        isFalse,
        reason: '旧回复必须真的从列表里消失',
      );
    });
  });

  group('确实重新问了模型', () {
    test('重发会写入一条**新的**助手回复', () async {
      final store = await openStore();
      await store.ask('原始问题');
      final oldReplyId = store.messages.last.id;

      final reply = await store.resendEditedMessage(
        store.messages.first.id,
        '改后的问题',
      );

      expect(reply, isNotEmpty, reason: '重发必须拿到回复');
      expect(store.messages.last.id, isNot(oldReplyId));
      expect(store.messages.last.content, reply);
    });

    test('未配 Key 时重发走的是与首次提问完全相同的兜底路径', () async {
      final store = await openStore();
      await store.ask('原始问题');
      expect(store.messages.last.content, noKeyReply);

      await store.resendEditedMessage(store.messages.first.id, '改后的问题');

      expect(
        store.messages.last.content,
        noKeyReply,
        reason: '重发复用 ask 的后半段，两条路径的回复应当一致',
      );
    });

    test('重发时紧急就医提示仍然优先（安全不能被重发绕开）', () async {
      final store = await openStore();
      await store.createConversation(title: '健康', topic: Topic.health);
      await store.ask('普通问题');
      expect(store.messages.last.content, noKeyReply);

      // 把问题改成紧急症状 —— 必须命中本地紧急分流，而不是走模型
      await store.resendEditedMessage(
        store.messages.first.id,
        '胸口剧痛还喘不上气',
      );

      final last = store.messages.last.content;
      expect(last, contains('120'), reason: '紧急提示不能被重发路径吞掉');
      expect(last, isNot(noKeyReply));
    });
  });

  group('边界与安全', () {
    test('不允许对助手回复重发', () async {
      final store = await openStore();
      await store.ask('原始问题');
      final replyId = store.messages.last.id;

      final result = await store.resendEditedMessage(replyId, '改掉它');

      expect(result, isEmpty);
      expect(
        store.messages.last.content,
        isNot('改掉它'),
        reason: '助手回复是「模型当时这么回答」的记录，不允许被改写',
      );
    });

    test('空内容不发请求、不改动任何消息', () async {
      final store = await openStore();
      await store.ask('原始问题');
      final snapshot = store.messages.map((m) => m.content).toList();

      expect(await store.resendEditedMessage(store.messages.first.id, '   '), isEmpty);
      expect(store.messages.map((m) => m.content).toList(), snapshot);
    });

    test('不存在的 id 安全返回，不抛异常', () async {
      final store = await openStore();
      await store.ask('原始问题');
      expect(await store.resendEditedMessage('不存在的id', '随便'), isEmpty);
      expect(store.messages.length, 2);
    });

    test('内容没变时仍然重发（用户可能就是想重答一次）', () async {
      final store = await openStore();
      await store.ask('同一个问题');
      final oldReplyId = store.messages.last.id;

      final reply = await store.resendEditedMessage(
        store.messages.first.id,
        '同一个问题',
      );

      expect(reply, isNotEmpty);
      expect(store.messages.last.id, isNot(oldReplyId));
      expect(store.messages.where((m) => m.isUser).length, 1);
    });
  });

  group('【关键】只删助手回复，不误删后续用户消息', () {
    test('连续多轮对话中，改中间一条只清掉它之后的助手回复', () async {
      final store = await openStore();
      await store.ask('第一问');
      await store.ask('第二问');
      await store.ask('第三问');

      // 形状：U1 A1 U2 A2 U3 A3
      expect(store.messages.length, 6);
      final u2 = store.messages[2];
      expect(u2.content, '第二问');
      final u3Id = store.messages[4].id;

      await store.resendEditedMessage(u2.id, '第二问（改）');

      final contents = store.messages.map((m) => m.content).toList();
      expect(contents, contains('第一问'));
      expect(
        contents.where((c) => c == '第三问').length,
        1,
        reason: 'U3 是用户说的话，属于「后面还没被回答的提问」，不该被删',
      );
      expect(
        store.messages.any((m) => m.id == u3Id),
        isTrue,
        reason: 'U3 必须还在',
      );
      expect(
        contents.where((c) => c == '第二问（改）').length,
        1,
        reason: '被改的那条只有一份',
      );
      // 三条提问都只各出现一次
      for (final q in ['第一问', '第二问（改）', '第三问']) {
        expect(contents.where((c) => c == q).length, 1, reason: q);
      }
    });

    test('改最后一条提问时，只有它自己的回复被替换', () async {
      final store = await openStore();
      await store.ask('第一问');
      await store.ask('第二问');
      final u1 = store.messages[0].id;
      final a1 = store.messages[1].id;

      await store.resendEditedMessage(store.messages[2].id, '第二问（改）');

      expect(store.messages[0].id, u1);
      expect(store.messages[1].id, a1, reason: '第一轮的回复与这次改动无关');
      expect(store.messages.length, 4, reason: 'U1 A1 U2 A2');
    });
  });

  group('标题联动（沿用 0.4C 的规则）', () {
    test('改首条消息时对话标题跟着更新', () async {
      final store = await openStore();
      await store.addMessage('user', '本月花了多少');
      expect(store.activeConversation!.title, '本月花了多少');

      await store.resendEditedMessage(store.messages.first.id, '上月花了多少');

      expect(store.activeConversation!.title, '上月花了多少');
    });
  });
}
