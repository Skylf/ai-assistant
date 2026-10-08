import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 一次 AI 调用的结果。用显式类型取代旧代码里「把异常文案当回复返回」的做法。
class AiResult {
  /// 通用构造：`error == null` 即成功。0.4F 新增，供联网搜索路径组装结果。
  const AiResult({
    required this.text,
    this.sources = const [],
    this.searched = false,
    this.error,
  }) : ok = error == null,
       cancelled = false;

  const AiResult.success(
    this.text, {
    this.sources = const [],
    this.searched = false,
  }) : ok = true,
       cancelled = false,
       error = null;
  const AiResult.failure(this.error)
    : ok = false,
      cancelled = false,
      searched = false,
      text = '',
      sources = const [];

  /// 用户主动暂停。
  ///
  /// 必须与 [failure] 分开：`package:http` **不支持取消**，暂停是靠「等回来
  /// 也丢掉」实现的，此时请求本身很可能完全成功。如果把它归进 failure，
  /// 用户会看到「AI 服务调用失败：…」——明明是**他自己**点的暂停，
  /// 却收到一条报错，会以为把 App 点坏了。
  const AiResult.cancelled()
    : ok = false,
      cancelled = true,
      searched = false,
      text = '',
      sources = const [],
      error = null;

  final bool ok;
  final String text;
  final String? error;
  final bool cancelled;

  /// 服务端返回的引用来源（0.4D 引入，0.4F 起真的会有值）。
  ///
  /// 0.4F 之前这个字段**永远是空的**：那时走 `chat/completions`，
  /// 而那条路没有联网能力。0.4F 换到 Anthropic 兼容 `/messages`
  /// （[AiWebSearchClient]）之后，联网检索到的真实 URL 会填进来。
  ///
  /// [parseSources] 仍然保留：它解析的是 OpenAI 风格的 `annotations[]`，
  /// 与 Anthropic 的 `web_search_tool_result` 是两套结构，各管一条路。
  final List<String> sources;

  /// **是否真的发生了联网检索**（0.4F）。
  ///
  /// 依据是服务端返回了 `web_search_tool_result`，**不是**「请求成功了」。
  /// 界面只有在它为 true 时才允许写「联网检索」—— 这是 0.4D 那一课的直接产物。
  final bool searched;

  /// 展示给用户的文案（成功为正文，失败为可读的错误说明）。
  String get display => ok ? text : _describe(error!);

  /// 把异常文本翻译成用户能看懂、且不泄露密钥的说明。
  static String _describe(String error) {
    if (error.contains('401')) {
      return 'API Key 无效或已过期，请在「设置 → API 配置」中重新填写。';
    }
    if (error.contains('404')) {
      return '服务地址或模型名不正确（404）：'
          '请到「设置 → AI 服务」点「获取可用模型」拉取该地址下真实可用的模型名。';
    }
    if (error.contains('400')) {
      return '请求被拒绝（400）：常见的两个原因是模型名写错、或该模型不支持当前参数。'
          '请到「设置 → AI 服务」点「获取可用模型」核对模型名。';
    }
    if (error.contains('402')) {
      return '账户余额不足，请前往服务商充值。';
    }
    if (error.contains('429')) {
      return '请求过于频繁或额度用尽，请稍后重试。';
    }
    if (error.contains('SocketException') ||
        error.contains('Failed host lookup')) {
      return '无法连接 AI 服务，请检查网络与 API Base URL。';
    }
    if (error.contains('TimeoutException')) {
      return 'AI 服务响应超时，请稍后重试。';
    }
    return 'AI 服务调用失败：$error';
  }
}

/// 「暂停 AI 回复」用的取消令牌。
///
/// ## 为什么是「丢弃」而不是「中断」
///
/// `package:http` 的 `Client.post` **没有取消能力**（`http` 包至今没有
/// `CancelToken`，这与 Dio 不同）。要真正中断只有两条路：
///  ① `Client.close()`：会连带作废这个 client 上**所有**在途请求，
///     而 Store 的 client 是共享的，还可能缓存着连接池；
///  ② 换成 Dio/自定义 socket：为一个暂停功能引依赖，本机还离线装不了。
///
/// 所以这里做成「**乐观取消**」：点了暂停就立刻停止等待、把这次请求作废，
/// 回到可输入状态；已经发出去的 HTTP 请求让它在后台自然结束，结果被丢弃。
///
/// 对用户的体验差别在于：省下的是**等待**，不是流量。所以 UI 上的措辞是
/// 「已暂停」而不是「已取消请求」——不承诺做不到的事。
class AskCancelToken {
  bool _cancelled = false;

