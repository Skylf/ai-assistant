import 'package:flutter/material.dart';

import '../core/topic.dart';
import '../theme.dart';

/// AI 模块的两种模式。
///
/// 0.4A 的要求是「账本分析与健康科普从 UI 到机制完全独立、互不影响」。
/// 这里的做法是把「模式」当作一个显式参数贯穿到底，而不是像以前那样
/// 根据输入内容在两种主题之间自动跳转：
///
///  - 每个模式只认自己的对话（[conversationsOf]），消息、记忆、提示词、
///    欢迎文案、建议问题、配色全部按模式取；
///  - 发送消息不再猜主题（[ChatPage.send] 的 `autoTopic` 默认为 false），
///    所以在账本模式里问药品问题也只会留在账本模式，不会把用户丢到另一个模块；
///  - 两种模式各自持有独立的对话列表，互不可见。
enum ChatMode {
  finance(
    topic: Topic.finance,
    label: '账本分析',
    title: '账本分析助手',
    shortLabel: '账本',
    entryTitle: '账本分析',
    entrySubtitle: '看懂收支结构，找到可以省下的钱',
    entrySlogan: '基于你本机的账目数据',
    icon: Icons.insights_outlined,
    inputHint: '想了解账本的什么？例如「本月哪一类花得最多」',
    thinkingText: '正在分析你的账目数据…',
    disclaimer: 'AI 建议基于你本机账目数据生成，仅供参考，不构成投资或财务建议。',
    emptyTitle: '还没有账本对话',
    emptyDetail: '新建一个对话，开始分析你的收支',
  ),
  health(
    topic: Topic.health,
    label: '健康科普',
    title: '健康科普助手',
    shortLabel: '健康',
    entryTitle: '健康科普',
    entrySubtitle: '用药常识与药品整理，守护家人健康',
    entrySlogan: '基于你本机的药箱数据',
    icon: Icons.health_and_safety_outlined,
    inputHint: '想了解什么？例如「哪些药即将到期」',
    thinkingText: '正在整理健康科普信息…',
    disclaimer: '健康科普不构成诊断、处方或个体化用药剂量建议；出现紧急症状请拨打 120。',
    emptyTitle: '还没有健康对话',
    emptyDetail: '新建一个对话，整理家庭药箱',
  );

  const ChatMode({
    required this.topic,
    required this.label,
    required this.title,
    required this.shortLabel,
    required this.entryTitle,
    required this.entrySubtitle,
    required this.entrySlogan,
    required this.icon,
    required this.inputHint,
    required this.thinkingText,
    required this.disclaimer,
    required this.emptyTitle,
    required this.emptyDetail,
  });

  /// 该模式对应的主题。落库时用它区分对话归属。
  final Topic topic;

  /// 模式名，例如「账本分析」。
  final String label;

  /// 助手自称，例如「账本分析助手」。
  final String title;

  /// 导航栏等窄空间用的短名。
  final String shortLabel;

  /// 入口卡片标题。
  final String entryTitle;

  /// 入口卡片副标题。
  final String entrySubtitle;

  /// 入口卡片上的一行说明。
  final String entrySlogan;

  final IconData icon;

  /// 输入框提示语。
  final String inputHint;

  /// 等待回复时的文案。
  final String thinkingText;

  /// 安全声明。
  final String disclaimer;

  /// 该模式下一个对话都没有时的提示。
  final String emptyTitle;
  final String emptyDetail;

  /// 品牌色。账本用主色，健康用青色系，让两个模块一眼可辨。
  Color get accent => this == ChatMode.health ? Tone.primaryHealth : Tone.primary;

  /// 品牌色的浅底，用于图标块与选中态。
  Color get accentContainer => this == ChatMode.health
      ? Tone.primaryHealthContainer
      : Tone.primaryContainer;

  /// 图标块配色。
  Color get iconColor => this == ChatMode.health ? Tone.iconTeal : Tone.iconBlue;

  /// 图标块底色。
  Color get iconTint => this == ChatMode.health ? Tone.tintTeal : Tone.tintBlue;

  /// 该模式的功能说明行（欢迎卡片用）。
  List<(IconData, String)> get features => this == ChatMode.health
      ? const [
          (Icons.medication_outlined, '整理家庭药箱'),
          (Icons.menu_book_outlined, '用药常识科普'),
          (Icons.category_outlined, '药品分类与提示'),
          (Icons.local_hospital_outlined, '提醒你及时就医'),
        ]
      : const [
          (Icons.pie_chart_outline, '看懂收支结构'),
          (Icons.trending_up, '找到可以省下的钱'),
          (Icons.flag_outlined, '给出本月预算建议'),
          (Icons.receipt_long_outlined, '按分类逐项拆解'),
        ];

  /// 该模式的建议问题（欢迎卡片与输入栏上方胶囊共用）。
  List<String> get suggestions => this == ChatMode.health
      ? const ['分析我的药箱', '哪些药即将到期？', '感冒药能一起吃吗？']
      : const ['查看收支明细', '按分类分析', '给我一些节省建议'];

  /// 新建对话时的默认名称。
  String get defaultConversationTitle =>
      this == ChatMode.health ? '健康科普' : '账本分析';

  static ChatMode of(Topic topic) =>
      topic == Topic.health ? ChatMode.health : ChatMode.finance;

  /// 桌面组件类型 → 该用哪个模块（0.5.2）。
  ///
  /// ## 为什么这个映射必须存在，而且不能猜
  ///
  /// 用户在桌面上点的是「AI 记账」还是「AI 记药」，**这件事本身就是模块归属的
  /// 唯一依据**。它在 0.4A 已被证明是必须的：真机上出现过在账本里说
  /// 「加到账本里去」，模型却给出 `med_add`，结果往药箱写了一条药。
  /// 所以模块由用户点的那个组件决定，**绝不交给模型或关键词去推断** ——
  /// 这里按 `kind` 前缀直接映射，`expense*` → 账本，其余 → 健康。
  ///
  /// [kind] 为空（不是从组件进来）时回落到账本模式，与本文件其它兜底一致。
  static ChatMode fromWidgetKind(String? kind) {
    final value = kind?.trim() ?? '';
    if (value.isEmpty) return ChatMode.finance;
    return value.startsWith('expense') ? ChatMode.finance : ChatMode.health;
  }
}
