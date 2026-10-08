import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:family_life_assistant/data/store.dart';
import 'package:family_life_assistant/main.dart';
import 'package:family_life_assistant/pages/api_config.dart';
import 'package:family_life_assistant/pages/memory.dart';
import 'package:family_life_assistant/pages/password_tool.dart';
import 'package:family_life_assistant/pages/settings.dart';
import 'package:family_life_assistant/pages/widget_settings.dart';
import 'package:family_life_assistant/security/password_engine.dart';
import 'package:family_life_assistant/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_db.dart';

/// 渲染预览工具（只出图，不做断言）。
///
/// 把主要页面按 360×800 的手机尺寸渲染成 PNG 存到
/// `test/tools/preview/`，便于与设计稿逐张比对。使用 `tags: ['preview']`
/// 标记，默认的 `flutter test` 会跳过（否则每次改 UI 都会因为图变了而变红）。
///
/// ```powershell
/// flutter test test/tools/render_pages.dart --tags preview --update-goldens
/// ```
///
/// 顺带的作用：窄屏渲染时任何布局溢出都会让这次运行失败，相当于一次手动的
/// 多尺寸布局检查 —— 抽屉按钮被顶出视口、日期行溢出这类问题就是这样发现的。
/// 出图工具，不做断言。
///
/// ```powershell
/// flutter test test/tools/render_pages.dart --tags preview --update-goldens
/// ```
///
/// 顺带的作用：窄屏渲染时任何布局溢出都会让这次运行失败，相当于一次手动的
/// 多尺寸布局检查 —— 抽屉按钮被顶出视口、日期行溢出这类问题就是这样发现的。
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

  testWidgets('渲染主要页面预览', (tester) async {
    // 360×800（1080/3）是常见的低端机尺寸，最容易暴露布局溢出
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final store = Store(db: FakeDb());
    await store.load();
    final now = DateTime.now();
    await store.expense({
      'title': '买菜',
      'amount': 86.5,
      'category': '餐饮',
      'spentAt': now.toIso8601String(),
    });
    await store.expense({
      'title': '地铁',
      'amount': 12.0,
      'category': '交通',
      'spentAt': now.toIso8601String(),
    });
    // 多给几天数据，否则「汇总」页的柱状图只有一两根柱子，
    // 网格线/渐变/峰值标记这些改动根本看不出来（预览就白出了）。
    const extraDays = [
      (1, '超市', 156.8, '餐饮'),
      (2, '打车', 38.0, '交通'),
      (3, '电影', 88.0, '娱乐'),
      (5, '午饭', 32.5, '餐饮'),
      (6, '水果', 45.0, '餐饮'),
      (9, '电费', 210.0, '居住'),
      (12, '书籍', 68.0, '学习'),
      (15, '咖啡', 28.0, '餐饮'),
      (18, '公交', 6.0, '交通'),
      (22, '聚餐', 320.0, '餐饮'),
    ];
    for (final (daysAgo, title, amount, category) in extraDays) {
      final at = now.subtract(Duration(days: daysAgo));
      await store.expense({
        'title': title,
        'amount': amount,
        'category': category,
        'spentAt': DateTime(
          at.year,
          at.month,
          at.day,
          12,
        ).toIso8601String(),
      });
    }
    await store.expense({
      'title': '工资',
      'amount': 8000.0,
      'category': '收入',
      // ⚠️ 必须是 `entryType`。这里原本写的是 `income: true` ——
      // `Store.expense` 只认 `entryType`，多出来的 `income` 键会被 `...input`
      // 原样存进数据库，于是预览图里工资被当成**支出**（显示成红色的
      // −8000.00，还被算进「支出」合计与分类占比）。
      // 这是 dumpText() 打印真实文案才发现的：golden 图里只有方块，看不出来。
      'entryType': 'income',
      'spentAt': now.toIso8601String(),
    });
    await store.med({
      'name': '布洛芬缓释胶囊',
      'ingredient': '布洛芬',
      'spec': '0.3g*20粒',
      'stock': 2,
      'expiry': '2027-05-01',
      'storage': '常温避光',
      // 0.4D：详情页新增了六个说明书级字段与「资料出处」。
      // 这里填上真实长度的内容，才能看出分区后的版面是否撑得住
      // （全是「未填写」的版面看起来永远是好的）。
      'usage': '口服。一次 1 粒，一日 2 次（早晚各一次）。',
      'indications': '用于缓解轻至中度疼痛，如头痛、关节痛、偏头痛、牙痛、肌肉痛、'
          '神经痛、痛经；也用于普通感冒或流行性感冒引起的发热。',
      'efficacy': '通过抑制前列腺素的合成而产生镇痛、抗炎作用。',
      'adverse': '偶见消化不良、胃烧灼感、胃痛、恶心、呕吐、皮疹；'
          '少见头晕、耳鸣、嗜睡。',
      'contraindications': '对本品及其他解热镇痛药过敏者禁用；'
          '活动性消化道溃疡或出血者禁用；孕妇及哺乳期妇女禁用。',
      'precautions': '不宜长期或大量使用，用于止痛不超过 5 天、解热不超过 3 天；'
          '避免与其他解热镇痛药同服；服药期间不得饮酒。',
      // 0.4F：改成「真的联网查过」的样子，让预览图里能看到
      // 按可信度分级的来源列表（官方 → 机构 → 其他）。
      'infoSource': '联网检索到 4 条来源；来源为公开网页，请以药品说明书与药师意见为准',
      'infoUrls': 'https://www.nmpa.gov.cn/datasearch/home-index.html\n'
          'https://www.dgphospital.com/m_renming_yiyuan/ypsms/202210/90d1ec3e.shtml\n'
          'https://dxy.com/medicine/7476\n'
          'https://ypk.39.net/xiyao/33535.html',
      'infoCheckedAt': '2026-09-30 19:05',
    });
    await store.med({
      'name': '蒙脱石散',
      'spec': '3g*10袋',
      'stock': 1,
      'expiry': '2026-10-01',
    });
    await store.addMessage('user', '本月哪一类花得最多？');

    await tester.pumpWidget(FamilyLifeAssistantApp(store: store));
    await tester.pumpAndSettle();

    Future<void> shoot(String name) => expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/$name.png'),
    );

    /// 出图之后把当前页面上的**真实文案**按屏幕顺序打印出来。
    ///
    /// 为什么需要它：golden 图里所有中文都渲染成方块（测试环境没有中文字体），
    /// 所以图片只能用来判断「有没有溢出、位置对不对」，判断不了
    /// 「文案对不对、有没有漏字段、数字串没串」。打印文本正好补上另一半，
    /// 让预览这一趟同时完成「排版检查」和「内容检查」。
    void dumpText(String name) {
      final items = <({double y, double x, String text})>[];
      for (final element in find.byType(Text).evaluate()) {
        final widget = element.widget as Text;
        final data = widget.data ?? widget.textSpan?.toPlainText() ?? '';
        if (data.trim().isEmpty) continue;
        final box = element.renderObject;
        if (box is! RenderBox || !box.hasSize) continue;
        final offset = box.localToGlobal(Offset.zero);
        items.add((y: offset.dy, x: offset.dx, text: data.trim()));
      }
      // 按屏幕从上到下、从左到右排列，读起来就是页面的实际顺序
      items.sort((a, b) {
        if ((a.y - b.y).abs() > 6) return a.y.compareTo(b.y);
        return a.x.compareTo(b.x);
      });
      debugPrint('--- 页面文案 [$name] ---');
      for (final item in items) {
        debugPrint('  y=${item.y.toStringAsFixed(0).padLeft(4)} ${item.text}');
      }
      // 图标也列出来。中文在 golden 里全是方块，光看文本 dump 会以为
      // 「那一排方块是文字」，实际可能是图标 —— 排查排版时必须能区分。
      final icons = <({double y, double x, String name})>[];
      for (final element in find.byType(Icon).evaluate()) {
        final widget = element.widget as Icon;
        final box = element.renderObject;
        if (box is! RenderBox || !box.hasSize) continue;
        final offset = box.localToGlobal(Offset.zero);
        icons.add((
          y: offset.dy,
          x: offset.dx,
          name: widget.icon?.codePoint.toString() ?? '?',
        ));
      }
      icons.sort((a, b) => a.y.compareTo(b.y));
      if (icons.isEmpty) {
        debugPrint('  （本页无 Icon）');
      } else {
        final grouped = <String, int>{};
        for (final icon in icons) {
          final key = 'y=${icon.y.toStringAsFixed(0)}';
          grouped[key] = (grouped[key] ?? 0) + 1;
        }
        debugPrint('  图标分布：${grouped.entries.map((e) => '${e.key}×${e.value}').join('  ')}');
      }
    }

    Future<void> tab(String label) async {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    /// 点页面顶部的分区标签（账本的 今日/汇总/分类、药箱的 药品/统计）。
    ///
    /// ⚠️ 不能用 `find.byType(SegmentedTabs)`：它是泛型类，
    /// `SegmentedTabs<LedgerLevel>` 与 `SegmentedTabs<MedsLevel>` 是两个不同的
    /// runtimeType，`byType(SegmentedTabs)` **一个都匹配不到**（踩过，
    /// 表现为「Found 0 widgets descending from SegmentedTabs」）。
    /// 所以页面给分区控件挂了固定 Key，这里按 Key 定位。
    Future<void> tapSegment(
      WidgetTester tester,
      String tabsKey,
      String label,
    ) async {
      final finder = find.descendant(
        of: find.byKey(Key(tabsKey)),
        matching: find.text(label),
      );
      expect(finder, findsOneWidget, reason: '分区控件 $tabsKey 里应当有「$label」');
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    /// 打开当前页面的录入抽屉并出图，然后取消返回。
    ///
    /// [trigger] 用来指定打开方式：药箱是悬浮按钮（`fab`），账本 0.4B 之后
    /// **没有**悬浮按钮了，改成点第一级里那个整宽「记一笔」按钮。
    Future<void> openSheetAndShoot(
      String name, {
      String trigger = 'fab',
    }) async {
      if (trigger == 'fab') {
        await tester.tap(find.byType(FloatingActionButton).first);
      } else {
        await tester.tap(find.text(trigger));
      }
      await tester.pumpAndSettle();
      await shoot(name);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
    }

    await shoot('01-home');

    await tab('账本');
    await shoot('02-expenses');
    dumpText('02-expenses');

    // 0.4B：账本拆成三级。三段都要出图 —— 只出第一级的话，
    // 「汇总的图表有没有溢出」「分类的百分比列会不会把金额挤掉」
    // 这两类窄屏问题就只能靠读代码猜。
    await tapSegment(tester, 'ledger-level-tabs', '汇总');
    await shoot('02b-expenses-summary');
    dumpText('02b-expenses-summary');
    await tapSegment(tester, 'ledger-level-tabs', '分类');
    await shoot('02c-expenses-category');
    dumpText('02c-expenses-category');
    await tapSegment(tester, 'ledger-level-tabs', '今日');

    await openSheetAndShoot('03-expense-form', trigger: '记一笔');

    await tab('药箱');
    await shoot('04-meds');
    dumpText('04-meds');

    // 0.4B：药箱拆成两级，统计级单独出图
    await tapSegment(tester, 'meds-level-tabs', '统计');
    await shoot('04b-meds-stats');
    dumpText('04b-meds-stats');
    await tapSegment(tester, 'meds-level-tabs', '药品');

    await openSheetAndShoot('05-med-form');

    // 0.4D：药品详情页版面重做 + 新增资料字段。这张图是**这一版的核心验收对象**，
    // 要能看出：所有卡片左右边缘对齐（宽度一致）、
    // 分区顺序是「状态 → 基本信息 → 用法与药效 → 安全信息 → 资料出处」，
    // 以及底部三个入口（让 AI 补充资料 / 去药监局查询 / 询问 AI）。
    await tester.tap(find.text('布洛芬缓释胶囊').first);
    await tester.pumpAndSettle();
    await shoot('05b-med-detail');
    dumpText('05b-med-detail');
    // 往下滚一屏，看后半部分的「安全信息 / 资料出处 / 操作按钮」
    await tester.drag(find.byType(ListView).first, const Offset(0, -320));
    await tester.pumpAndSettle();
    await shoot('05c-med-detail-safety');
    dumpText('05c-med-detail-safety');
    // ⚠️ 不能用 `tester.pageBack()`：它找的是标准 AppBar 的返回按钮
    // （`CupertinoNavigationBarBackButton`），而详情页用的是自定义的 `DetailHeader`，
    // 于是报「Found 0 widgets with type CupertinoNavigationBarBackButton」。
    // 也不用 `find.byTooltip('返回')` —— DetailHeader 里的 Tooltip 并没有真的
    // 挂成可查找的 widget。这里直接弹栈：预览只关心「页面长什么样」，
    // 返回动作由页面测试覆盖，不必在这里重测一遍。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    // 未填详细信息的药（全部是「未填写」+ 整组空提示），确认那一版版面也不难看
    await tester.tap(find.text('蒙脱石散').first);
    await tester.pumpAndSettle();
    await shoot('05d-med-detail-empty');
    dumpText('05d-med-detail-empty');
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    await tab('AI');
    // 0.4A：AI Tab 先是两个模块的入口页，再进模块介绍页（没有输入框），
    // 点「创建对话」之后才进对话页。
    await shoot('06-ai-hub');

    await tester.tap(find.text('账本分析').first);
    await tester.pumpAndSettle();
    await shoot('07-module-finance');
    dumpText('07-module-finance');

    // 0.4C：侧滑菜单里的「置顶区 / 普通区」必须有明确分界线 —— 这是纯排版要求，
    // 只能出图看。先造出「一条置顶 + 两条普通」，两区都非空才会画分界线。
    // ⚠️ 必须在**退出介绍页之前**做：右上角「历史对话」按钮只在介绍页上。
    //
    // ⚠️ 这里必须**逐条创建 + 每次 pumpAndSettle**，不能在 `Future.wait` 里并发建。
    //
    // 原因（2026-10-08 实测踩到）：`createConversation` 内部会
    // `await db.put` → `_reloadConversations` → `selectConversation`，
    // 并且**每次都会把新对话设为当前对话**。并发建三条时，「哪一条是当前对话」
    // 取决于它们各自的完成顺序 —— 而侧滑菜单会把当前对话画成高亮块。
    // 于是出图时高亮块落在哪一条上是不确定的：
    // 我连跑三次都拿到同一张图（14.20% 与 golden 不符），
    // 而 golden 是在另一次运行里生成的 —— 图的内容本身就不稳定。
    // 串行 + 每次 settle，把「当前对话」钉死在最后建的那条上。
    //
    // 顺带：`toggleConversationPin` 也要在创建之后立刻做，否则
    // 「置顶区」里可能出现还没打上 pin 的条目。
    final pinned = await store.createConversation(
      title: '每月固定开销',
      topic: Topic.finance,
    );
    await tester.pumpAndSettle();
    await store.toggleConversationPin(pinned.id);
    await tester.pumpAndSettle();
    await store.createConversation(title: '春节开销复盘', topic: Topic.finance);
    await tester.pumpAndSettle();
    await store.createConversation(title: '外卖花了多少', topic: Topic.finance);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('历史对话'));
    await tester.pumpAndSettle();
    await shoot('07b-history-pinned');
    dumpText('07b-history-pinned');
    // 关掉抽屉，回到介绍页
    await tester.tapAt(const Offset(320, 400));
    await tester.pumpAndSettle();

    await tester.tap(find.text('创建对话'));
    await tester.pumpAndSettle();
    await shoot('08-chat-finance');

    // 0.4C：对话页长按消息弹出「修改 / 复制 / 删除」菜单。
    // 这一段既是出图，也是**溢出检查** —— 上一轮加「置顶对话」把对话操作
    // 菜单撑破 37 像素，就是这一类菜单在窄屏上的真实风险。
    await tester.enterText(find.byType(TextField).last, '这个月花了多少？');
    await tester.pumpAndSettle();
    // 发送按钮是 IconButton（Icons.send），只有忙态才会包一层 Tooltip（暂停回复），
    // 所以这里按图标找，不能用 byTooltip('发送')。
    await tester.tap(find.byIcon(Icons.send).last);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('这个月花了多少？').last);
    await tester.pumpAndSettle();
    await shoot('08b-chat-message-actions');
    dumpText('08b-chat-message-actions');
    // 关掉菜单（往上点空白处）
    await tester.tapAt(const Offset(180, 40));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('健康科普').first);
    await tester.pumpAndSettle();
    await shoot('09-module-health');

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    await tab('设置');
    await shoot('10-settings');

    // 设置页需要滚动才能看到「实用工具 → 密码生成器」，单独出一张图，
    // 避免「入口到底在不在」只能靠读代码判断。
    await tester.scrollUntilVisible(
      find.text('密码生成器'),
      160,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
    await tester.pumpAndSettle();
    await shoot('11-settings-tools');

    // 0.5.2：桌面组件设置页单独出图。
    //
    // 这一页在窄屏上的风险是实打实的：四种组件各占一张「图标 + 标题 + 两行说明 +
    // 一个按钮」的卡片，是所有页面里纵向内容最多的之一；而且每张卡里的
    // 「添加到桌面」按钮是**必须能点到**的（点不到就等于功能不存在）。
    // 出图能看出按钮有没有被挤掉、卡片有没有溢出。
    //
    // 用固定内容直接构造页面，不经过真实点击 —— 与密码生成器那一段同理：
    // 真实路径要调系统的 requestPinAppWidget，在测试环境里没有实现。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: WidgetSettingsPage(store: store),
      ),
    );
    await tester.pumpAndSettle();
    await shoot('13-widget-settings');
    dumpText('13-widget-settings');

    // 按钮数与「添加到桌面」文案数必须都等于 4（四种组件各一个）。
    // 少一个就说明有卡片被挤出可视区或渲染失败 —— 出图看不出这种「缺一个」。
    debugPrint(
      '组件设置页「添加到桌面」按钮数：'
      '${find.text('添加到桌面').evaluate().length}（应为 4）',
    );

    // 0.5.3：全局记忆页单独出图。新增了「把全部对话改成全局记忆」这一个入口，
    // 它正是「用户升级后老对话还显示仅本对话」那个困惑的解法 ——
    // 出图确认这一行真的渲染出来了（而不是只存在于代码里）。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: GlobalMemoryPage(store: store),
      ),
    );
    await tester.pumpAndSettle();
    await shoot('14-global-memory');
    dumpText('14-global-memory');
    debugPrint(
      '全局记忆页「把全部对话改成全局记忆」入口数：'
      '${find.text('把全部对话改成「全局记忆」').evaluate().length}（应为 1）',
    );

    // 记录实际渲染出来的版本号，串版本时一眼能看出来
    debugPrint('设置页版本号文案：$appVersion 发行版');
    debugPrint(
      '设置页是否渲染出该文案：'
      '${find.text('$appVersion 发行版').evaluate().isNotEmpty}',
    );
    debugPrint(
      '密码生成器入口数量：${find.text('密码生成器').evaluate().length}',
    );

    // 密码生成器单独渲染。
    //
    // 不能直接点进去截图：真实页面用 Random.secure() 生成密码（这是刻意的
    // 安全设计），每次渲染的密码与强度都不一样，预览图就无法复现。这里用固定
    // 种子构造同一个页面，只为了让预览图稳定。
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: PasswordToolPage(
          store: store,
          engine: PasswordEngine(random: Random(20260919)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await shoot('12-password');

    // 「AI 服务」页：模型名不再硬编码，靠「获取可用模型」问服务商要。
    // 这里顺带用 HttpOverrides 伪造一次 /models 响应，验证按钮真的能解析出模型
    // 列表并渲染成胶囊 —— 只渲染空状态的话，「按钮点不动」是看不出来的。
    //
    // 必须先填一个 Key：没配 Key 时客户端会直接拒绝请求（这是刻意的，
    // 避免无凭据去打服务商接口），那样预览就只会看到空状态。
    await store.saveSettings(
      url: 'https://api.deepseek.com',
      model: 'deepseek-chat',
      apiKey: 'sk-preview-only',
    );
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(), home: AiConfigPage(store: store)),
    );
    await tester.pumpAndSettle();
    await shoot('13-ai-config-empty');

    await HttpOverrides.runZoned(() async {
      await tester.tap(find.text('获取可用模型'));
      await tester.pumpAndSettle();
    }, createHttpClient: (_) => _FakeModelsHttpClient());
    await shoot('14-ai-config-models');

    debugPrint(
      '拉取到的模型胶囊数量：${find.byType(ChoiceChip).evaluate().length}',
    );
    debugPrint(
      '模型胶囊文案：'
      '${tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).map((c) => (c.label as Text).data).join(", ")}',
    );
  }, tags: ['preview']);
}