  /// 是否已被取消。调用方在关键节点检查它。
  bool get cancelled => _cancelled;

  /// 请求取消。重复调用无副作用。
  void cancel() => _cancelled = true;
}

/// 兼容 OpenAI Chat Completions 的最小客户端。
class AiClient {
  AiClient({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 45),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String model;
  final String apiKey;
  final Duration timeout;
  final http.Client _client;

  /// 拼接 `/chat/completions`，兼容用户填写带或不带结尾斜杠的 Base URL。
  Uri get endpoint {
    final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$base/chat/completions');
  }

  /// 拼接 `/models`，用于拉取服务商当前真实可用的模型列表。
  Uri get modelsEndpoint {
    final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$base/models');
  }

  static const defaultBaseUrl = 'https://api.deepseek.com';

  /// 默认模型名。
  ///
  /// 这一项是「兜底」而不是「事实来源」：模型名由服务商决定，随时可能新增或
  /// 改名，写死在客户端里迟早会过期（0.2C 的 `deepseek-flash` 就是这么报废的）。
  /// 因此设置页提供「获取可用模型」，直接问服务商要列表，避免靠猜。
  ///
  /// 关于 `deepseek-flash`：曾经有一条注释断言「它在开放平台上并不存在」，
  /// 并据此在读取设置时把用户存的 `deepseek-flash` **静默改写成**默认值。
  /// **那条断言是错的** —— 真机《获取可用模型》拉回来的列表里就有
  /// `deepseek-flash` 与 `deepseek-v4-pro`。静默改写用户手选的有效模型名，
  /// 会让界面显示一个该服务商没有的名字并持续 404，且用户无从察觉。
  /// 该迁移已删除。
  ///
  /// **不要再凭听说去改这一个常量，也不要写死任何模型名对照表。**
  /// 开发环境无法联网核实服务商当前的模型 id，改错就是全量 404。
  /// 模型名以「设置 → AI 服务 → 获取可用模型」拉回来的列表为准（那是服务商
  /// 自己的回答）；接口在模型名不对时返回的 400/404 文案也会把用户导向那个按钮。
  ///
  /// 默认值取 `deepseek-flash`（用户指定）。它与界面上的「v4.1 flash」是
  /// **同一个模型，只是叫法不同**，而 `deepseek-flash` 是接口 `/models`
  /// **真实返回的名字** —— 以接口为准，不用别名。
  static const defaultModel = 'deepseek-flash';

  /// 这个 App 不需要的模型：**贵且没有收益**。
  ///
  /// 用户原话：「不支持 pro（因为这点货不需要更贵的 pro）」。
  /// 一个家庭记账 + 药箱的助手，Pro 级别的推理能力换不来更好的结果，
  /// 却会按 Pro 计费 —— 所以**不让它出现在可选项里**，从源头上避免误点。
  ///
  /// 判据用「名字里含 `pro`」而不是写死 `deepseek-v4-pro`：
  /// 服务商改版本号时（`deepseek-v5-pro`）这条规则仍然成立，
  /// 而写死的名字会**悄悄失效** —— 胶囊又冒出来，用户又可能点到贵的那个。
  static bool isUnsupportedModel(String id) =>
      id.toLowerCase().contains('pro');

  /// 从服务商给的模型列表里挑出**本 App 该显示的**那些。
  ///
  /// 两层过滤，缺一不可：
  ///  ① 去掉 [isUnsupportedModel]（Pro 之类）；
  ///  ② 结果为空时**回退到原列表** —— 万一哪天服务商只剩 Pro，
  ///     至少还能选；显示一个空列表等于把用户堵死在设置页。
  static List<String> selectableModels(List<String> all) {
    final cheap = all.where((m) => !isUnsupportedModel(m)).toList();
    return cheap.isEmpty ? all : cheap;
  }

  /// 在可选模型里挑一个**最该当默认值**的。
  ///
  /// 优先 `deepseek-flash`（用户指定、也是接口真实名字），
  /// 其次任何含 `flash` 的（便宜档），再其次第一个。
  ///
  /// 为什么要有这个：如果用户当前存的是 `deepseek-v4-pro`（老版本界面上点过），
  /// 它已经从可选列表里消失了，但输入框里还留着那个值 ——
  /// 会出现「显示着一个列表里没有的名字」这种说不通的状态。
  /// 用这个函数把它拉回一个**确实存在且不该贵**的模型。
  static String preferredModel(List<String> selectable) {
    if (selectable.isEmpty) return defaultModel;
    if (selectable.contains(defaultModel)) return defaultModel;
    final flash = selectable.where((m) => m.toLowerCase().contains('flash'));
    if (flash.isNotEmpty) return flash.first;
    return selectable.first;
  }

  /// 拉取可用模型列表。返回 null 表示没有可用的模型信息（网络/鉴权/格式问题）。
  Future<List<String>?> listModels() async {
    if (apiKey.trim().isEmpty) return null;
    try {
      final response = await _client
          .get(
            modelsEndpoint,
            headers: {'Authorization': 'Bearer ${apiKey.trim()}'},
          )
          .timeout(timeout);
      return parseModelIds(response);
    } on Exception {
      return null;
    }
  }

  /// 从 `/models` 响应里取出模型 id，按字母序去重。
  ///
  /// 故意做成可见的纯函数，便于离线测试各种畸形响应。
  ///
  /// 只接受**字符串**形式的 id：OpenAI 兼容格式是 `{"id": "deepseek-chat"}`。
  /// 早先这里写的是 `item['id']?.toString()`，于是 `{"id": 123}`、`{"id": {}}`、
  /// `{"id": []}`、`{"id": true}` 都会被转成 `123` / `{a: 1}` / `[]` / `true`
  /// 并渲染成可点的模型胶囊 —— 用户点一下就把垃圾写进模型名，再用它去发请求。
  @visibleForTesting
  static List<String>? parseModelIds(http.Response response) {
    if (response.statusCode < 200 || response.statusCode > 299) return null;
    try {
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (decoded is! Map) return null;
      final data = decoded['data'];
      if (data is! List) return null;
      final ids = <String>{};
      for (final item in data) {
        if (item is! Map) continue;
        final raw = item['id'];
        if (raw is! String) continue;
        final id = raw.trim();
        // 长度上限：畸形/恶意响应可能塞进几 MB 的字符串，渲染出来会把布局撑爆
        if (id.isEmpty || id.length > _maxModelIdLength) continue;
        ids.add(id);
      }
      final sorted = ids.toList()..sort();
      return sorted.isEmpty ? null : sorted;
    } on FormatException {
      return null;
    }
  }

  /// 模型 id 的合理长度上限。真实模型名都在 100 字符以内。
  static const _maxModelIdLength = 200;

  /// 发一次对话补全请求。
  ///
  /// ## 为什么这里没有「联网搜索」开关（0.4D 结论）
  ///
  /// 0.4D 一开始给这个方法加过 `webSearch` 参数，发 `{"type": "web_search"}`。
  /// 真机实测「查不到、也没报错」，查证后确认那条路**根本不可能生效**：
  /// DeepSeek 开放平台《创建响应》文档里 `tools` 数组的 `type`
  /// **只允许 `function` 一个值**，并原话写明「**内置工具类型会被忽略**」。
  /// （产品端网页/App 的「联网搜索」是另一套，API 不提供。）
  ///
  /// 「被忽略」比「被拒绝」更糟：请求成功、HTTP 200，只是联网没发生。
  /// 于是代码里那个参数**没有任何作用，却让调用方以为试过联网了** ——
  /// 这正是 0.4D 把那一步写成「降级并标注未联网核实」的依据，
  /// 而实际上**从头到尾都没有联网过**，标注的分支是个谎言。
  ///
  /// 所以这个参数已被删除。现在的做法是：
  ///  · 不假装联网，如实说明来源是**模型已有知识**；
  ///  · 需要「权威来源」时走真正权威的路 —— 见 `core/med_info.dart`，
  ///    它提供国家药监局（NMPA）查询入口，让用户拿着药名去官方库核对。
  ///
  /// 将来若服务商真的提供了可用的服务端检索，再加回来，并**先用一次真实请求验证**。
  Future<AiResult> complete({
    required String system,
    required List<Map<String, String>> messages,
    double temperature = 0.3,
  }) async {
    if (apiKey.trim().isEmpty) {
      return const AiResult.failure('尚未配置 API Key');
    }
    try {
      final response = await _client
          .post(
            endpoint,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${apiKey.trim()}',
            },
            body: jsonEncode({
              'model': model.trim(),
              'temperature': temperature,
              'messages': [
                {'role': 'system', 'content': system},
                ...messages,
              ],
            }),
          )
          .timeout(timeout);
      return parse(response);
    } on Exception catch (e) {
      return AiResult.failure('$e');
    }
  }

