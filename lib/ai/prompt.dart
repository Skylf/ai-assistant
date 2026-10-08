import '../core/stats.dart';
import '../core/topic.dart';
import '../core/util.dart';

export '../core/topic.dart';

/// 系统提示词构造。
///
/// 旧实现把全量账目与药品的 JSON 直接拼进每一条 system message，数据一多
/// 就会撑爆上下文。这里改为「紧凑摘要 + 预算内明细」：先给统计结论，再按
/// 预算附带最近的明细，超出部分明确告知模型已被截断。
///
/// 同时负责 0.2A 文档提出的「AI 可以输出图表来增强分析表达」：提示词里约定
/// 一个 ```chart 代码块协议，客户端解析后渲染成真实图表（见 widgets/chart.dart）。
class PromptBuilder {
  const PromptBuilder._();

  /// 明细部分的字符预算（按中文 3 字节保守估算长度）。
  static const detailBudget = 3500;

  /// 明细最多附带多少条。
  static const detailLimit = 60;

  /// 图表代码块的语言标记。
  static const chartFence = 'chart';

  /// 动作计划代码块的语言标记。
  static const actionFence = 'actions';

  /// 是否告知模型「可以输出动作计划」。
  ///
  /// 关闭时提示词与旧版完全一致（用于「仅本地解析」模式，也方便对比两种模式的
  /// 实际效果）。开启后模型就能把自然语言里的录入意图抽成结构化动作。
  static String actionProtocol(Topic topic) {
    final schema = topic == Topic.health
        ? '{"type":"med_add","name":"护肝片","stock":2,"expiry":"2027-05-01",'
              '"ingredient":"","spec":"","storage":""}'
        : '{"type":"expense_add","title":"买菜","amount":32.5,'
              '"category":"日常","entryType":"expense"}';
    final types = topic == Topic.health
        ? '只支持 med_add（往药箱加药）。'
        : '只支持 expense_add（往账本记一笔），'
              'entryType 为 expense（支出，默认）或 income（收入）。';
    return '【动作协议】\n'
        '当用户在**要求你录入数据**，而不是在提问时，'
        '请在回复的最后追加一段动作计划：先写一行 ```$actionFence，'
        '再写一行 JSON，最后一行写 ```。\n'
        'JSON 形如：{"actions":[$schema]}\n'
        '**这些说法都算「要求录入」**，都要输出动作计划：\n'
        '「添加药品 X」「记一笔 买菜 32」「加个药」「帮我记账」；\n'
        '**以及不带任何动词、只是在陈述事实的说法**：\n'
        '「我有两盒护肝片」「家里还有维生素和钙片」「今天买菜花了 32」'
        '「工资发了八千」。\n'
        '用户不会每次都先说「请帮我记录」，陈述事实就等于要你记下来 —— '
        '这是最容易被漏掉的一类，**不要**把它当成闲聊或提问。\n'
        'actions 是数组，**一条消息要录入几项就放几个元素**。'
        '用户说「添加药品：A,B,C」就是三个 med_add，不要合成一个名叫「A,B,C」的。'
        '「和」「跟」「以及」以及顿号同样是并列关系：'
        '「两盒护肝片和维生素」是**两个** med_add，不是一个叫「护肝片和维生素」的药。\n'
        '$types\n'
        '【最重要的一条：先录入，不要追问】\n'
        '**只要你能从用户这句话里读出「要录入哪些东西」，就必须立刻输出动作计划，'
        '当场录入。**\n'
        '不要因为缺少保质期、规格、成分、储存方式、分类等**次要**信息就反过来'
        '要用户补充 —— 用户说「我有两盒护肝片」时，正确反应是**立刻加进去**'
        '（名称=护肝片、库存=2，其余留空），而不是问他保质期到什么时候。\n'
        '用户随时可以在药箱/账本页面自己补这些字段，卡住不录入才是帮倒忙。\n'
        '只有连**要录入什么**都判断不出来时（例如「那个药还有吗」），才追问。\n'
        '正文里写一句「已加入，保质期等细节可以随时在药箱里补充」，'
        '不要罗列一串问题让用户回答。\n'
        '字段要求：name/title 必填且只能是单个名称，不含逗号；'
        'stock 为整数（用户说「还有两盒」「剩 3 个」都要理解成 2 和 3）；'
        'expiry 必须是 YYYY-MM-DD，用户说「下个月过期」这类相对时间要按今天推算；'
        '**用户没说或推不出来的字段一律留空字符串或省略，绝不要为它停下来提问。**'
        '不确定的值不要编造。\n'
        '正文里要用一两句话说明你理解成了什么、加了哪些东西，'
        '不要只输出 JSON；除了这段代码块，正文中不要出现其它原始 JSON。\n'
        '如果用户只是在提问（问有多少、问该不该吃），**不要**输出动作计划。';
  }
  /// 统一入口：按主题、记忆作用域与用户自定义提示词拼装。
  static String build({
    required Topic topic,
    required List<Map<String, dynamic>> expenses,
    required List<Map<String, dynamic>> meds,
    required DateTime now,
    String customPrompt = '',
    List<String> globalMemory = const [],
    MemoryScope memoryScope = MemoryScope.defaultScope,
    bool allowActions = true,
  }) {
    final base = topic == Topic.health
        ? health(meds, now)
        : finance(expenses, now);
    final buffer = StringBuffer(base);

    buffer
      ..writeln()
      ..writeln('【输出格式要求】')
      ..writeln('用简体中文，条理清晰，可用短列表与加粗小标题。'
          '不要在正文里输出原始 JSON，也不要使用表格。')
      ..writeln(_chartProtocol(topic));
    if (allowActions) {
      buffer
        ..writeln()
        ..writeln(actionProtocol(topic));
    }

    if (globalMemory.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【全局记忆】以下是用户允许跨对话保留的背景信息，'
            '回答时可以引用，但不要主动复述：');
      for (final note in globalMemory) {
        buffer.writeln('- ${note.trim()}');
      }
    }

