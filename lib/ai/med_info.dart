import 'package:flutter/material.dart';

import '../data/store.dart';
import 'web_search.dart';

/// 药品资料查询（0.4D 起，0.4F 改为**真正联网**）。
///
/// ## 用户的要求，与它撞上的现实
///
/// 用户原话是「ai 从网上查，注意，信息来源一定要可靠准确权威」。
///
/// ## 走过的三段弯路（都记着，别再走）
///
/// ① **0.4D 第一版**：往 `chat/completions` 里发 `{"type":"web_search"}`。
///    官方文档原文写着 `tools` 的 `type` **只允许 `function`**、
///    「**内置工具类型会被忽略**」—— 所以它**不报错、不联网**，静默无效。
///    我还据此写了一条「降级并标注未真正联网核实」的分支，
///    而那条分支**从来没有执行过**，等于给用户看了一句假话。
///
/// ② **0.4E**：承认①走不通，但**把结论下得太大** —— 我说「DeepSeek API
///    没有联网能力，要接第三方搜索」。这是**错的**：我只验证了
///    `chat/completions` 这一条路没有，就断言整个 API 没有。
///
/// ③ **0.4F（现在）**：查了 DSH 自己的实现
///    （`@deepseek-ai/dsh-web-search-deepseek`）才发现真相 ——
///    DeepSeek 有**另一个端点**原生支持联网：
///
/// | | 聊天 | 联网搜索 |
/// |---|---|---|
/// | 路径 | `/chat/completions` | `/anthropic/v1/messages` |
/// | 协议 | OpenAI 兼容 | Anthropic 兼容 |
/// | 联网 | 无 | `web_search_20250305` 服务端工具 |
///
///    DSH 的注释原话：「Default endpoint: DeepSeek's Anthropic-compatible API,
///    `/v1` included (`/messages` is appended). **This is NOT the
///    chat-completions base**」。**同一个 Key、同一个服务商，换个端点就能联网。**
///
/// ## 现在的做法
///
/// ① 真的联网检索，来源写**真实 URL**；
/// ② **只有真的检索了才敢说「联网检索」** —— [WebSearchResult.searched]
///    依据的是服务端真的返回了 `web_search_tool_result`，
///    不是「请求成功了」这种间接推断（这正是①的教训）；
/// ③ 来源按**可信度分级**并排序（官方 → 机构/厂家 → 其他），
///    因为实测一轮「布洛芬缓释胶囊」的 16 条结果里有 14 条是卖药电商与资讯站 ——
///    **「联网查到了」不等于「查到了权威来源」**，必须让用户看得出来；
/// ④ 同时保留国家药监局（NMPA）官方查询入口：那是唯一真正权威、
///    且我们能负责任地指向的来源；
/// ⑤ 查不到的项写「未知」，**绝不编造内容去填满字段**；
/// ⑥ 失败时**必须把原因带回界面**（[MedLookupResult.error]），不再静默返回空。
///
/// ## 为什么不做「AI 直接生成说明书摘要」而不标注来源
///
/// 那会把「模型记忆」和「查到的资料」混成一种东西显示给用户。用户 0.4D
/// 之前就抱怨过药品信息不完善；用臆造的内容去填补，只会让不完善变成不可信。

/// 国家药监局（NMPA）数据查询入口。
///
/// 这是本功能里**唯一可以被称作「权威」的来源**：官方数据库、可自行核对。
/// 刻意不做 URL 拼接（按药名拼查询串的官方地址不稳、且可能失效），
/// 只给入口页，让用户在那里搜 —— 稳，且不会把用户带到仿冒站点。
const nmpaSearchUrl = 'https://www.nmpa.gov.cn/datasearch/home-index.html';

/// 资料查询的字段 → 结果 key。
///
/// 顺序即界面分组顺序。**只查这些字段**，不让模型自由发挥 ——
/// 字段固定才能可靠解析，也才能让「哪一项没查到」变得可见。
const medInfoFields = <String, String>{
  'usage': '用法用量',
  'indications': '治疗范围/适应症',
  'efficacy': '药效/作用机制',
  'adverse': '不良反应',
  'contraindications': '禁忌',
  'precautions': '注意事项',
};

/// 一次查询的结果。
///
/// 刻意不用「空 map 表示失败」：那样界面无法区分
/// 「请求就失败了」和「请求成功但一条都没查到」，
/// 两者给用户的下一步动作完全不同（一个是「检查配置/重试」，
/// 一个是「照说明书手抄」）。0.4D 真机上的「资料出处：暂无」
/// 就是这个歧义造成的 —— 失败被当成「没查到」静默吞掉。
class MedLookupResult {
  const MedLookupResult({
    required this.fields,
    this.error,
    this.note = '',
    this.sources = const [],
    this.searched = false,
  });

