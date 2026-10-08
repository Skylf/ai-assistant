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
  /// 只在当前对话内保留上下文（默认，最保守）。
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

  static MemoryScope fromCode(dynamic code) => MemoryScope.values.firstWhere(
    (scope) => scope.code == code?.toString(),
    orElse: () => MemoryScope.local,
  );
}
