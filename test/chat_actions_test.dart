import 'package:family_life_assistant/core/chat_mode.dart';
import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/pages/chat.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 0.4C 的三项 AI 逻辑改动。
///
/// 用户原话：
///  · 「ai 对话页面用户发出去的消息新增修改，复制功能」
///  · 「历史对话新增置顶功能，并且在置顶与非置顶之间要有明确分界线」
///  · 「创建对话后，如果没有任何消息发送，则默认为不创建新的对话，
///     不要点击创建就创建新对话，而是确实有消息发送才创建新对话」
///
/// 这一组测**数据层**的行为（复制是纯 UI，另有 widget 测试覆盖）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Store> openStore() async {
    final store = Store(db: FakeDb());
    await store.load();
    return store;
  }

  group('修改与删除消息', () {
    test('【关键】修改用户消息只改正文，不新增消息', () async {
      final store = await openStore();
      await store.createConversation(title: '测试', topic: Topic.finance);
      await store.addMessage('user', '买菜 32');
      await store.addMessage('assistant', '已记下');

      final id = store.messages.first.id;
      final ok = await store.updateMessage(id, '买菜 35');

      expect(ok, isTrue);
      expect(store.messages.length, 2, reason: '修改不能变成新增一条');
      expect(store.messages.first.content, '买菜 35');
      expect(store.messages[1].content, '已记下', reason: '助手消息不受影响');
      expect(store.messages.first.id, id, reason: 'id 必须保持，否则时间轴会跳');
    });

    test('修改不会改发送时间（消息在时间轴上不跳动）', () async {
      final store = await openStore();
      await store.createConversation(title: '测试', topic: Topic.finance);
      await store.addMessage('user', '原始内容');
      final before = store.messages.first.createdAt;

      await store.updateMessage(store.messages.first.id, '改过的内容');

      expect(store.messages.first.createdAt, before);
    });

    test('【关键】不允许修改助手回复', () async {
      final store = await openStore();
      await store.createConversation(title: '测试', topic: Topic.finance);
      await store.addMessage('assistant', '模型的回答');

      final ok = await store.updateMessage(store.messages.first.id, '改掉它');

      expect(ok, isFalse, reason: '助手回复是记录，改了就和实际回答不一致');
      expect(store.messages.first.content, '模型的回答');
    });

    test('空内容、相同内容、不存在的 id 都不算改动', () async {
      final store = await openStore();
      await store.createConversation(title: '测试', topic: Topic.finance);
      await store.addMessage('user', '内容');
      final id = store.messages.first.id;

      expect(await store.updateMessage(id, '   '), isFalse);
      expect(await store.updateMessage(id, '内容'), isFalse);
      expect(await store.updateMessage('不存在的id', 'x'), isFalse);
      expect(store.messages.length, 1);
    });

    test('修改首条消息时，对话标题跟着更新', () async {
      final store = await openStore();
      await store.createConversation(title: '新对话', topic: Topic.finance);
      await store.addMessage('user', '本月花了多少');

      // 首条消息会把「新对话」自动命名成内容
      expect(store.activeConversation!.title, '本月花了多少');

      await store.updateMessage(store.messages.first.id, '上月花了多少');

      expect(
        store.activeConversation!.title,
        '上月花了多少',
        reason: '改了错字，侧滑菜单里的标题也要跟着改',
      );
    });

    test('删除消息后列表里不再有它', () async {
      final store = await openStore();
      await store.createConversation(title: '测试', topic: Topic.finance);
      await store.addMessage('user', '一');
      await store.addMessage('user', '二');
      final id = store.messages.first.id;

      expect(await store.deleteMessage(id), isTrue);
      expect(store.messages.length, 1);
      expect(store.messages.first.content, '二');
      expect(await store.deleteMessage(id), isFalse, reason: '重复删除应返回 false');
    });
  });

  group('对话置顶', () {
    test('【关键】置顶的排在最前，未置顶的永远在置顶区之后', () async {
      final store = await openStore();
      // 注意两点（都踩过）：
      //  ① `load()` 自带一个默认对话，断言必须针对具体 id，
      //     不能假设「索引 0 就是我刚建的那个」；
      //  ② 连续 `createConversation` 的 `DateTime.now()` 可能落在**同一个
      //     微秒**上 → `updatedAt` 完全相等 → 未置顶区内部的先后顺序不确定。
      //     所以下面**不断言未置顶区内部谁在前**（那是测试自己在猜时序），
      //     只断言「置顶区与未置顶区的分组」这个真正的规则。
      final a = await store.createConversation(
        title: 'A',
        topic: Topic.finance,
      );
      final b = await store.createConversation(
        title: 'B',
        topic: Topic.finance,
      );
      final c = await store.createConversation(
        title: 'C',
        topic: Topic.finance,
      );
      // 默认对话的 id 必须**现在**就固定下来，而且要按**标题**认。
      //
      // ⚠️ 这里连着踩了两次，都是「引用会漂」，值得记下来：
      //  ① 原来写的是 `store.conversations.last.id`，且放在**置顶之后**才求值 ——
      //     置顶把它挤走之后 `last` 可能落在 C 身上，四个 id 的集合塌成三个，
      //     断言偶发变红（8 次里红 2 次）；
      //  ② 改成「建完就取」后我用 `firstWhere(!isPinned)` —— **仍然错**，
      //     因为列表是**新对话在前**排序的，第一条未置顶的正是刚建的 C。
      //     这次变成**必红**（10/10）——从偶发变必现，反而好查了。
      // 教训：在「排序规则」和「身份识别」之间要分清楚，认身份就按**唯一且不变**
      // 的东西认（标题），别借用位置或状态。
      final defaultId = store.conversations
          .firstWhere((x) => x.title == '新对话')
          .id;
      expect(store.conversations.length, 4, reason: '默认对话 + A/B/C');
      expect(
        {defaultId, a.id, b.id, c.id}.length,
        4,
        reason: '四个 id 必须互不相同，否则后面的集合断言形同虚设',
      );

      await store.toggleConversationPin(a.id);
      expect(
        store.conversations.first.id,
        a.id,
        reason: '唯一置顶的必须排最前',
      );

      await store.toggleConversationPin(b.id);

      // ⚠️ 这里**不能**断言「B 在 A 前面」。
      //
      // 原本的写法是 `await Future.delayed(2ms)` 把两次置顶的时间错开，
      // 然后断言「后置顶的 B 在前」。它**偶发失败**（全量跑时出现过一次，
      // 单独跑和重跑都绿）—— 因为「等 2ms 就一定能拉开时间戳」这个前提不成立：
      // `DateTime.now()` 在本机的实际精度比 2ms 粗，两次 `pinnedAt` 完全可能相等，
      // 于是顺序交给 id 兜底比较决定，而 B 的 id 未必大于 A。
      //
      // 更根本的是：**「置顶区内部按什么排」产品从未承诺过**。
      // 用户要的只是「置顶的在上、与普通区之间有明确分界线」。
      // 断言一个没承诺过的顺序，就是测试在替产品做决定 —— 这种测试迟早会红，
      // 而且红的时候看起来像产品坏了。所以只断言真正的规则。
      expect(
        store.conversations.take(2).map((x) => x.id).toSet(),
        {a.id, b.id},
        reason: '置顶区应当就是 A 和 B（内部先后不作要求，见上面的说明）',
      );
      expect(
        store.conversations.take(2).every((x) => x.isPinned),
        isTrue,
        reason: '前两条都应是置顶项',
      );
      expect(
        store.conversations.skip(2).every((x) => !x.isPinned),
        isTrue,
        reason: '置顶区之后不能再混入置顶项',
      );
      expect(
        store.conversations.map((x) => x.id).toSet(),
        {a.id, b.id, c.id, defaultId},
        reason: '不能因为排序丢掉任何对话',
      );
    });

    test('同微秒置顶的两条，顺序仍然确定（不会每次排序都变）', () async {
      // 这条守的是排序的**确定性**，不是「谁该在前」。
      // 没有 id 兜底 key 时，比较返回 0 → 顺序取决于底层 HashMap 遍历顺序，
      // 同一个列表反复排序可能给出不同结果（表现为「置顶的两条偶尔换位置」）。
      final store = await openStore();
      final a = await store.createConversation(
        title: 'A',
        topic: Topic.finance,
      );
      final b = await store.createConversation(
        title: 'B',
        topic: Topic.finance,
      );
      // 连续两次置顶，时间戳很可能落在同一微秒（这正是要覆盖的边界）
      await store.toggleConversationPin(a.id);
      await store.toggleConversationPin(b.id);

      final first = store.conversations.map((c) => c.id).toList();
      // 反复重载，顺序必须一模一样
      for (var i = 0; i < 5; i++) {
        await store.updateConversation(a.id, title: 'A');
        expect(
          store.conversations.map((c) => c.id).toList(),
          first,
          reason: '第 ${i + 1} 次重载后顺序变了，说明排序不稳定',
        );
      }
      // 两条置顶项都必须在前两位
      expect(store.conversations.take(2).every((c) => c.isPinned), isTrue);
    });

    test('同一秒内创建的对话，置顶仍能可靠地把它排到最前', () async {
      // 这一条专门守住上面提到的「同一微秒」边界：即使 A 的 updatedAt
      // 不比别人新，置顶也必须把它顶到最前（置顶优先于时间）。
      final store = await openStore();
      final a = await store.createConversation(
        title: 'A',
        topic: Topic.finance,
      );
      await store.createConversation(title: 'B', topic: Topic.finance);
      await store.createConversation(title: 'C', topic: Topic.finance);

      await store.toggleConversationPin(a.id);

      expect(store.conversations.first.id, a.id);
      expect(store.conversations.first.isPinned, isTrue);
    });

    test('取消置顶后回到普通区（不会留在置顶区最前）', () async {
      final store = await openStore();
      final a = await store.createConversation(
        title: 'A',
        topic: Topic.finance,
      );
      final b = await store.createConversation(
        title: 'B',
        topic: Topic.finance,
      );

      // 两条都置顶，这样「谁在第一」由置顶状态决定，而不是由时间戳决定。
      await store.toggleConversationPin(a.id);
      await store.toggleConversationPin(b.id);
      expect(store.conversations.take(2).every((c) => c.isPinned), isTrue);

      await store.toggleConversationPin(a.id);

      final reloaded = store.conversations.firstWhere((c) => c.id == a.id);
      expect(reloaded.isPinned, isFalse, reason: '取消置顶必须真的写回 NULL');
      // 这条断言测的是「A 不再占据置顶区」，而不是「A 排在未置顶区最后」。
      //
      // 原写法是 `expect(store.conversations.first.id, isNot(a.id))`，它依赖
      // 「A 的 updatedAt 比 B 旧」这个**产品从未承诺的前提**。实测：A、B 由
      // 连续的 createConversation 创建，两次 DateTime.now() 落在**同一微秒**
      // （本机是常态，不是偶发），于是未置顶区的顺序由 id 兜底比较决定，
      // A 完全可能排在第一 —— 测试就会以一个与产品行为无关的理由失败。
      // 现在 B 仍然是置顶的，所以「第一必须是 B」是确定的。
      expect(store.conversations.first.id, b.id);
      expect(store.conversations.every((c) => !c.isPinned || c.id == b.id), isTrue);
    });

    test('置顶不影响 activeConversation（置顶是整理动作）', () async {
      final store = await openStore();
      final a = await store.createConversation(
        title: 'A',
        topic: Topic.finance,
      );
      await store.createConversation(title: 'B', topic: Topic.finance);
      await store.selectConversation(a.id);

      await store.toggleConversationPin(a.id);

      expect(store.activeConversation!.id, a.id);
    });

    test('发消息不会把置顶的对话挤出置顶区', () async {
      final store = await openStore();
      final a = await store.createConversation(
        title: 'A',
        topic: Topic.finance,
      );
      await store.toggleConversationPin(a.id);
      final b = await store.createConversation(
        title: 'B',
        topic: Topic.finance,
      );

      // B 发一条消息，updatedAt 变成最新；但 A 已置顶，必须仍在最前
      await store.addMessage('user', '在 B 里说话');

      expect(store.conversations.first.id, a.id);
      expect(b.id, isNot(store.conversations.first.id));
    });

    test('isPinned 与 pinnedAt 一致', () async {
      final store = await openStore();
      final a = await store.createConversation(
        title: 'A',
        topic: Topic.finance,
      );
      expect(a.isPinned, isFalse);
      expect(a.pinnedAt, isNull);

      await store.toggleConversationPin(a.id);
      final pinned = store.conversations.firstWhere((c) => c.id == a.id);
      expect(pinned.isPinned, isTrue);
      expect(pinned.pinnedAt, isNotNull);
    });
  });

  group('模型层：置顶字段', () {
    test('toRow / fromRow 往返保留置顶时间', () {
      final at = DateTime(2026, 9, 30, 12, 34, 56);
      final c = Conversation(
        id: 'x',
        title: 't',
        topic: Topic.finance,
        memory: MemoryScope.local,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
        pinnedAt: at,
      );
      final back = Conversation.fromRow(c.toRow());
      expect(back.pinnedAt, at);
      expect(back.isPinned, isTrue);
    });

    test('未置顶时 toRow 写 null，fromRow 读回 null', () {
      final c = Conversation(
        id: 'x',
        title: 't',
        topic: Topic.finance,
        memory: MemoryScope.local,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
      );
      expect(c.toRow()['pinnedAt'], isNull);
      expect(Conversation.fromRow(c.toRow()).pinnedAt, isNull);
    });

    test('copyWith(clearPin: true) 能真的清掉置顶', () {
      // 这是个很容易写错的点：可空参数传 null 等于「不修改」，
      // 所以取消置顶必须靠显式开关，不能靠传 null。
      final c = Conversation(
        id: 'x',
        title: 't',
        topic: Topic.finance,
        memory: MemoryScope.local,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
        pinnedAt: DateTime(2026, 3, 3),
      );
      expect(c.copyWith(clearPin: true).pinnedAt, isNull);
      expect(c.copyWith().pinnedAt, isNotNull, reason: '不传参数不该清掉置顶');
    });
  });

  group('ChatDraft：点创建不落库', () {
    test('【关键】只构造草稿不会产生任何对话', () async {
      final store = await openStore();
      // 清掉 load 时自动建的那个，便于断言“确实没新增”
      for (final c in [...store.conversations]) {
        await store.deleteConversation(c.id);
      }
      final baseline = store.conversations.length;

      // 模拟用户点「创建对话」：只造草稿，不调用 store
      const draft = ChatDraft(
        mode: ChatMode.finance,
        title: '账本分析',
      );
      expect(draft.title, '账本分析');

      expect(
        store.conversations.length,
        baseline,
        reason: '点创建不写库，这正是用户要的行为',
      );
    });

    test('草稿落库用的是草稿自己的模块（不会被上一个对话带偏）', () async {
      final store = await openStore();
      await store.createConversation(title: '健康对话', topic: Topic.health);

      // 草稿属于账本模块，即使当前活跃对话是健康模块
      const draft = ChatDraft(mode: ChatMode.finance, title: '账本分析');
      final created = await store.createConversation(
        title: draft.title,
        topic: draft.mode.topic,
      );

      expect(created.topic, Topic.finance, reason: '模块归属由草稿决定，不由活跃对话决定');
      expect(store.activeConversation!.id, created.id);
    });
  });
}