  /// 解析出来的字段。空 map 表示一条都没得到。
  final Map<String, String> fields;

  /// 失败原因（网络错误、未配置 API Key、模型没按格式回答…）。
  /// 为 null 表示请求本身成功。
  final String? error;

  /// 给用户看的补充说明（例如「模型没按格式回答」）。
  final String note;

  /// 联网检索到的真实来源（按可信度排好序）。
  final List<WebSource> sources;

  /// **是否真的发生了联网检索**。界面据此决定能否写「联网检索」。
  final bool searched;

  bool get ok => error == null;

  /// 请求成功但一条字段都没解析出来。
  bool get succeededButEmpty => ok && fields.isEmpty;
}

/// 组织提示词。抽成纯函数，便于离线测试它**确实**约束了来源与格式。
@visibleForTesting
String buildLookupPrompt(String name, {String? ingredient}) {
  final extra = (ingredient == null || ingredient.trim().isEmpty)
      ? ''
      : '（通用名/成分：${ingredient.trim()}）';
  return '''
请查「$name」$extra 的**药品说明书级**公开资料，并严格按下面的格式回答。

格式要求（每行一项，查不到就写「未知」，不要编造）：
${medInfoFields.entries.map((e) => '${e.key}: ${e.value}').join('\n')}
source: 你依据的来源名称（例如「国家药监局药品说明书」「药品说明书原文」）；若你并未查到可靠来源，必须写「未知」

硬性要求：
1. 只写**一般性**药品资料，**绝对不要**给出针对某个具体人的剂量建议，也不要诊断疾病。
2. 每一项尽量简短（一两句话），不要写成长篇。
3. **不要**输出「source」以外任何形式的参考文献列表。
4. 若你无法确认某一条的准确性，就在那一项写「未知」。**宁可写未知，也不要猜。**
''';
}

/// 查询并解析模型回答。
///
/// 抽成纯函数：不给它网络与界面，只给一段模型输出，便于穷举各种畸形格式。
/// 返回只包含**解析成功且非「未知」**的字段 —— 空 map 表示一条都没得到，
/// 界面据此如实提示。
@visibleForTesting
Map<String, String> parseLookupReply(String reply) {
  final out = <String, String>{};
  // 逐行找「key: value」。要容忍模型爱用的各种包装：
  //   · 前面有 `-` / `*` / `1.` / `、` 之类的列表符号；
  //   · 键被 Markdown 加粗成 **usage**；
  //   · 用全角冒号「：」。
  final line = RegExp(
    r'^\s*[-*•\d.、\s]*\*{0,2}([A-Za-z_]+)\*{0,2}\s*[:：]\s*(.*)$',
  );
  for (final raw in reply.split('\n')) {
    final m = line.firstMatch(raw);
    if (m == null) continue;
    final key = m.group(1)!.trim();
    var value = m.group(2)!.trim();
    if (!medInfoFields.containsKey(key) && key != 'source') continue;
    // 去掉模型爱加的引号/星号
    value = value.replaceAll(RegExp(r'^[*\s"]+|[*\s"]+$'), '');
    if (value.isEmpty) continue;
    // 「未知」「没查到」这类一律视为没查到，不写进数据库 ——
    // 把「未知」当内容存下来，用户会以为真的查到了。
    if (RegExp(
      r'^(未知|不详|不清楚|无法确认|没有查到|未查到|查不到|未能查到|无|none|unknown|n/?a)[。.！!]?$',
      caseSensitive: false,
    ).hasMatch(value)) {
      continue;
    }
    out[key] = value;
  }
  return out;
}

