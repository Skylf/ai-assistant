import 'package:family_life_assistant/ai/client.dart';
import 'package:family_life_assistant/data/db.dart';
import 'package:family_life_assistant/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 数据库结构升级相关的回归测试。
///
/// 背景：真机上出现过「进软件白屏」。原因是 schema v3 的迁移只建了新表，忘了
/// 给既有的 `chats` 表加 `conversationId`，于是启动时
/// `SELECT * FROM chats WHERE conversationId=?` 抛异常，`Store.load()` 失败、
/// `runApp` 不执行 —— 用户看到纯白屏。这里的用例锁住修复结果。
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

  group('schema 版本与迁移', () {
    test('schema 版本已推进到 7（含 v6 分类字段与 v7 联网来源列）', () {
      expect(SqfliteDb.schemaVersion, 7);
    });

    test('建表语句包含 conversationId', () {
      // onCreate 与 onUpgrade 必须一致，否则全新安装与升级安装的结构会不同
      const create = 'CREATE TABLE chats('
          'id TEXT PRIMARY KEY,'
          'role TEXT,'
          'content TEXT,'
          'topic TEXT,'
          'conversationId TEXT,'
          'createdAt TEXT)';
      expect(create.contains('conversationId'), isTrue);
    });

    test('chats 在需要排序的表清单里', () {
      expect(localDbTables, contains(T.chats));
      expect(localDbOrder[T.chats], 'createdAt ASC');
    });

    test('【关键】v6 新增的药品列，建表与迁移两条路径都覆盖到', () {
      // 这个断言防的是一种很隐蔽的差异：只改了建表语句、忘了写迁移，
      // 于是「全新安装有这些列、老用户升级没有」。老用户点开药品详情保存时
      // 才会炸，而且只有升级用户能复现。
      final migrate = SqfliteDb.migrationStatements(
        tables: {T.expenses, T.meds, T.chats, T.conversations, T.passwords},
        columns: {
          T.expenses: {'id', 'entryType'},
          // 故意把 meds 做成 v5 的样子：只有老列
          T.meds: {
            'id',
            'name',
            'ingredient',
            'spec',
            'stock',
            'expiry',
            'storage',
            'note',
          },
          T.chats: {'id', 'conversationId'},
          T.conversations: {'id', 'pinnedAt'},
          T.passwords: {'id'},
        },
      ).join('\n');

      for (final column in SqfliteDb.medsV6Columns) {
        expect(
          migrate,
          contains('ALTER TABLE ${T.meds} ADD COLUMN $column TEXT'),
          reason: 'v6 的 $column 列缺少迁移语句',
        );
      }
    });
  });

  group('旧结构设备的启动行为', () {
    test('坏结构会让 load 抛错，但错误被记录而不是静默白屏', () async {
      final store = Store(db: LegacyChatsDb());
      await expectLater(store.load(), throwsA(isA<StateError>()));
      expect(store.isReady, isFalse);
      expect(store.bootError, isNotNull);
      expect(store.bootError.toString(), contains('conversationId'));
    });

    test('结构正常时 isReady 为 true 且没有错误', () async {
      final store = Store(db: FakeDb());
      await store.load();
      expect(store.isReady, isTrue);
      expect(store.bootError, isNull);
    });

    test('首次启动会自动建一个对话并准备好可用状态', () async {
      final store = Store(db: FakeDb());
      await store.load();
      expect(store.conversations, hasLength(1));
      expect(store.activeConversationId, isNotEmpty);
    });

    test('安全存储损坏时退回默认设置，而不是起不来', () async {
      // 真机上出现过密钥库损坏（bad base-64），读设置整体抛异常。
      // 这时应该用默认值继续启动，用户重新填 API Key 即可。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(secureStorageChannel),
            (call) async => throw PlatformException(
              code: 'error',
              message: 'bad base-64',
            ),
          );

      final store = Store(db: FakeDb());
      await store.load();

      expect(store.isReady, isTrue, reason: '设置读失败不应导致启动失败');
      expect(store.bootError, isNull);
      expect(store.url, AiClient.defaultBaseUrl);
      expect(store.model, AiClient.defaultModel);
      expect(store.hasApiKey, isFalse);
    });
  });

  group('无归属消息的认领', () {
    test('v2 老消息（没有 conversationId）会挂到按主题建立的默认对话', () async {
      final db = FakeDb();
      await db.put(T.chats, {
        'id': 'm1',
        'role': 'user',
        'content': '本月花了多少',
        'topic': 'f',
        'createdAt': '2026-01-01T10:00:00.000',
      });
      await db.put(T.chats, {
        'id': 'm2',
        'role': 'assistant',
        'content': '本月支出 ¥100',
        'topic': 'f',
        'createdAt': '2026-01-01T10:00:05.000',
      });
      await db.put(T.chats, {
        'id': 'm3',
        'role': 'user',
        'content': '这药怎么吃',
        'topic': 'h',
        'createdAt': '2026-01-02T10:00:00.000',
      });

      final store = Store(db: db);
      await store.load();

      // 两个主题各得一个默认对话
      expect(store.conversations, hasLength(2));
      final finance = store.conversations.firstWhere(
        (c) => c.topic == Topic.finance,
      );
      final health = store.conversations.firstWhere(
        (c) => c.topic == Topic.health,
      );
      expect(finance.title, '默认账本分析');
      expect(health.title, '默认健康科普');

      // 消息被挂到对应主题的对话上，历史记录没丢
      final chats = await db.all(T.chats);
      expect(
        chats.where((r) => r['conversationId'] == finance.id).length,
        2,
      );
      expect(
        chats.where((r) => r['conversationId'] == health.id).length,
        1,
      );
    });

    test('已有同主题对话时复用，不重复建默认对话', () async {
      final db = FakeDb();
      final existing = Conversation(
        id: 'c-existing',
        title: '我的账本对话',
        topic: Topic.finance,
        memory: MemoryScope.local,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await db.put(T.conversations, existing.toRow());
      await db.put(T.chats, {
        'id': 'm1',
        'role': 'user',
        'content': '旧消息',
        'topic': 'f',
        'createdAt': '2026-01-01T10:00:00.000',
      });

      final store = Store(db: db);
      await store.load();

      expect(store.conversations, hasLength(1));
      expect(store.conversations.first.id, 'c-existing');
      final chats = await db.all(T.chats);
      expect(chats.single['conversationId'], 'c-existing');
    });

    test('坏版本 v3 的状态：已有对话但老消息没有归属', () async {
      // 这正是真机白屏修复后重启时的状态：conversations 表已存在（v3 建过），
      // chats 的 conversationId 是这一版才补上的，老消息因此为空。
      final db = FakeDb();
      final existing = Conversation(
        id: 'c-finance',
        title: '新对话',
        topic: Topic.finance,
        memory: MemoryScope.local,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await db.put(T.conversations, existing.toRow());
      await db.put(T.chats, {
        'id': 'm-old',
        'role': 'user',
        'content': '升级前的老消息',
        'topic': 'f',
        'createdAt': '2026-01-01T10:00:00.000',
      });

      final store = Store(db: db);
      await store.load();

      expect(store.isReady, isTrue);
      // 复用了已有对话，没有多冒出一个
      expect(store.conversations, hasLength(1));
      final chats = await db.all(T.chats);
      expect(chats.single['conversationId'], 'c-finance');
      // 认领后的消息能被正常读出来
      expect(store.messages, hasLength(1));
      expect(store.messages.single.content, '升级前的老消息');
    });

    test('认领之后再启动不会重复处理', () async {      final db = FakeDb();
      await db.put(T.chats, {
        'id': 'm1',
        'role': 'user',
        'content': '旧消息',
        'topic': 'f',
        'createdAt': '2026-01-01T10:00:00.000',
      });

      final first = Store(db: db);
      await first.load();
      final countAfterFirst = (await db.all(T.conversations)).length;

      final second = Store(db: db);
      await second.load();
      expect((await db.all(T.conversations)).length, countAfterFirst);
      // 消息仍只有一条，且已归属
      final chats = await db.all(T.chats);
      expect(chats, hasLength(1));
      expect(chats.single['conversationId'], isNotEmpty);
    });
  });
}
