import 'package:flutter/material.dart';

import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'settings.dart';

/// AI 对话设置（二级页）。
///
/// 说明主题自动识别与三档记忆的作用范围，并给出当前对话的快捷入口。
class ChatSettingsPage extends StatelessWidget {
  const ChatSettingsPage({super.key, required this.store});

  final Store store;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => SettingsScaffold(
      title: 'AI 对话设置',
      caption: '这些机制决定了 AI 能看到多少你的本地数据。',
      children: [
        SettingsGroup(
          title: '主题识别',
          children: [
            const SettingsRow(
              icon: Icons.call_split,
              tint: Tone.tintBlue,
              color: Tone.iconBlue,
              title: '两个模块完全独立',
              subtitle: '点开 AI 先选「账本分析」或「健康科普」，'
                  '两者的对话、记忆与提示词互不影响。',
            ),
            const SettingsRow(
              icon: Icons.swap_horiz,
              tint: Tone.tintTeal,
              color: Tone.iconTeal,
              title: '不会自动切换模块',
              subtitle: '在账本分析里问药品问题也留在账本分析，'
                  '想聊健康请回到入口页进「健康科普」。',
            ),
          ],
        ),
        SettingsGroup(
          title: '记忆机制',
          children: [
            for (final scope in MemoryScope.values)
              SettingsRow(
                icon: scope.icon,
                tint: scope == MemoryScope.off
                    ? Tone.tintSlate
                    : (scope == MemoryScope.global
                          ? Tone.tintPurple
                          : Tone.tintGreen),
                color: scope == MemoryScope.off
                    ? Tone.iconSlate
                    : (scope == MemoryScope.global
                          ? Tone.iconPurple
                          : Tone.iconGreen),
                title: scope.label,
                subtitle: scope.detail,
              ),
          ],
        ),
        SettingsGroup(
          title: '当前状态',
          children: [
            SettingsRow(
              icon: Icons.chat_bubble_outline,
              tint: Tone.tintBlue,
              color: Tone.iconBlue,
              title: '当前对话',
              subtitle: store.activeConversation?.title ?? '暂无对话',
              trailingText: store.activeConversation == null
                  ? ''
                  : '记忆${store.activeConversation!.memory.label}',
            ),
            SettingsRow(
              icon: Icons.folder_outlined,
              tint: Tone.tintGreen,
              color: Tone.iconGreen,
              title: '对话总数',
              subtitle: '在 AI 页面右上角可以新建、重命名、清空与删除',
              trailingText: '${store.conversations.length} 个',
            ),
          ],
        ),
        const SizedBox(height: Gap.x4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: Text(
            '无论选择哪一档记忆，消息都会先保存在本机；「关闭记忆」只表示发送给模型时'
            '不带上下文，本地回看不受影响。',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ),
  );
}