    if (memoryScope == MemoryScope.off) {
      buffer
        ..writeln()
        ..writeln('【本次会话】用户关闭了记忆，你只会看到当前这一轮问题，'
            '不要假设存在此前的对话内容。');
    }

    if (customPrompt.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('【用户自定义提示词】在遵守上述健康与安全约束的前提下尽量满足：')
        ..writeln(customPrompt.trim());
    }

    return buffer.toString();
  }

  /// 图表协议说明。
  ///
  /// 只允许两类图表，且要求数字必须来自给定数据，避免模型编造。
  static String _chartProtocol(Topic topic) {
    final example = topic == Topic.finance
        ? '{"type":"category","title":"本月支出分类",'
              '"categories":[{"label":"餐饮","value":32.80,"display":"¥32.80","percent":42}],'
              '"total":{"label":"本月支出","value":"¥78.00"}}'
        : '{"type":"category","title":"药箱状态分布",'
              '"categories":[{"label":"正常","value":8,"display":"8 项"}],'
              '"total":{"label":"药品总数","value":"12 项"}}';
    return '当回答涉及金额分布、分类构成或数量对比时，在正文之后追加一段图表：'
        '先写一行 ```$chartFence，再写一行 JSON，最后一行写 ```。\n'
        'JSON 形如：$example\n'
        'type 只能是 category（分类对比）或 trend（随时间变化，'
        '数据放在 categories 里，label 写日期）。'
        'categories 最多 6 项，percent 为 0-100 的整数。'
        '所有数字必须来自上面给你的数据，不得编造；数据不足时不要输出图表。';
  }

  /// 单条账目文本：日期 | 类型 | 名称 | 分类 | 金额。
  static String expenseLine(Map<String, dynamic> e) {
    final title = _text(e['title']);
    final category = _text(e['category']);
    return '${formatDate(e['spentAt'], unknown: '日期未知')} | '
        '${isIncome(e) ? '收入' : '支出'} | '
        '${title.isEmpty ? '未命名' : title} | '
        '${category.isEmpty ? '未分类' : category} | '
        '${money(entryAmount(e))}';
  }

  /// 单条药品文本：药品 | 成分 | 规格 | 库存 | 有效期 | 储存。
  static String medLine(Map<String, dynamic> m) {
    final name = _text(m['name']);
    return '${name.isEmpty ? '未命名药品' : name} | '
        '${_or(m['ingredient'], '成分未填')} | '
        '${_or(m['spec'], '规格未填')} | '
        '${m['stock'] ?? 0} | '
        '${formatDate(m['expiry'], unknown: '未填')} | '
        '${_or(m['storage'], '储存未填')}';
  }

  static String finance(List<Map<String, dynamic>> expenses, DateTime now) {
    final out = sumEntries(expenses, now, income: false);
    final income = sumEntries(expenses, now, income: true);
    final ranked = expenseByCategory(expenses, now);
    final previous = sumEntries(
      expenses,
      DateTime(now.year, now.month - 1),
      income: false,
    );

    final buffer = StringBuffer()
      ..writeln('你是家庭账本分析助手。只依据下面提供的本地账目数据回答，数据里没有的内容不得编造。')
      ..writeln('金额单位为人民币。回答先给结论，再给依据，最后指出数据不足之处。')
      ..writeln('不要给出投资、借贷或税务的专业建议；涉及决策风险时提示用户自行判断。')
      ..writeln()
      // 这一条必须写在最前面。没有它，模型的默认反应是把「今天买菜50」理解成
      // 「用户想了解本月买菜花了多少」——真机上就是这么答的（回了一段本月支出
      // 统计，一条账都没记）。分析与录入的优先顺序不点明，模型会选错，
      // 而且它的回答看上去完全合理，用户只会以为功能坏了。
      ..writeln('【先判断用户想干什么】')
      ..writeln('用户的每一句话，要么是**让你记录一笔账**，要么是**向你提问**。')
      ..writeln('如果他说的是一个具体花销/收入事实（「今天买菜50」「工资发了八千」），'
          '那就是**要你记下来**，请立刻按下面的动作协议录入，'
          '**不要**当成查询去统计已有数据 —— 哪怕这句话里没有「记」字。')
      ..writeln('只有他确实在问（「这个月花了多少」「哪类花得最多」）时才做分析。')
      ..writeln('判断不清时：先录入，再在正文里说明。少记一笔比答错问题更麻烦。')
      ..writeln()
      // 真机实测：用户先说「今天买菜50，吃饭250，加到账本里去」，下一句只说
      // 「今天买菜20」，模型却在「依据」里引用**上一句**，并照抄那两笔旧金额，
      // 把当前这句话完全忽略。历史里已经执行过的动作会被再执行一次 ——
      // 重复记账比漏记更坏，因为账面上多出来的钱用户很难发现。
      ..writeln('【只处理最后一条用户消息】')
      ..writeln('历史里的话**都已经处理过了**。你的动作计划必须、且只能来自'
          '**最后一条用户消息**。')
      ..writeln('不要把历史里出现过的金额、菜名、药品名再录一遍 —— '
          '那会造成重复记账或重复加药。')
      ..writeln('用户这次只说了「今天买菜20」，就只录一笔 20 元的买菜，'
          '**不要**把上一句的「吃饭250」或任何它之前的数字捎带进来。')
      ..writeln('正文里也不要拿历史消息当依据，只看最后一条。')
      ..writeln()
      ..writeln('【本月概览】${now.year} 年 ${now.month} 月')
      ..writeln('支出合计：${money(out)}')
      ..writeln('收入合计：${money(income)}')
      ..writeln('结余：${money(income - out)}')
      ..writeln('上月支出合计：${money(previous)}')
      ..writeln(
        '账目条数：本月 ${countEntries(expenses, now)} 条，'
        '全部 ${expenses.length} 条',
      );

    if (ranked.isEmpty) {
      buffer.writeln('本月支出分类：暂无数据');
    } else {
      buffer.writeln('本月支出分类（由高到低）：');
      for (final entry in ranked.take(8)) {
        final ratio = out <= 0 ? 0 : entry.value / out * 100;
        buffer.writeln(
          '- ${entry.key}：${money(entry.value)}（${ratio.toStringAsFixed(0)}%）',
        );
      }
      if (ranked.length > 8) {
        buffer.writeln('- 其余 ${ranked.length - 8} 个分类已省略');
      }
    }

    buffer
      ..writeln()
      ..writeln('【明细】格式：日期 | 类型 | 名称 | 分类 | 金额');
    buffer.write(
      _bounded(expenses.map(expenseLine).toList(), expenses.length, '条账目'),
    );
    return buffer.toString();
  }

  static String health(List<Map<String, dynamic>> meds, DateTime now) {
    final expired = meds
        .where((m) => ExpiryInfo.parse(m['expiry']).isExpired(now))
        .length;
    final soon = meds
        .where((m) => ExpiryInfo.parse(m['expiry']).isExpiringWithin(90, now))
        .length;
    final missing = meds
        .where((m) => !ExpiryInfo.parse(m['expiry']).hasDate)
        .length;

    final buffer = StringBuffer()
      ..writeln('你是家庭健康与用药信息助手，不是医生。')
      ..writeln('只能基于下面提供的药箱数据做健康科普，不诊断、不处方、不给出个体化剂量。')
      ..writeln('孕哺期、儿童、老人、多病共存、多药联用、疑似相互作用或症状加重时，'
          '一律建议咨询药师或医生。')
      ..writeln('如果用户在描述急症，先提醒立即联系当地急救（中国大陆为 120）。')
      ..writeln()
      // 与账本同理：不点明优先级，模型会把「我这有三盒护肝片」理解成
      // 「用户想了解药箱现状」，于是回一段概览、一条都没加（真机实测踩到）。
      ..writeln('【先判断用户想干什么】')
      ..writeln('用户的每一句话，要么是**让你往药箱里加药**，要么是**向你提问**。')
      ..writeln('如果他在说自己有什么药、有多少（「我这有三盒护肝片」'
          '「家里还有维生素」），那就是**要你记下来**，'
          '请立刻按动作协议录入，**不要**当成查询去复述药箱概览，'
          '也**不要**先追问保质期等信息 —— 哪怕这句话里没有「加」字。')
      ..writeln('只有他确实在问（「我这药还能吃吗」「有没有过期的」）时才做分析。')
      ..writeln('判断不清时：先录入，再在正文里说明。')
      ..writeln()
      // 真机实测：「帮我把布洛芬和连花清瘟加到药箱里去」这种**明确的祈使句**
      // 被回复成了自我介绍 + 功能清单，一条药都没加。所以要额外强调：
      // 带「加/记/录入」等动词的句子是**命令**，必须立刻执行，
      // 绝不能回一段自我介绍或反问。
      ..writeln('【只处理最后一条用户消息，且祈使句必须执行】')
      ..writeln('历史里的话**都已经处理过了**，动作计划只能来自**最后一条用户消息**，'
          '不要把历史里的药品名再录一遍（会造成重复加药）。')
      ..writeln('如果最后一条是**命令**（含「加」「添加」「录入」「记」'
          '「加到药箱里去」等），你必须**立刻输出动作计划把它加进去**。'
          '严禁在这种情况下回复自我介绍、功能介绍、'
          '「我可以帮你做这些事」或反问「想先加点什么」—— '
          '用户已经说清楚了，工具性回复等于没干活。')
      ..writeln()
      ..writeln('【药箱概览】')
      ..writeln('药品总数：${meds.length}')
      ..writeln('已过期：$expired')
      ..writeln('90 天内到期：$soon')
      ..writeln('未填写有效期：$missing')
      ..writeln()
      ..writeln('【明细】格式：药品 | 成分 | 规格 | 库存 | 有效期 | 储存');
    buffer.write(_bounded(meds.map(medLine).toList(), meds.length, '项药品'));
    return buffer.toString();
  }

  /// 按预算拼接明细，并把截断情况明确写进提示词。
  static String _bounded(List<String> lines, int total, String unit) {
    if (lines.isEmpty) return '（暂无数据）';
    final buffer = StringBuffer();
    var used = 0;
    var kept = 0;
    for (final line in lines.take(detailLimit)) {
      used += line.length;
      if (used > detailBudget && kept > 0) break;
      buffer.writeln(line);
      kept++;
    }
    if (kept < total) {
      buffer.writeln('（共 $total $unit，为控制长度仅列出最近 $kept $unit，其余未列出）');
    }
    return buffer.toString();
  }

  static String _text(dynamic v) => v?.toString().trim() ?? '';

  static String _or(dynamic v, String fallback) {
    final t = _text(v);
    return t.isEmpty ? fallback : t;
  }
}
