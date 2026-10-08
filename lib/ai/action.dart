import 'dart:convert';

import '../core/topic.dart';
import '../core/util.dart';

/// 模型返回的「动作计划」。
///
/// 为什么需要它：中文自然语言的录入意图（「还有两盒」「下个月过期」「剩3个」）
/// 不可能靠关键词穷举。早先只用本地正则解析，`库存|数量|共` 这种表注定漏，
/// 结果是把「理解人话」这件本该由模型做的事硬塞进一堆关键词里 —— 那不是 AI
/// 助手，是关键词匹配器。
///
/// 现在的分工是：
/// - **模型负责理解**：把「添加药品：护肝片,维生素B,钙片，都还有两盒，下个月过期」
///   变成结构化动作；
/// - **App 负责执行**：只认识下面这几种 type，逐条落库，并在回复里逐条列出。
///
/// 这样新增说法不需要改解析代码。代价是每次录入多一次模型调用，所以
/// [Store.ask] 仍然先跑本地正则：常见写法（`添加药品 a 库存 2`）零成本即时命中，
/// 解析不出来才升级给模型。本地正则从「唯一的解析器」降级成「快路径缓存」。
class ActionPlan {
  const ActionPlan._();

  /// 动作计划的代码块语言标记。
  ///
  /// 与 `PromptBuilder.actionFence` 必须一致：提示词里写 ` ```actions `，
  /// 这里就要认 `actions`。两边写错一个字母的表现是「模型明明给了动作却没执行」，
  /// 而且不报错。
  static const actionFence = 'actions';

  /// 支持的药品动作。
  static const medAdd = 'med_add';

  /// 支持的账目动作。
  static const expenseAdd = 'expense_add';

  /// 某个主题下允许执行的动作类型。
  ///
  /// **这是一道必须存在的护栏，不是多余的校验。** 真机上出过这样的事：
  /// 用户在**账本**里说「今天买菜50，吃饭250，加到账本里去」，
  /// 模型却输出了 `med_add`，App 就老老实实往**药箱**加了一条「护肝片」；
  /// 而回复的标签按主题写成「账目已加入账本」，于是用户看到一句自相矛盾的话：
  ///
  /// > 已加入药箱 · 护肝片：2 盒 …… 账目已加入账本（共 1 项）：· 护肝片
  ///
  /// 账本与药箱是两套完全不同的记录，混写一次用户就得自己去猜、去清理。
  /// 根因是「模型说加什么就加什么」这个设计本身就错了：
  /// **主题决定写哪个模块，模型只能决定写什么内容。**
  static Set<String> allowedTypes(Topic topic) => topic == Topic.health
      ? const {medAdd}
      : const {expenseAdd};

  /// 从模型回复里解析动作计划，**只保留当前主题允许的动作类型**。
  ///
  /// 返回空列表表示「没有可执行的动作」，调用方应把原文当普通回答。
  ///
  /// 容错要求很高：模型可能用 ```json 包起来、可能在正文里夹一段裸 JSON、
  /// 也可能输出非法 JSON。任何一种都不该让用户看到报错，最差的情况是退化成
  /// 普通对话回复（用户至少能看到模型说了什么）。
  static List<Map<String, dynamic>> parse(String raw, {Topic topic = Topic.health}) {
    for (final candidate in _candidates(raw)) {
      final actions = _keepAllowed(_decodeRaw(candidate), topic);
      if (actions.isNotEmpty) return actions;
    }
    return const [];
  }

