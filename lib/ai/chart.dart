import 'dart:convert';

/// 图表块的数据模型。
///
/// 0.2A 文档要求「ai 可以输出图表来增强分析表达」。实现方式是在模型回复里
/// 约定一个 ```chart 代码块，客户端解析后渲染成真实图表；解析失败就退回纯
/// 文本，绝不因为模型输出不规范而崩溃或白屏。
class ChartBlock {
  const ChartBlock({
    required this.type,
    required this.title,
    required this.categories,
    this.totalLabel = '',
    this.totalValue = '',
    this.note = '',
  });

  /// `category`（分类对比）或 `trend`（随时间变化）。
  final String type;
  final String title;
  final List<ChartItem> categories;
  final String totalLabel;
  final String totalValue;
  final String note;

  bool get isValid => categories.isNotEmpty;

  double get maxValue => categories.fold<double>(
    0,
    (acc, item) => item.value > acc ? item.value : acc,
  );

  /// 从模型输出的 JSON 构造。字段缺失或类型不符时返回 null。
  static ChartBlock? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type']?.toString().trim().toLowerCase() ?? '';
    if (type != 'category' && type != 'trend') return null;

    final rawItems = raw['categories'];
    if (rawItems is! List) return null;
    final items = <ChartItem>[];
    for (final entry in rawItems.take(6)) {
      final item = ChartItem.tryParse(entry);
      if (item != null) items.add(item);
    }
    if (items.isEmpty) return null;

    final total = raw['total'];
    return ChartBlock(
      type: type,
      title: raw['title']?.toString().trim() ?? '',
      categories: items,
      totalLabel: total is Map ? total['label']?.toString() ?? '' : '',
      totalValue: total is Map ? total['value']?.toString() ?? '' : '',
      note: raw['note']?.toString().trim() ?? '',
    );
  }
}

/// 图表中的一项。
class ChartItem {
  const ChartItem({
    required this.label,
    required this.value,
    required this.display,
  });

  final String label;
  final double value;

  /// 展示用文案（例如 `¥32.80` / `2 项`）。缺失时由渲染层按数值生成。
  final String display;

  static ChartItem? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final label = raw['label']?.toString().trim() ?? '';
    if (label.isEmpty) return null;
    final rawValue = raw['value'];
    final value = rawValue is num
        ? rawValue.toDouble()
        : double.tryParse(rawValue?.toString() ?? '');
    if (value == null) return null;
    return ChartItem(
      label: label,
      value: value,
      display: raw['display']?.toString().trim() ?? '',
    );
  }
}

/// 一条助手消息拆解后的结果：正文 + 图表。
class ParsedReply {
  const ParsedReply(this.text, this.chart);

  final String text;
  final ChartBlock? chart;

  bool get hasChart => chart != null;
}

/// 解析模型回复，把 ```chart 代码块抽出来。
class ChartParser {
  const ChartParser._();

  /// 匹配 ```chart ... ``` 或 ```json ... ``` 代码块。
  ///
  /// 语言标记**不能写成 `(?:chart|json)?`**：那样标记是可选的，等于匹配任意
  /// 代码块。加了「动作协议」（```actions）之后后果很严重 —— 动作 JSON 会被
  /// 当成图表数据解析；解析不出来时又原样留在正文里，用户会看到一大段裸 JSON。
  /// 两类协议必须各认各的标记。
  static final _fence = RegExp(
    r'```(?:chart|json)\s*\n(.*?)```',
    dotAll: true,
    caseSensitive: false,
  );

  static ParsedReply parse(String source) {
    if (source.trim().isEmpty) return const ParsedReply('', null);
    if (!source.contains('{')) return ParsedReply(source, null);

    for (final match in _fence.allMatches(source)) {
      final chart = _tryDecode(match.group(1));
      if (chart != null) {
        return ParsedReply(
          _clean(source.replaceRange(match.start, match.end, '')),
          chart,
        );
      }
    }
    // 兜底：模型偶尔会忘记写代码块。用括号配平找出顶层 JSON 对象，
    // 而不是用正则 —— `\{[^{}]*\}` 会在嵌套的 categories 对象上截断。
    for (final range in _topLevelObjects(source)) {
      final chart = _tryDecode(source.substring(range.$1, range.$2));
      if (chart != null) {
        return ParsedReply(
          _clean(
            source.replaceRange(range.$1, range.$2, ''),
          ),
          chart,
        );
      }
    }
    return ParsedReply(source, null);
  }

  /// 扫描出所有括号配平的顶层 `{...}` 区间。
  static List<(int, int)> _topLevelObjects(String source) {
    final ranges = <(int, int)>[];
    var depth = 0;
    var start = -1;
    var inString = false;
    var escaped = false;

    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
        continue;
      }
      if (char == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (char == '}') {
        if (depth > 0) {
          depth--;
          if (depth == 0 && start >= 0) {
            ranges.add((start, i + 1));
            start = -1;
          }
        }
      }
    }
    return ranges;
  }

  static ChartBlock? _tryDecode(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty || !text.startsWith('{')) return null;
    try {
      return ChartBlock.tryParse(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  /// 抽掉图表后清掉残留的空行与尾随的说明符，避免聊天气泡里出现空档。
  static String _clean(String text) => text
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .replaceAll(RegExp(r'^\s*\n'), '')
      .trimRight();
}
