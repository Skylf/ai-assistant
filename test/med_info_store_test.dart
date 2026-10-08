import 'package:family_life_assistant/core/med_classify.dart';
import 'package:family_life_assistant/data/store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 0.4D 需求 2.2 / 2.3 的数据层：分类可手选 + 资料回填。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = 'plugins.it_nomads.com/flutter_secure_storage';

  setUp(() {
    // 安全存储没有桌面测试实现，统一返回空值让 Store 落到默认配置
    // （否则会走真实插件通道，且可能读到别的测试文件留下的 mock）。
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

  group('手选分类会覆盖自动判断', () {
    test('form 为空时走自动判断', () async {
      final store = await openStore();
      await store.med({'name': '布洛芬缓释胶囊', 'stock': 1});
      final med = store.meds.single;
      expect(med['form'] ?? '', '');
      expect(routeOf(med), MedRoute.oral);
    });

    test('form = 外用 时手选生效（即使药名含胶囊）', () async {
      final store = await openStore();
      await store.med({'name': '某某胶囊', 'stock': 1, 'form': '外用'});
      final med = store.meds.single;
      expect(routeOf(med), MedRoute.oral, reason: '不看 form 的话是内服');
      expect(
        routeOf(med, explicit: med['form']?.toString()),
        MedRoute.topical,
        reason: '用户手选的分类必须优先',
      );
    });

    test('form 可以从「外用」改回「自动判断」（写空串而不是删键）', () async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1, 'form': '外用'});
      final med = store.meds.single;
      expect(routeOf(med, explicit: med['form']?.toString()), MedRoute.topical);

      await store.med({'form': ''}, existing: med);
      final updated = store.meds.single;
      expect(updated['form'], '');
      expect(
        routeOf(updated, explicit: updated['form']?.toString()),
        MedRoute.oral,
        reason: '改回自动后必须重新按名称判断',
      );
    });
  });

  group('updateMedInfo：只动资料字段', () {
    test('写入资料字段、来源与查询时间', () async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 2});
      final id = store.meds.single['id'].toString();

      await store.updateMedInfo(
        id,
        fields: {'usage': '口服，一次1粒', 'adverse': '偶见恶心'},
        source: '模型已有知识，自述依据「药品说明书」；未经核实，仅供参考',
        checkedAt: DateTime(2026, 9, 30, 19, 5),
      );

      final med = store.meds.single;
      expect(med['usage'], '口服，一次1粒');
      expect(med['adverse'], '偶见恶心');
      // 0.4E：来源存的是「模型已有知识…未经核实」，**不再有 URL** ——
      // 我们没有联网来源，存一个 URL 出来就是编造。
      expect(med['infoSource'], contains('模型已有知识'));
      expect(med['infoSource'], isNot(contains('http')));
      expect(med['infoCheckedAt'], '2026-09-30 19:05');
    });

    test('【关键】不会碰库存、有效期、名称（补充资料不该改这些）', () async {
      final store = await openStore();
      await store.med({
        'name': '布洛芬缓释胶囊',
        'stock': 7,
        'expiry': '2027-05-01',
        'spec': '0.3g*20粒',
      });
      final id = store.meds.single['id'].toString();

      await store.updateMedInfo(
        id,
        fields: {'usage': '口服，一次1粒'},
        source: 's',
        checkedAt: DateTime(2026, 9, 30),
      );

      final med = store.meds.single;
      expect(med['name'], '布洛芬缓释胶囊');
      expect(med['stock'], 7);
      expect(med['expiry'], '2027-05-01');
      expect(med['spec'], '0.3g*20粒');
    });

    test('【关键】白名单外的键被忽略（防止误传 stock 把库存清掉）', () async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 7});
      final id = store.meds.single['id'].toString();

      await store.updateMedInfo(
        id,
        fields: {
          'usage': '口服',
          // 这三个都**不该**被写进去 —— 白名单只放资料字段
          'stock': '0',
          'name': '被改掉了',
          'expiry': '1999-01-01',
        },
        source: 's',
        checkedAt: DateTime(2026, 9, 30),
      );

      final med = store.meds.single;
      expect(med['usage'], '口服');
      expect(med['stock'], 7, reason: '补充资料绝不能改库存');
      expect(med['name'], '布洛芬');
      expect(med['expiry'], isNot('1999-01-01'));
    });

    test('不存在的 id 安全返回，不抛异常', () async {
      final store = await openStore();
      await expectLater(
        store.updateMedInfo(
          '不存在的id',
          fields: {'usage': 'x'},
          source: 's',
          checkedAt: DateTime(2026, 9, 30),
        ),
        completes,
      );
    });

    test('空 fields 也会写入来源与时间（表示「查过但没查到」）', () async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      final id = store.meds.single['id'].toString();

      await store.updateMedInfo(
        id,
        fields: const {},
        source: '模型已有知识（未经核实，仅供参考）',
        checkedAt: DateTime(2026, 9, 30),
      );

      expect(store.meds.single['infoSource'], contains('模型已有知识'));
    });
  });

  group('旧药品升级后也能手选分类与填资料', () {
    test('v5 的老记录（没有这些列）读出来后各字段为空，不抛异常', () async {
      final store = await openStore();
      // 模拟一条老数据：完全没有 v6 的列
      await store.med({'name': '阿莫西林', 'stock': 1});
      final med = store.meds.single;
      for (final key in ['form', 'usage', 'indications', 'efficacy',
        'adverse', 'contraindications', 'precautions', 'infoSource',
        'infoCheckedAt']) {
        expect(med[key] ?? '', '', reason: '老记录的 $key 应为空');
      }
      // 关键：分类与标签计算不能因为字段为空而炸
      expect(() => tagsOfMed(med), returnsNormally);
      expect(tagsOfMed(med), contains('内服'));
    });
  });
}
