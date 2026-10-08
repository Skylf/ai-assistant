import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:family_life_assistant/ai/web_search.dart';
import 'package:family_life_assistant/data/store.dart';

import 'support/fake_http.dart';

/// 0.4F：DeepSeek 原生联网搜索。
///
/// ## 这一版为什么值得配这么多测试
///
/// 「联网查询」这个功能在本项目里**反复错了三次**：
///  ① 0.4D 往 chat/completions 发 `{"type":"web_search"}` —— 被**静默忽略**，
///     但我据此写了一条「降级并标注未真正联网核实」的分支，那条分支从未执行过；
///  ② 0.4E 我据此宣布「API 不支持联网，要接第三方」—— 只验证了一条路就下了全局结论；
///  ③ 0.4F 查 DSH 自己的实现才发现另有一个 Anthropic 兼容端点原生支持。
///
/// 三次里最贵的一课是：**「请求成功」不等于「联网发生了」**。
/// 所以下面第一组测试守的就是这一条 —— `searched` 必须来自服务端的
/// `web_search_tool_result` 块，而不是任何形式的推断。
void main() {
  /// 用 [MockClient.streaming] 造一个「假服务端」，直接控制 SSE 字节。
  AiWebSearchClient clientReturning(String sse, {int status = 200}) {
    final mock = MockClient.streaming(
      (request, bodyStream) async =>
          http.StreamedResponse(Stream<List<int>>.value(utf8.encode(sse)), status),
    );
    return AiWebSearchClient(apiKey: 'sk-test', client: mock);
  }

  group('请求形状：必须是 Anthropic 兼容的 Messages 请求', () {
    test('端点拼在 /messages 上（不是 /chat/completions）', () {
      final client = AiWebSearchClient(
        apiKey: 'k',
        baseUrl: 'https://api.deepseek.com/anthropic/v1',
      );
      expect(client.endpoint.path, '/anthropic/v1/messages');
      expect(client.endpoint.path, isNot(contains('chat/completions')));
    });

    test('【关键】带 web_search_20250305 服务器工具，而不是 web_search', () {
      final client = AiWebSearchClient(apiKey: 'k');
      final body = client.buildBody('查布洛芬');
      final tools = body['tools'] as List;
      final tool = tools.single as Map<String, Object?>;

      // ⚠️ 这里就是 0.4D 错的字面位置：写 `web_search` 会被服务端**静默忽略**。
      // 正确的 type 是带日期的版本号。
      expect(tool['type'], 'web_search_20250305');
      expect(tool['type'], isNot('web_search'));
      expect(tool['name'], 'web_search');
      expect(tool['max_uses'], isA<int>());
    });

    test('用 requests 流式请求（非流式就拿不到阶段事件）', () {
      final body = AiWebSearchClient(apiKey: 'k').buildBody('查布洛芬');
      expect(body['stream'], isTrue);
    });

    test('单条 user 消息，内容是 text 块', () {
      final body = AiWebSearchClient(apiKey: 'k').buildBody('查布洛芬');
      final messages = body['messages'] as List;
      final content = (messages.single as Map)['content'] as List;
      expect((content.single as Map)['type'], 'text');
      expect((content.single as Map)['text'], '查布洛芬');
    });

    test('模型名取用户配置，不写死', () {
      final body = AiWebSearchClient(apiKey: 'k', model: 'my-model')
          .buildBody('x');
      expect(body['model'], 'my-model');
    });
  });

  group('baseUrl 推导：聊天基址 → Anthropic 兼容基址', () {
    test('官方域名加上 /anthropic/v1', () {
      expect(
        AiWebSearchClient.anthropicBaseFrom('https://api.deepseek.com'),
        'https://api.deepseek.com/anthropic/v1',
      );
      // 带结尾斜杠也要对
      expect(
        AiWebSearchClient.anthropicBaseFrom('https://api.deepseek.com/'),
        'https://api.deepseek.com/anthropic/v1',
      );
    });

    test('已经填了 Anthropic 基址就原样保留（不重复追加）', () {
      expect(
        AiWebSearchClient.anthropicBaseFrom(
          'https://api.deepseek.com/anthropic/v1',
        ),
        'https://api.deepseek.com/anthropic/v1',
      );
    });

    test('【关键】非官方地址绝不擅自改写主机', () {
      // 用户可能用自建网关。把请求改到 api.deepseek.com 是**发到用户没指定的地方**，
      // 比联网失败严重得多。所以只做「已知官方域名」的映射，其余原样返回。
      expect(
        AiWebSearchClient.anthropicBaseFrom('https://my-gateway.internal/v1'),
        'https://my-gateway.internal/v1',
      );
    });
  });

  group('【关键】「联网了没有」必须由服务端证据决定', () {
    test('服务端返回 web_search_tool_result → searched=true，并拿到结构化来源', () async {
      final client = clientReturning(
        FakeHttpClient.webSearchReply(
          '布洛芬的用法用量是……',
          sources: const [
            'https://www.nmpa.gov.cn/datasearch/a.html',
            'https://dxy.com/medicine/7476',
          ],
        ),
      );

      final result = await client.search('查布洛芬');

      expect(result.ok, isTrue);
      expect(result.searched, isTrue);
      expect(result.answer, '布洛芬的用法用量是……');
      expect(result.sources.map((s) => s.url), [
        'https://www.nmpa.gov.cn/datasearch/a.html',
        'https://dxy.com/medicine/7476',
      ]);
    });

    test('【关键】服务端没返回检索块 → searched=false（不许凭「请求成功」就说联网了）', () async {
      // 这正是 0.4D 的错：请求 200、有正文，就以为联网发生了。
      final client = clientReturning(
        FakeHttpClient.webSearchReply('我凭已有知识回答……', searched: false),
      );

      final result = await client.search('查布洛芬');

      expect(result.ok, isTrue, reason: '请求确实成功了');
      expect(result.answer, isNotEmpty, reason: '正文确实有');
      expect(
        result.searched,
        isFalse,
        reason: '没有 web_search_tool_result 就是没联网 —— 这一条是 0.4D 事故的守门测试',
      );
      expect(result.sources, isEmpty);
    });

    test('结构化来源去重（同一 URL 出现两次只留一条）', () async {
      final client = clientReturning(
        FakeHttpClient.webSearchReply(
          'x',
          sources: const [
            'https://dxy.com/medicine/7476',
            'https://dxy.com/medicine/7476',
            'https://a.com/1',
          ],
        ),
      );
      final result = await client.search('x');
      expect(result.sources.map((s) => s.url).toSet(), {
        'https://dxy.com/medicine/7476',
        'https://a.com/1',
      });
      expect(result.sources.length, 2);
    });

    test('绝不从正文里抓 URL：正文有链接但无检索块时来源仍为空', () async {
      // 正文里的 URL 可能是模型编的；结构化块才是服务端真实检索的结果。
      final client = clientReturning(
        FakeHttpClient.webSearchReply(
          '参见 https://fake-made-up.example.com/not-real 的说明',
          searched: false,
        ),
      );
      final result = await client.search('x');
      expect(result.sources, isEmpty);
      expect(result.searched, isFalse);
    });

    test('来源带上了标题（便于用户判断那是什么站）', () async {
      final client = clientReturning(
        FakeHttpClient.webSearchReply(
          'x',
          sources: const ['https://www.nmpa.gov.cn/a.html'],
        ),
      );
      final result = await client.search('x');
      expect(result.sources.single.title, isNotEmpty);
    });
  });

  group('阶段提示：必须是真实事件驱动（界面「正在联网搜索」的依据）', () {
    test('【关键】联网时依次收到 思考 → 搜索 → 整理', () async {
      final phases = <SearchPhase>[];
      final client = clientReturning(
        FakeHttpClient.webSearchReply('答案', sources: const ['https://a.com']),
      );

      await client.search('x', onPhase: phases.add);

      expect(phases, [
        SearchPhase.thinking,
        SearchPhase.searching,
        SearchPhase.composing,
      ]);
      expect(SearchPhase.searching.label, contains('联网搜索'));
    });

    test('【关键】没联网时就**不该**出现「正在联网搜索」', () async {
      // 用户要求「思考文字要体现出正在联网搜索」——
      // 反过来说：**没在搜的时候绝不能显示在搜**。否则又是 0.4D 那种假状态。
      final phases = <SearchPhase>[];
      final client = clientReturning(
        FakeHttpClient.webSearchReply('凭已有知识答', searched: false),
      );

      await client.search('x', onPhase: phases.add);

      expect(
        phases,
        isNot(contains(SearchPhase.searching)),
        reason: '服务端没搜，界面就不许说在搜',
      );
      expect(phases, contains(SearchPhase.thinking));
      expect(phases.first, SearchPhase.thinking);
    });

    test('搜索阶段只报一次（不因多个 server_tool_use 块而刷屏）', () async {
      final phases = <SearchPhase>[];
      // 真实响应里 max_uses>1 时会有多个 server_tool_use 块
      final sse = FakeHttpClient.webSearchReply(
        '答案',
        sources: const ['https://a.com'],
      ).replaceFirst(
        'event: content_block_start',
        'event: content_block_start\n'
            'data: {"type":"content_block_start","index":9,"content_block":{"type":"server_tool_use","name":"web_search"}}\n'
            '\n'
            'event: content_block_start',
      );
      final client = clientReturning(sse);

      await client.search('x', onPhase: phases.add);

      expect(
        phases.where((p) => p == SearchPhase.searching).length,
        1,
        reason: '同一阶段重复回调会让界面文案闪动',
      );
    });
  });

  group('失败要说得出原因（0.4D「显示暂无」的教训）', () {
    test('没配 Key 时不发请求，直接说清楚', () async {
      final client = AiWebSearchClient(apiKey: '  ');
      final result = await client.search('x');
      expect(result.ok, isFalse);
      expect(result.error, contains('API Key'));
    });

    test('空查询不发请求', () async {
      final result = await AiWebSearchClient(apiKey: 'k').search('   ');
      expect(result.ok, isFalse);
      expect(result.error, contains('空'));
    });

    test('401 → 告诉用户去哪改，且带上状态码', () async {
      final client = clientReturning('', status: 401);
      final result = await client.search('x');
      expect(result.ok, isFalse);
      expect(result.error, contains('401'));
      expect(result.error, contains('API Key'));
    });

    test('404 → 指出这是端点问题（联通网检索走的是另一个端点）', () async {
      final client = clientReturning('', status: 404);
      final result = await client.search('x');
      expect(result.error, contains('404'));
      expect(result.error, contains('anthropic'));
    });

    test('服务端 error 事件被翻译出来，不吞掉', () async {
      final client = clientReturning(
        'event: error\n'
        'data: {"type":"error","error":{"type":"overloaded_error","message":"服务过载"}}\n'
        '\n',
      );
      final result = await client.search('x');
      expect(result.ok, isFalse);
      expect(result.error, contains('服务过载'));
    });

    test('完全没有事件（空响应）→ 明确报「服务端没有返回内容」', () async {
      final client = clientReturning('');
      final result = await client.search('x');
      expect(result.ok, isFalse);
      expect(result.error, contains('没有返回内容'));
    });

    test('畸形 JSON 的心跳不会中断整条流', () async {
      // 真实服务端会发 ping / 非 JSON 心跳。解析失败必须当「没有 payload」，
      // 而不是抛异常把整条流带崩 —— 那样用户会看到「搜索失败」，其实只是少读一个心跳。
      final client = clientReturning(
        'event: ping\n'
        'data: not-json-at-all\n'
        '\n'
        '${FakeHttpClient.webSearchReply('答案', sources: const ['https://a.com'])}',
      );
      final result = await client.search('x');
      expect(result.ok, isTrue);
      expect(result.answer, '答案');
      expect(result.searched, isTrue);
    });
  });

  group('来源可信度分级（用户要求「来源一定要权威」）', () {
    test('政府域名算官方', () {
      expect(
        tierOfSource('https://www.nmpa.gov.cn/datasearch/a.html'),
        SourceTier.official,
      );
      expect(tierOfSource('https://www.nhc.gov.cn/x'), SourceTier.official);
    });

    test('医院/药企算机构', () {
      expect(
        tierOfSource('https://www.dgphospital.com/ypsms/a.shtml'),
        SourceTier.institutional,
      );
      expect(tierOfSource('http://www.rdpharma.cn/info/33.html'),
          SourceTier.institutional);
    });

    test('【关键】卖药站与资讯站只能算「其他」', () {
      // 实测查「布洛芬缓释胶囊」16 条结果里 14 条是这类站点。
      // 不给它们降级标注，用户会以为和药监局一样可信。
      for (final url in [
        'https://dxy.com/medicine/7476',
        'https://ypk.39.net/xiyao/33535.html',
        'http://zjhpyy.com/goods/56202.jhtml',
        'https://buy.yfdyf.com/m/health/detail/3158/52.html',
      ]) {
        expect(tierOfSource(url), SourceTier.general, reason: url);
      }
    });

    test('无法解析的地址不崩，算「其他」', () {
      expect(tierOfSource('不是网址'), SourceTier.general);
      expect(tierOfSource(''), SourceTier.general);
    });

    test('【关键】排序把官方提到最前，且同级保持原顺序（稳定）', () {
      const list = [
        WebSource(url: 'https://dxy.com/1'),
        WebSource(url: 'https://ypk.39.net/2'),
        WebSource(url: 'https://www.nmpa.gov.cn/3'),
        WebSource(url: 'https://www.dgphospital.com/4'),
        WebSource(url: 'https://a.com/5'),
      ];
      final ranked = rankSources(list);
      expect(ranked.map((s) => s.url), [
        'https://www.nmpa.gov.cn/3', // 官方
        'https://www.dgphospital.com/4', // 机构
        'https://dxy.com/1', // 其他：保持原始相对顺序
        'https://ypk.39.net/2',
        'https://a.com/5',
      ]);
    });

    test('排序不改动传入的列表（避免调用方看到意外变化）', () {
      const original = [WebSource(url: 'https://dxy.com/1')];
      final before = List.of(original);
      rankSources(original);
      expect(original, before);
    });

    test('搜索结果里的来源已经排好序', () async {
      final client = clientReturning(
        FakeHttpClient.webSearchReply(
          'x',
          sources: const [
            'https://dxy.com/1',
            'https://www.nmpa.gov.cn/2',
          ],
        ),
      );
      final result = await client.search('x');
      expect(result.sources.first.tier, SourceTier.official);
    });
  });

  group('主对话的请求正文：系统提示词与历史都要进去', () {
    test('三段标记齐全，最后一条用户消息在末尾', () {
      final query = Store.buildChatSearchQuery(
        system: '【系统设定内容】只处理最后一条。',
        history: const [
          {'role': 'user', 'content': '今天买菜20'},
          {'role': 'assistant', 'content': '好的。'},
          {'role': 'user', 'content': '那药呢'},
        ],
      );

      expect(query, contains('【系统设定】'));
      expect(query, contains('只处理最后一条。'));
      expect(query, contains('【对话】'));
      expect(query, contains('用户：今天买菜20'));
      expect(query, contains('助手：好的。'));
      expect(query, contains('【要求】'));
      // 最后一条用户消息必须是整体里最后出现的对话内容
      expect(query.indexOf('用户：那药呢'), greaterThan(query.indexOf('助手：好的。')));
    });

    test('【关键】明确要求「不需要外部信息就别搜」（避免每次都白花一次检索）', () {
      final query = Store.buildChatSearchQuery(
        system: 's',
        history: const [
          {'role': 'user', 'content': 'q'},
        ],
      );
      expect(query, contains('不要为了搜索而搜索'));
      expect(query, contains('记账'));
    });

    test('空历史也不崩', () {
      final query = Store.buildChatSearchQuery(system: 's', history: const []);
      expect(query, contains('【系统设定】'));
      expect(query, contains('【要求】'));
    });
  });
}
