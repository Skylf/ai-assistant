import 'package:flutter/material.dart';

import '../core/chat_mode.dart';
import '../data/store.dart';
import '../theme.dart';
import 'module_home.dart';

/// AI 模块入口页。
///
/// 0.4A：点击 AI 先看到「账本分析」与「健康科普」两个入口，点进去才进入具体
/// 界面。两个模块从界面到机制完全独立 —— 各自的对话列表、消息、记忆、提示词
/// 互不影响，这里是唯一的交汇点，也仅用于选择进入哪一个。
class AiHubPage extends StatefulWidget {
  const AiHubPage({super.key, required this.store});

  final Store store;

  @override
  State<AiHubPage> createState() => AiHubPageState();
}

class AiHubPageState extends State<AiHubPage> {
  Store get store => widget.store;

  /// 当前是否有属于该模式的对话。
  List<Conversation> _conversationsOf(ChatMode mode) =>
      store.conversations.where((c) => c.topic == mode.topic).toList();

  /// 打开某个模块。
  ///
  /// 进入的是该模块的介绍页（[ModuleHomePage]）；[question] 非空时，介绍页会
  /// 新建一个对话并在对话页里自动发送这个问题。
  Future<void> open(ChatMode mode, {String question = ''}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModuleHomePage(
          store: store,
          mode: mode,
          initialQuestion: question,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(
          Gap.page,
          Gap.x3,
          Gap.page,
          Gap.x6,
        ),
        children: [
          Text(
            'AI 助手',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: Gap.x1 + 2),
          Text(
            '账本分析与健康科普是两个独立模块，各自存放对话与记忆',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Gap.x5),
          for (final mode in ChatMode.values) ...[
            _ModeEntry(
              mode: mode,
              conversationCount: _conversationsOf(mode).length,
              lastAt: _conversationsOf(mode).isEmpty
                  ? null
                  : _conversationsOf(mode).first.updatedAt,
              onTap: () => open(mode),
            ),
            if (mode != ChatMode.values.last) const SizedBox(height: Gap.x4),
          ],
          const SizedBox(height: Gap.x5),
          _privacyNotice(context),
        ],
      ),
    );
  }

  Widget _privacyNotice(BuildContext context) => Container(
    padding: const EdgeInsets.all(Gap.card),
    decoration: BoxDecoration(
      color: Tone.tintTeal,
      borderRadius: BorderRadius.circular(Gap.radius),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.shield_outlined, size: 20, color: Tone.primary),
        const SizedBox(width: Gap.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '本地优先',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: Gap.hairline),
              Text(
                '两个模块都只在本机保存对话记录；只有你主动提问时，'
                '才会把对应的账目或药箱摘要发送给模型服务商。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 一个模块的入口卡片。
class _ModeEntry extends StatelessWidget {
  const _ModeEntry({
    required this.mode,
    required this.conversationCount,
    required this.onTap,
    this.lastAt,
  });

  final ChatMode mode;
  final int conversationCount;
  final DateTime? lastAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Tone.surface,
      borderRadius: BorderRadius.circular(Gap.radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Gap.radius),
        child: Container(
          padding: const EdgeInsets.all(Gap.card),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Gap.radius),
            border: Border.all(color: Tone.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: mode.accentContainer,
                      borderRadius: BorderRadius.circular(Gap.x4),
                    ),
                    child: Icon(mode.icon, size: 26, color: mode.accent),
                  ),
                  const SizedBox(width: Gap.x4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mode.entryTitle,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: Gap.hairline),
                        Text(
                          mode.entrySubtitle,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Gap.x2),
                  Icon(Icons.chevron_right, color: mode.accent),
                ],
              ),
              const SizedBox(height: Gap.x4),
              Row(
                children: [
                  Icon(
                    Icons.forum_outlined,
                    size: 15,
                    color: Tone.textTertiary,
                  ),
                  const SizedBox(width: Gap.x2),
                  Text(
                    conversationCount == 0
                        ? '还没有对话'
                        : '$conversationCount 个对话',
                    style: theme.textTheme.labelSmall,
                  ),
                  const Spacer(),
                  Text(
                    lastAt == null ? mode.entrySlogan : _relative(lastAt!),
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _relative(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return '刚刚有更新';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${at.year}/${at.month}/${at.day}';
  }
}
