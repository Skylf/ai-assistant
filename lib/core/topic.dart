import 'package:flutter/material.dart';

/// AI 对话主题。替代旧代码里散落的 `'h'` / `'f'` 裸字符串。
/// 单独放在 core 下，避免 `ai/prompt.dart` 与 `data/models.dart` 互相 import
/// 形成循环依赖。
enum Topic {
  finance('f', '账本分析', '洞察收支，合理规划'),
  health('h', '健康科普', '用药知识，守护健康');

  const Topic(this.code, this.label, this.slogan);

  /// 存库用短码，保持与 0.2A 之前的数据兼容。
  final String code;
  final String label;

  /// 主题选择卡上的副标题。
  final String slogan;

  /// 界面上的主题名（与 [label] 同义，供通用组件使用）。
  String get title => label;

  static Topic fromCode(dynamic code) =>
      code == health.code ? Topic.health : Topic.finance;
}

/// 记忆作用域。放在 core 下同样是为了避免模块间循环依赖。
enum MemoryScope {
  /// 只在当前对话内保留上下文。
  local(
    'local',
    '仅当前对话',
    '对话内保留上下文，不写入全局记忆',
    '仅本对话',
  ),

  /// 允许该对话的要点沉淀为全局记忆，跨对话共享。
  global(
    'global',
    '存入全局记忆',
    '该对话内容可作为全局记忆，被其他对话引用',
    '全局记忆',
  ),

  /// 完全不向模型发送历史，每次都是新会话。
  off('off', '不记忆', '不向模型发送任何历史消息，每次都是新会话', '不记忆');

  const MemoryScope(this.code, this.label, this.detail, this.shortLabel);

  final String code;
  final String label;
  final String detail;

  /// 紧凑展示用的短标签（例如 AI 页顶部的小胶囊）。
  final String shortLabel;

  IconData get icon => switch (this) {
    MemoryScope.local => Icons.chat_bubble_outline,
    MemoryScope.global => Icons.public,
    MemoryScope.off => Icons.visibility_off_outlined,
  };

  /// **新建对话**的记忆默认值。
  ///
  /// 2026-10-08 用户要求改为 [MemoryScope.global]（原为 `local`）。
  /// 收在一处而不是散在各个 `?? MemoryScope.local` 兜底里，是因为这个默认值
  /// 出现在 5 个地方（新建对话、读消息、构造提示词、对话页展示、反序列化兜底），
  /// 散着写就会出现「新建时是全局、但某条路径兜底又变回仅当前对话」这种
  /// **同一件事有两种答案**的状态 —— 那种不一致极难从现象反推。
  ///
  /// 它同时充当**反序列化的兜底**：库里存了无法识别的记忆码时按新默认值走，
  /// 与「新建对话」保持一致。
  ///
  /// ⚠️ 这个改动只影响**新建的对话**。已经存在的对话保留它们自己存的记忆档位
  /// （`updateConversation(memory:)` 显式存下来的值），
  /// **不会被静默改写** —— 用户对某个对话做过的选择不该被一次升级抹掉。
  ///
  /// ⚠️ 语义提醒：`global` 的含义是「这个对话的内容可以沉淀为全局记忆、
  /// 被其他对话引用」。默认改成它，意味着**新对话之间默认共享上下文**。
  /// 这是用户的明确选择，但它确实降低了对话之间的隔离性 ——
  /// 用户仍可在对话页把某个对话单独改回「仅当前对话」或「不记忆」。
  static const defaultScope = MemoryScope.global;

  static MemoryScope fromCode(dynamic code) => MemoryScope.values.firstWhere(
    (scope) => scope.code == code?.toString(),
    orElse: () => defaultScope,
  );
}
