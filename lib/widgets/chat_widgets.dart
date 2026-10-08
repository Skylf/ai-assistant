import 'package:flutter/material.dart';

import 'package:intl/intl.dart';

import '../ai/chart.dart';
import '../ai/web_search.dart';
import '../core/chat_mode.dart';
import '../data/store.dart';
import '../theme.dart';
import 'chart.dart' as charts;
import 'common.dart';
import 'markdown.dart';

/// 聊天相关的展示组件。
///
/// 0.4A 把 AI 拆成账本与健康两个独立模块。每个模块有两层界面：
///  1. 模块介绍页（[lib/pages/module_home.dart]）：介绍能力、列对话、创建对话；
///  2. 对话页（[lib/pages/chat.dart]）：只有消息与输入框，不放别的东西。
/// 这里放两层共用的展示组件，配色与文案都取各自的 [ChatMode]。

/// 日期分隔条。
class DateSeparator extends StatelessWidget {
  const DateSeparator({super.key, required this.at});

  final DateTime at;

  static bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final label = sameDay(at, now)
        ? '今天 ${DateFormat('HH:mm').format(at)}'
        : DateFormat('M 月 d 日 HH:mm').format(at);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.x3),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.x3,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: Tone.surfaceMuted,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label, style: Theme.of(context).textTheme.labelSmall),
        ),
      ),
    );
  }
}

