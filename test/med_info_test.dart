import 'dart:convert';

import 'package:family_life_assistant/ai/client.dart';
import 'package:family_life_assistant/ai/med_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 0.4D 需求 2.3：药品详细信息的**联网查询**。
///
/// 用户的要求是「ai 从网上查，注意，信息来源一定要可靠准确权威」。
///
/// 这一组测试的核心不是「能不能查到」，而是**查不到时必须诚实**：
///  · 解析不到字段 → 返回空 map，绝不用编造内容填满；
///  · 来源解析不到 → 返回空列表，绝不显示假 URL；
///  · 服务商不支持联网 → 降级成普通请求，并在来源里如实写明「未真正联网核实」。
///
/// 「把模型记忆伪装成联网结果」是这个功能最危险的失败方式，
/// 所以下面有一半的断言都在防它。
void main() {
  group('提示词约束（来源与格式）', () {
    test('要求的字段一个都不少', () {
      final prompt = buildLookupPrompt('布洛芬缓释胶囊');
      for (final key in medInfoFields.keys) {
        expect(prompt, contains('$key:'), reason: '提示词里缺少字段 $key');
      }
    });

    test('明确要求自报来源，且允许写「未知」', () {
      final prompt = buildLookupPrompt('布洛芬');
      expect(prompt, contains('source:'));
      expect(prompt, contains('未知'));
    });

    test('明确禁止给个体剂量建议与诊断（健康安全底线）', () {
      final prompt = buildLookupPrompt('布洛芬');
      expect(prompt, contains('不要'));
      expect(prompt, contains('诊断'));
      expect(prompt, contains('剂量'));
    });

    test('带上通用名/成分（同名不同成分的药很多）', () {
      final withIngredient = buildLookupPrompt('芬必得', ingredient: '布洛芬');
      expect(withIngredient, contains('布洛芬'));
      final without = buildLookupPrompt('芬必得');
      expect(without, isNot(contains('通用名/成分：')));
    });
  });

  group('解析模型回答', () {
    test('标准格式全部解析出来', () {
      final parsed = parseLookupReply('''
usage: 口服，一次1粒，一日2次
indications: 用于缓解轻至中度疼痛
efficacy: 抑制前列腺素合成
adverse: 偶见恶心、胃部不适
contraindications: 对本品过敏者禁用
precautions: 孕妇及哺乳期妇女慎用
source: 药品说明书
''');
      expect(parsed['usage'], '口服，一次1粒，一日2次');
      expect(parsed['indications'], '用于缓解轻至中度疼痛');
      expect(parsed['efficacy'], '抑制前列腺素合成');
      expect(parsed['adverse'], '偶见恶心、胃部不适');
      expect(parsed['contraindications'], '对本品过敏者禁用');
      expect(parsed['precautions'], '孕妇及哺乳期妇女慎用');
      expect(parsed['source'], '药品说明书');
    });

    test('容忍全角冒号、列表符号、加粗星号（模型输出很花）', () {
      final parsed = parseLookupReply('''
**usage**：每日 1 次
- indications: 头痛
* adverse: 皮疹
1. precautions：饭后服用
''');
      expect(parsed['usage'], '每日 1 次');
      expect(parsed['indications'], '头痛');
      expect(parsed['adverse'], '皮疹');
      expect(parsed['precautions'], '饭后服用');
    });

    test('【关键】「未知」不写进结果 —— 不能把没查到当成查到了', () {
      final parsed = parseLookupReply('''
usage: 未知
indications: 不详
efficacy: 不清楚
adverse: 无法确认
contraindications: 无
precautions: unknown
''');
      expect(
        parsed,
        isEmpty,
        reason: '把「未知」当内容存下来，用户会以为真的查到了',
      );
    });

    test('「未知」的几种写法都拦得住（含尾部标点）', () {
      for (final v in ['未知', '未知。', '未知.', '不详', 'N/A', 'n/a', 'None', '没有查到']) {
        final parsed = parseLookupReply('usage: $v');
        expect(parsed, isEmpty, reason: '「$v」应被视为没查到');
      }
    });

    test('部分有值部分未知时，只保留有值的那些', () {
      final parsed = parseLookupReply('''
usage: 口服，一次1粒
adverse: 未知
precautions: 孕妇慎用
''');
      expect(parsed.keys, containsAll(['usage', 'precautions']));
      expect(parsed.containsKey('adverse'), isFalse);
    });

    test('不认识的键被忽略（模型爱加自己的字段）', () {
      final parsed = parseLookupReply('''
usage: 口服
dosage: 一次1粒
注意: 别乱吃
''');
      expect(parsed.keys.toList(), ['usage']);
    });

    test('整段瞎聊、没有任何字段时返回空 map', () {
      expect(parseLookupReply('抱歉，我无法查询这类信息。'), isEmpty);
      expect(parseLookupReply(''), isEmpty);
    });

    test('值里的冒号不会被截断（URL、时间都含冒号）', () {
      final parsed = parseLookupReply('source: 见 https://www.nmpa.gov.cn 的说明');
      expect(parsed['source'], '见 https://www.nmpa.gov.cn 的说明');
    });
  });

  group('来源描述必须诚实（两种来源不能混）', () {
    // 这一组是 0.4D→0.4F 三次返工的核心，值得完整记下：
    //
    // ① 0.4D 第一版按 `webSearchUsed` 分成「联网检索」和「未真正联网核实」两种文案，
    //    而**联网那条分支从来没有真正执行过** —— 往 chat/completions 发内置
    //    `web_search` 工具会被**静默忽略**（官方文档：「内置工具类型会被忽略」）。
    //    于是界面上的「未真正联网核实」是在描述一件从未发生的事。
    // ② 0.4E 我据此把话改死：任何来源文案都不许出现「联网」「检索」。
    //    这话在**当时是对的**，但结论下得太大 —— 我说「DeepSeek API 没有联网能力」，
    //    实际只是 chat/completions 这一条路没有。
    // ③ 0.4F 换到 Anthropic 兼容 `/messages` + `web_search_20250305`，
    //    **真的能联网了**。所以「联网检索」字样重新被允许 ——
    //    条件是**真的检索了**（依据是服务端返回了 `web_search_tool_result`）。
    //
    // 于是现在的契约变成两条，缺一不可：
    //  · searched=true  → 必须说「联网检索」，不能还含糊其辞；
    //  · searched=false → **一个字都不许提「联网/检索/搜索/网上查」**，
    //                     否则又回到 ① 的撒谎状态。
    // 下面第一条守的就是 searched=false 那一半 —— 它是最容易退化的一半。

    test('【关键】没联网时，来源文案里绝不允许出现「联网」「检索」', () {
      for (final reported in ['', '药品说明书', '国家药监局药品说明书']) {
        final s = describeSource(searched: false, modelReported: reported);
        for (final word in ['联网', '检索', '搜索', '网上查']) {
          expect(
            s.contains(word),
            isFalse,
            reason: '来源文案「$s」里出现了「$word」—— 这次根本没联网，'
                '这样写等于告诉用户内容被查证过',
          );
        }
      }
    });

    test('【关键】联网了就必须说「联网检索」，不能含糊', () {
      final s = describeSource(searched: true, sourceCount: 16);
      expect(s, contains('联网检索'));
      expect(s, contains('16'), reason: '来源条数要写出来，用户才知道查到了多少');
    });

    test('【关键】联网了也不许只说「模型已有知识」', () {
      final s = describeSource(searched: true, sourceCount: 3);
      expect(
        s,
        isNot(contains('模型已有知识')),
        reason: '真联网查到了却说是模型记忆，是把来源说低了 —— 用户会以为没法核对',
      );
    });

    test('联网了但一条来源都没有，措辞要含糊得住（不能编条数）', () {
      final s = describeSource(searched: true, sourceCount: 0);
      expect(s, contains('联网检索'));
      expect(s, isNot(contains('0 条')));
      expect(s, isNot(contains('null')));
    });

    test('没联网时，明说「模型已有知识」', () {
      final s = describeSource(searched: false, modelReported: '');
      expect(s, contains('模型已有知识'));
      expect(s, contains('未经核实'));
    });

    test('没联网且模型自报依据时原样保留，但标明是「自述」', () {
      final s = describeSource(searched: false, modelReported: '药品说明书');
      expect(s, contains('药品说明书'));
      expect(s, contains('自述'));
      expect(s, contains('模型已有知识'));
    });

    test('自报依据两侧空白不影响结果', () {
      expect(
        describeSource(searched: false, modelReported: '  药品说明书  '),
        describeSource(searched: false, modelReported: '药品说明书'),
      );
    });

    test('来源文案本身不含 URL（URL 单独存 infoUrls 字段）', () {
      // 来源描述是给人看的一句话，URL 列表是结构化字段。
      // 混在一起就得在字符串里做解析 —— 那正是「用正则解析本该结构化的东西」。
      for (final searched in [true, false]) {
        expect(
          describeSource(searched: searched, modelReported: '某某网'),
          isNot(contains('http')),
        );
      }
    });

    test('药监局入口是官方域名，且指向查询页', () {
      expect(nmpaSearchUrl, startsWith('https://'));
      expect(nmpaSearchUrl, contains('nmpa.gov.cn'));
      expect(nmpaSearchUrl, contains('datasearch'));
    });
  });

  group('查询结果要能区分「失败」和「没查到」', () {
    // 0.4D 真机 bug：`lookupMedInfo` 失败时静默返回空 map，
    // 界面于是显示「资料出处：暂无」，用户完全不知道是配置错了、
    // 网络断了、还是模型没按格式回答 —— 三种情况下一步动作完全不同。

    test('失败结果带出原因', () {
      const r = MedLookupResult(fields: {}, error: '尚未配置 API Key');
      expect(r.ok, isFalse);
      expect(r.error, '尚未配置 API Key');
      expect(r.succeededButEmpty, isFalse);
    });

    test('成功但一条都没解析出来：ok 为真、fields 为空', () {
      const r = MedLookupResult(fields: {}, note: '模型没按格式回答');
      expect(r.ok, isTrue);
      expect(r.succeededButEmpty, isTrue);
      expect(r.note, '模型没按格式回答');
    });

    test('成功且有内容', () {
      const r = MedLookupResult(fields: {'usage': '口服'});
      expect(r.ok, isTrue);
      expect(r.succeededButEmpty, isFalse);
      expect(r.fields, {'usage': '口服'});
    });

    test('三种情况互不相等（界面才能给出三种不同提示）', () {
      const failed = MedLookupResult(fields: {}, error: 'x');
      const empty = MedLookupResult(fields: {});
      const filled = MedLookupResult(fields: {'usage': '口服'});
      expect(
        {failed.ok, empty.ok, filled.ok},
        {false, true},
        reason: 'failed 与 empty 必须能区分',
      );
      expect(empty.succeededButEmpty, isNot(filled.succeededButEmpty));
    });
  });

  group('从响应里解析引用来源', () {
    test('OpenAI/DeepSeek 风格的 url_citation', () {
      final urls = AiClient.parseSources({
        'choices': [
          {
            'message': {
              'content': 'x',
              'annotations': [
                {
                  'type': 'url_citation',
                  'url_citation': {'url': 'https://a.example/1'},
                },
                {
                  'type': 'url_citation',
                  'url_citation': {'url': 'https://b.example/2'},
                },
              ],
            },
          },
        ],
      });
      expect(urls, ['https://a.example/1', 'https://b.example/2']);
    });

    test('web_search_results / 顶层 search_results 也认得', () {
      expect(
        AiClient.parseSources({
          'choices': [
            {
              'message': {
                'web_search_results': [
                  {'url': 'https://c.example'},
                ],
              },
            },
          ],
        }),
        ['https://c.example'],
      );
      expect(
        AiClient.parseSources({
          'search_results': [
            {'url': 'https://d.example'},
          ],
        }),
        ['https://d.example'],
      );
    });

    test('去重且保持顺序', () {
      final urls = AiClient.parseSources({
        'choices': [
          {
            'message': {
              'annotations': [
                {
                  'url_citation': {'url': 'https://a.example'},
                },
              ],
              'citations': ['https://a.example', 'https://b.example'],
            },
          },
        ],
      });
      expect(urls, ['https://a.example', 'https://b.example']);
    });

    test('【关键】没有来源信息时返回空列表，绝不编造', () {
      expect(AiClient.parseSources({'choices': [{'message': {'content': 'x'}}]}), isEmpty);
      expect(AiClient.parseSources(null), isEmpty);
      expect(AiClient.parseSources('随便一段文字'), isEmpty);
      expect(AiClient.parseSources(const <String, Object>{}), isEmpty);
    });

    test('非 URL 的字符串不会被当成来源', () {
      expect(
        AiClient.parseSources({
          'citations': ['药品说明书', 'not-a-url', '/local/path'],
        }),
        isEmpty,
      );
    });

    test('畸形结构不抛异常（恶意/异常响应不能让 App 崩）', () {
      expect(
        () => AiClient.parseSources({
          'choices': 'not-a-list',
          'search_results': 'not-a-list',
          'citations': [123, null, {}, {'url': 456}],
        }),
        returnsNormally,
      );
    });
  });

  group('请求体：绝不带内置工具（带了也会被静默忽略）', () {
    // DeepSeek 开放平台的 `tools` 数组只接受 `type: "function"`，
    // 内置工具（web_search）**会被忽略**，而且不报错。
    // 所以带上它不但没用，还会让代码读起来像「试过联网了」。
    // 这里断言请求体里根本没有 tools 字段 —— 断了那条歧路的念想。

    test('普通请求里没有 tools 字段', () async {
      final fake = FakeHttpClient(
        body: '{"choices":[{"message":{"content":"ok"}}]}',
      );
      final client = AiClient(
        baseUrl: 'https://example.test',
        model: 'm',
        apiKey: 'k',
        client: fake,
      );
      await client.complete(
        system: 's',
        messages: const [
          {'role': 'user', 'content': 'q'},
        ],
      );
      expect(fake.bodies.single, isNot(contains('"tools"')));
      expect(fake.bodies.single, isNot(contains('web_search')));
    });

    test('请求体仍然是合法的 chat completions 结构', () async {
      final fake = FakeHttpClient(
        body: '{"choices":[{"message":{"content":"ok"}}]}',
      );
      final client = AiClient(
        baseUrl: 'https://example.test',
        model: 'm',
        apiKey: 'k',
        client: fake,
      );
      await client.complete(
        system: 'sys',
        messages: const [
          {'role': 'user', 'content': 'q'},
        ],
        temperature: 0,
      );
      final body = jsonDecode(fake.bodies.single) as Map<String, dynamic>;
      expect(body['model'], 'm');
      expect(body['temperature'], 0);
      final messages = body['messages'] as List;
      expect(messages.first, {'role': 'system', 'content': 'sys'});
      expect(messages.last, {'role': 'user', 'content': 'q'});
    });
  });
}

/// 极简的假 http 客户端：记录请求体、返回固定响应。
///
/// 只实现这里用到的方法。刻意**不**用 mockito —— 项目里其他测试也是手写假对象，
/// 保持一致，也免得为了一个测试引依赖（本机还是离线的）。
class FakeHttpClient extends http.BaseClient {
  FakeHttpClient({required this.body, this.statusCode = 200});

  final String body;
  final int statusCode;
  final bodies = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) bodies.add(request.body);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      statusCode,
    );
  }
}
