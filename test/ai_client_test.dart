import 'dart:convert';

import 'package:family_life_assistant/ai/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('AiClient.endpoint', () {
    test('拼接 chat/completions', () {
      final client = AiClient(
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-chat',
        apiKey: 'sk-test',
      );
      expect(
        client.endpoint.toString(),
        'https://api.deepseek.com/chat/completions',
      );
    });

    test('容忍结尾斜杠与多余空格', () {
      final client = AiClient(
        baseUrl: '  https://api.deepseek.com/  ',
        model: 'm',
        apiKey: 'k',
      );
      expect(
        client.endpoint.toString(),
        'https://api.deepseek.com/chat/completions',
      );
    });

    test('默认模型名是官方存在的对话模型', () {
      expect(AiClient.defaultModel, 'deepseek-flash');
      expect(AiClient.defaultBaseUrl, 'https://api.deepseek.com');
    });

    test('拼接 models 端点', () {
      final client = AiClient(
        baseUrl: 'https://api.deepseek.com/',
        model: 'm',
        apiKey: 'k',
      );
      expect(
        client.modelsEndpoint.toString(),
        'https://api.deepseek.com/models',
      );
    });
  });

  group('AiClient.parseModelIds', () {
    http.Response json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
    );

    test('取出 id 并排序去重（OpenAI 兼容格式）', () {
      final ids = AiClient.parseModelIds(
        json({
          'object': 'list',
          'data': [
            {'id': 'deepseek-reasoner', 'object': 'model'},
            {'id': 'deepseek-chat', 'object': 'model'},
            {'id': 'deepseek-chat', 'object': 'model'},
          ],
        }),
      );
      expect(ids, ['deepseek-chat', 'deepseek-reasoner']);
    });

    test('非 2xx 返回 null，由界面引导手工填写', () {
      expect(
        AiClient.parseModelIds(json({'error': 'unauthorized'}, 401)),
        isNull,
      );
    });

    test('空列表视为没有可用模型', () {
      expect(AiClient.parseModelIds(json({'data': []})), isNull);
    });

    test('缺少 data 字段不崩溃', () {
      expect(AiClient.parseModelIds(json({'object': 'list'})), isNull);
      expect(AiClient.parseModelIds(json([1, 2, 3])), isNull);
    });

    test('非 JSON 响应不崩溃', () {
      expect(
        AiClient.parseModelIds(
          http.Response.bytes(utf8.encode('<html>502</html>'), 200),
        ),
        isNull,
      );
    });

    test('忽略没有 id 的条目与空 id', () {
      final ids = AiClient.parseModelIds(
        json({
          'data': [
            {'object': 'model'},
            {'id': '   '},
            {'id': ' deepseek-chat '},
          ],
        }),
      );
      expect(ids, ['deepseek-chat']);
    });

    // 对抗性审查发现：旧实现用 `item['id']?.toString()`，把非字符串 id 也
    // 转成了模型名。这些垃圾会变成可点的胶囊，点一下就写进模型名并发出去。
    test('拒绝非字符串 id（数字/布尔/对象/数组）', () {
      final ids = AiClient.parseModelIds(
        json({
          'data': [
            {'id': 123},
            {'id': true},
            {'id': {}},
            {'id': <String, dynamic>{'a': 1}},
            {'id': <dynamic>[]},
            {'id': 'deepseek-chat'},
          ],
        }),
      );
      expect(ids, ['deepseek-chat']);
    });

    test('拒绝超长 id（防止畸形响应撑爆布局）', () {
      final huge = 'x' * 5000;
      final ids = AiClient.parseModelIds(
        json({
          'data': [
            {'id': huge},
            {'id': 'deepseek-chat'},
          ],
        }),
      );
      expect(ids, ['deepseek-chat']);
    });

    test('恰好在上限内的长 id 仍然接受', () {
      final ok = 'x' * 200;
      final ids = AiClient.parseModelIds(
        json({
          'data': [
            {'id': ok},
          ],
        }),
      );
      expect(ids, [ok]);
    });
  });

  group('AiClient.parse', () {
    http.Response json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
    );

    test('正常取出正文', () {
      final result = AiClient.parse(
        json({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': ' 你好 '},
            },
          ],
        }),
      );
      expect(result.ok, isTrue);
      expect(result.text, '你好');
      expect(result.display, '你好');
    });

    test('非 2xx 视为失败并带上状态码', () {
      final result = AiClient.parse(
        json({'error': {'message': 'invalid api key'}}, 401),
      );
      expect(result.ok, isFalse);
      expect(result.display, contains('API Key'));
    });

    test('404 时提示模型名可能写错', () {
      final result = AiClient.parse(json({'error': 'not found'}, 404));
      expect(result.ok, isFalse);
      expect(result.display, contains('404'));
      expect(result.display, contains('获取可用模型'));
    });

    test('400 时也提示核对模型名', () {
      final result = AiClient.parse(json({'error': 'bad request'}, 400));
      expect(result.ok, isFalse);
      expect(result.display, contains('400'));
      expect(result.display, contains('获取可用模型'));
    });

    test('缺少 choices 不崩溃', () {
      final result = AiClient.parse(json({'id': 'x'}));
      expect(result.ok, isFalse);
      expect(result.display, contains('choices'));
    });

    test('内容为空视为失败', () {
      final result = AiClient.parse(
        json({
          'choices': [
            {
              'message': {'content': '   '},
            },
          ],
        }),
      );
      expect(result.ok, isFalse);
      expect(result.display, contains('空回复'));
    });

    test('返回非 JSON 时给出可读错误', () {
      final result = AiClient.parse(
        http.Response.bytes(utf8.encode('<html>502</html>'), 502),
      );
      expect(result.ok, isFalse);
      expect(result.display, contains('502'));
    });
  });
}
