import 'dart:io';

import 'package:family_life_assistant/core/chat_mode.dart';
import 'package:family_life_assistant/data/widget_bridge.dart';
import 'package:family_life_assistant/data/widget_launch.dart';
import 'package:family_life_assistant/theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// 0.5.2 桌面组件的桥接层测试。
///
/// ## 这一层为什么最需要测试
///
/// 桌面组件的数据流是「原生写文件 → Dart 读文件 → 进数据库」，
/// **两端在两个进程里、两套语言写的**。这类边界最常见的两种失效都是静默的：
///
///  ① **常量对不上**：原生把文件写成 `widget_pending.jsonl`、Dart 读
///     `widget-pending.jsonl` —— 组件记完了，App 永远读不到，两边都不报错；
///  ② **字段名漂移**：原生写 `amount`、Dart 读 `money` —— 记录进去了，
///     但金额是空的。用户看到账本里多了一条 0 元的账。
///
/// 这两类问题**都不会抛异常**，只能靠断言两端一致来防。所以下面不只测
/// Dart 自己的解析逻辑，还**去读原生源码**做交叉断言。
void main() {
  /// 在原生源码里搜一段文本；找不到就返回 null。
  ///
  /// 四个原生文件都要搜：常量散在 `WidgetBridge.kt`（文件名）、
  /// `WidgetProviders.kt`（组件类型 id）、`MainActivity.kt`（通道名）、
  /// `QuickEntryActivity.kt`（分类清单）里。
  String? ktSource(String needle) {
    for (final path in [
      'android/app/src/main/kotlin/com/familyassistant/family_life_assistant/widget/WidgetBridge.kt',
      'android/app/src/main/kotlin/com/familyassistant/family_life_assistant/widget/WidgetProviders.kt',
      'android/app/src/main/kotlin/com/familyassistant/family_life_assistant/MainActivity.kt',
      'android/app/src/main/kotlin/com/familyassistant/family_life_assistant/widget/QuickEntryActivity.kt',
    ]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final content = file.readAsStringSync();
      if (content.contains(needle)) return content;
    }
    return null;
  }

  group('【关键】跨端常量必须一致（不一致是静默失效）', () {
    test('队列文件名：Dart 与 Kotlin 逐字相同', () {
      final source = ktSource('QUEUE_FILE');
      expect(
        source,
        isNotNull,
        reason: '找不到原生 WidgetBridge.kt —— 跨端断言不能静默跳过',
      );
      expect(
        source,
        contains('QUEUE_FILE = "${WidgetBridge.queueFileName}"'),
        reason:
            '原生写的文件名与 Dart 读的不一致时，用户在桌面记的东西'
            '永远进不了 App，而两边都不报错。'
            'Dart 侧是「${WidgetBridge.queueFileName}」',
      );
    });

    test('汇总文件名：Dart 与 Kotlin 逐字相同', () {
      final source = ktSource('SUMMARY_FILE');
      expect(source, isNotNull);
      expect(
        source,
        contains('SUMMARY_FILE = "${WidgetBridge.summaryFileName}"'),
      );
    });

    test('【关键】MethodChannel 名：Dart 与 Kotlin 逐字相同', () {
      final source = ktSource('widget_launch');
      expect(source, isNotNull, reason: '找不到原生通道注册代码');
      expect(
        source,
        contains('"${WidgetLaunch.channelName}"'),
        reason:
            '通道名不一致的表现是「点 AI 组件会打开 App、但不弹输入框」'
            '——用户以为组件坏了，其实是名字对不上',
      );
    });

    test('四种组件类型 id：Dart 与 Kotlin 逐字相同', () {
      final source = ktSource('EXPENSE_AI');
      expect(source, isNotNull);
      for (final id in [
        WidgetLaunch.kindExpense,
        WidgetLaunch.kindExpenseAi,
        WidgetLaunch.kindMed,
        WidgetLaunch.kindMedAi,
      ]) {
        expect(
          source,
          contains('id = "$id"'),
          reason: '原生 WidgetKind 里缺少 id="$id"',
        );
      }
    });

    test('【关键】原生浮层的分类清单与 App 的 Categories.all 完全相同', () {
      // 原生浮层必须在 App 引擎启动前就能画出来（这正是它快的原因），
      // 所以分类清单只能**在 Kotlin 里抄一份**。抄的东西必须被盯着：
      // 两边一旦漂移，表现是「App 里加了分类，桌面上选不到」——
      // 用户只会觉得桌面上少了个选项，不会想到是清单不同步。
      final source = ktSource('val CATEGORIES');
      expect(
        source,
        isNotNull,
        reason: '找不到原生 QuickEntryActivity 里的 CATEGORIES 常量',
      );
      // 只取 CATEGORIES 这一个 listOf(...) 的内容，避免匹配到 UNITS
      final match = RegExp(
        r'val CATEGORIES = listOf\(([^)]*)\)',
        dotAll: true,
      ).firstMatch(source!);
      expect(match, isNotNull, reason: 'CATEGORIES 的写法变了，测试需要更新');

      final nativeCategories = RegExp(r'"([^"]+)"')
          .allMatches(match!.group(1)!)
          .map((m) => m.group(1)!)
          .toList();

      expect(
        nativeCategories,
        Categories.all,
        reason:
            '原生浮层的分类清单与 App 的 Categories.all 不一致。'
            'App 侧是 ${Categories.all}，原生侧是 $nativeCategories',
      );
    });
  });

  group('解析待入库队列', () {
    test('正常的一行能解析出来', () {
      final parsed = WidgetBridge.parseQueue(
        '{"id":"a1","kind":"expense","amount":20,"category":"餐饮"}',
      );
      expect(parsed, hasLength(1));
      expect(parsed.first['amount'], 20);
    });

    test('多行按行解析', () {
      final parsed = WidgetBridge.parseQueue(
        '{"id":"a","kind":"expense","amount":1}\n'
        '{"id":"b","kind":"med","name":"布洛芬"}\n',
      );
      expect(parsed.map((e) => e['id']), ['a', 'b']);
    });

    test('【关键】半截写入的最后一行被跳过，前面的照样能用', () {
      // 这是选 JSON Lines 的**全部理由**：原生是「追加一行」写入的，
      // 写到一半被系统杀掉，最坏只损坏最后一行。
      // 若改成整份 JSON 数组，一个字节坏掉就是用户所有记录全丢。
      final parsed = WidgetBridge.parseQueue(
        '{"id":"a","kind":"expense","amount":1}\n'
        '{"id":"b","kind":"expen',
      );
      expect(parsed, hasLength(1));
      expect(parsed.first['id'], 'a');
    });

    test('空内容与空行不产生记录', () {
      expect(WidgetBridge.parseQueue(''), isEmpty);
      expect(WidgetBridge.parseQueue('\n\n  \n'), isEmpty);
    });

    test('缺 id 的行被丢弃（没有 id 就无法保证幂等）', () {
      expect(WidgetBridge.parseQueue('{"kind":"expense","amount":1}'), isEmpty);
      expect(WidgetBridge.parseQueue('{"id":"  ","kind":"expense"}'), isEmpty);
    });

    test('kind 不认识的行被丢弃', () {
      expect(
        WidgetBridge.parseQueue('{"id":"a","kind":"password","x":1}'),
        isEmpty,
      );
      expect(WidgetBridge.parseQueue('{"id":"a"}'), isEmpty);
    });

    test('JSON 是数组而不是对象时丢弃，不崩', () {
      expect(WidgetBridge.parseQueue('[1,2,3]'), isEmpty);
      expect(WidgetBridge.parseQueue('"just a string"'), isEmpty);
      expect(WidgetBridge.parseQueue('null'), isEmpty);
    });
  });

  group('编码回队列', () {
    test('保留原始 Map，不重新组装字段', () {
      // 万一原生侧加了新键、而 App 还没升级，重新组装会把它悄悄抹掉。
      final kept = [
        {'id': 'a', 'kind': 'expense', 'amount': 1, 'futureField': 'x'},
      ];
      final encoded = WidgetBridge.encodeQueue(kept);
      expect(encoded, contains('futureField'));
      // 编回来还能解析出同样内容
      final again = WidgetBridge.parseQueue(encoded);
      expect(again.first['futureField'], 'x');
    });

    test('空列表编成空串（不是 "[]"）', () {
      // 写成 "[]" 的话下次 parseQueue 会把它当一行非对象 JSON 丢掉，
      // 虽然不致命，但会让文件里留一条无意义的垃圾行。
      expect(WidgetBridge.encodeQueue(const []), '');
    });

    test('每条一行、以换行结尾', () {
      final encoded = WidgetBridge.encodeQueue([
        {'id': 'a', 'kind': 'expense'},
        {'id': 'b', 'kind': 'med'},
      ]);
      expect(encoded.endsWith('\n'), isTrue);
      expect(encoded.split('\n').where((l) => l.isNotEmpty), hasLength(2));
    });
  });

  group('规整成可入库的字段表', () {
    Map<String, dynamic>? normalize(Map<String, dynamic> raw) =>
        WidgetBridge.normalize(raw);

    test('记账：字段原样映射，不需要翻译表', () {
      final out = normalize({
        'id': 'a1',
        'kind': 'expense',
        'title': '午餐',
        'amount': 25.5,
        'category': '餐饮',
        'note': '公司楼下',
        'entryType': 'expense',
        'spentAt': '2026-10-08T12:30:00.000',
      });
      expect(out, isNotNull);
      expect(out!['id'], 'a1');
      expect(out['title'], '午餐');
      expect(out['amount'], 25.5);
      expect(out['category'], '餐饮');
      expect(out['note'], '公司楼下');
      expect(out['entryType'], 'expense');
      expect(out['spentAt'], startsWith('2026-10-08T12:30:00'));
    });

    test('【关键】金额非法时返回 null（调用方丢弃这一条）', () {
      for (final bad in ['abc', '', null, true, [], {}]) {
        expect(
          normalize({'id': 'a', 'kind': 'expense', 'amount': bad}),
          isNull,
          reason: '金额是 $bad 时不该产出一条金额诡异的账目',
        );
      }
    });

    test('金额是字符串数字时也能接受', () {
      // 原生 JSONObject 在某些路径上会把数字写成字符串
      expect(WidgetBridge.toAmount('12.5'), 12.5);
      expect(WidgetBridge.toAmount('12'), 12.0);
    });

    test('金额 NaN / 无穷 / 负数被拒', () {
      expect(WidgetBridge.toAmount(double.nan), isNull);
      expect(WidgetBridge.toAmount(double.infinity), isNull);
      expect(WidgetBridge.toAmount(-1), isNull);
      expect(WidgetBridge.toAmount(-0.01), isNull);
    });

    test('金额 0 放行（原生侧已拦，这里不重复拦）', () {
      // 两处都拦会带来「规则不一致」的隐患：改了一处忘了另一处就会出现
      // 「原生让过、Dart 丢掉」这种查不出来的差异。
      expect(WidgetBridge.toAmount(0), 0.0);
    });

    test('日期解析失败回落到现在，而不是丢掉整条记录', () {
      final out = normalize({
        'id': 'a',
        'kind': 'expense',
        'amount': 5,
        'spentAt': '不是日期',
      });
      expect(out, isNotNull, reason: '宁可时间不准，也不该丢掉这笔账');
      final parsed = DateTime.tryParse(out!['spentAt'].toString());
      expect(parsed, isNotNull);
      expect(
        DateTime.now().difference(parsed!).inMinutes.abs(),
        lessThan(5),
        reason: '应当回落到「现在」附近',
      );
    });

    test('entryType 只认 income，其余一律按 expense', () {
      for (final value in ['', 'expense', '乱写', null]) {
        final out = normalize({
          'id': 'a',
          'kind': 'expense',
          'amount': 1,
          'entryType': value,
        });
        expect(out!['entryType'], 'expense', reason: 'entryType=$value');
      }
      final income = normalize({
        'id': 'a',
        'kind': 'expense',
        'amount': 1,
        'entryType': 'income',
      });
      expect(income!['entryType'], 'income');
    });

    test('记药：名称为空时返回 null', () {
      expect(normalize({'id': 'a', 'kind': 'med', 'name': '  '}), isNull);
      expect(normalize({'id': 'a', 'kind': 'med'}), isNull);
    });

    test('记药：数量缺失或非法时按 1，与 App 表单默认值一致', () {
      for (final bad in [null, '', 'abc', -5]) {
        final out = normalize({'id': 'a', 'kind': 'med', 'name': '药', 'stock': bad});
        expect(out, isNotNull);
        expect(out!['stock'], 1, reason: 'stock=$bad 时应回落到 1');
      }
    });

    test('记药：数量为 0 是合法的（确实没货了）', () {
      final out = normalize({'id': 'a', 'kind': 'med', 'name': '药', 'stock': 0});
      expect(out!['stock'], 0);
    });

    test('缺 id 一律返回 null', () {
      expect(normalize({'kind': 'expense', 'amount': 1}), isNull);
    });

    test('未知 kind 返回 null', () {
      expect(normalize({'id': 'a', 'kind': 'mystery'}), isNull);
    });

    test('字符串字段两端空格被去掉', () {
      final out = normalize({
        'id': 'a',
        'kind': 'med',
        'name': '  布洛芬  ',
        'spec': '  0.3g  ',
      });
      expect(out!['name'], '布洛芬');
      expect(out['spec'], '0.3g');
    });
  });

  group('桌面组件汇总', () {
    Map<String, dynamic> build(
      List<Map<String, dynamic>> expenses,
      List<Map<String, dynamic>> meds,
    ) => WidgetBridge.buildSummary(
      expenses: expenses,
      meds: meds,
      now: DateTime(2026, 10, 8, 15, 0),
    );

    test('只统计今天的支出，不把收入算进去', () {
      final summary = build([
        {'amount': 20, 'entryType': 'expense', 'spentAt': '2026-10-08T08:00:00'},
        {'amount': 30, 'entryType': 'expense', 'spentAt': '2026-10-08T19:00:00'},
        {'amount': 5000, 'entryType': 'income', 'spentAt': '2026-10-08T09:00:00'},
      ], const []);
      expect(summary[WidgetBridge.keyTodayExpense], '50');
      expect(summary[WidgetBridge.keyTodayCount], 2);
    });

    test('昨天的账不计入今天', () {
      final summary = build([
        {'amount': 99, 'entryType': 'expense', 'spentAt': '2026-10-07T23:59:00'},
      ], const []);
      expect(summary[WidgetBridge.keyTodayExpense], '0');
      expect(summary[WidgetBridge.keyTodayCount], 0);
    });

    test('金额是整数时不显示小数点', () {
      final summary = build([
        {'amount': 50.0, 'entryType': 'expense', 'spentAt': '2026-10-08T08:00:00'},
      ], const []);
      expect(summary[WidgetBridge.keyTodayExpense], '50');
    });

    test('金额有小数时保留两位', () {
      final summary = build([
        {'amount': 12.5, 'entryType': 'expense', 'spentAt': '2026-10-08T08:00:00'},
      ], const []);
      expect(summary[WidgetBridge.keyTodayExpense], '12.50');
    });

    test('日期无法解析的账目被跳过，不崩', () {
      final summary = build([
        {'amount': 20, 'entryType': 'expense', 'spentAt': '坏日期'},
      ], const []);
      expect(summary[WidgetBridge.keyTodayExpense], '0');
    });

    test('药箱总数与需关注数', () {
      final summary = build(const [], [
        {'name': 'A', 'stock': 5, 'expiry': '2030-01-01'},
        {'name': 'B', 'stock': 0, 'expiry': '2030-01-01'}, // 没库存
        {'name': 'C', 'stock': 3, 'expiry': '2026-10-20'}, // 30 天内到期
      ]);
      expect(summary[WidgetBridge.keyMedTotal], 3);
      expect(summary[WidgetBridge.keyMedAttention], 2);
    });

    test('没有到期日的药品不算需关注', () {
      final summary = build(const [], [
        {'name': 'A', 'stock': 5},
        {'name': 'B', 'stock': 5, 'expiry': ''},
      ]);
      expect(summary[WidgetBridge.keyMedAttention], 0);
    });
  });

  group('桌面组件启动请求', () {
    test('解析原生返回的 map', () {
      final request = WidgetLaunch.parseLaunch({'kind': 'med_ai', 'ai': true});
      expect(request, isNotNull);
      expect(request!.kind, WidgetLaunch.kindMedAi);
      expect(request.isAi, isTrue);
      expect(request.isExpense, isFalse);
    });

    test('记账类被识别为账本', () {
      expect(
        WidgetLaunch.parseLaunch({'kind': 'expense_ai', 'ai': true})!.isExpense,
        isTrue,
      );
      expect(
        WidgetLaunch.parseLaunch({'kind': 'med', 'ai': false})!.isExpense,
        isFalse,
      );
    });

    test('缺 ai 字段时按 kind 后缀推断', () {
      // 只用其中一个字段就能得出答案时，不该依赖另一个也正确
      expect(
        WidgetLaunch.parseLaunch({'kind': 'med_ai'})!.isAi,
        isTrue,
      );
      expect(
        WidgetLaunch.parseLaunch({'kind': 'expense'})!.isAi,
        isFalse,
      );
    });

    test('null / 空 / 陌生 kind 都返回 null', () {
      expect(WidgetLaunch.parseLaunch(null), isNull);
      expect(WidgetLaunch.parseLaunch({'kind': ''}), isNull);
      expect(WidgetLaunch.parseLaunch({'kind': '   '}), isNull);
      expect(WidgetLaunch.parseLaunch({'kind': 'evil_widget'}), isNull);
      expect(WidgetLaunch.parseLaunch('not a map'), isNull);
    });

    test('契约：组件类型只有四种', () {
      expect(WidgetLaunch.isKnownKind('expense'), isTrue);
      expect(WidgetLaunch.isKnownKind('expense_ai'), isTrue);
      expect(WidgetLaunch.isKnownKind('med'), isTrue);
      expect(WidgetLaunch.isKnownKind('med_ai'), isTrue);
      expect(WidgetLaunch.isKnownKind('expense_ai_2'), isFalse);
    });
  });

  group('组件类型 → 模块归属', () {
    test('【关键】记账组件只进账本模块，记药组件只进健康模块', () {
      // 归属由「用户点了哪个组件」决定，绝不能交给模型或关键词推断。
      // 真机上出现过在账本里说「加到账本里去」、模型却给 med_add，
      // 结果往药箱写了一条药 —— 所以这条必须钉死。
      expect(ChatMode.fromWidgetKind('expense'), ChatMode.finance);
      expect(ChatMode.fromWidgetKind('expense_ai'), ChatMode.finance);
      expect(ChatMode.fromWidgetKind('med'), ChatMode.health);
      expect(ChatMode.fromWidgetKind('med_ai'), ChatMode.health);
    });

    test('空或陌生 kind 回落到账本，不崩', () {
      expect(ChatMode.fromWidgetKind(null), ChatMode.finance);
      expect(ChatMode.fromWidgetKind(''), ChatMode.finance);
      expect(ChatMode.fromWidgetKind('  '), ChatMode.finance);
    });
  });
}
