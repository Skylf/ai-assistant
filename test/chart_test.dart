import 'package:family_life_assistant/ai/chart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('图表块解析', () {
    test('标准 category 块被抽出，正文保留', () {
      const reply = '''
本月支出主要集中在餐饮和购物。

```chart
{
  "type": "category",
  "title": "本月分类占比",
  "categories": [
    {"label": "餐饮", "value": 800, "display": "¥800.00", "percent": 40},
    {"label": "购物", "value": 600, "display": "¥600.00", "percent": 30}
  ],
  "total": {"label": "本月支出", "value": "¥2000.00"},
  "note": "餐饮占比偏高，可以关注外卖频次。"
}
```

建议先控制外卖。
''';
      final parsed = ChartParser.parse(reply);
      expect(parsed.hasChart, isTrue);
      expect(parsed.chart!.type, 'category');
      expect(parsed.chart!.title, '本月分类占比');
      expect(parsed.chart!.categories.length, 2);
      expect(parsed.chart!.categories.first.label, '餐饮');
      expect(parsed.chart!.categories.first.value, 800);
      expect(parsed.chart!.totalValue, '¥2000.00');
      expect(parsed.chart!.note, contains('外卖'));
      // 代码块被摘掉，前后正文都在
      expect(parsed.text, contains('本月支出主要集中在餐饮和购物。'));
      expect(parsed.text, contains('建议先控制外卖。'));
      expect(parsed.text, isNot(contains('```')));
      expect(parsed.text, isNot(contains('"type"')));
    });

    test('trend 类型同样被识别', () {
      const reply =
          '```chart\n{"type":"trend","title":"近三月支出",'
          '"categories":[{"label":"7 月","value":1200},'
          '{"label":"8 月","value":980}]}\n```';
      final parsed = ChartParser.parse(reply);
      expect(parsed.chart!.type, 'trend');
      expect(parsed.chart!.categories.length, 2);
      expect(parsed.chart!.maxValue, 1200);
    });

    test('忘记写代码块的裸 JSON 也能识别', () {
      const reply =
          '这是结果：{"type":"category","categories":[{"label":"交通","value":50}]} 完。';
      final parsed = ChartParser.parse(reply);
      expect(parsed.hasChart, isTrue);
      expect(parsed.chart!.categories.single.label, '交通');
    });

    test('普通回复不会被误判成图表', () {
      const reply = '这个月你花了 2000 元，其中餐饮占 40%。建议减少外卖。';
      final parsed = ChartParser.parse(reply);
      expect(parsed.hasChart, isFalse);
      expect(parsed.text, reply);
    });

    test('提到 JSON 但没有图表结构时保持纯文本', () {
      const reply = '接口会返回 {"name":"test"} 这样的对象。';
      final parsed = ChartParser.parse(reply);
      expect(parsed.hasChart, isFalse);
      expect(parsed.text, reply);
    });

    test('非法 JSON 不抛异常', () {
      const reply = '```chart\n{"type":"category", categories: [}\n```';
      final parsed = ChartParser.parse(reply);
      expect(parsed.hasChart, isFalse);
      expect(parsed.text, contains('type'));
    });

    test('缺少 value 的条目被忽略，全部无效时不算图表', () {
      const reply =
          '```chart\n{"type":"category","categories":[{"label":"餐饮"},'
          '{"label":"购物","value":10}]}\n```';
      final parsed = ChartParser.parse(reply);
      expect(parsed.hasChart, isTrue);
      expect(parsed.chart!.categories.length, 1);
      expect(parsed.chart!.categories.single.label, '购物');

      const broken =
          '```chart\n{"type":"category","categories":[{"label":"餐饮"}]}\n```';
      expect(ChartParser.parse(broken).hasChart, isFalse);
    });

    test('未知 type 被拒绝，避免渲染出无法解释的图形', () {
      const reply =
          '```chart\n{"type":"pie","categories":[{"label":"餐饮","value":1}]}\n```';
      expect(ChartParser.parse(reply).hasChart, isFalse);
    });

    test('超过 6 个分类时截断，避免聊天气泡被撑爆', () {
      final items = List.generate(
        9,
        (i) => '{"label":"分类$i","value":${10 - i}}',
      ).join(',');
      final parsed = ChartParser.parse(
        '```chart\n{"type":"category","categories":[$items]}\n```',
      );
      expect(parsed.chart!.categories.length, 6);
    });

    test('空字符串直接返回，不进入解析', () {
      final parsed = ChartParser.parse('   ');
      expect(parsed.hasChart, isFalse);
      expect(parsed.text, '');
    });

    test('数字字符串形式的 value 也能解析', () {
      const reply =
          '```chart\n{"type":"category","categories":[{"label":"餐饮","value":"88.5"}]}\n```';
      expect(ChartParser.parse(reply).chart!.categories.single.value, 88.5);
    });
  });
}