/// 一条消息气泡。
///
/// 0.4C 起支持**长按**弹出操作菜单（复制 / 修改 / 删除）。用户的要求是
/// 「用户发出去的消息新增修改、复制功能」—— 做成长按而不是每条气泡下面挂一排
/// 小图标：聊天气泡本身很矮，挂图标会把每一条都撑高，整屏消息条数直接砍半。
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mode,
    this.onLongPress,
  });

  final ChatMessage message;
  final ChatMode mode;

  /// 长按回调。为空时长按无反应（例如只读场景）。
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    // 对话内容用 bodySmall（13sp）：聊天里文字量大，bodyMedium 在手机上偏大。
    final textStyle = Theme.of(context).textTheme.bodySmall;

    if (message.role == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          // 用 opaque 保证气泡内的空白区域也能触发长按
          behavior: HitTestBehavior.opaque,
          onLongPress: onLongPress,
          child: Container(
            margin: const EdgeInsets.only(bottom: Gap.x3, left: 40),
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.x3 + 2,
              vertical: Gap.x2 + 2,
            ),
            decoration: BoxDecoration(
              color: mode.accent,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(5),
              ),
            ),
            child: Text(
              message.content,
              style: textStyle?.copyWith(color: Colors.white, height: 1.35),
            ),
          ),
        ),
      );
    }

    final parsed = ChartParser.parse(message.content);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.x3, right: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AssistantAvatar(
            size: 28,
            icon: mode.icon,
            tint: mode.accentContainer,
            color: mode.accent,
          ),
          const SizedBox(width: Gap.x2),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.x3 + 2,
                vertical: Gap.x3,
              ),
              decoration: BoxDecoration(
                color: Tone.surface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(5),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
                border: Border.all(color: Tone.outline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (parsed.text.trim().isNotEmpty)
                    SimpleMarkdown(parsed.text, baseStyle: textStyle),
                  if (parsed.chart != null) ...[
                    if (parsed.text.trim().isNotEmpty)
                      const SizedBox(height: Gap.x3),
                    charts.AiChart(parsed.chart!),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 等待回复时的气泡，超过 3 秒开始显示秒数。
///
/// ## 0.4F：显示「正在做什么」，而不是只有一句固定的「思考中」
///
/// 用户明确要求「思考文字要体现出正在联网搜索」。
///
/// 关键设计：这句话**不是定时器演出来的**。[phase] 由 `Store` 在**真的收到**
/// 服务端事件时回调写入 —— 只有真回了 `server_tool_use`，才会显示
/// 「正在联网搜索…」。若服务端压根没搜，这里就一直是「正在思考…」。
///
/// 为什么必须这样：0.4D 我曾经让界面写「未真正联网核实」，而那条分支
/// 从来没执行过 —— **界面上显示的状态必须对应一个真实发生的事件**，
/// 否则就是在骗用户。
class ThinkingBubble extends StatelessWidget {
  const ThinkingBubble({
    super.key,
    required this.seconds,
    required this.mode,
    this.phase,
  });

  final int seconds;
  final ChatMode mode;

  /// 当前真实阶段。为 null 时退回模块自己的默认文案。
  final SearchPhase? phase;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.x3, right: 24),
    child: Row(
      children: [
        AssistantAvatar(
          icon: mode.icon,
          tint: mode.accentContainer,
          color: mode.accent,
        ),
        const SizedBox(width: Gap.x2),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.x3 + 2,
              vertical: Gap.x3,
            ),
            decoration: BoxDecoration(
              color: Tone.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Tone.outline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: Gap.x3),
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 联网搜索时加一个小图标：一眼能看出它在联网，而不是只在「想」。
                      if (phase == SearchPhase.searching) ...[
                        const Icon(
                          Icons.travel_explore_outlined,
                          size: 14,
                          color: Tone.iconBlue,
                        ),
                        const SizedBox(width: Gap.x1),
                      ],
                      Flexible(
                        child: Text(
                          phase?.label ?? mode.thinkingText,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                if (seconds >= 3) ...[
                  const SizedBox(width: Gap.x2),
                  Text(
                    '${seconds}s',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// 模块介绍卡：助手自我介绍 + 能力清单 + 安全声明。
///
/// 这是**模块介绍页**顶部的卡片，不在对话页里 —— 对话页只放消息与输入框。
class ModeHeroCard extends StatelessWidget {
  const ModeHeroCard({super.key, required this.mode});

  final ChatMode mode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Gap.card),
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(Gap.radius),
        border: Border.all(color: Tone.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AssistantAvatar(
                size: 48,
                icon: mode.icon,
                tint: mode.accentContainer,
                color: mode.accent,
              ),
              const SizedBox(width: Gap.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '你好，我是${mode.title}',
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: Gap.hairline),
                    Text(mode.entrySlogan, style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.x4),
          for (final row in mode.features)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.x3),
              child: Row(
                children: [
                  IconTile(
                    icon: row.$1,
                    size: 32,
                    iconSize: 17,
                    tint: mode.accentContainer,
                    color: mode.accent,
                  ),
                  const SizedBox(width: Gap.x3),
                  Expanded(
                    child: Text(row.$2, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(Gap.x3),
            decoration: BoxDecoration(
              color: mode == ChatMode.health
                  ? Tone.tintAmber
                  : Tone.surfaceMuted,
              borderRadius: BorderRadius.circular(Gap.x3),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  mode == ChatMode.health
                      ? Icons.health_and_safety_outlined
                      : Icons.info_outline,
                  size: 16,
                  color: mode == ChatMode.health
                      ? Tone.warning
                      : Tone.textSecondary,
                ),
                const SizedBox(width: Gap.x2),
                Expanded(
                  child: Text(
                    mode.disclaimer,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 对话列表里的一行：标题 + 更新时间/消息数 + 长按菜单。
class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.conversation,
    required this.mode,
    required this.active,
    required this.onTap,
    this.onLongPress,
  });

  final Conversation conversation;
  final ChatMode mode;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = [
      DateFormat('M/d HH:mm').format(conversation.updatedAt),
      '记忆${conversation.memory.label}',
    ].join(' · ');

    return Material(
      color: active ? mode.accentContainer : Tone.surface,
      borderRadius: BorderRadius.circular(Gap.inputRadius),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(Gap.inputRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.x3,
            vertical: Gap.x3,
          ),
          child: Row(
            children: [
              // 置顶的对话换成实心图钉图标，扫一眼就能区分（0.4C）。
              // 只靠排序不够 —— 用户需要知道「为什么这条在最上面」。
              Icon(
                conversation.isPinned
                    ? Icons.push_pin
                    : Icons.chat_bubble_outline,
                size: 18,
                color: conversation.isPinned
                    ? mode.accent
                    : (active ? mode.accent : Tone.textTertiary),
              ),
              const SizedBox(width: Gap.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conversation.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: Gap.hairline),
                    Text(subtitle, style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: active ? mode.accent : Tone.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部输入栏。字号比正文小一档（12sp），长时间对话时更耐看。
class ChatInputBar extends StatelessWidget {
  const ChatInputBar({
    super.key,
    required this.controller,
    required this.busy,
    required this.onSend,
    required this.mode,
    this.onStop,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;
  final ChatMode mode;

  /// 点「暂停」时调用。为 null 时忙态只能显示转圈（旧行为）。
  ///
  /// 0.4B：用户要求「发送按钮在等待时变成暂停按钮，点击可暂停回复」。
  /// 之前忙态是一个**不可点**的转圈 —— 用户只能干等，最长要等到超时。
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    // 忙态且支持暂停时，按钮变暂停图标并可点；否则退回旧的转圈。
    final canStop = busy && onStop != null;
    return Container(
      padding: EdgeInsets.fromLTRB(
        Gap.x4,
        Gap.x2 + 2,
        Gap.x4,
        Gap.x2 + 2 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      decoration: const BoxDecoration(
        color: Tone.surface,
        border: Border(top: BorderSide(color: Tone.outline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              // 等待回复时也允许继续打字：清空输入框的行为不该强迫用户
              // 在等待期间什么都不能做。暂停后可以直接把打好的字发出去。
              style: const TextStyle(fontSize: 12, height: 1.35),
              // ⚠️ 回车 = 换行，**不是**发送（0.4F 用户要求）。
              //
              // 原来这里是 `TextInputAction.send` + `onSubmitted: onSend`，
              // 于是回车直接发出去 —— 而输入框本身是 `maxLines: 4` 的多行框。
              // 多行框却不给换行，等于**能力被抢走了**：用户想分两段写一句
              // 稍长的问题（比如先列药名再问禁忌）根本没机会，按一下就发。
              //
              // 两处必须成对改：
              //  · `TextInputAction.newline` 才是「回车产生换行符」这个动作；
              //  · 必须**同时去掉 `onSubmitted`** —— 留着它，回车仍会被当成提交。
              //
              // 代价说清楚：现在**只能点右边按钮发送**。这对多行输入是合理的
              // （否则你没法输入换行），但也意味着少了一个快捷方式。
              // 这是用户明确要的取舍，不是遗漏。
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: mode.inputHint,
                hintStyle: const TextStyle(fontSize: 12),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Gap.x3,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: Gap.x2),
          SizedBox(
            width: 40,
            height: 40,
            child: Material(
              color: busy ? Tone.textTertiary : mode.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: busy ? (canStop ? onStop : null) : onSend,
                child: canStop
                    ? const Tooltip(
                        message: '暂停回复',
                        child: Icon(
                          Icons.stop_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      )
                    : busy
                    ? const Padding(
                        // 11 = (按钮 40 − 指示器 18) / 2，让转圈与发送图标在同一个
                        // 位置。它是从图标尺寸推导出来的居中值，不是随手间距，所以
                        // 不取自 Gap 网格；改成别的数字会让两种状态对不齐。
                        padding: EdgeInsets.all(11),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send, color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单行文本编辑弹窗（重命名对话 / 修改消息）。
///
/// 用自己的 State 持有 controller：在 builder 里现场创建、又在 showDialog
/// 返回后立刻 dispose，会在弹窗退场动画那一帧触发「controller 已释放」断言。
///
/// 0.4C 参数化：原先写死「重命名对话」+ `maxLength: 30` + 单行。修改消息要复用它，
/// 但一条消息可以远超 30 字，所以标题/提示/长度/行数都开放出来。
class RenameDialog extends StatefulWidget {
  const RenameDialog({
    super.key,
    required this.initial,
    this.title = '重命名对话',
    this.hint = '对话名称',
    this.maxLength = 30,
    this.maxLines = 1,
    this.confirmLabel = '保存',
  });

  final String initial;
  final String title;
  final String hint;

  /// 字符上限。对话名 30 够用；消息给 2000。
  final int maxLength;

  /// 输入框最大行数。1 = 单行（对话名）；消息给 6，长句子能看见全文。
  final int maxLines;

  final String confirmLabel;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: widget.maxLength,
      minLines: 1,
      maxLines: widget.maxLines,
      decoration: InputDecoration(hintText: widget.hint),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
