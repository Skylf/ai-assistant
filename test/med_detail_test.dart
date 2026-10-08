import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';

/// 0.4D 需求 2.4：药品详情页的**尺寸适配**与**布局逻辑**。
///
/// 用户原话：「药品具体信息点进去 ui 尺寸适配有问题，且 ui 布局需要逻辑性优化」，
/// 并附了一张真机截图 —— 截图里「库存卡」几乎占满一行，而下面的「信息卡」
/// 缩成窄窄一条，两卡左右边缘对不齐。
///
/// **根因**：详情页里那个 `Column` 没写 `crossAxisAlignment`，
/// 于是用默认的 `center`，子项按**自身固有宽度**居中排布：
/// 库存卡内容宽（图标 56 + 文字 + 按钮），信息卡内容窄（只有文字），
/// 两张卡宽度就不一样了。
///
/// 所以这一组最关键的一条是**量宽度**，而不是数控件个数 ——
/// 「卡片存在」在改版前也是成立的，只有量宽度才能抓住这个 bug。
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

  /// 打开某盒药的详情页。
  Future<void> openDetail(WidgetTester tester, String name) async {
    await tester.tap(find.text('药箱').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle();
  }

  /// 把详情页滚到目标可见。
  ///
  /// 不用 `tester.scrollUntilVisible`：它内部要 `finder.evaluate().single`，
  /// 在「页面上有多个 Scrollable」时会抛 `Bad state: No element`，
  /// 而报错完全看不出是滚动器选错了。这里直接对第一个 ListView 逐段拖动，
  /// 行为可预测，失败时也能一眼看出是「没滚到」而不是「找不到」。
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    for (var i = 0; i < 40; i++) {
      if (target.evaluate().isNotEmpty) {
        await tester.ensureVisible(target.first);
        await tester.pumpAndSettle();
        return;
      }
      await tester.drag(
        find.byType(ListView).first,
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
    }
    // 滚到底还是没找到 —— 让断言去报「找不到这个控件」，
    // 而不是在这里抛一个与业务无关的异常。
  }

  /// 详情页是 360×640 的窄屏（与真机截图接近），最容易暴露尺寸问题。
  Future<void> pumpSmall(WidgetTester tester, Store store) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpApp(tester, store);
  }

  group('【关键】尺寸适配：内容卡必须撑满可用宽度', () {
    testWidgets('详情页里所有 Card 的宽度一致（修的就是这个 bug）', (tester) async {
      final store = await openStore();
      await store.med({
        'name': '布洛芬缓释胶囊',
        'ingredient': '布洛芬',
        'spec': '0.3g*20粒',
        'stock': 2,
        'expiry': '2027-05-01',
      });
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬缓释胶囊');

      // 收集页面上所有 Card 的宽度
      final widths = tester
          .widgetList<Card>(find.byType(Card))
          .toList()
          .asMap()
          .keys
          .map((i) => tester.getSize(find.byType(Card).at(i)).width)
          .toList();

      expect(widths.length, greaterThanOrEqualTo(4), reason: '状态卡 + 至少三个分组卡');
      final first = widths.first;
      for (final w in widths) {
        expect(
          w,
          closeTo(first, 0.5),
          reason:
              '卡片宽度必须一致（=$first），实际出现 $widths —— '
              '宽度不一致正是用户截图里的问题，根因是 Column 默认 center 对齐',
        );
      }
    });

    testWidgets('分组卡宽度 = 屏宽 - 左右各 Gap.page 边距', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1, 'expiry': '2027-05-01'});
      await pumpSmall(tester, store);
      await openDetail(tester, '布洛芬');

      final cardWidth = tester.getSize(find.byType(Card).first).width;
      // Gap.page = 20，所以 360 - 20*2 = 320
      expect(
        cardWidth,
        closeTo(320, 1),
        reason: '卡片应撑满「屏宽 - 左右边距」，而不是缩成自身内容宽度',
      );
    });

    testWidgets('窄屏（360×640）上没有溢出', (tester) async {
      final store = await openStore();
      await store.med({
        'name': '布洛芬缓释胶囊',
        'ingredient': '布洛芬',
        'spec': '0.3g*20粒',
        'stock': 2,
        'expiry': '2027-05-01',
        'storage': '常温、避光、干燥',
        'usage': '口服，一次1粒，一日2次，饭后服用；连续使用不超过3天',
        'indications': '用于缓解轻至中度疼痛，如头痛、关节痛、偏头痛、牙痛、肌肉痛',
        'efficacy': '通过抑制前列腺素的合成而产生镇痛抗炎作用',
        'adverse': '偶见消化不良、胃烧灼感、恶心、呕吐、皮疹',
        'contraindications': '对本品及其他解热镇痛药过敏者禁用；活动性消化道溃疡者禁用',
        'precautions': '孕妇及哺乳期妇女慎用；不宜长期或大量使用；避免与其他解热镇痛药同服',
      });
      await pumpSmall(tester, store);
      await openDetail(tester, '布洛芬缓释胶囊');
      expect(tester.takeException(), isNull, reason: '窄屏上不应出现 RenderFlex 溢出');

      // 滚到底部也要能滚、且不溢出
      await scrollTo(tester, find.text('询问 AI'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('超长文本（无空格的长串）也不溢出', (tester) async {
      final store = await openStore();
      await store.med({
        'name': '布洛芬',
        'stock': 1,
        'precautions': 'A' * 300,
      });
      await pumpSmall(tester, store);
      await openDetail(tester, '布洛芬');
      await scrollTo(tester, find.textContaining('AAAA'));
      expect(tester.takeException(), isNull);
    });
  });

  group('布局逻辑：按看信息的顺序分区', () {
    testWidgets('四个分区标题都在（基本信息 / 用法与药效 / 安全信息 + 状态卡）', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      for (final title in ['基本信息', '用法与药效']) {
        expect(find.text(title), findsOneWidget, reason: '缺少分区「$title」');
      }
      await scrollTo(tester, find.text('安全信息'));
      expect(find.text('安全信息'), findsOneWidget);
    });

    testWidgets('详细信息的六个字段标签都在', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      const labels = [
        '用法用量',
        '治疗范围 / 适应症',
        '药效 / 作用',
        '不良反应',
        '禁忌',
        '注意事项',
      ];
      for (final label in labels) {
        await scrollTo(tester, find.text(label));
        expect(find.text(label), findsOneWidget, reason: '缺少字段「$label」');
      }
    });

    testWidgets('填过的值显示出来，没填的显示「未填写」', (tester) async {
      final store = await openStore();
      await store.med({
        'name': '布洛芬',
        'stock': 1,
        'usage': '口服，一次1粒',
      });
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      expect(find.text('口服，一次1粒'), findsOneWidget);
      // 没填的字段应有「未填写」占位（至少一处）
      expect(find.text('未填写'), findsWidgets);
    });

    testWidgets('整组都没填时给出「该怎么办」的提示，而不是堆一排「未填写」', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      await scrollTo(tester, find.textContaining('还没有用法用量'));
      expect(find.textContaining('还没有用法用量'), findsOneWidget);
    });

    testWidgets('状态卡显示库存、有效期与分类', (tester) async {
      final store = await openStore();
      await store.med({
        'name': '布洛芬缓释胶囊',
        'stock': 3,
        'expiry': '2027-05-01',
      });
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬缓释胶囊');

      expect(find.text('库存 3 盒'), findsOneWidget);
      expect(find.text('有效期'), findsOneWidget);
      expect(find.textContaining('分类（自动判断）'), findsOneWidget);
      // 布洛芬缓释胶囊应自动判为内服
      expect(find.text('内服'), findsWidgets);
    });
  });

  group('资料出处必须露出来', () {
    testWidgets('没查过时说明「暂无」', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      await scrollTo(tester, find.textContaining('资料出处'));
      expect(find.textContaining('资料出处：暂无'), findsOneWidget);
    });

    testWidgets('查过之后显示来源与查询时间', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      final id = store.meds.single['id'].toString();
      await store.updateMedInfo(
        id,
        fields: {'usage': '口服，一次1粒'},
        source: '模型已有知识，自述依据「药品说明书」；未经核实，仅供参考',
        checkedAt: DateTime(2026, 9, 30, 19, 5),
      );
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      await scrollTo(tester, find.textContaining('资料出处'));
      // 来源与查询时间都要露出来，且来源里**不能有 URL**（我们没有联网来源）
      expect(find.textContaining('资料出处：模型已有知识'), findsOneWidget);
      expect(find.textContaining('2026-09-30 19:05'), findsOneWidget);
      expect(find.textContaining('http'), findsNothing);
    });

    testWidgets('来源文案里的「模型已有知识」与「未经核实」都会显示出来', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      final id = store.meds.single['id'].toString();
      await store.updateMedInfo(
        id,
        fields: {'usage': '口服'},
        // 0.4E：文案不再出现「联网」字样，改成如实说明是模型已有知识。
        source: '模型已有知识（未经核实，仅供参考）',
        checkedAt: DateTime(2026, 9, 30),
      );
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      await scrollTo(tester, find.textContaining('资料出处'));
      // 「模型已有知识」在页面上会出现两处：来源行，以及底部那句安全说明
      // （「AI 补充的内容来自模型已有知识，未经核实，可能有误」）。
      // 两处都出现正好说明**来源与免责声明是一致的**，所以用 findsWidgets。
      expect(find.textContaining('模型已有知识'), findsWidgets);
      expect(find.textContaining('未经核实'), findsWidgets);
      // 这条记录是 0.4E 时代「没联网」存下来的（infoUrls 为空）。
      // 0.4F 起页面**允许**出现「联网」字样（按钮就叫「联网查询资料」），
      // 但**来源那一行**仍然不能说联网 —— 这条记录本来就没联网。
      expect(
        find.textContaining('联网检索到'),
        findsNothing,
        reason: '这条记录没有来源 URL，不许显示联网结果',
      );
    });

    testWidgets('有联网来源时按可信度分级列出，且不显示协议前缀', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      final id = store.meds.single['id'].toString();
      await store.updateMedInfo(
        id,
        fields: {'usage': '口服'},
        source: '联网检索到 2 条来源；来源为公开网页，请以药品说明书与药师意见为准',
        checkedAt: DateTime(2026, 9, 30),
        sources: const [
          'https://dxy.com/medicine/7476',
          'https://www.nmpa.gov.cn/datasearch/x.html',
        ],
      );
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      await scrollTo(tester, find.textContaining('资料出处'));
      // 官方来源被排到最前（分级排序生效），且等级标签要显示出来 ——
      // 只平铺 URL 不标等级，用户会默认它们同等可信。
      expect(find.text('官方'), findsOneWidget);
      expect(find.text('其他网站'), findsOneWidget);
      // 去掉 https:// 前缀省地方（完整网址点一下可复制）
      expect(find.textContaining('nmpa.gov.cn/datasearch'), findsOneWidget);
      expect(find.textContaining('https://'), findsNothing);
    });
  });

  group('手动分类入口', () {
    testWidgets('自动判不出来时提示可手动指定', (tester) async {
      final store = await openStore();
      await store.med({'name': '体温计', 'stock': 1});
      await pumpApp(tester, store);
      await openDetail(tester, '体温计');

      await scrollTo(tester, find.textContaining('没能按名称自动分类'));
      expect(find.textContaining('没能按名称自动分类'), findsOneWidget);
      expect(find.text('手动指定'), findsOneWidget);
    });

    testWidgets('已手选分类的不再提示，且状态卡标明「手动指定」', (tester) async {
      final store = await openStore();
      await store.med({'name': '体温计', 'stock': 1, 'form': '外用'});
      await pumpApp(tester, store);
      await openDetail(tester, '体温计');

      expect(find.textContaining('没能按名称自动分类'), findsNothing);
      expect(find.textContaining('分类（手动指定）'), findsOneWidget);
      expect(find.text('外用'), findsWidgets);
    });

    testWidgets('自动判得出来的药不显示手选提示', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      expect(find.textContaining('没能按名称自动分类'), findsNothing);
    });
  });

  group('三个操作入口都在', () {
    testWidgets('联网查询资料 / 去药监局查询 / 询问 AI 都在底部', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      // ⚠️ 这个按钮的名字**改过两次，方向相反**，两次都是为了「名实相符」：
      //  · 0.4D 叫「联网查询资料」，但那时的实现**根本连不上网**
      //    （往 chat/completions 发内置 web_search 工具会被静默忽略）；
      //  · 0.4E 改名「让 AI 补充资料」，同时把来源文案里的「联网」字样清干净；
      //  · 0.4F 换到 Anthropic 兼容 `/messages` + `web_search_20250305`，
      //    **真的联网了**，于是名字改回「联网查询资料」。
      //
      // 教训：按钮名不是文案问题，是**承诺**问题。能力没有时不许叫联网，
      // 能力有了也不该藏着 —— 所以这条断言跟着能力走，而不是跟着文案偏好走。
      await scrollTo(tester, find.text('联网查询资料'));
      expect(find.text('联网查询资料'), findsOneWidget);

      await scrollTo(tester, find.text('去药监局查询（权威来源）'));
      expect(find.text('去药监局查询（权威来源）'), findsOneWidget);

      await scrollTo(tester, find.text('询问 AI'));
      expect(find.text('询问 AI'), findsOneWidget);
    });

    testWidgets('安全声明仍在（不能被新版面挤掉）', (tester) async {
      final store = await openStore();
      await store.med({'name': '布洛芬', 'stock': 1});
      await pumpApp(tester, store);
      await openDetail(tester, '布洛芬');

      await scrollTo(tester, find.textContaining('不替代医生诊断'));
      expect(find.textContaining('不替代医生诊断'), findsOneWidget);
    });
  });
}
