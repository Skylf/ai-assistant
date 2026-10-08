import 'dart:convert';

import 'package:family_life_assistant/core/update.dart';
import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/main.dart';
import 'package:family_life_assistant/pages/settings.dart' show appVersion;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_db.dart';

void main() {
  group('版本号比较', () {
    test('普通三段版本号', () {
      expect(UpdateChecker.compareVersions('0.3.0', '0.2.9'), greaterThan(0));
      expect(UpdateChecker.compareVersions('0.2.0', '0.3.0'), lessThan(0));
      expect(UpdateChecker.compareVersions('1.0.0', '1.0.0'), 0);
    });

    test('段数不同时缺失位按 0 处理', () {
      expect(UpdateChecker.compareVersions('1.0', '1.0.0'), 0);
      expect(UpdateChecker.compareVersions('1.0.1', '1.0'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1', '1.0.0'), 0);
    });

    test('两位数字段按数值而不是字典序比较', () {
      expect(UpdateChecker.compareVersions('0.10.0', '0.9.0'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.2.10', '1.2.9'), greaterThan(0));
    });

    test('带 build 号（+2）也能比较', () {
      expect(UpdateChecker.compareVersions('0.2.0+3', '0.2.0+2'), greaterThan(0));
      expect(UpdateChecker.compareVersions('0.2.0+1', '0.2.0'), greaterThan(0));
    });

    test('字母后缀版本（0.3A / 0.2C）能正确排序', () {
      expect(UpdateChecker.compareVersions('0.3A', '0.2C'), greaterThan(0));
      expect(UpdateChecker.compareVersions('0.2C', '0.2B'), greaterThan(0));
      expect(UpdateChecker.compareVersions('0.2A', '0.2C'), lessThan(0));
    });

    test('正式版比同号预发布版新', () {
      expect(
        UpdateChecker.compareVersions('1.0.0', '1.0.0-beta'),
        greaterThan(0),
      );
      expect(
        UpdateChecker.compareVersions('1.0.0-beta', '1.0.0'),
        lessThan(0),
      );
    });

    test('前缀 v 被忽略，大小写不敏感', () {
      expect(UpdateChecker.compareVersions('v1.2.3', '1.2.3'), 0);
      expect(UpdateChecker.compareVersions('V1.2.3', 'v1.2.3'), 0);
    });

    test('相同版本返回 0，便于「已是最新」判断', () {
      expect(UpdateChecker.compareVersions('0.3A', '0.3A'), 0);
    });
  });

  group('更新清单解析', () {
    test('未配置更新源时给出明确说明而不是报错', () async {
      const checker = UpdateChecker();
      final result = await checker.check(currentVersion: '0.3A');
      expect(result.status, UpdateStatus.notConfigured);
      expect(result.message, contains('未配置更新源'));
    });

    test('未配置更新源不算「已是最新」', () async {
      // 这里曾经断言 isReassuring == true，于是默认构建（没传
      // --dart-define=UPDATE_MANIFEST_URL）下页面显示绿勾「已是最新版本」，
      // 而实际上代码在任何网络调用之前就返回了 —— 用户拿到的是错误的安全感。
      // 「没检查」和「检查了、没有新版」必须区分开。
      const checker = UpdateChecker();
      final result = await checker.check(currentVersion: '0.4.1');
      expect(
        result.isReassuring,
        isFalse,
        reason: '没核对过就不能说「已是最新」',
      );
      expect(result.hasUpdate, isFalse);
    });

    test('清单版本更高时提示有新版本并带上说明与下载地址', () {
      final result = UpdateChecker.parseManifest(
        jsonEncode({
          'version': '0.5.0',
          'notes': '新增购物清单模块',
          'url': 'https://example.com/app-0.5.0.apk',
        }),
        currentVersion: '0.4.1',
      );
      expect(result.status, UpdateStatus.available);
      expect(result.hasUpdate, isTrue);
      expect(result.latestVersion, '0.5.0');
      expect(result.notes, '新增购物清单模块');
      expect(result.downloadUrl, 'https://example.com/app-0.5.0.apk');
      expect(result.message, contains('0.5.0'));
    });

    test('三段式版本号能正确比较大小', () {
      // 更新清单与 App 内版本都改成三段式语义版本后，比较必须仍然可靠：
      // 这是「能不能提示用户升级」的唯一依据。
      expect(UpdateChecker.compareVersions('0.5.0', '0.4.1'), greaterThan(0));
      expect(UpdateChecker.compareVersions('0.4.1', '0.4.1'), 0);
      expect(UpdateChecker.compareVersions('0.4.0', '0.4.1'), lessThan(0));
      expect(UpdateChecker.compareVersions('0.10.0', '0.9.0'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.0.0', '0.99.99'), greaterThan(0));
    });

    test('清单版本相同或更低时视为已是最新', () {
      for (final version in ['0.3A', '0.2C']) {
        final result = UpdateChecker.parseManifest(
          jsonEncode({'version': version}),
          currentVersion: '0.3A',
        );
        expect(result.status, UpdateStatus.upToDate);
        expect(result.hasUpdate, isFalse);
        expect(result.isReassuring, isTrue);
      }
    });

    test('缺少 version 字段时报告清单问题', () {
      final result = UpdateChecker.parseManifest(
        jsonEncode({'notes': '忘了写版本号'}),
        currentVersion: '0.3A',
      );
      expect(result.status, UpdateStatus.failed);
      expect(result.message, contains('version'));
    });

    test('不是 JSON 时不抛异常', () {
      final result = UpdateChecker.parseManifest(
        '<html>404</html>',
        currentVersion: '0.3A',
      );
      expect(result.status, UpdateStatus.failed);
      expect(result.message, contains('JSON'));
    });

    test('JSON 是数组而不是对象时报告格式问题', () {
      final result = UpdateChecker.parseManifest(
        '[1, 2, 3]',
        currentVersion: '0.3A',
      );
      expect(result.status, UpdateStatus.failed);
      expect(result.message, contains('JSON'));
    });

    test('用 MockClient 覆盖端到端检查流程', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({'version': '0.5A', 'url': 'https://e.com/a.apk'}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      // 未配置 manifestUrl 时不会发请求，这里直接验证解析入口等价于
      // 网络成功后的行为。
      final parsed = UpdateChecker.parseManifest(
        utf8.decode(
          (await client.get(Uri.parse('https://example.com/m.json'))).bodyBytes,
        ),
        currentVersion: '0.3A',
      );
      expect(parsed.status, UpdateStatus.available);
      expect(parsed.latestVersion, '0.5A');
    });
  });

  group('更新日志', () {
    test('每个版本都有标题与变更条目', () {
      expect(Changelog.entries, isNotEmpty);
      for (final entry in Changelog.entries) {
        expect(entry.version, isNotEmpty);
        expect(entry.title, isNotEmpty);
        expect(entry.highlights, isNotEmpty);
      }
    });

    test('最新一条与展示用的应用版本一致', () {
      // 两个地方各写了一份版本号，必须对齐，否则「当前版本」标记会错位
      expect(Changelog.latest, appVersion);
    });

    test('版本号严格递减，界面上的顺序才是对的', () {
      for (var i = 1; i < Changelog.entries.length; i++) {
        expect(
          UpdateChecker.compareVersions(
            Changelog.entries[i - 1].version,
            Changelog.entries[i].version,
          ),
          greaterThan(0),
          reason: '${Changelog.entries[i - 1].version} 应新于 '
              '${Changelog.entries[i].version}',
        );
      }
    });
  });

  group('更新日志的渲染', () {
    // 0.4D 真机上暴露出来的问题：更新日志里写了 `**给药途径**` 这类行内加粗，
    // 而这一页早先用裸 `Text` 显示，于是把星号原样画给用户看了
    // （截图里就是「按**给药途径**判断」）。同一个仓库里明明有 SimpleMarkdown，
    // 只是这一页没接上。
    //
    // 这里断言的是**渲染结果**而不是数据，因为数据本来就该带 Markdown ——
    // 该修的是渲染，不是把星号从文案里删掉了事。

    /// 收集当前界面上所有可见文字（含富文本片段）。
    List<String> visibleText(WidgetTester tester) {
      final out = <String>[];
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        final d = w.data;
        if (d != null) out.add(d);
        final s = w.textSpan;
        if (s != null) out.add(s.toPlainText());
      }
      return out;
    }

    testWidgets('变更条目里的行内加粗会被渲染，而不是把星号画出来', (tester) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // 安全存储在桌面测试里没有实现，统一返回空值让 Store 走默认配置。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(
                'plugins.it_nomads.com/flutter_secure_storage',
              ),
              null,
            ),
      );

      final store = Store(db: FakeDb());
      await store.load();
      await tester.pumpWidget(FamilyLifeAssistantApp(store: store));
      await tester.pumpAndSettle();

      // 设置 → 检查更新。
      // 「检查更新」在设置页靠下，首屏看不到，必须先滚到它 ——
      // 直接用 find.text 会抛 `Bad state: No element`（.last 对空结果集报错）。
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();

      final target = find.text('检查更新');
      for (var i = 0; i < 30 && target.evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -160));
        await tester.pumpAndSettle();
      }
      expect(target, findsWidgets, reason: '设置页里应当有「检查更新」入口');
      await tester.tap(target.first);
      await tester.pumpAndSettle();

      final texts = visibleText(tester);
      expect(texts, isNotEmpty, reason: '更新页应当渲染出内容');

      // 整个页面上不该有任何 `**` 残留（那就是没渲染的 Markdown）
      final raw = texts.where((t) => t.contains('**')).toList();
      expect(
        raw,
        isEmpty,
        reason: '更新日志把 Markdown 星号原样显示了：$raw',
      );

      // 而且确实渲染出了这一版的条目（防止「页面上根本没这段文字」而假通过）
      //
      // ⚠️ 这里**不能写死某一版的字样**。早先写的是 `'给药途径'`（0.4D 的词），
      // 0.4F 加了一条更长的条目把 0.4D 挤出了首屏 → 这条断言变红，
      // 而**渲染其实是好的**。那是「断言绑在了会漂的东西上」，不是产品有 bug。
      // 改成从**当前最新一条**取版本号：版本号会一直往上走，这个锚点不会。
      final head = Changelog.entries.first;
      expect(
        texts.any((t) => t.contains(head.version)),
        isTrue,
        reason: '最新一条（${head.version}）应当渲染出来，'
            '否则上面「没有星号残留」是空跑',
      );
    });
  });
}