/// 只回答 `GET /models` 的假 HttpClient，用于预览模型列表的渲染结果。
///
/// 说明：这里实现的是 dart:io 的 `HttpClient` 而不是 `package:http` 的 `Client`，
/// 因为 `Store` 内部自己 new 了客户端；所幸 `http` 包对无参 `http.Client()` 走的
/// 就是 dart:io，`HttpOverrides` 能拦住。两个注意点：
/// 1. `IOClient` 调用的是 `openUrl`（不是 `getUrl`）；
/// 2. getter 走 `noSuchMethod` 不够 —— 返回 null 会撞上非空类型，必须逐个实现。
class _FakeModelsHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeModelsRequest();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeModelsRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<HttpClientResponse> close() async => _FakeModelsResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeModelsResponse extends Stream<List<int>>
    implements HttpClientResponse {
  static final _body = utf8.encode(
    jsonEncode({
      'object': 'list',
      'data': [
        {'id': 'deepseek-chat'},
        {'id': 'deepseek-reasoner'},
      ],
    }),
  );

  @override
  int get statusCode => 200;

  @override
  String get reasonPhrase => 'OK';

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  int get contentLength => _body.length;

  @override
  HttpHeaders get headers => _FakeHeaders();

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  List<Cookie> get cookies => const [];

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
