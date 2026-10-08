import '../core/topic.dart';

export '../core/topic.dart';

/// 一个独立对话。
///
/// 0.2A 之前只有「账本 / 健康」两个固定主题的单一会话，这里升级为可创建、
/// 可删除、可分别设置记忆作用域的多个对话。
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.topic,
    required this.memory,
    required this.createdAt,
    required this.updatedAt,
    this.pinnedAt,
  });

  final String id;
  final String title;
  final Topic topic;
  final MemoryScope memory;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 置顶时间。为空表示未置顶（0.4C 新增）。
  ///
  /// 存**时间**而不是 `bool`，有两个理由：
  ///  1. 多条置顶时能按「最近置顶的排最前」排序，比布尔值信息量大；
  ///  2. 老库补列时默认 `NULL` 天然就是「未置顶」，不需要额外回填。
  final DateTime? pinnedAt;

  bool get isPinned => pinnedAt != null;

  bool get isGlobalMemory => memory == MemoryScope.global;

  Conversation copyWith({
    String? title,
    Topic? topic,
    MemoryScope? memory,
    DateTime? updatedAt,
    DateTime? pinnedAt,
    bool clearPin = false,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    topic: topic ?? this.topic,
    memory: memory ?? this.memory,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    // 取消置顶要写 NULL，而 `pinnedAt: null` 在可空参数上等于「不修改」，
    // 所以另给一个显式开关，避免「想取消置顶却什么也没发生」。
    pinnedAt: clearPin ? null : (pinnedAt ?? this.pinnedAt),
  );

  static Conversation fromRow(Map<String, dynamic> row) => Conversation(
    id: row['id']?.toString() ?? '',
    title: row['title']?.toString() ?? '新对话',
    topic: Topic.fromCode(row['topic']),
    memory: MemoryScope.fromCode(row['memory']),
    createdAt:
        DateTime.tryParse(row['createdAt']?.toString() ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(row['updatedAt']?.toString() ?? '') ?? DateTime.now(),
    pinnedAt: DateTime.tryParse(row['pinnedAt']?.toString() ?? ''),
  );

  Map<String, dynamic> toRow() => {
    'id': id,
    'title': title,
    'topic': topic.code,
    'memory': memory.code,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'pinnedAt': pinnedAt?.toIso8601String(),
  };
}

/// 密码生成器保存的记录。
///
/// 有意不保存密码明文：本机数据库是明文 SQLite，保存明文等于把用户的账号
/// 密码随手写进普通文件。这里只保存用途、参数与强度，供回溯「我上次用了多
/// 强的密码」，需要明文时由用户自行复制。
class SavedPassword {
  const SavedPassword({
    required this.id,
    required this.label,
    required this.site,
    required this.length,
    required this.strength,
    required this.entropy,
    required this.createdAt,
  });

  final String id;
  final String label;
  final String site;
  final int length;

  /// 0-4 级强度。
  final int strength;
  final double entropy;
  final DateTime createdAt;

  static SavedPassword fromRow(Map<String, dynamic> row) => SavedPassword(
    id: row['id']?.toString() ?? '',
    label: row['label']?.toString() ?? '',
    site: row['site']?.toString() ?? '',
    length: row['length'] is num ? (row['length'] as num).toInt() : 0,
    strength: row['strength'] is num ? (row['strength'] as num).toInt() : 0,
    entropy: row['entropy'] is num ? (row['entropy'] as num).toDouble() : 0,
    createdAt:
        DateTime.tryParse(row['createdAt']?.toString() ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toRow() => {
    'id': id,
    'label': label,
    'site': site,
    'length': length,
    'strength': strength,
    'entropy': entropy,
    'createdAt': createdAt.toIso8601String(),
  };
}