  /// 从回复里摘掉承载动作计划的代码块，返回「正文 + 动作计划」。
  ///
  /// 为什么必须摘掉：动作 JSON 是给 App 看的，不是给用户看的。模型一旦输出了
  /// 这段块、而 App 又因为任何原因没执行（模式关了、JSON 只坏了一点点），
  /// 原样留在正文里就会变成一屏裸 JSON —— 那正是「图表不该露出裸 JSON」这条
  /// 既有约束要防的事，动作协议同样要防。
  ///
  /// 认两类围栏：
  /// - ` ```actions ` —— 提示词约定的写法，**无条件摘掉**（标记本身就说明是数据）；
  /// - ` ```json ` / 无标记 —— 模型经常不听话改用这个。**但必须内容真的是动作
  ///   才摘**，因为图表协议也用 ` ```json `，无脑摘掉会把图表数据一起删了。
  ///
  /// 图表块最终由 `ChartParser` 在渲染时摘掉（所以库里存的仍是原文），
  /// 动作块必须在这里就摘掉，因为动作是「已执行」的，再显示一遍没有意义。
  ///
  /// [rejected] 为 true 表示「模型确实给了动作，但类型与当前模块不符，被丢弃」。
  /// 这不是普通情况：它说明模型搞错了模块，调用方应当留下现场便于排查。
  static ({
    String body,
    List<Map<String, dynamic>> actions,
    bool rejected,
  })
  extract(String raw, {Topic topic = Topic.health}) {
    // 1) 显式 ```actions 围栏：**无论 JSON 好坏都摘掉**。
    //    围栏标记本身已经说明「这段是给 App 的数据」。JSON 写坏了也不能把它
    //    留给用户看 —— 一屏裸 JSON 对用户毫无价值，还像是应用崩了。
    final explicit = _fenceRegExp(actionFence).firstMatch(raw);
    if (explicit != null) {
      final raw1 = _decodeRaw(explicit.group(1)!.trim());
      final actions = _keepAllowed(raw1, topic);
      return (
        body: _stripRange(raw, explicit.start, explicit.end),
        actions: actions,
        rejected: actions.isEmpty && (raw1?.isNotEmpty ?? false),
      );
    }
    // 2) ```json / 无标记围栏：只有内容真的是动作才摘。
    //    图表协议也用 ```json，无脑摘掉会把图表数据一起删了。
    return _extractWhereBodyIsActions(raw, topic) ??
        // 3) 完全没有围栏：允许模型只吐一段 JSON
        _extractBare(raw, topic);
  }

  /// 无围栏时的兜底。
  static ({
    String body,
    List<Map<String, dynamic>> actions,
    bool rejected,
  })
  _extractBare(String raw, Topic topic) {
    final actions = parse(raw, topic: topic);
    if (actions.isNotEmpty) {
      return (body: raw, actions: actions, rejected: false);
    }
    final anyRaw = _decodeRaw(raw.trim());
    return (
      body: raw,
      actions: const [],
      rejected: anyRaw?.isNotEmpty ?? false,
    );
  }

  static RegExp _fenceRegExp(String tag) => RegExp(
    '```$tag' r'[ \t]*\r?\n(.*?)```',
    dotAll: true,
    caseSensitive: false,
  );

  /// 摘掉 [start, end) 这一段代码块。trim 是因为代码块通常紧跟在正文换行之后，
  /// 直接拼接会多留一行空行。
  static String _stripRange(String raw, int start, int end) =>
      (raw.substring(0, start) + raw.substring(end)).trim();

  /// 在第一个「内容能解析成当前主题允许的动作」的 ` ```json ` / 无标记围栏处摘除。
  static ({
    String body,
    List<Map<String, dynamic>> actions,
    bool rejected,
  })?
  _extractWhereBodyIsActions(String raw, Topic topic) {
    var sawRejected = false;
    for (final match in _fenceRegExp(r'(?:json)?').allMatches(raw)) {
      final rawActions = _decodeRaw(match.group(1)!.trim());
      if (rawActions == null || rawActions.isEmpty) continue;
      final actions = _keepAllowed(rawActions, topic);
      if (actions.isEmpty) {
        // 是动作，但属于另一个模块 —— 记住这件事，继续找有没有对的
        sawRejected = true;
        continue;
      }
      return (
        body: _stripRange(raw, match.start, match.end),
        actions: actions,
        rejected: false,
      );
    }
    if (sawRejected) return (body: raw, actions: const [], rejected: true);
    return null;
  }

