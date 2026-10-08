import 'dart:io';

import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/pages/api_config.dart';
import 'package:family_life_assistant/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_db.dart';
import 'support/fake_http.dart';

/// 「AI 服务」页的回归测试。
///
/// 这里每一条都来自一次对抗性审查中**真实复现出来的红灯**（原始复现文件已删除，
/// 结论固化到本文件）。它们有一个共同点：都是「看起来没问题、用户会踩」的路径，
/// 而不是崩溃。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });

  test('【回归】用户手选的模型名不会被静默改写', () async {
    // 曾经 `Store._loadSettings` 里有一条写死的迁移：
    //   if (model == 'deepseek-flash') model = AiClient.defaultModel;
    // 依据是「DeepSeek 上不存在 deepseek-flash」。
    // 但真机《获取可用模型》拉回来的列表里**就有** `deepseek-flash` 与
    // `deepseek-v4-pro`，所以这条迁移会把用户有效的选择换成该服务商根本没有的
    // 名字，而且每次启动都改写并回写 —— 用户只看到持续 404，查不出原因。
    //
    // 这里盯的是「服务商真实存在的模型名」，正是单元测试最难覆盖、也最该锁住
    // 的一类：它不来自我们的代码，而来自外部世界。
    for (final id in ['deepseek-flash', 'deepseek-v4-pro', 'deepseek-reasoner']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
              if (call.method == 'readAll' || call.method == 'read') {
                final args = call.arguments;
                final key = args is Map ? args['key']?.toString() : null;
                if (key == null || key == 'model') return id;
              }
              return null;
            },
          );

      final store = Store(db: FakeDb());
      await store.load();
      expect(
        store.model,
        id,
        reason: '「$id」是服务商真实返回的模型名，必须原样保留、不得改写',
      );
    }
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  Future<Store> openStore() async {
    final store = Store(db: FakeDb());
    await store.load();
    return store;
  }

  Future<void> pumpPage(WidgetTester tester, Store store) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: AiConfigPage(store: store)),
    );
    await tester.pumpAndSettle();
  }

  /// 模型名输入框里的当前文本。
  ///
  /// 按标签文字定位 TextField 会失败（label 与 TextField 是同级而非嵌套），
  /// 所以按顺序取第 2 个输入框：地址 → 模型 → Key。
  String storeModelFieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text;

  /// 往模型名输入框里打字（先确保它可见，页面需要滚动）。
  Future<void> enterModelText(WidgetTester tester, String text) async {
    final field = find.byType(TextField).at(1);
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  /// 在伪造的网络环境下点击「获取可用模型」。
  Future<FakeHttpClient> tapLoadModels(
    WidgetTester tester, {
    List<String> models = const ['deepseek-chat', 'deepseek-reasoner'],
    int status = 200,
    String? body,
  }) async {
    final fake = FakeHttpClient(
      statusCode: status,
      body: body ?? FakeHttpClient.models(models).body,
    );
    await HttpOverrides.runZoned(() async {
      await tester.tap(find.text('获取可用模型'));
      await tester.pumpAndSettle();
    }, createHttpClient: (_) => fake);
    return fake;
  }

  group('获取可用模型：只读，不写配置', () {
    testWidgets('已保存的 API Key 不会被清空输入框后抹掉', (tester) async {
      final store = await openStore();
      await store.saveSettings(
        url: 'https://api.deepseek.com',
        model: 'deepseek-chat',
        apiKey: 'sk-ORIGINAL-KEY',
      );
      await pumpPage(tester, store);

      // 用户把 Key 输入框清空，然后点「获取可用模型」
      await tester.enterText(
        find.widgetWithText(TextField, 'sk-…'),
        '',
      );
      await tester.pumpAndSettle();
      await tapLoadModels(tester);

      // 关键：拉列表是只读操作，已保存的 Key 必须原样还在
      expect(
        store.key,
        'sk-ORIGINAL-KEY',
        reason: '拉取模型列表不应改写已保存的 API Key',
      );
      expect(store.hasApiKey, isTrue);
    });

    testWidgets('输入框里的半成品 Key 不会被静默落盘', (tester) async {
      final store = await openStore();
      await store.saveSettings(
        url: 'https://api.deepseek.com',
        model: 'deepseek-chat',
        apiKey: 'sk-ORIGINAL-KEY',
      );
      await pumpPage(tester, store);

      await tester.enterText(
        find.widgetWithText(TextField, 'sk-…'),
        'sk-half-typed',
      );
      await tester.pumpAndSettle();
      await tapLoadModels(tester);

      // 没点「保存」就不该写进去
      expect(store.key, 'sk-ORIGINAL-KEY');
    });

    testWidgets('没填 Key 时不发请求，并直接说明原因', (tester) async {
      final store = await openStore();
      await store.saveSettings(
        url: 'https://api.deepseek.com',
        model: 'deepseek-chat',
        apiKey: '',
      );
      await pumpPage(tester, store);
      final fake = await tapLoadModels(tester);

      expect(fake.requests, isEmpty, reason: '没有凭据就不该去打服务商接口');
      // 唯一确定的事实是没填 Key，不能引导用户去怀疑服务商
      expect(find.textContaining('请先填写 API Key'), findsOneWidget);
      expect(find.textContaining('未提供 /models 接口'), findsNothing);
    });
  });

  group('拉取成功', () {
    testWidgets('模型名渲染成可点选的胶囊', (tester) async {
      final store = await openStore();
      // 用一个与占位提示不同的模型名，避免和输入框的 hint 文案撞车
      await store.saveSettings(
        url: 'https://api.deepseek.com',
        model: 'my-model',
        apiKey: 'sk-test',
      );
      await pumpPage(tester, store);
      final fake = await tapLoadModels(tester);

      expect(fake.requests.single.toString(), 'https://api.deepseek.com/models');
      expect(find.byType(ChoiceChip), findsNWidgets(2));
      expect(find.text('deepseek-chat'), findsOneWidget);

      // 点胶囊应把模型名填进输入框
      await tester.tap(find.text('deepseek-reasoner'));
      await tester.pumpAndSettle();
      expect(storeModelFieldText(tester), 'deepseek-reasoner');
    });
  });

  group('状态文案不互相矛盾', () {
    testWidgets('保存成功与拉取失败不会同时挂在屏幕上', (tester) async {
      final store = await openStore();
      await store.saveSettings(
        url: 'https://api.deepseek.com',
        model: 'deepseek-chat',
        apiKey: '',
      );
      await pumpPage(tester, store);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('已保存到系统安全存储'), findsOneWidget);

      // 拉取失败：不能再保留「已保存」的红框，两条结论不能并存
      await tapLoadModels(tester);
      expect(find.text('已保存到系统安全存储'), findsNothing);
      expect(find.textContaining('请先填写 API Key'), findsOneWidget);
    });

    testWidgets('手工填好模型名后，拉取失败的提示会消失', (tester) async {
      final store = await openStore();
      await store.saveSettings(
        url: 'https://api.deepseek.com',
        model: '',
        apiKey: 'sk-test',
      );
      await pumpPage(tester, store);
      await tapLoadModels(tester, status: 500, body: '{}');
      expect(find.textContaining('没能获取到模型列表'), findsOneWidget);

      await enterModelText(tester, 'deepseek-chat');
      expect(
        find.textContaining('没能获取到模型列表'),
        findsNothing,
        reason: '用户已经手工填好了，旧提示不该继续挂着',
      );
    });
  });
}