  /// 从响应里取出正文。故意做成可见的 @visibleForTesting 纯函数，便于离线测试。
  @visibleForTesting
  static AiResult parse(http.Response response) {
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode < 200 || response.statusCode > 299) {
      return AiResult.failure('HTTP ${response.statusCode}：${_short(body)}');
    }
    try {
      final decoded = jsonDecode(body);
      final choices = (decoded is Map) ? decoded['choices'] : null;
      if (choices is! List || choices.isEmpty) {
        return const AiResult.failure('服务返回内容缺少 choices 字段');
      }
      final message = (choices.first is Map) ? choices.first['message'] : null;
      final content = (message is Map) ? message['content'] : null;
      final text = content?.toString().trim() ?? '';
      if (text.isEmpty) return const AiResult.failure('服务返回了空回复');
      return AiResult.success(text, sources: parseSources(decoded));
    } on FormatException catch (e) {
      return AiResult.failure('响应不是合法 JSON：${e.message}');
    }
  }

  /// 从响应里取出服务端返回的引用来源。
  ///
  /// ⚠️ **当前没有任何调用路径会产生来源**（见 [AiResult.sources] 的说明）。
  /// 保留它是因为解析逻辑本身是独立且有价值的：将来服务商真提供了服务端检索，
  /// 这里已经就绪，并有完整测试。
  ///
  /// 各家字段名不统一，所以同时看三种已知形状（都不在就当没有来源）：
  ///  ① `choices[0].message.annotations[]` 里 `type == 'url_citation'`
  ///     的 `url_citation.url`（OpenAI / DeepSeek 的引用写法）；
  ///  ② `choices[0].message.web_search_results[]` 的 `url`；
  ///  ③ 顶层 `search_results[]` / `citations[]` 的 `url` 或裸字符串。
  ///
  /// **解析不到就返回空列表，绝不编造** —— 来源区显示假 URL 比显示「暂无」
  /// 危险得多，用户会因此以为内容经过核实。
  @visibleForTesting
  static List<String> parseSources(Object? decoded) {
    if (decoded is! Map) return const [];
    final urls = <String>[];

    void take(Object? node) {
      if (node is String) {
        final s = node.trim();
        if (s.startsWith('http')) urls.add(s);
        return;
      }
      if (node is! Map) return;
      for (final key in const ['url', 'link', 'uri', 'source']) {
        final v = node[key];
        if (v is String && v.trim().startsWith('http')) urls.add(v.trim());
      }
      // url_citation 是包一层 {"type": ..., "url_citation": {...}} 的形状
      final nested = node['url_citation'];
      if (nested != null) take(nested);
    }

    void takeList(Object? node) {
      if (node is! List) return;
      for (final item in node) {
        take(item);
      }
    }

    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final message = (choices.first as Map)['message'];
      if (message is Map) {
        takeList(message['annotations']);
        takeList(message['web_search_results']);
        takeList(message['citations']);
      }
    }
    takeList(decoded['search_results']);
    takeList(decoded['citations']);

    // 去重且保持出现顺序：同一来源在多个字段里重复出现是常态。
    final seen = <String>{};
    return [
      for (final u in urls)
        if (seen.add(u)) u,
    ];
  }

  void close() => _client.close();

  static String _short(String body) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 200 ? flat : '${flat.substring(0, 200)}…';
  }
}