/// 把来源整理成一句可显示、可核查的文字。
///
/// ## 0.4F：两种来源必须分得清清楚楚
///
/// 现在这个功能**真的会联网**了（走 Anthropic 兼容 `/messages` +
/// `web_search_20250305`），所以文案里出现「联网检索」是**允许的** ——
/// 但**只在真的检索了的时候**。
///
/// 这正是这个函数的全部意义：0.4D 曾经无条件写「未真正联网核实」，
/// 而那条分支从来没有执行过，等于给用户看了一句假话。现在按
/// [searched] 分流，而这个值来自**服务端真的返回了 `web_search_tool_result`**，
/// 不是「请求成功了」这种间接推断。
///
/// · 联网成功 → 「联网检索到 N 条来源，请以官方说明书为准」（并附 URL）
/// · 没联网   → 「模型已有知识（未经核实，仅供参考）」—— 措辞里
///   **不出现「联网」二字**，避免让人以为本来能联网、只是这次没成。
///
/// [modelReported] 是模型自报的依据名称，只有没联网时才会用上。
@visibleForTesting
String describeSource({
  required bool searched,
  int sourceCount = 0,
  String modelReported = '',
}) {
  if (searched) {
    final n = sourceCount > 0 ? '到 $sourceCount 条来源' : '结果';
    return '联网检索$n；来源为公开网页，请以药品说明书与药师意见为准';
  }
  const tail = '未经核实，仅供参考';
  final reported = modelReported.trim();
  if (reported.isEmpty) {
    return '模型已有知识（$tail）';
  }
  return '模型已有知识，自述依据「$reported」；$tail';
}

/// 执行一次资料整理，把结果写进药品记录。
///
/// ## 0.4F：改成真正的联网检索
///
/// 0.4E 时这里发的是普通聊天请求，来源只能写「模型已有知识」——
/// 因为 **`chat/completions` 端点根本没有联网能力**。0.4F 改走
/// [AiWebSearchClient]（Anthropic 兼容 `/messages` + `web_search_20250305`），
/// 于是来源里可以放**真实检索到的 URL**。
///
/// 关键约束：**只有真的发生了检索才写「联网检索」**。
/// [WebSearchResult.searched] 为 false 时一律退回「模型已有知识」的措辞 ——
/// 只凭「请求成功」就说自己联网过，正是 0.4D 犯的错。
///
/// [onPhase] 会收到**真实发生**的阶段（思考 → 联网搜索 → 整理），供界面显示。
Future<MedLookupResult> lookupMedInfo({
  required BuildContext context,
  required Store store,
  required Map<String, dynamic> med,
  void Function(SearchPhase phase)? onPhase,
  void Function(List<WebSource> sources)? onSources,
}) async {
  final name = med['name']?.toString().trim() ?? '';
  if (name.isEmpty) {
    return const MedLookupResult(fields: {}, error: '这个药品没有名称，无法查询');
  }
  if (!store.hasApiKey) {
    return const MedLookupResult(
      fields: {},
      error: '尚未配置 API Key，请到「设置 → AI 服务 → API 配置」填写',
    );
  }

  final prompt = buildLookupPrompt(name, ingredient: med['ingredient']?.toString());

  // 药名 + 「说明书」是能命中说明书页的关键词组合；不写「AI」这类噪声词。
  final query =
      '请联网查询「$name」的药品说明书，然后严格按下面的字段格式回答：\n\n$prompt';

  final client = AiWebSearchClient(
    apiKey: store.key,
    baseUrl: AiWebSearchClient.anthropicBaseFrom(store.url),
    model: store.model,
  );

  final result = await client.search(
    query,
    onPhase: onPhase,
    onSources: onSources,
  );

  // 请求本身失败：把原因带回界面（未配置 Key / 网络 / 服务端报错）。
  // 注意**即使失败也要保留已拿到的来源** —— 检索可能成功了、只是整理阶段断了。
  if (!result.ok) {
    return MedLookupResult(
      fields: const {},
      error: result.error,
      sources: result.sources,
      searched: result.searched,
    );
  }

  final parsed = parseLookupReply(result.answer);
  final fields = {
    for (final entry in parsed.entries)
      if (entry.key != 'source') entry.key: entry.value,
  };

  // 成功但一条都没解析出来：多半是模型没按固定格式回答。
  if (fields.isEmpty) {
    return MedLookupResult(
      fields: const {},
      note: '模型没有按「字段: 内容」的格式回答，没有可保存的内容',
      sources: result.sources,
      searched: result.searched,
    );
  }

  await store.updateMedInfo(
    med['id'].toString(),
    fields: fields,
    source: describeSource(
      searched: result.searched,
      sourceCount: result.sources.length,
      modelReported: parsed['source'] ?? '',
    ),
    checkedAt: DateTime.now(),
    // 只有真的联网了才存来源 URL。没联网却存一堆 URL，等于伪造出处。
    sources: result.searched
        ? result.sources.map((s) => s.url).toList()
        : const [],
  );
  return MedLookupResult(
    fields: fields,
    sources: result.sources,
    searched: result.searched,
  );
}
