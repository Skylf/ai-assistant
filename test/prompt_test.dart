import 'package:family_life_assistant/ai/action.dart';
import 'package:family_life_assistant/ai/prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 18);

  Map<String, dynamic> expense(num amount, {String type = 'expense'}) => {
    'id': 'e$amount$type',
    'title': '条目 $amount',
    'amount': amount,
    'category': '日常',
    'spentAt': '2026-09-18T10:00:00.000',
    'entryType': type,
  };

  Map<String, dynamic> med(String name, String expiry, {int stock = 1}) => {
    'id': name,
    'name': name,
    'ingredient': '',
    'spec': '',
    'stock': stock,
    'expiry': expiry,
    'storage': '',
  };

  group('Topic', () {
    test('短码与旧数据兼容', () {
      expect(Topic.finance.code, 'f');
      expect(Topic.health.code, 'h');
      expect(Topic.fromCode('h'), Topic.health);
      expect(Topic.fromCode('f'), Topic.finance);
      expect(Topic.fromCode(null), Topic.finance);
    });
  });

  group('账本提示词', () {
    test('包含收支分开的统计，不把收入算进支出', () {
      final prompt = PromptBuilder.finance(
        [expense(100), expense(8000, type: 'income')],
        now,
      );
      expect(prompt, contains('支出合计：¥100.00'));
      expect(prompt, contains('收入合计：¥8000.00'));
      expect(prompt, contains('结余：¥7900.00'));
    });

    test('包含分类占比', () {
      final prompt = PromptBuilder.finance([expense(100)], now);
      expect(prompt, contains('日常：¥100.00（100%）'));
    });

    test('无数据时给出明确提示而不是空列表', () {
      final prompt = PromptBuilder.finance(const [], now);
      expect(prompt, contains('本月支出分类：暂无数据'));
      expect(prompt, contains('（暂无数据）'));
    });

    test('声明不得编造', () {
      final prompt = PromptBuilder.finance([expense(1)], now);
      expect(prompt, contains('不得编造'));
    });
  });

  group('健康提示词', () {
    test('包含过期与临期统计', () {
      final prompt = PromptBuilder.health([
        med('过期药', '2026-01-01'),
        med('临期药', '2026-10-01'),
        med('远期药', '2028-01-01'),
        med('无有效期', ''),
      ], now);
      expect(prompt, contains('药品总数：4'));
      expect(prompt, contains('已过期：1'));
      expect(prompt, contains('90 天内到期：1'));
      expect(prompt, contains('未填写有效期：1'));
    });

    test('包含不诊断不处方的约束', () {
      final prompt = PromptBuilder.health([med('布洛芬', '2027-01-01')], now);
      expect(prompt, contains('不是医生'));
      expect(prompt, contains('不诊断、不处方'));
    });
  });

  group('明细预算', () {
    test('数据量很大时截断并说明', () {
      final rows = List.generate(
        400,
        (i) => expense(i + 1)..['spentAt'] = '2026-09-18T10:00:00.000',
      );
      final prompt = PromptBuilder.finance(rows, now);
      expect(prompt, contains('其余未列出'));
      // 明细预算 + 摘要，整体必须远小于把 400 条全塞进去的长度
      expect(prompt.length, lessThan(6000));
    });

    test('小数据量不出现截断说明', () {
      final prompt = PromptBuilder.finance([expense(1), expense(2)], now);
      expect(prompt, isNot(contains('其余未列出')));
    });

    test('明细行格式稳定', () {
      final line = PromptBuilder.expenseLine(expense(32.5));
      expect(line, '2026-09-18 | 支出 | 条目 32.5 | 日常 | ¥32.50');
      expect(
        PromptBuilder.medLine(med('布洛芬', '')),
        '布洛芬 | 成分未填 | 规格未填 | 1 | 未填 | 储存未填',
      );
    });
  });

  group('动作协议真的会发到模型', () {
    /// 组装一条系统提示词，参数只改需要变的部分。
    String build({bool allowActions = true, Topic topic = Topic.health}) =>
        PromptBuilder.build(
          topic: topic,
          expenses: [expense(32.5)],
          meds: [med('布洛芬', '2027-05-01')],
          now: now,
          allowActions: allowActions,
        );

    test('默认包含动作协议与正确示例', () {
      final prompt = build();
      expect(prompt, contains('【动作协议】'));
      expect(prompt, contains('med_add'));
      // 关键：告诉模型「多项要拆成多个元素」，这正是用户报告的那个缺陷
      expect(prompt, contains('一条消息要录入几项就放几个元素'));
      expect(prompt, contains('三个 med_add'));
    });

    test('账本主题给的是 expense_add 示例', () {
      final prompt = build(topic: Topic.finance);
      expect(prompt, contains('expense_add'));
      expect(prompt, contains('entryType'));
    });

    test('关闭动作时不出现协议（本地模式不该多花 token）', () {
      final prompt = build(allowActions: false);
      expect(prompt, isNot(contains('【动作协议】')));
      expect(prompt, isNot(contains('med_add')));
      // 图表协议不受影响
      expect(prompt, contains('```${PromptBuilder.chartFence}'));
    });

    test('【回归】提示词给的围栏标记与执行侧认的标记必须一致', () {
      // 这两处写在不同文件里（prompt.dart 负责告诉模型，action.dart 负责认），
      // 写错一个字母的表现是「模型明明按协议回答了却没执行」，而且不报错。
      // 这类「两边各写一份字面量」的地方必须锁住。
      expect(PromptBuilder.actionFence, ActionPlan.actionFence);
      final prompt = build();
      expect(
        prompt,
        contains('```${ActionPlan.actionFence}'),
        reason: '提示词里的围栏标记必须就是执行侧认的那个',
      );
    });

    test('协议要求模型同时给正文说明，避免用户只看到一堆 JSON', () {
      final prompt = build();
      expect(prompt, contains('正文'));
      expect(prompt, contains('不要只输出 JSON'));
    });

    test('协议明确「只是提问时不要输出动作计划」', () {
      // 否则用户问「我还有多少药」也会被当成录入，凭空多出药品
      final prompt = build();
      expect(prompt, contains('不要**输出动作计划'));
    });

    test('【回归】陈述事实也算录入，不要求用户先说「请帮我记录」', () {
      // 用户实测踩到：「我有两盒药：护肝片和维生素」既没被录入，还被反问保质期。
      // 这句话没有任何动词，模型很容易当成闲聊。
      final prompt = build();
      for (final phrase in [
        '我有两盒护肝片',
        '家里还有维生素和钙片',
        '今天买菜花了 32',
        '工资发了八千',
      ]) {
        expect(
          prompt,
          contains(phrase),
          reason: '「$phrase」这类无动词陈述必须被举例说明是录入请求',
        );
      }
      expect(prompt, contains('陈述事实就等于要你记下来'));
    });

    test('【回归】明确禁止为缺失的次要字段追问用户', () {
      final prompt = build();
      expect(prompt, contains('先录入，不要追问'));
      expect(prompt, contains('不要因为缺少保质期'));
      expect(prompt, contains('绝不要为它停下来提问'));
      // 要给出「应该怎么做」的正例，否则模型只知道不该问、不知道该怎么办
      expect(prompt, contains('名称=护肝片、库存=2'));
    });

    test('【回归】「和」「顿号」等并列词要拆成多项', () {
      // 「护肝片和维生素」曾经有被合成一个药名的风险，与用户最初报告的
      // 「a,b,c 变成一个药」是同一类错误，只是分隔符换成了中文并列词。
      final prompt = build();
      expect(prompt, contains('和'));
      expect(prompt, contains('顿号同样是并列关系'));
      expect(prompt, contains('两盒护肝片和维生素'));
      expect(prompt, contains('两个'));
    });
  });

  group('【回归】先判断意图：陈述事实是录入，不是查询', () {
    // 真机实测：说「今天买菜50，吃饭180」，模型回了一段「本月支出 ¥0.00」的统计，
    // 一条账都没记。根因是主题提示词开头写着「你是家庭账本分析助手…
    // 只依据本地账目数据回答」，模型把陈述句当成了查询。
    // 分析型人设与录入型任务是冲突的，必须明确点出优先级。

    test('账本提示词在最前面声明录入优先于分析', () {
      final prompt = PromptBuilder.build(
        topic: Topic.finance,
        expenses: const [],
        meds: const [],
        now: now,
      );
      expect(prompt, contains('【先判断用户想干什么】'));
      expect(prompt, contains('今天买菜50'));
      expect(prompt, contains('工资发了八千'));
      expect(prompt, contains('不要**当成查询去统计已有数据'));
      expect(prompt, contains('先录入，再在正文里说明'));

      // 优先级声明必须排在「本月概览」之前，否则模型先读到的是分析指令
      final judgeAt = prompt.indexOf('【先判断用户想干什么】');
      final overviewAt = prompt.indexOf('【本月概览】');
      expect(judgeAt, greaterThanOrEqualTo(0));
      expect(
        judgeAt,
        lessThan(overviewAt),
        reason: '意图判断必须写在数据概览之前，否则等于没写',
      );
    });

    test('健康提示词同样声明录入优先，并明确禁止先追问保质期', () {
      final prompt = PromptBuilder.build(
        topic: Topic.health,
        expenses: const [],
        meds: const [],
        now: now,
      );
      expect(prompt, contains('【先判断用户想干什么】'));
      expect(prompt, contains('我这有三盒护肝片'));
      expect(prompt, contains('不要**先追问保质期'));
      expect(prompt, contains('家里还有维生素'));

      final judgeAt = prompt.indexOf('【先判断用户想干什么】');
      final overviewAt = prompt.indexOf('【药箱概览】');
      expect(judgeAt, lessThan(overviewAt));
    });

    test('健康提示词的核心安全约束没有被挤掉', () {
      // 加内容时不能把「不是医生 / 不诊断 / 不处方 / 120」这些挤没了
      final prompt = PromptBuilder.build(
        topic: Topic.health,
        expenses: const [],
        meds: const [],
        now: now,
      );
      expect(prompt, contains('不是医生'));
      expect(prompt, contains('不诊断、不处方'));
      expect(prompt, contains('120'));
    });
  });
}
