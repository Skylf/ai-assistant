import 'package:family_life_assistant/data/db.dart';
import 'package:family_life_assistant/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 多对话管理（0.2A 功能）的纯逻辑测试。
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

  Future<Store> openStore([FakeDb? db]) async {
    final store = Store(db: db ?? FakeDb());
    await store.load();
    return store;
  }

  group('对话初始化', () {
    test('首次启动至少有一个对话并已选中', () async {
      final store = await openStore();
      expect(store.conversations, isNotEmpty);
      expect(store.activeConversation, isNotNull);
      expect(store.activeConversationId, store.activeConversation!.id);
      expect(store.messages, isEmpty);
    });

    test('从 v2 迁移：按主题挂到默认对话，历史不丢', () async {
      final db = FakeDb();
      // 模拟 0.2A 之前的数据：只有 topic，没有 conversationId
      await db.open();
      await db.put(T.chats, {
        'id': 'old-1',
        'role': 'user',
        'content': '旧账本问题',
        'topic': 'f',
        'createdAt': '2026-01-01T10:00:00.000',
      });
      await db.put(T.chats, {
        'id': 'old-2',
        'role': 'user',
        'content': '旧健康问题',
        'topic': 'h',
        'createdAt': '2026-01-01T11:00:00.000',
      });

      final store = await openStore(db);
      expect(store.conversations.length, 2);

      final finance = store.conversations.firstWhere(
        (c) => c.topic == Topic.finance,
      );
      final health = store.conversations.firstWhere(
        (c) => c.topic == Topic.health,
      );
      expect(finance.title, '默认账本分析');
      expect(health.title, '默认健康科普');

      await store.selectConversation(health.id);
      expect(store.messages.length, 1);
      expect(store.messages.single.content, '旧健康问题');

      await store.selectConversation(finance.id);
      expect(store.messages.single.content, '旧账本问题');
    });
  });

  group('新建与切换', () {
    test('新建对话会切换过去，且各对话消息互相隔离', () async {
      final store = await openStore();
      final first = store.activeConversation!;
      await store.addMessage('user', '第一个对话的问题');

      final second = await store.createConversation(title: '饮食规划');
      expect(store.activeConversationId, second.id);
      expect(store.conversations.length, 2);
      // 新对话是空的，不应看到第一个对话的消息
      expect(store.messages, isEmpty);

      await store.addMessage('user', '第二个对话的问题');
      expect(store.messages.length, 1);

      await store.selectConversation(first.id);
      expect(store.messages.length, 1);
      expect(store.messages.single.content, '第一个对话的问题');
    });

    test('未命名时使用「新对话」，首条用户消息自动成为标题', () async {
      final store = await openStore();
      final created = await store.createConversation();
      expect(created.title, '新对话');

      await store.addMessage('user', '帮我看看本月餐饮支出');
      expect(store.activeConversation!.title, '帮我看看本月餐饮支出');

      // 助手消息不改标题
      await store.addMessage('assistant', '好的');
      expect(store.activeConversation!.title, '帮我看看本月餐饮支出');
    });

    test('过长的首条消息被截断为 16 字加省略号', () async {
      final store = await openStore();
      await store.createConversation();
      await store.addMessage('user', '一' * 40);
      expect(store.activeConversation!.title, '${'一' * 16}…');
    });

    test('手动命名的对话不会被首条消息覆盖', () async {
      final store = await openStore();
      await store.createConversation(title: '装修预算');
      await store.addMessage('user', '这个问题很长很长很长很长很长很长');
      expect(store.activeConversation!.title, '装修预算');
    });
  });

  group('更新与删除', () {
    test('可以改标题、主题与记忆档位', () async {
      final store = await openStore();
      final id = store.activeConversationId;

      await store.updateConversation(
        id,
        title: '新标题',
        topic: Topic.health,
        memory: MemoryScope.global,
      );
      final updated = store.activeConversation!;
      expect(updated.title, '新标题');
      expect(updated.topic, Topic.health);
      expect(updated.memory, MemoryScope.global);
    });

    test('删除对话会一并删除它的消息', () async {
      final store = await openStore();
      final first = store.activeConversation!;
      await store.addMessage('user', '要被删掉的消息');

      final second = await store.createConversation(title: '保留');
      await store.deleteConversation(first.id);

      expect(store.conversations.length, 1);
      expect(store.conversations.single.id, second.id);
      // 删掉的是非当前对话，当前对话的消息不受影响
      expect(store.messages, isEmpty);
    });

    test('删除当前对话会自动切到另一个并加载它的消息', () async {
      final store = await openStore();
      final first = store.activeConversation!;
      await store.addMessage('user', '第一条');

      final second = await store.createConversation(title: '第二个');
      await store.addMessage('user', '第二条');

      await store.selectConversation(first.id);
      expect(store.messages.single.content, '第一条');

      await store.deleteConversation(first.id);
      expect(store.activeConversationId, second.id);
      expect(store.messages.single.content, '第二条');
    });

    test('删掉最后一个对话会自动补一个空对话', () async {
      final store = await openStore();
      await store.deleteConversation(store.activeConversationId);
      expect(store.conversations.length, 1);
      expect(store.activeConversation, isNotNull);
      expect(store.messages, isEmpty);
    });

    test('清空对话只删消息、保留对话与设置', () async {
      final store = await openStore();
      final id = store.activeConversationId;
      await store.updateConversation(id, title: '自定义', memory: MemoryScope.global);
      await store.addMessage('user', '一条消息');

      await store.clearConversation(id);
      expect(store.messages, isEmpty);
      expect(store.conversations.length, 1);
      expect(store.activeConversation!.title, '自定义');
      expect(store.activeConversation!.memory, MemoryScope.global);
    });
  });

  group('记忆作用域', () {
    test('【关键】新建对话的默认记忆是「存入全局记忆」', () async {
      // 2026-10-08 用户要求：AI 对话记忆默认为全局记忆（原为「仅当前对话」）。
      // 断言写成 defaultScope 而不是字面量 global，这样「默认值是什么」只有
      // 一处定义；但**同时**断言它确实是 global —— 否则改了常量这条测试
      // 会跟着一起变，等于没测。两行缺一不可。
      expect(MemoryScope.defaultScope, MemoryScope.global);
      final store = await openStore();
      expect(store.activeConversation!.memory, MemoryScope.global);
    });

    test('显式指定其他记忆档位时不会被默认值覆盖', () async {
      // 默认值只作用于「新建对话」这一次调用，不能把调用方明确传的值吃掉。
      final store = await openStore();
      final local = await store.createConversation(
        title: '私密对话',
        memory: MemoryScope.local,
      );
      expect(local.memory, MemoryScope.local);
      final off = await store.createConversation(
        title: '临时问问',
        memory: MemoryScope.off,
      );
      expect(off.memory, MemoryScope.off);
      // 新建之后立刻读回，确认落库的就是传进去的那个档位
      expect(store.activeConversation!.memory, MemoryScope.off);
    });

    test('【关键】升级前就存在的对话保留自己的档位，不会被默认值改写', () async {
      // 真实现场：用户升级到 0.5.3 后发问「为啥我在聊天里看到的还是仅本对话记忆」。
      //
      // 根因是**这不是 bug**，而是刻意的：默认值只作用于 `createConversation`
      // 那一刻，库里已有的行保留自己 `memory` 列存的值。
      //
      // 这条测试用**同一个 FakeDb 开两次 Store** 来复现「升级前后」：
      // 第一次是升级前（把默认值显式写成 local，模拟旧版本建出来的对话），
      // 第二次是升级后重新 load —— 断言它**仍然是 local**。
      // 如果哪天有人把「默认值」改成「迁移时覆盖所有旧对话」，
      // 这条会红，提醒他那是数据破坏而不是功能改进。
      final db = FakeDb();

      final before = await openStore(db);
      await before.updateConversation(
        before.activeConversationId,
        memory: MemoryScope.local,
      );
      await before.addMessage('user', '升级前就在的老对话');
      final id = before.activeConversationId;
      expect(before.activeConversation!.memory, MemoryScope.local);

      // 同一个库，重新启动（等价于升级后第一次打开）
      final after = await openStore(db);
      expect(after.conversations.length, 1);
      expect(after.conversations.single.id, id);
      expect(
        after.conversations.single.memory,
        MemoryScope.local,
        reason: '已有对话的记忆档位必须原样保留 —— 用户自己设过的选择不该被升级抹掉',
      );
      // 而**新建**的对话走新默认值，两者并存不矛盾
      final fresh = await after.createConversation(title: '升级后新建的');
      expect(fresh.memory, MemoryScope.global);
      expect(after.conversations.length, 2);
      // 老的那条依然没被动过
      expect(
        after.conversations.firstWhere((c) => c.id == id).memory,
        MemoryScope.local,
      );
    });

    test('三档记忆都有展示文案，不会出现空标签', () {
      for (final scope in MemoryScope.values) {
        expect(scope.label, isNotEmpty);
        expect(scope.shortLabel, isNotEmpty);
        expect(scope.detail, isNotEmpty);
        expect(scope.code, isNotEmpty);
        expect(scope.icon, isNotNull);
      }
    });

    test('一键把全部对话改成「全局记忆」：只改需要改的，并报告真实条数', () async {
      final store = await openStore();
      // 初始那条是新建的（global），再手工造出 local / off 各一条
      await store.updateConversation(
        store.activeConversationId,
        memory: MemoryScope.local,
      );
      final off = await store.createConversation(
        title: '不记忆的',
        memory: MemoryScope.off,
      );
      expect(off.memory, MemoryScope.off);

      // 两条是 local/off，都不是 global
      expect(store.countConversationsNotGlobal(), 2);

      final changed = await store.setAllConversationMemory(MemoryScope.global);
      expect(changed, 2);
      for (final c in store.conversations) {
        expect(c.memory, MemoryScope.global);
      }
      expect(store.countConversationsNotGlobal(), 0);

      // 幂等：没有需要改的时候返回 0，不报错
      expect(await store.setAllConversationMemory(MemoryScope.global), 0);
    });

    test('一键改档位不会白改已经是目标档位的对话', () async {
      // `setAllConversationMemory` 只动档位不同的那几条。如果它无差别地全部
      // 写一遍，`updatedAt` 会被刷新，而 `updatedAt` 参与「最近」排序 ——
      // 用户会看到对话顺序无缘无故变了。
      final store = await openStore();
      final global = store.conversations.single;
      expect(global.memory, MemoryScope.global);
      final before = global.updatedAt;

      final changed = await store.setAllConversationMemory(MemoryScope.global);

      expect(changed, 0);
      expect(
        store.conversations.single.updatedAt,
        before,
        reason: '已经是「全局记忆」的对话不该被重写，否则排序会跟着变',
      );
    });

    test('全局记忆可以保存与读回', () async {
      final store = await openStore();
      expect(store.globalMemory, isEmpty);
      expect(store.globalMemoryNotes(), isEmpty);

      await store.saveGlobalMemory('家里有 2 位老人');
      expect(store.globalMemory, '家里有 2 位老人');
      expect(store.globalMemoryNotes(), ['家里有 2 位老人']);

      await store.saveGlobalMemory('   ');
      expect(store.globalMemory, isEmpty);
      expect(store.globalMemoryNotes(), isEmpty);
    });

    test('主题码能双向转换，未知码回落到账本', () {
      expect(Topic.fromCode('f'), Topic.finance);
      expect(Topic.fromCode('h'), Topic.health);
      expect(Topic.fromCode('x'), Topic.finance);
      expect(Topic.fromCode(null), Topic.finance);
      expect(MemoryScope.fromCode('global'), MemoryScope.global);
      expect(MemoryScope.fromCode('off'), MemoryScope.off);
      expect(MemoryScope.fromCode('local'), MemoryScope.local);
      // 无法识别的记忆码回落到当前默认档位（与新建对话一致，不留第二种答案）
      expect(MemoryScope.fromCode('nope'), MemoryScope.defaultScope);
      expect(MemoryScope.fromCode(null), MemoryScope.defaultScope);
    });
  });

  group('自定义提示词', () {
    test('按主题分别保存', () async {
      final store = await openStore();
      await store.saveCustomPrompts(finance: '先说结论', health: '用词口语化');
      expect(store.customPromptFinance, '先说结论');
      expect(store.customPromptHealth, '用词口语化');
    });
  });

  group('密码记录', () {
    test('保存时不存明文，只留用途与强度', () async {
      final store = await openStore();
      final record = await store.savePasswordRecord(
        label: '邮箱',
        site: '随机密码',
        length: 16,
        strength: 3,
        entropy: 95.2,
      );
      expect(store.savedPasswords.length, 1);
      expect(record.label, '邮箱');

      final row = record.toRow();
      expect(row.containsKey('password'), isFalse);
      expect(row.containsKey('plaintext'), isFalse);
      expect(row.values.map((v) => v.toString()), isNot(contains('sk-')));
      // 导出的数据里也不应出现明文字段
      final exported = await store.exportJson();
      expect(exported.contains('passwordRecords'), isTrue);
    });

    test('删除与清空', () async {
      final store = await openStore();
      final first = await store.savePasswordRecord(
        label: 'A',
        site: '随机密码',
        length: 12,
        strength: 2,
        entropy: 60,
      );
      await store.savePasswordRecord(
        label: 'B',
        site: '密钥',
        length: 32,
        strength: 4,
        entropy: 180,
      );
      expect(store.savedPasswords.length, 2);

      await store.removePasswordRecord(first.id);
      expect(store.savedPasswords.length, 1);
      expect(store.savedPasswords.single.label, 'B');

      await store.clearPasswordRecords();
      expect(store.savedPasswords, isEmpty);
    });
  });

  group('数据管理', () {
    test('dataCounts 反映各表数量', () async {
      final store = await openStore();
      await store.expense({'title': '买菜', 'amount': 10.0});
      await store.med({'name': '布洛芬', 'stock': 2});
      await store.savePasswordRecord(
        label: 'A',
        site: '随机密码',
        length: 8,
        strength: 1,
        entropy: 40,
      );

      final counts = store.dataCounts;
      expect(counts['expenses'], 1);
      expect(counts['medicines'], 1);
      expect(counts['passwords'], 1);
      expect(counts['conversations'], store.conversations.length);
    });

    test('清空账本不影响药箱与对话', () async {
      final store = await openStore();
      await store.expense({'title': '买菜', 'amount': 10.0});
      await store.med({'name': '布洛芬', 'stock': 2});
      await store.addMessage('user', '你好');

      await store.clearData(tables: [T.expenses]);
      expect(store.expenses, isEmpty);
      expect(store.meds.length, 1);
      expect(store.messages.length, 1);
    });

    test('清空对话后自动补一个空对话，且记忆设置被重置', () async {
      final store = await openStore();
      // 先显式改成与默认**不同**的档位，否则「被重置」这件事测不出来
      // （默认值改成 global 之后，如果这里写死 global，就恒真了）。
      await store.updateConversation(
        store.activeConversationId,
        memory: MemoryScope.off,
      );
      expect(store.activeConversation!.memory, MemoryScope.off);
      await store.addMessage('user', '你好');

      await store.clearData(tables: [T.conversations, T.chats]);
      expect(store.messages, isEmpty);
      expect(store.conversations.length, 1);
      // 补出来的新对话应当回到**默认**档位
      expect(store.activeConversation!.memory, MemoryScope.defaultScope);
    });

    test('导出的 JSON 含版本号且不含 API Key', () async {
      final store = await openStore();
      await store.saveSettings(
        url: 'https://api.deepseek.com',
        model: 'deepseek-chat',
        apiKey: 'sk-secret-should-not-leak',
      );
      await store.expense({'title': '买菜', 'amount': 10.0});

      final json = await store.exportJson();
      expect(json.contains('schemaVersion'), isTrue);
      expect(json.contains('sk-secret-should-not-leak'), isFalse);
      expect(json.contains('买菜'), isTrue);
    });

    test('导出覆盖所有对话的消息，而不是只有当前对话', () async {
      final store = await openStore();
      await store.addMessage('user', '第一个对话的话');
      await store.createConversation(title: '第二个对话');
      await store.addMessage('user', '第二个对话的话');

      final data = await store.exportData();
      final messages = data['messages'] as List;
      expect(messages.length, 2);
      final contents = messages
          .map((m) => (m as Map)['content'].toString())
          .toList();
      expect(contents, containsAll(['第一个对话的话', '第二个对话的话']));
    });
  });

  group('AI 反向添加多条：真的落库（不只是解析对）', () {
    // 解析正确不等于落库正确：`ask` 里如果只用了第一个动作，用户看到的回复
    // 可能是对的，但药箱里只多了一样东西。这里断言**存储里的最终状态**。
    test('添加药品：a,b,c 落库三条，而不是一条名叫 a,b,c 的', () async {
      final store = await openStore();
      final conversation = await store.createConversation(
        title: '药箱咨询',
        topic: Topic.health,
      );
      expect(conversation.topic, Topic.health);

      final reply = await store.ask('添加药品：a,b,c');

      expect(store.meds.length, 3, reason: '应该真的加进三条');
      expect(
        store.meds.map((m) => m['name']).toList()..sort(),
        ['a', 'b', 'c'],
      );
      expect(
        store.meds.any((m) => m['name'] == 'a,b,c'),
        isFalse,
        reason: '必须不存在名叫「a,b,c」的那一条',
      );
      // 回复要能让用户核对每一项
      expect(reply, contains('共 3 项'));
    });

    test('列表带共用参数时，每一项都拿到参数', () async {
      final store = await openStore();
      await store.createConversation(title: '药箱咨询', topic: Topic.health);

      await store.ask('添加药品 a,b,c 库存 2 有效期 2027-05-01');

      expect(store.meds.length, 3);
      for (final m in store.meds) {
        expect(m['stock'], 2);
        expect(m['expiry'], '2027-05-01');
      }
    });

    test('账本一条消息多笔都落库', () async {
      final store = await openStore();
      final conversation = await store.createConversation(
        title: '记账',
        topic: Topic.finance,
      );
      expect(conversation.topic, Topic.finance);

      await store.ask('记账 买菜 32.5, 打车 18');

      expect(store.expenses.length, 2);
      final byTitle = {
        for (final e in store.expenses) e['title'] as String: e['amount'],
      };
      expect(byTitle['买菜'], 32.5);
      expect(byTitle['打车'], 18.0);
    });

    test('单项行为不变', () async {
      final store = await openStore();
      await store.createConversation(title: '药箱咨询', topic: Topic.health);

      final reply = await store.ask('添加药品 布洛芬 库存 5');

      expect(store.meds.length, 1);
      expect(store.meds.single['name'], '布洛芬');
      expect(store.meds.single['stock'], 5);
      expect(reply, contains('药品已加入药箱：布洛芬'));
      expect(reply, isNot(contains('共')));
    });
  });
}
