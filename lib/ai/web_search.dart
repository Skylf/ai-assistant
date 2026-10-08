import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'client.dart';

/// DeepSeek 原生联网搜索（0.4F）。
///
/// ## 为什么是「另一个端点」，而不是给现有请求加个参数
///
/// 0.4D 曾往 `chat/completions` 里加 `{"type":"web_search"}`，结果**被静默忽略**：
/// HTTP 200、正常返回，只是联网没发生。查证后确认那是死路。
///
/// 真正能联网的是 DeepSeek 的 **Anthropic 兼容 Messages 端点**：
///
/// | | 聊天 | 联网搜索 |
/// |---|---|---|
/// | 路径 | `/chat/completions` | `/anthropic/v1/messages` |
/// | 协议 | OpenAI 兼容 | Anthropic 兼容 |
/// | 联网 | 无 | `web_search_20250305` 服务端工具 |
///
/// 这个差别是 **DSH 自己的实现**（`@deepseek-ai/dsh-web-search-deepseek`）
/// 里写明的，其注释原话：
/// 「Default endpoint: DeepSeek's Anthropic-compatible API, `/v1` included
/// (`/messages` is appended). **This is NOT the chat-completions base**」。
///
/// ⚠️ **只对官方 `api.deepseek.com` 有效**。走中转/网关时这个服务端工具
/// 很可能被丢掉，而且同样是静默的。所以这里**要求真实观测**：
/// 拿不到 `web_search_tool_result` 就如实说「没有联网」，不假装搜过。
///
/// ## 为什么用流式
///
/// 用户明确要求「思考文字要体现出正在联网搜索」。非流式的话，界面上那句话
/// 只是**在请求开始前猜一个**，等请求回来才知道到底搜没搜 —— 那是撒谎。
/// 流式能看到真实的阶段事件：
///  · `content_block_start` 里出现 `server_tool_use` → **真的在搜了**
///  · `web_search_tool_result` 到达 → 拿到了来源
///  · `text` 开始出现 → 正在组织答案
///
/// 界面上显示的每一句都对应一个**真实收到的服务端事件**。

/// 请求进行中的真实阶段，供界面显示「正在做什么」。
enum SearchPhase {
  /// 已发出请求，还没收到任何阶段信息。
  thinking('正在思考…'),

  /// 收到了 `server_tool_use` —— 服务端真的在联网检索。
  searching('正在联网搜索…'),

  /// 检索结果已回来，模型在组织回答。
  composing('正在整理资料…');

  const SearchPhase(this.label);

  final String label;
}

/// 来源可信度的分级。
///
/// ## 为什么必须做这件事
///
/// 用户对 0.4D 的原话是「信息来源一定要**可靠准确权威**」。
/// 联网确实能查到东西，但实测一轮「布洛芬缓释胶囊」的结果是：
/// 医院/药企说明书页 2 条，剩下 14 条是**卖药电商、健康资讯站、药房商城**。
/// 也就是说——**「联网查到了」不等于「查到了权威来源」**。
///
/// 只把 URL 列出来而不区分，用户会默认它们同等可信。所以这里按域名分级，
/// 界面上把级别写出来，让用户自己判断该信哪一条。
enum SourceTier {
  /// 药监局、卫健委等**官方**域名。
  official('官方'),

  /// 医院、药企官网：一手说明书来源。
  institutional('机构/厂家'),

  /// 其他（资讯站、电商、百科等）。**数量最多，但可信度最低**。
  general('其他网站');

  const SourceTier(this.label);

  final String label;
}

