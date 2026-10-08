import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 假 HTTP 层，供需要「让 App 以为自己在联网」的测试使用。
///
/// 为什么用 dart:io 的 `HttpClient` 而不是 `package:http` 的 `Client`：
/// `Store` 内部自己 `new` 了 `AiClient`（`AiClient` 默认 `http.Client()`），
/// 测试无法注入。所幸无参 `http.Client()` 在移动/桌面端就是 dart:io 的
/// `HttpClient`，所以用 `HttpOverrides.runZoned` 能把它拦住。
///
/// 两个坑（都踩过）：
/// 1. `IOClient` 调用的是 `openUrl`，不是 `getUrl`；
/// 2. getter 不能只靠 `noSuchMethod` 返回 null —— 非空返回类型会直接抛
///    `type 'Null' is not a subtype of ...`，必须逐个实现。
class FakeHttpClient implements HttpClient {
  FakeHttpClient({
    required this.statusCode,
    required this.body,
    this.delay = Duration.zero,
    this.responder,
  });

  /// 返回 JSON 模型列表，模拟 OpenAI 兼容的 `GET /models`。
  factory FakeHttpClient.models(
    List<String> ids, {
    Duration delay = Duration.zero,
  }) => FakeHttpClient(
    statusCode: 200,
    body: jsonEncode({
      'object': 'list',
      'data': [for (final id in ids) {'id': id}],
    }),
    delay: delay,
  );

  /// 按路径分派响应，模拟一个真实服务商。
  ///
  /// `routes` 的键是路径片段（如 `/models`、`/chat/completions`）。用于测「对话里
  /// 让模型把话抽成动作」这类需要同时用到两个端点的场景。
  factory FakeHttpClient.routed(
    Map<String, ({int status, String body})> routes, {
    ({int status, String body})? fallback,
    String? chatText,
    List<String> searchSources = const [],
    int searchStatus = 200,
  }) => FakeHttpClient(
    statusCode: 200,
    body: '',
    responder: (url) {
      for (final entry in routes.entries) {
        if (url.path.contains(entry.key)) return entry.value;
      }
      // 0.4F 起对话改走联网端点（`/messages`，SSE 流式）：
      // 只要调用方给了 [chatText]，就在这里合成一段合法的流式响应。
      if (chatText != null && url.path.contains('/messages')) {
        return (
          status: searchStatus,
          body: FakeHttpClient.webSearchReply(
            chatText,
            sources: searchSources,
            searched: searchStatus == 200,
          ),
        );
      }
      return fallback ?? (status: 404, body: '{"error":"no route"}');
    },
  );

  /// 合成一段**合法的 Anthropic Messages SSE 流**，模拟联网搜索端点。
  ///
  /// 事件顺序刻意与实测的真实响应一致（0.4F 用真凭据跑出来的）：
  /// `message_start` → `content_block_start(server_tool_use)` →
  /// `content_block_start(web_search_tool_result)` →
  /// `content_block_start(text)` → 若干 `content_block_delta` → `message_stop`。
  ///
  /// `server_tool_use` 出现在结果之前 —— 这正是「正在联网搜索」那句提示
  /// 能**先出现、再变成「正在整理」**的依据。
  static String webSearchReply(
    String content, {
    List<String> sources = const [],
    bool searched = true,
  }) {
    final events = <String>[];
    void emit(String name, Object payload) {
      events
        ..add('event: $name')
        ..add('data: ${jsonEncode(payload)}')
        ..add('');
    }

    emit('message_start', {
      'type': 'message_start',
      'message': {'id': 'msg_fake', 'role': 'assistant', 'content': []},
    });

    if (searched) {
      emit('content_block_start', {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'server_tool_use', 'name': 'web_search'},
      });
      emit('content_block_stop', {'type': 'content_block_stop', 'index': 0});

      // 结构化来源：只有真联网才会有这些块。
      emit('content_block_start', {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'web_search_tool_result',
          'content': [
            for (final url in sources)
              {'type': 'web_search_result', 'url': url, 'title': '来源'},
          ],
        },
      });
      emit('content_block_stop', {'type': 'content_block_stop', 'index': 1});
    }

    emit('content_block_start', {
      'type': 'content_block_start',
      'index': 2,
      'content_block': {'type': 'text', 'text': ''},
    });
    // 故意拆成两段 delta：真实响应是分片的；一次给完就测不出增量拼接的 bug。
    final half = content.length ~/ 2;
    for (final piece in [content.substring(0, half), content.substring(half)]) {
      if (piece.isEmpty) continue;
      emit('content_block_delta', {
        'type': 'content_block_delta',
        'index': 2,
        'delta': {'type': 'text_delta', 'text': piece},
      });
    }
    emit('content_block_stop', {'type': 'content_block_stop', 'index': 2});
    emit('message_stop', {'type': 'message_stop'});

    return events.join('\n');
  }

  /// 让假服务商返回一段助手回复（OpenAI 兼容格式）。
  static String chatReply(String content) => jsonEncode({
    'choices': [
      {
        'message': {'role': 'assistant', 'content': content},
      },
    ],
  });

  final int statusCode;
  final String body;
  final Duration delay;

  /// 按 URL 决定响应；为空时用 [statusCode] / [body]。
  final ({int status, String body}) Function(Uri url)? responder;

  /// 记录被请求过的 URL，便于断言「有没有真的发出去」。
  final List<Uri> requests = [];

  /// 记录每次请求的请求体（UTF-8 解出的 JSON 字符串）。
  ///
  /// 有了它才能断言**真正发出去的内容**：例如「历史被裁剪后，旧消息不再出现在
  /// 请求里」。只断言 App 内部状态是不够的 —— 发出去的才是模型看到的。
  final List<String> bodies = [];

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requests.add(url);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final resolved = responder?.call(url);
    return _FakeRequest(
      statusCode: resolved?.status ?? statusCode,
      body: resolved?.body ?? body,
      sink: bodies,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest({required this.statusCode, required this.body, this.sink});

  final int statusCode;
  final String body;

  /// 请求体收集处（可选）。
  final List<String>? sink;

  final BytesBuilder _captured = BytesBuilder();

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  void write(Object? object) => _captured.add(utf8.encode('$object'));

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _captured.add(chunk);
    }
  }

  @override
  Future<HttpClientResponse> close() async {
    if (sink != null) sink!.add(utf8.decode(_captured.takeBytes()));
    return _FakeResponse(statusCode: statusCode, body: body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({required this.statusCode, required String body})
    : _bytes = utf8.encode(body);

  final List<int> _bytes;

  @override
  final int statusCode;

  @override
  String get reasonPhrase => 'OK';

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  int get contentLength => _bytes.length;

  @override
  HttpHeaders get headers => _FakeHeaders();

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  List<Cookie> get cookies => const [];

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
