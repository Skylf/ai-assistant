import 'dart:convert';
import 'dart:io';

import 'package:family_life_assistant/ai/action.dart';
import 'package:family_life_assistant/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';
import 'support/fake_http.dart';

/// 同名药品的库存叠加。
///
/// 用户实测反馈：「我药箱里以前记录了 2 盒护肝片，两盒维生素，他没有加数量，
/// 而是新增加了两个条目」。同名两条记录会让「家里还有几盒」永远算错，
/// 而用户得自己发现并手动清理 —— 属于「安静地做错事」。
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

  Future<Store> openStore(ActionInputMode mode) async {
    final store = Store(db: FakeDb());
    await store.load();
    await store.saveSettings(
      url: 'https://api.example.com/v1',
      model: 'test-model',
      apiKey: 'sk-test',
    );
    await store.saveActionMode(mode);
    await store.createConversation(title: '药箱', topic: Topic.health);
    return store;
  }

  /// 让假模型返回一段动作计划，执行后返回回复。
  Future<String> askWith(Store store, String question, String modelReply) async {
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

  String medReply(List<Map<String, dynamic>> meds) => '```actions\n'
      '${jsonEncode({'actions': [for (final m in meds) {...m, 'type': 'med_add'}]})}\n'
      '```';

  group('findMedByName', () {
    test('完全同名才匹配，两端空格忽略', () async {
      final store = await openStore(ActionInputMode.localOnly);
      await store.med({'name': '护肝片', 'stock': 2});

      expect(store.findMedByName('护肝片')?['name'], '护肝片');
      expect(store.findMedByName('  护肝片  ')?['name'], '护肝片');
    });

    test('名字不完全相同就不算同一个药（不猜）', () async {
      final store = await openStore(ActionInputMode.localOnly);
      await store.med({'name': '布洛芬缓释胶囊', 'stock': 2});

      // 这是**不同规格的不同产品**，自动合并会让用户丢数据
      expect(store.findMedByName('布洛芬'), isNull);
      expect(store.findMedByName('护肝片(某牌)'), isNull);
      expect(store.findMedByName(''), isNull);
    });
  });

  group('med(addStock:) 的语义', () {
    test('叠加而不是覆盖', () async {
      final store = await openStore(ActionInputMode.localOnly);
      await store.med({'name': '护肝片', 'stock': 2});

      final existing = store.findMedByName('护肝片')!;
      await store.med({'name': '护肝片', 'stock': 3}, existing: existing, addStock: true);

      expect(store.meds.length, 1, reason: '不该多出一条');
      expect(store.meds.single['stock'], 5, reason: '2 + 3 = 5');
      expect(store.meds.single['id'], existing['id'], reason: '还是同一条记录');
    });

    test('库存是字符串也能叠加（模型可能给 "3"）', () async {
      final store = await openStore(ActionInputMode.localOnly);
      await store.med({'name': '维生素', 'stock': 2});

      final existing = store.findMedByName('维生素')!;
      await store.med({'name': '维生素', 'stock': '3'}, existing: existing, addStock: true);

      expect(store.meds.single['stock'], 5);
    });

    test('不带 addStock 时保持覆盖语义（编辑页面用）', () async {
      final store = await openStore(ActionInputMode.localOnly);
      await store.med({'name': '护肝片', 'stock': 2});
      final existing = store.findMedByName('护肝片')!;

      await store.med({'name': '护肝片', 'stock': 7}, existing: existing);

      expect(store.meds.single['stock'], 7);
    });

    test('叠加时新信息会补进已有记录，旧字段不被清空', () async {
      final store = await openStore(ActionInputMode.localOnly);
      await store.med({'name': '护肝片', 'stock': 2, 'spec': '0.5g'});
      final existing = store.findMedByName('护肝片')!;

      await store.med(
        {'name': '护肝片', 'stock': 3, 'expiry': '2027-05-01'},
        existing: existing,
        addStock: true,
      );

      expect(store.meds.single['stock'], 5);
      expect(store.meds.single['spec'], '0.5g', reason: '原有规格不该被抹掉');
      expect(store.meds.single['expiry'], '2027-05-01');
    });
  });

  group('模型路径：用户实测场景', () {
    test('已有 2 盒护肝片，再说「还有 3 盒」→ 合并成 5，不是两条', () async {
      final store = await openStore(ActionInputMode.aiOnly);
      // 先用本地路径建立基线（等价于用户之前手动记的）
      await store.med({'name': '护肝片', 'stock': 2});

      final reply = await askWith(
        store,
        '我还有3盒护肝片',
        medReply([
          {'name': '护肝片', 'stock': 3},
        ]),
      );

      expect(store.meds.length, 1, reason: '绝不能变成两条同名记录');
      expect(store.meds.single['stock'], 5);
      expect(reply, contains('原有 2 盒'));
      expect(reply, contains('新增 3 盒'));
      expect(reply, contains('共 5 盒'), reason: '回复要说明是叠加，而不是只说名字');
      expect(reply, contains('合并'));
    });

    test('一次消息里同名出现两次，也要叠加', () async {
      final store = await openStore(ActionInputMode.aiOnly);
      await askWith(
        store,
        '两盒护肝片，又买了三盒护肝片',
        medReply([
          {'name': '护肝片', 'stock': 2},
          {'name': '护肝片', 'stock': 3},
        ]),
      );

      expect(store.meds.length, 1);
      expect(store.meds.single['stock'], 5);
    });

    test('新药与已有药混在一起：新的新建、旧的叠加', () async {
      final store = await openStore(ActionInputMode.aiOnly);
      await store.med({'name': '维生素', 'stock': 2});

      await askWith(
        store,
        '我有3盒护肝片，两盒维生素',
        medReply([
          {'name': '护肝片', 'stock': 3},
          {'name': '维生素', 'stock': 2},
        ]),
      );

      expect(store.meds.length, 2);
      final byName = {for (final m in store.meds) m['name'] as String: m['stock']};
      expect(byName['护肝片'], 3, reason: '新药按给的库存建');
      expect(byName['维生素'], 4, reason: '已有的叠加 2+2');
    });
  });

  group('本地路径行为与模型路径一致', () {
    test('本地写法同样叠加库存', () async {
      // 两条路径必须一致，否则「随便说」和「按格式说」结果不同，用户无从理解
      final store = await openStore(ActionInputMode.localOnly);
      await store.createConversation(title: '药箱', topic: Topic.health);
      await store.ask('添加药品 护肝片 库存 2');
      expect(store.meds.single['stock'], 2);

      final reply = await store.ask('添加药品 护肝片 库存 3');

      expect(store.meds.length, 1);
      expect(store.meds.single['stock'], 5);
      expect(reply, contains('共 5 盒'));
    });

    test('本地路径多项且含同名项时也叠加', () async {
      final store = await openStore(ActionInputMode.localOnly);
      await store.ask('添加药品 护肝片 库存 2');
      await store.ask('添加药品 护肝片,维生素 库存 3');

      final byName = {for (final m in store.meds) m['name'] as String: m['stock']};
      expect(store.meds.length, 2);
      expect(byName['护肝片'], 5, reason: '2 + 3');
      expect(byName['维生素'], 3);
    });
  });

  group('ActionPlan 不该替我们合并', () {
    test('同名两条都要原样交给执行层（合并是执行层的责任）', () {
      // 如果解析层就把同名合并掉，回复里就说不清「哪一项被合并了」，
      // 也无法体现用户「一次说了两遍」这个事实
      final actions = ActionPlan.parse(
        jsonEncode({
          'actions': [
            {'type': 'med_add', 'name': '护肝片', 'stock': 2},
            {'type': 'med_add', 'name': '护肝片', 'stock': 3},
          ],
        }),
      );
      expect(actions.length, 2);
    });
  });

  group('【回归】账本里绝不能出现药品（用户截图那个 bug）', () {
    // 用户原话：「？我在账本里让添加，给我加了两个护肝片？什么玩意」
    // 对话主题是账本，模型却回了 med_add，App 照做，于是药箱多了一条护肝片，
    // 回复还自相矛盾（「已加入药箱」+「账目已加入账本」）。

    Future<Store> openFinance() async {
      final store = Store(db: FakeDb());
      await store.load();
      await store.saveSettings(
        url: 'https://api.example.com/v1',
        model: 'test-model',
        apiKey: 'sk-test',
      );
      await store.saveActionMode(ActionInputMode.aiOnly);
      await store.createConversation(title: '账本分析', topic: Topic.finance);
      return store;
    }

    test('账本对话里模型给 med_add → 药箱必须一条都不加', () async {
      final store = await openFinance();

      await askWith(
        store,
        '今天买菜50，吃饭250，加到账本里去',
        medReply([
          {'name': '护肝片', 'stock': 2},
        ]),
      );

      expect(store.meds, isEmpty, reason: '账本对话绝不能往药箱写数据');
    });

    test('账本对话里模型给 med_add → 账本也不能凭空多一条', () async {
      final store = await openFinance();

      await askWith(
        store,
        '今天买菜50，吃饭250，加到账本里去',
        medReply([
          {'name': '护肝片', 'stock': 2},
        ]),
      );

      // 丢弃动作后退化成普通回复：账本保持 0 条，而不是把药品当成账目记进去
      expect(store.expenses, isEmpty);
    });

    test('回复里不能出现「已加入药箱」这种跨模块的话', () async {
      final store = await openFinance();

      final reply = await askWith(
        store,
        '今天买菜50，吃饭250，加到账本里去',
        medReply([
          {'name': '护肝片', 'stock': 2},
        ]),
      );

      expect(reply, isNot(contains('药品已加入药箱')));
      expect(reply, isNot(contains('护肝片')), reason: '不能让用户以为药箱被动过');
    });

    test('同一句里给对的动作时正常工作（护栏没误伤）', () async {
      final store = await openFinance();

      final reply = await askWith(
        store,
        '今天买菜50，吃饭250，加到账本里去',
        '```actions\n'
            '${jsonEncode({'actions': [
              {'type': 'expense_add', 'title': '买菜', 'amount': 50},
              {'type': 'expense_add', 'title': '吃饭', 'amount': 250},
            ]})}\n```',
      );

      expect(store.expenses.length, 2);
      expect(store.meds, isEmpty);
      expect(reply, contains('账目已加入账本'));
      expect(reply, contains('共 2 项'));
    });

    test('药箱对话里模型给 expense_add → 账本一条都不加', () async {
      final store = await openStore(ActionInputMode.aiOnly);

      await askWith(
        store,
        '我有两盒护肝片',
        '```actions\n'
            '${jsonEncode({'actions': [
              {'type': 'expense_add', 'title': '买菜', 'amount': 50},
            ]})}\n```',
      );

      expect(store.expenses, isEmpty, reason: '药箱对话绝不能往账本写数据');
      expect(store.meds, isEmpty);
    });
  });
}