/// 判断一条来源属于哪一级。
///
/// 用**域名后缀 + 明确关键词**而不是硬编码具体站点：硬编码会过时，
/// 而 `gov.cn` 这类后缀是稳定且权威的判据。
///
/// ⚠️ 关键词**必须够长、够明确**，否则会误判。
/// 这里踩过一次：早先的列表里有 `'yy'`，于是 `dxy.com`（丁香园，商业资讯站）
/// 因为含子串 `'yy'` 被判成了「机构/厂家」——**把最需要降级标注的那类站点
/// 抬成了高可信**，正好和这个分级要解决的问题相反。
/// 现在只留 `hospital` / `pharm` / `yiyuan` 这类不会被普通域名碰巧命中的词。
SourceTier tierOfSource(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return SourceTier.general;

  // 官方：政府域名（nmpa.gov.cn 药监局、nhc.gov.cn 卫健委等）
  if (host.endsWith('.gov.cn') || host.endsWith('.gov')) {
    return SourceTier.official;
  }
  // 机构/厂家：医院与药企官网。词长得够怪，不会被资讯站碰上。
  const institutional = ['hospital', 'pharm', 'yiyuan', 'medcenter'];
  if (institutional.any(host.contains)) return SourceTier.institutional;

  return SourceTier.general;
}

/// 按可信度给来源排序：官方 → 机构/厂家 → 其他。
///
/// **稳定排序**：同级内部保持服务端返回的原始顺序（服务端已按相关性排过），
/// 不要用不稳定的排序把相关性也打乱。
List<WebSource> rankSources(List<WebSource> sources) {
  final ranked = List<WebSource>.of(sources);
  int order(WebSource s) => tierOfSource(s.url).index;
  // 插入排序：稳定，且来源条数很少（十几条），性能无所谓。
  for (var i = 1; i < ranked.length; i++) {
    final current = ranked[i];
    var j = i - 1;
    while (j >= 0 && order(ranked[j]) > order(current)) {
      ranked[j + 1] = ranked[j];
      j--;
    }
    ranked[j + 1] = current;
  }
  return ranked;
}

/// 一条联网来源。
@immutable
class WebSource {
  const WebSource({required this.url, this.title = ''});

  final String url;
  final String title;

  SourceTier get tier => tierOfSource(url);

  @override
  bool operator ==(Object other) =>
      other is WebSource && other.url == url && other.title == title;

  @override
  int get hashCode => Object.hash(url, title);
}

/// 一次联网搜索调用的结果。
@immutable
class WebSearchResult {
  const WebSearchResult({
    this.answer = '',
    this.sources = const [],
    this.searched = false,
    this.error,
  });

  /// 模型最终给出的正文。
  final String answer;

  /// 服务端返回的真实来源（去重）。
  final List<WebSource> sources;

  /// **是否真的发生了联网检索**（收到了 `web_search_tool_result`）。
  ///
  /// 这个字段是整个模块的诚实底线：只有它为 true，界面才可以写「联网检索」。
  /// 只凭「请求成功」就宣称联网过，正是 0.4D 犯过的错。
  final bool searched;

  /// 失败原因。为 null 表示成功。
  final String? error;

  bool get ok => error == null;
}

