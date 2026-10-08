import 'package:family_life_assistant/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('紧急症状分流', () {
    test('命中关键词返回固定话术', () {
      expect(Store.urgentAdvice('孩子误服了药'), contains('120'));
      expect(Store.urgentAdvice('突然胸痛'), contains('急诊'));
    });

    test('普通问题不分流', () {
      expect(Store.urgentAdvice('头孢和酒精能一起吃吗'), isNull);
    });

    // 0.4B 补词：原列表只有 7 个书面词，下面这些**口语说法全部漏检**。
    // 判据是 `contains`，所以列的是什么词就只能命中什么词 ——
    // 漏检的代价是把急症当成普通科普问答回。
    test('口语说法也要命中（不能只认书面词）', () {
      for (final text in [
        '胸口剧痛还喘不上气', // 原表只有「胸痛」「呼吸困难」，都命不中
        '喘不过气来了',
        '孩子吃错药了',
        '突然说话不清、半边身子动不了', // 中风表现
        '伤口一直止不住血',
        '过敏休克了',
        '怎么叫都叫不醒',
      ]) {
        expect(
          Store.urgentAdvice(text),
          isNotNull,
          reason: '「$text」应当被判为紧急情况',
        );
        expect(Store.urgentAdvice(text), contains('120'));
      }
    });

    test('不能误伤日常问药（否则天天弹急诊提示，用户会忽略它）', () {
      for (final text in [
        '布洛芬一天吃几次',
        '这个药饭前吃还是饭后吃',
        '孩子发烧38度要吃退烧药吗',
        '感冒了吃什么药',
        '血压有点高要注意什么',
        '这个药能长期吃吗',
      ]) {
        expect(
          Store.urgentAdvice(text),
          isNull,
          reason: '「$text」是普通问药，不该分流成急诊',
        );
      }
    });

    test('关键词表没有空白项（contains 空串恒为真，会全部误判）', () {
      // 这是个很容易犯的错：列表里混进一个 '' 或纯空格，
      // `any(question.contains)` 就恒为 true，所有提问都会被当成急症。
      for (final keyword in Store.urgentKeywords) {
        expect(keyword.trim(), isNotEmpty, reason: '关键词不能为空');
      }
    });
  });

  group('账本反向操作', () {
    test('记账 名称 金额', () {
      final action = Store.parseAction('记账 买菜 32.5', Topic.finance);
      expect(action, isNotNull);
      expect(action!.type, 'expense');
      expect(action.row['title'], '买菜');
      expect(action.row['amount'], 32.5);
      expect(action.row['entryType'], 'expense');
    });

    test('无空格也能解析', () {
      final action = Store.parseAction('记账买菜50', Topic.finance);
      expect(action?.row['title'], '买菜');
      expect(action?.row['amount'], 50);
    });

    test('识别收入', () {
      final action = Store.parseAction('记一笔 工资收入 8000', Topic.finance);
      expect(action?.row['entryType'], 'income');
      expect(action?.row['amount'], 8000);
    });

    test('添加账目 名称，金额', () {
      final action = Store.parseAction('添加账目 打车，18', Topic.finance);
      expect(action?.type, 'expense');
      expect(action?.row['title'], '打车');
      expect(action?.row['amount'], 18);
    });

    test('缺少金额时不拦截，交给 AI 回答', () {
      expect(Store.parseAction('记账 买菜', Topic.finance), isNull);
    });

    test('普通提问不触发落库', () {
      expect(Store.parseAction('本月花了多少钱？', Topic.finance), isNull);
    });

    test('两个主题互不串台', () {
      expect(Store.parseAction('记账 买菜 10', Topic.health), isNull);
      expect(Store.parseAction('添加药品布洛芬', Topic.finance), isNull);
    });
  });

  group('药箱反向操作', () {
    test('只给名称时库存默认 1', () {
      final action = Store.parseAction('添加药品 布洛芬', Topic.health);
      expect(action?.type, 'med');
      expect(action?.row['name'], '布洛芬');
      expect(action?.row['stock'], 1);
      expect(action?.row['expiry'], '');
    });

    test('解析库存与有效期', () {
      final action = Store.parseAction(
        '添加药品布洛芬，库存 2，有效期 2027-05-01',
        Topic.health,
      );
      expect(action?.row['name'], '布洛芬');
      expect(action?.row['stock'], 2);
      expect(action?.row['expiry'], '2027-05-01');
    });

    test('空格分隔时参数不会被名称吞掉', () {
      final action = Store.parseAction(
        '添加药品 布洛芬 库存 5 有效期 2027-01-02',
        Topic.health,
      );
      expect(action?.row['name'], '布洛芬');
      expect(action?.row['stock'], 5);
      expect(action?.row['expiry'], '2027-01-02');
    });

    test('支持中文日期写法并归一化', () {
      final action = Store.parseAction(
        '添加药瓶 维C 库存 3 有效期 2027年5月1日',
        Topic.health,
      );
      expect(action?.row['expiry'], '2027-05-01');
    });

    test('支持斜杠日期写法', () {
      final action = Store.parseAction(
        '添加药品 阿莫西林 有效期 2027/6/9',
        Topic.health,
      );
      expect(action?.row['expiry'], '2027-06-09');
    });

    test('只写年月时按当月 1 日处理', () {
      final action = Store.parseAction(
        '添加药品 创可贴 有效期 2028年3月',
        Topic.health,
      );
      expect(action?.row['expiry'], '2028-03-01');
    });

    test('非法月份不写入有效期', () {
      final action = Store.parseAction(
        '添加药品 测试药 有效期 2027年13月',
        Topic.health,
      );
      expect(action?.row['expiry'], '');
    });
  });

  group('一条消息添加多项（回归：曾经只加出一项）', () {
    // 用户报告的原话：说「添加药品：a,b,c」时，得到的是一个名叫「a,b,c」的药品，
    // 而不是三个药品。根因是中文冒号不在前缀的可选空白里、ASCII 逗号也不在名称的
    // 终止字符集里，于是整串被当成一个名称。这里把用户实际用的写法固定下来。
    test('用户原话：添加药品：a,b,c 得到三个药品', () {
      final actions = Store.parseActions('添加药品：a,b,c', Topic.health);
      expect(actions.length, 3);
      expect(actions.map((a) => a.row['name']).toList(), ['a', 'b', 'c']);
      expect(
        actions.every((a) => a.row['stock'] == 1),
        isTrue,
        reason: '只给名字时每项库存都默认 1',
      );
    });

    test('中文逗号与顿号也能分项', () {
      expect(
        Store.parseActions('添加药品 维生素C，钙片、锌片', Topic.health)
            .map((a) => a.row['name'])
            .toList(),
        ['维生素C', '钙片', '锌片'],
      );
    });

    test('分号、竖线、换行都能分项', () {
      for (final input in [
        '添加药品 a;b;c',
        '添加药品 a｜b｜c',
        '添加药品 a\nb\nc',
        '加药 a、b',
      ]) {
        expect(
          Store.parseActions(input, Topic.health).length,
          input.contains('a、b') ? 2 : 3,
          reason: '「$input」应被分项',
        );
      }
    });

    test('列表 + 统一参数：库存与有效期套用到每一项', () {
      // 这是最实用的形态：一次把几种药加进来，共用同一个有效期
      final actions = Store.parseActions(
        '添加药品 a,b,c 库存 2 有效期 2027-05-01',
        Topic.health,
      );
      expect(actions.length, 3);
      for (final a in actions) {
        expect(a.row['stock'], 2);
        expect(a.row['expiry'], '2027-05-01');
      }
      expect(actions.map((a) => a.row['name']).toList(), ['a', 'b', 'c']);
    });

    test('参数写法不会被误当成多个药品', () {
      // 反向风险：逗号在「名称与参数」之间时不能分项。
      // 「库存 2」「有效期 …」都是参数，不是药品名。
      final actions = Store.parseActions(
        '添加药品布洛芬，库存 2，有效期 2027-05-01',
        Topic.health,
      );
      expect(
        actions.length,
        1,
        reason: '逗号在这里是名称与参数的分隔，不是列表分隔',
      );
      expect(actions.single.row['name'], '布洛芬');
      expect(actions.single.row['stock'], 2);
    });

    test('列表项本身又带参数时按参数解析，不拆散', () {
      final actions = Store.parseActions('添加药品 布洛芬 库存 5', Topic.health);
      expect(actions.length, 1);
      expect(actions.single.row['name'], '布洛芬');
      expect(actions.single.row['stock'], 5);
    });

    test('多项时回复逐条列出，能看出每一项都进去了', () {
      // 「安静地少加一个」是最难发现的失效，所以回复必须能核对
      final reply = Store.actionReplyForTest(
        Store.parseActions('添加药品：a,b,c', Topic.health),
      );
      expect(reply, contains('共 3 项'));
      expect(reply, contains('a'));
      expect(reply, contains('b'));
      expect(reply, contains('c'));
    });

    test('单项时回复保持原来的简短样式', () {
      final reply = Store.actionReplyForTest(
        Store.parseActions('添加药品 布洛芬', Topic.health),
      );
      expect(reply, '药品已加入药箱：布洛芬，并已同步显示在对应页面。');
    });

    test('陈述句由模型处理，本地绝不能瞎猜成一个药名', () {
      // 用户实测说过的话：「我有两盒药：护肝片和维生素」。
      // 本地解析器认不出这句是**应该的** —— 这属于「理解人话」，交给模型。
      // 但它更不能把整句话当成一个药名建进去：那是最初报告的缺陷的变体，
      // 只是分隔符从逗号换成了「和」。**宁可交给模型，也不要安静地做错事。**
      for (final said in [
        '我有两盒药：护肝片和维生素',
        '家里还有维生素和钙片',
        '我有两盒护肝片',
      ]) {
        expect(
          Store.parseActions(said, Topic.health),
          isEmpty,
          reason: '「$said」本地不该解析出动作（应交模型），更不能当成一个药名',
        );
      }
    });
  });

  group('账本一条消息多笔', () {
    test('名称列表 + 统一金额：记账 买菜,打车 30', () {
      final actions = Store.parseActions('记账 买菜,打车 30', Topic.finance);
      expect(actions.length, 2);
      expect(actions.map((a) => a.row['title']).toList(), ['买菜', '打车']);
      expect(actions.every((a) => a.row['amount'] == 30), isTrue);
    });

    test('名称与金额逐个配对：记账 买菜 32.5, 打车 18', () {
      final actions = Store.parseActions('记账 买菜 32.5, 打车 18', Topic.finance);
      expect(actions.length, 2);
      expect(actions[0].row['title'], '买菜');
      expect(actions[0].row['amount'], 32.5);
      expect(actions[1].row['title'], '打车');
      expect(actions[1].row['amount'], 18.0);
    });

    test('单个名称 + 金额仍走原路径', () {
      final actions = Store.parseActions('记账 打车，18', Topic.finance);
      expect(actions.length, 1);
      expect(actions.single.row['title'], '打车');
      expect(actions.single.row['amount'], 18);
    });

    test('名称列表但没给金额：不落库，交给 AI 追问', () {
      expect(Store.parseActions('记账 买菜,打车', Topic.finance), isEmpty);
    });

    test('普通提问不触发落库', () {
      expect(Store.parseActions('本月花了多少钱？', Topic.finance), isEmpty);
    });
  });
}