  /// 从回复里挑出可能是 JSON 的片段，按可信度从高到低。
  /// 从回复里挑出可能是动作 JSON 的片段，按可信度从高到低。
  ///
  /// 围栏只认 ` ```actions `：` ```json ` 与无标记围栏可能是**图表**数据，
  /// 交给 [extract] 按「内容是不是动作」判断，这里不抢。
  static List<String> _candidates(String raw) {
    final out = <String>[];
    // 1) ```actions 围栏里的内容
    for (final m in _fenceRegExp(actionFence).allMatches(raw)) {
      out.add(m.group(1)!.trim());
    }
    // 2) 整段就是一个 JSON
    final trimmed = raw.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) out.add(trimmed);
    // 3) 正文里夹着的第一个 {...} 或 [...]（兜底：模型忘了写围栏）
    for (final m in RegExp(r'\{.*\}', dotAll: true).allMatches(raw)) {
      out.add(m.group(0)!.trim());
      break;
    }
    for (final m in RegExp(r'\[.*\]', dotAll: true).allMatches(raw)) {
      out.add(m.group(0)!.trim());
      break;
    }
    return out;
  }

  /// 把 JSON 解成「规范化后的动作」，**不按主题过滤**。
  ///
  /// 无动作或 JSON 非法返回 null（与「解出来但是空数组」区分开：
  /// 后者说明确实是动作格式，只是内容都不合法）。
  static List<Map<String, dynamic>>? _decodeRaw(String text) {
    if (text.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }

    final rawActions = switch (decoded) {
      List<dynamic>() => decoded,
      Map<String, dynamic>() when decoded['actions'] is List =>
        decoded['actions'] as List<dynamic>,
      // 单个动作对象（模型有时只给一个，不套 actions 数组）
      Map<String, dynamic>() when decoded['type'] is String => [decoded],
      _ => null,
    };
    if (rawActions == null) return null;

    final out = <Map<String, dynamic>>[];
    for (final item in rawActions) {
      if (item is! Map) continue;
      final action = _normalize(item.cast<String, dynamic>());
      if (action != null) out.add(action);
    }
    return out;
  }

  /// 丢掉不属于当前模块的动作。
  ///
  /// 这是防「账本里加出一条护肝片」的那道闸：模型可能搞错模块，
  /// 而模块归属由用户在界面上的选择决定，不该由模型说了算。
  static List<Map<String, dynamic>> _keepAllowed(
    List<Map<String, dynamic>>? actions,
    Topic topic,
  ) {
    if (actions == null || actions.isEmpty) return const [];
    final allowed = allowedTypes(topic);
    return actions.where((a) => allowed.contains(a['type'])).toList();
  }

  /// 把一条模型动作规范化成落库用的行数据。字段缺失或类型不对就丢弃这一条。
  static Map<String, dynamic>? _normalize(Map<String, dynamic> raw) {
    final type = _str(raw['type']);
    switch (type) {
      case medAdd:
        final name = _str(raw['name']);
        if (name.isEmpty) return null;
        return {
          'type': medAdd,
          'summary': name,
          'row': {
            'name': name,
            'ingredient': _str(raw['ingredient']),
            'spec': _str(raw['spec']),
            'stock': _int(raw['stock'], fallback: 1),
            'expiry': _normalizeDate(_str(raw['expiry'])),
            'storage': _str(raw['storage']),
            'note': '由 AI 快捷录入',
          },
        };
      case expenseAdd:
        final title = _str(raw['title']);
        if (title.isEmpty) return null;
        final amount = _double(raw['amount']);
        if (amount == null || amount < 0) return null;
        return {
          'type': expenseAdd,
          'summary': '$title ${money(amount)}',
          'row': {
            'title': title,
            'amount': amount,
            // 分类缺失时明确写「未分类」，而不是编一个（界面上能一眼看出要补）
            'category': _str(raw['category']).isEmpty
                ? '未分类'
                : _str(raw['category']),
            'note': '由 AI 快捷录入',
            'entryType': _str(raw['entryType']) == 'income' ? 'income' : 'expense',
          },
        };
      default:
        return null;
    }
  }

  /// 归一化模型给的有效期：可能是 `2027-05-01`，也可能是 `2027/5/1`。
  static String _normalizeDate(String raw) {
    final m = RegExp(
      r'(\d{4})\s*[-/.年]\s*(\d{1,2})(?:\s*[-/.月]\s*(\d{1,2})\s*日?)?',
    ).firstMatch(raw);
    if (m == null) return '';
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = m.group(3) == null ? 1 : int.parse(m.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return '';
    return '$year-${month.toString().padLeft(2, '0')}'
        '-${day.toString().padLeft(2, '0')}';
  }

  static String _str(Object? v) => v is String ? v.trim() : '';

  static int _int(Object? v, {required int fallback}) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? fallback;
    return fallback;
  }

  static double? _double(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }
}
