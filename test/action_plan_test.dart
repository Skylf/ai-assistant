import 'dart:convert';

import 'package:family_life_assistant/ai/action.dart';
import 'package:family_life_assistant/ai/chart.dart';
import 'package:family_life_assistant/core/topic.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模型动作计划的解析。
///
/// 这一层的存在意义：中文录入意图不可能靠关键词穷举，所以「理解人话」交给模型，
/// App 只负责执行。模型不保证输出格式，所以解析必须极度宽容 —— 但**宽容不等于
/// 乱猜**：字段缺失就丢弃那一条，而不是编一个值出来。
void main() {
  group('标准输出', () {
    test('actions 数组解析成多条药品', () {
      final actions = ActionPlan.parse(
        jsonEncode({
          'actions': [
            {'type': 'med_add', 'name': '护肝片', 'stock': 2, 'expiry': '2027-05-01'},
            {'type': 'med_add', 'name': '维生素B', 'stock': 2, 'expiry': '2027-05-01'},
            {'type': 'med_add', 'name': '钙片', 'stock': 2, 'expiry': '2027-05-01'},
          ],
        }),
      );
      expect(actions.length, 3);
      expect(actions.map((a) => (a['row'] as Map)['name']).toList(), [
        '护肝片',
        '维生素B',
        '钙片',
      ]);
      expect((actions.first['row'] as Map)['stock'], 2);
      expect((actions.first['row'] as Map)['expiry'], '2027-05-01');
    });

    test('正文里的 ```actions 围栏', () {
      final raw = '明白，我给你加了三样药。\n\n'
          '```actions\n'
          '{"actions":[{"type":"med_add","name":"A"},{"type":"med_add","name":"B"}]}\n'
          '```';
      final actions = ActionPlan.parse(raw);
      expect(actions.length, 2);
      expect(actions.map((a) => (a['row'] as Map)['name']).toList(), ['A', 'B']);
    });

    test('```json 围栏也接受', () {
      final actions = ActionPlan.parse(
        '好的：\n```json\n{"actions":[{"type":"med_add","name":"A"}]}\n```',
      );
      expect(actions.length, 1);
    });

    test('只给单个动作对象（没套 actions 数组）', () {
      final actions = ActionPlan.parse(
        '{"type":"med_add","name":"布洛芬","stock":3}',
      );
      expect(actions.length, 1);
      expect((actions.single['row'] as Map)['name'], '布洛芬');
      expect((actions.single['row'] as Map)['stock'], 3);
    });

    test('账目动作带金额与收入类型', () {
      final actions = ActionPlan.parse(
        jsonEncode({
          'actions': [
            {
              'type': 'expense_add',
              'title': '工资',
              'amount': 8000,
              'entryType': 'income',
              'category': '工资',
            },
          ],
        }),
        topic: Topic.finance,
      );
      final row = actions.single['row'] as Map;
      expect(row['title'], '工资');
      expect(row['amount'], 8000.0);
      expect(row['entryType'], 'income');
      expect(actions.single['summary'], '工资 ¥8000.00');
    });
  });

  group('字段规范化', () {
    test('库存缺失时默认 1；字符串数字也能读', () {
      final a = ActionPlan.parse(
        '{"actions":[{"type":"med_add","name":"A"}]}',
      );
      expect((a.single['row'] as Map)['stock'], 1);

      final b = ActionPlan.parse(
        '{"actions":[{"type":"med_add","name":"A","stock":"3"}]}',
      );
      expect((b.single['row'] as Map)['stock'], 3);
    });

    test('有效期写法归一化成 YYYY-MM-DD', () {
      for (final input in ['2027/5/1', '2027-5-1', '2027年5月1日']) {
        final actions = ActionPlan.parse(
          jsonEncode({
            'actions': [
              {'type': 'med_add', 'name': 'A', 'expiry': input},
            ],
          }),
        );
        expect(
          (actions.single['row'] as Map)['expiry'],
          '2027-05-01',
          reason: '「$input」应归一化',
        );
      }
    });

    test('非法日期留空而不是丢弃整条', () {
      // 药名是对的、只是日期没听清：不该因为一个字段就整条不录
      final actions = ActionPlan.parse(
        '{"actions":[{"type":"med_add","name":"A","expiry":"2027年13月"}]}',
      );
      expect(actions.length, 1);
      expect((actions.single['row'] as Map)['expiry'], '');
    });

    test('金额是字符串也能读', () {
      final actions = ActionPlan.parse(
        '{"actions":[{"type":"expense_add","title":"买菜","amount":"32.5"}]}',
        topic: Topic.finance,
      );
      expect((actions.single['row'] as Map)['amount'], 32.5);
    });

    test('分类缺失写「未分类」而不是编一个', () {
      final actions = ActionPlan.parse(
        '{"actions":[{"type":"expense_add","title":"买菜","amount":10}]}',
        topic: Topic.finance,
      );
      expect((actions.single['row'] as Map)['category'], '未分类');
    });
  });

  group('必须拒绝的输入（不能乱猜）', () {
    test('药名缺失或空 → 丢弃该条', () {
      expect(ActionPlan.parse('{"actions":[{"type":"med_add","stock":2}]}'), isEmpty);
      expect(
        ActionPlan.parse('{"actions":[{"type":"med_add","name":"   "}]}'),
        isEmpty,
      );
    });

    test('金额缺失或非法 → 丢弃该条（不能默认 0 元）', () {
      expect(
        ActionPlan.parse('{"actions":[{"type":"expense_add","title":"买菜"}]}'),
        isEmpty,
      );
      expect(
        ActionPlan.parse(
          '{"actions":[{"type":"expense_add","title":"买菜","amount":"abc"}]}',
        ),
        isEmpty,
      );
      expect(
        ActionPlan.parse(
          '{"actions":[{"type":"expense_add","title":"买菜","amount":-5}]}',
        ),
        isEmpty,
      );
    });

    test('未知 type → 丢弃（App 只执行自己认识的 type）', () {
      expect(
        ActionPlan.parse('{"actions":[{"type":"delete_all_data"}]}'),
        isEmpty,
      );
      expect(
        ActionPlan.parse('{"actions":[{"type":"med_delete","name":"A"}]}'),
        isEmpty,
      );
    });

    test('一条消息里好坏混着时，只丢坏的那条', () {
      final actions = ActionPlan.parse(
        jsonEncode({
          'actions': [
            {'type': 'med_add', 'name': '好的'},
            {'type': 'med_add'},
            {'type': 'med_add', 'name': '也是好的'},
          ],
        }),
      );
      expect(actions.length, 2);
      expect(actions.map((a) => (a['row'] as Map)['name']).toList(), [
        '好的',
        '也是好的',
      ]);
    });
  });

  group('extract 摘掉代码块，且不误伤其它协议', () {
    test('摘掉 ```actions 块，正文保留', () {
      final r = ActionPlan.extract(
        '好的，加了三样。\n```actions\n{"actions":[{"type":"med_add","name":"A"}]}\n```',
      );
      expect(r.body, '好的，加了三样。');
      expect(r.actions.length, 1);
      expect(r.body, isNot(contains('```')));
      expect(r.body, isNot(contains('med_add')));
    });

    test('正文在代码块之后也能保留', () {
      final r = ActionPlan.extract(
        '```actions\n{"actions":[{"type":"med_add","name":"A"}]}\n```\n请确认。',
      );
      expect(r.body, contains('请确认。'));
      expect(r.body, isNot(contains('actions')));
    });

    test('没有代码块的纯正文：正文原样，动作为空', () {
      final r = ActionPlan.extract('你本月支出 ¥78.00。');
      expect(r.body, '你本月支出 ¥78.00。');
      expect(r.actions, isEmpty);
    });

    test('【回归】图表解析器不能吃掉 actions 块', () {
      // ChartParser 的正则一度写成 `(?:chart|json)?`，语言标记可选 = 匹配任意
      // 代码块。动作块因此被当成图表数据，解析不出来又原样留在正文里。
      // 这里锁住两类协议各认各的标记。
      final reply =
          '分析如下。\n```chart\n'
          '{"type":"category","title":"支出","categories":[{"label":"餐饮","value":32.8}]}\n'
          '```\n```actions\n{"actions":[{"type":"med_add","name":"A"}]}\n```';

      final chart = ChartParser.parse(reply);
      expect(chart.chart, isNotNull, reason: '图表仍要能解析出来');
      expect(chart.hasChart, isTrue);

      final extracted = ActionPlan.extract(reply);
      expect(extracted.actions.length, 1, reason: '动作也要能解析出来');
      expect(
        extracted.body,
        isNot(contains('med_add')),
        reason: '正文里不能残留动作 JSON',
      );
    });

    test('```json 围栏不再被动作解析器当成动作块之外的干扰', () {
      // 模型偶尔用 ```json 而不是 ```actions；仍应认得出来
      final r = ActionPlan.extract(
        '好的。\n```json\n{"actions":[{"type":"med_add","name":"A"}]}\n```',
      );
      expect(r.actions.length, 1);
      expect(r.body, '好的。');
    });
  });

  group('畸形输出退化成普通回复', () {
    test('纯文本回复 → 空（当普通对话处理）', () {
      expect(ActionPlan.parse('你本月支出是 ¥78.00，比上月少了 12%。'), isEmpty);
    });

    test('非法 JSON → 空', () {
      expect(ActionPlan.parse('{"actions":[{'), isEmpty);
      expect(ActionPlan.parse('```actions\n{不是JSON}\n```'), isEmpty);
    });

    test('JSON 合法但没有 actions 字段 → 空', () {
      expect(ActionPlan.parse('{"answer":"没有要录入的东西"}'), isEmpty);
      expect(ActionPlan.parse('{"actions":[]}'), isEmpty);
      expect(ActionPlan.parse('{"actions":"不是数组"}'), isEmpty);
    });

    test('actions 里是非对象元素 → 跳过', () {
      expect(ActionPlan.parse('{"actions":[1,null,"x",[]]}'), isEmpty);
    });

    test('空字符串不崩', () {
      expect(ActionPlan.parse(''), isEmpty);
    });
  });

  group('【回归】模块护栏：主题决定写哪个模块，模型说了不算', () {
    // 真机实测（用户截图）：「账本分析」里说
    // 「今天买菜50，吃饭250，加到账本里去」，模型却输出 med_add，
    // App 就老老实实往**药箱**加了一条「护肝片」，回复还自相矛盾：
    //   「已加入药箱」+「账目已加入账本（共 1 项）：· 护肝片」
    // 账本与药箱是两套完全不同的记录，混写一次用户就得自己去猜、去清理。

    test('账本主题下丢弃 med_add', () {
      final actions = ActionPlan.parse(
        '```actions\n{"actions":[{"type":"med_add","name":"护肝片","stock":2}]}\n```',
        topic: Topic.finance,
      );
      expect(actions, isEmpty, reason: '账本里绝不能出现药品动作');
    });

    test('药箱主题下丢弃 expense_add', () {
      final actions = ActionPlan.parse(
        '{"actions":[{"type":"expense_add","title":"买菜","amount":50}]}',
        topic: Topic.health,
      );
      expect(actions, isEmpty, reason: '药箱里绝不能出现账目动作');
    });

    test('混着给出时只保留本模块的那条', () {
      final raw = jsonEncode({
        'actions': [
          {'type': 'med_add', 'name': '护肝片', 'stock': 2},
          {'type': 'expense_add', 'title': '买菜', 'amount': 50},
        ],
      });
      expect(
        ActionPlan.parse(raw, topic: Topic.finance).single['type'],
        'expense_add',
      );
      expect(
        ActionPlan.parse(raw, topic: Topic.health).single['type'],
        'med_add',
      );
    });

    test('被丢弃时 extract 会标记 rejected，供调用方留下现场', () {
      final r = ActionPlan.extract(
        '```actions\n{"actions":[{"type":"med_add","name":"护肝片"}]}\n```',
        topic: Topic.finance,
      );
      expect(r.actions, isEmpty);
      expect(r.rejected, isTrue, reason: 'rejected 要告诉调用方「模型搞错模块了」');
      // 即使动作被丢弃，代码块也必须摘掉，不能让用户看到裸 JSON
      expect(r.body, isNot(contains('med_add')));
      expect(r.body, isNot(contains('```')));
    });

    test('普通的「没有动作」不算 rejected', () {
      final r = ActionPlan.extract('你本月支出 ¥78.00。', topic: Topic.finance);
      expect(r.actions, isEmpty);
      expect(r.rejected, isFalse, reason: '只是没录入，不是模块搞错');
    });

    test('allowedTypes 的映射是穷举的', () {
      expect(ActionPlan.allowedTypes(Topic.health), {ActionPlan.medAdd});
      expect(ActionPlan.allowedTypes(Topic.finance), {ActionPlan.expenseAdd});
    });
  });
}