/// DeepSeek 联网搜索客户端。
///
/// 与 [AiClient] 分开是因为：**端点、协议、请求体、响应体全都不一样**。
/// 硬塞进 `AiClient.complete` 会让一个「OpenAI 兼容聊天」的方法长出一套
/// Anthropic 分支，两边都变得难读。
class AiWebSearchClient {
  AiWebSearchClient({
    required this.apiKey,
    /// Anthropic 兼容基址。**不是** chat-completions 的基址。
    this.baseUrl = 'https://api.deepseek.com/anthropic/v1',
    this.model = 'deepseek-v4-flash',
    this.apiVersion = '2023-06-01',
    this.maxTokens = 4096,
    this.maxUses = 5,
    this.timeout = const Duration(seconds: 60),
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;
  final String baseUrl;
  final String model;
  final String apiVersion;
  final int maxTokens;

  /// 单次请求最多用几次搜索。服务端工具自己的旋钮（没有「结果条数」选项）。
  final int maxUses;

  final Duration timeout;
  final http.Client _client;

  /// 官方端点才支持这个服务端工具；非官方地址由调用方决定是否仍然尝试。
  static const officialHost = 'api.deepseek.com';

  /// 从用户在「API 配置」里填的 **chat-completions** 基址，推出 Anthropic 兼容基址。
  ///
  /// 两个基址**不一样**，这是整件事最容易搞错的地方：
  ///  · 聊天：`https://api.deepseek.com`          → `/chat/completions`
  ///  · 搜索：`https://api.deepseek.com/anthropic/v1` → `/messages`
  ///
  /// 用户只会填一个（聊天的那个）。所以这里做一次映射：
  ///  · 官方域名 → 换成 `/anthropic/v1`
  ///  · 已经带了 `/anthropic` 的 → 原样保留（用户可能自己填对了）
  ///  · 其他（中转/自建）→ 原样返回，让它去撞，撞不通就如实报错
  ///
  /// **不硬编码 `api.deepseek.com`**：用户可以换服务商，硬编码会让它悄悄
  /// 去连一个不是他配的地址 —— 那是把请求发到用户没指定的地方，不可接受。
  static String anthropicBaseFrom(String chatBaseUrl) {
    final base = chatBaseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.isEmpty) return 'https://$officialHost/anthropic/v1';
    // 用户已经填了 Anthropic 基址
    if (base.contains('/anthropic')) return base;
    final uri = Uri.tryParse(base);
    if (uri != null && uri.host.toLowerCase() == officialHost) {
      return '$base/anthropic/v1';
    }
    // 非官方地址：原样返回，不擅自改写用户配置的目标主机。
    return base;
  }

  /// `POST {baseUrl}/messages`
  Uri get endpoint {
    final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$base/messages');
  }

  /// 构造请求体。抽成纯函数便于断言**发出去的到底是什么**。
  @visibleForTesting
  Map<String, Object?> buildBody(String query) => {
    'model': model.trim(),
    'max_tokens': maxTokens,
    'messages': [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': query},
        ],
      },
    ],
    // 服务器工具：由服务端执行检索，结果以结构化块返回。
    // 注意 `type` 是带日期的版本号，不是 `web_search`。
    'tools': [
      {'type': 'web_search_20250305', 'name': 'web_search', 'max_uses': maxUses},
    ],
    'stream': true,
  };

  /// 发一次联网搜索请求，边收边回调 [onPhase]。
  ///
  /// [onPhase] 只会收到**真实发生**的阶段（见 [SearchPhase] 说明）。
  Future<WebSearchResult> search(
    String query, {
    void Function(SearchPhase phase)? onPhase,
    void Function(List<WebSource> sources)? onSources,
    AskCancelToken? cancel,
  }) async {
    if (apiKey.trim().isEmpty) {
      return const WebSearchResult(error: '尚未配置 API Key');
    }
    if (query.trim().isEmpty) {
      return const WebSearchResult(error: '查询内容为空');
    }

    onPhase?.call(SearchPhase.thinking);

    final request = http.Request('POST', endpoint)
      ..headers.addAll({
        'x-api-key': apiKey.trim(),
        'authorization': 'Bearer ${apiKey.trim()}',
        'anthropic-version': apiVersion,
        'content-type': 'application/json',
        'accept': 'text/event-stream',
      })
      ..body = jsonEncode(buildBody(query));

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on Exception catch (e) {
      return WebSearchResult(error: _describe(e));
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 把服务端的话带回来 —— 「静默失败」正是 0.4D 的教训。
      final body = await _readAll(response.stream);
      return WebSearchResult(error: _describeStatus(response.statusCode, body));
    }

    final text = StringBuffer();
    final sources = <WebSource>[];
    final seen = <String>{};
    var searched = false;
    var announcedSearching = false;
    var announcedComposing = false;

    try {
      await for (final event in _sseEvents(response.stream).timeout(timeout)) {
        if (cancel?.cancelled ?? false) {
          return const WebSearchResult(error: '已暂停');
        }
        // ⚠️ 必须先 jsonDecode：`event.data` 是**原始 JSON 字符串**。
        // 早先这里直接把字符串当 map 取字段，`value is Map` 恒为 false，
        // 于是每个事件都解析成 null、最终报「服务端没有返回内容」——
        // 而日志里明明看得出 `content_block_start` 收到了。
        final payload = _parseEvent(event.data);
        switch (event.name) {
          case 'content_block_start':
            final block = _asMap(payload?['content_block']);
            final type = block?['type'];
            if (type == 'server_tool_use') {
              // ★ 到这一刻才能说「正在联网搜索」。
              if (!announcedSearching) {
                announcedSearching = true;
                onPhase?.call(SearchPhase.searching);
              }
            } else if (type == 'web_search_tool_result') {
              searched = true;
              _collectSources(block?['content'], sources, seen);
              if (sources.isNotEmpty) onSources?.call(List.of(sources));
            } else if (type == 'text') {
              if (!announcedComposing) {
                announcedComposing = true;
                onPhase?.call(SearchPhase.composing);
              }
            }
          case 'content_block_delta':
            final delta = _asMap(payload?['delta']);
            if (delta?['type'] == 'text_delta') {
              if (!announcedComposing) {
                announcedComposing = true;
                onPhase?.call(SearchPhase.composing);
              }
              text.write(delta?['text'] as String? ?? '');
            }
          case 'message_delta':
            // 有些服务端把最终结果放在 message_delta 里，这里兜一层。
            final delta = _asMap(payload?['delta']);
            final blocks = delta?['content'];
            if (blocks is List) {
              for (final raw in blocks) {
                final block = _asMap(raw);
                if (block?['type'] == 'web_search_tool_result') {
                  searched = true;
                  _collectSources(block?['content'], sources, seen);
                }
              }
            }
          case 'error':
            final err = _asMap(payload?['error']);
            return WebSearchResult(
              error: '联网搜索出错：${err?['message'] ?? '未知错误'}',
              searched: searched,
              sources: List.unmodifiable(sources),
            );
        }
      }
    } on TimeoutException {
      return WebSearchResult(
        error: '联网搜索超时（${timeout.inSeconds} 秒）',
        searched: searched,
        sources: List.unmodifiable(sources),
      );
    } on Exception catch (e) {
      return WebSearchResult(
        error: _describe(e),
        searched: searched,
        sources: List.unmodifiable(sources),
      );
    }

    final answer = text.toString().trim();
    if (answer.isEmpty && !searched) {
      return const WebSearchResult(error: '服务端没有返回内容');
    }
    // 按可信度重排：官方来源置顶。
    return WebSearchResult(
      answer: answer,
      sources: List.unmodifiable(rankSources(sources)),
      searched: searched,
    );
  }

  /// 从 `web_search_tool_result` 的 `content` 里取 `web_search_result` 条目。
  ///
  /// 与 DSH 的做法一致：**只认结构化字段**，绝不从模型正文里用正则抓 URL ——
  /// 正文里的 URL 可能是模型编的，而结构化块是服务端真实检索的结果。
  static void _collectSources(
    Object? content,
    List<WebSource> out,
    Set<String> seen,
  ) {
    if (content is! List) return;
    for (final raw in content) {
      final item = _asMap(raw);
      if (item?['type'] != 'web_search_result') continue;
      final url = (item?['url'] as String?)?.trim() ?? '';
      if (url.isEmpty || !seen.add(url)) continue;
      out.add(WebSource(url: url, title: (item?['title'] as String?)?.trim() ?? ''));
    }
  }

  /// 极简 SSE 解析：逐行读 `event:` / `data:`，遇空行派发一个事件。
  ///
  /// 只做这里用得到的部分。Anthropic 的 Messages 流每条消息都有 `event:` 行。
  static Stream<({String name, String data})> sseEvents(Stream<List<int>> byteStream) async* {
    final lines = byteStream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    var name = '';
    final data = StringBuffer();
    await for (final line in lines) {
      if (line.isEmpty) {
        if (name.isNotEmpty || data.isNotEmpty) {
          yield (name: name, data: data.toString());
        }
        name = '';
        data.clear();
        continue;
      }
      if (line.startsWith('event:')) {
        name = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        // 同一事件可能有多行 data，按 SSE 规范用换行拼接。
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
      // 其余（id:/retry:/注释）忽略
    }
    if (name.isNotEmpty || data.isNotEmpty) {
      yield (name: name, data: data.toString());
    }
  }

  static Stream<({String name, String data})> _sseEvents(
    Stream<List<int>> byteStream,
  ) => sseEvents(byteStream);
  /// 把 JSON 解出来的对象安全地当作 `Map<String, Object>` 用。
  ///
  /// ⚠️ **不能用 `value.cast<String, Object?>()`**。
  ///
  /// `cast` 返回的是一个**惰性视图**：它在被迭代/取值那一刻才转换，类型不匹配时
  /// 抛的是 `TypeError`。而调用点写在 `try { … } on Exception catch` 里 ——
  /// `TypeError` **是 `Error` 不是 `Exception`**，于是它既没被捕获，也没让流程
  /// 走到「报错」，而是让整个事件循环悄无声息地结束。改用 `Map.from` 得到
  /// 真正的 map，问题当场抛出而不是被吞掉。
  ///
  /// 注意这里接收的是**已经 `jsonDecode` 过的值**，不是 JSON 字符串。
  /// 早先这个函数被直接传了 `event.data`（String），`value is Map` 恒为 false，
  /// 于是**每个事件都解析成 null** —— 表现是「服务端没有返回内容」，
  /// 而日志里明明收到了 `content_block_start`。见 [_parseEvent]。
  static Map<String, Object?>? _asMap(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : null;

  /// 解析一条 SSE 事件的 `data`（JSON 字符串）→ map。
  ///
  /// JSON 坏了要**当成没有 payload**，不能把异常抛到事件循环外面：
  /// 服务端偶尔会发 `ping` 之类没有 data 的事件，也可能发非 JSON 的心跳。
  /// 抛出去会中断整条流，用户看到的是「搜索失败」，而其实只是少读了一个心跳。
  static Map<String, Object?>? _parseEvent(String data) {
    final raw = data.trim();
    if (raw.isEmpty) return null;
    try {
      return _asMap(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  static Future<String> _readAll(Stream<List<int>> stream) async {
    final buffer = StringBuffer();
    await for (final chunk in stream) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
      if (buffer.length > 4000) break;
    }
    return buffer.toString();
  }

  /// 把 HTTP 状态码翻译成用户能看懂、且**能据此决定下一步**的说明。
  ///
  /// 每条都要带上状态码：用户报问题时，「401」比「查询失败」有用得多，
  /// 而且能立刻区分「Key 没配好」和「网络不通」——这两者的处理办法完全不同。
  static String _describeStatus(int status, String body) {
    return switch (status) {
      401 || 403 => 'API Key 无效或已过期（HTTP $status），'
          '请在「设置 → API 配置」中重新填写。',
      404 => '服务地址或模型名不正确（HTTP 404）：'
          '联网检索走的是 Anthropic 兼容端点（`{基址}/anthropic/v1/messages`），'
          '请确认 API 地址填的是服务商官方地址。',
      429 => '请求过于频繁（HTTP 429），请稍后再试。',
      >= 500 => '服务商暂时不可用（HTTP $status），请稍后再试。',
      _ => '联网查询失败（HTTP $status）${_snippet(body)}',
    };
  }

  static String _snippet(String body) {
    final trimmed = body.trim();
    return trimmed.isEmpty ? '' : '：${trimmed.substring(0, trimmed.length.clamp(0, 200))}';
  }

  /// 把异常翻译成用户能看懂、且不泄露密钥的说明。
  static String _describe(Exception e) {
    final raw = e.toString();
    if (raw.contains('SocketException') || raw.contains('Failed host lookup')) {
      return '网络连接失败，请检查网络';
    }
    if (raw.contains('TimeoutException')) return '请求超时';
    if (raw.contains('HandshakeException') || raw.contains('Certificate')) {
      return 'HTTPS 证书校验失败';
    }
    return raw.length > 200 ? '${raw.substring(0, 200)}…' : raw;
  }
}
