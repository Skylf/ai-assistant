import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/common.dart';

/// 启动失败页。
///
/// 存在的意义：本地数据库结构异常、迁移失败这类问题以前会让 `runApp` 直接
/// 不执行，用户看到纯白屏。现在把错误摆到界面上，至少能看清发生了什么、
/// 并提供一个重试入口，不用连电脑抓 logcat。
class BootErrorPage extends StatelessWidget {
  const BootErrorPage({super.key, required this.error, this.onRetry});

  /// 启动阶段的异常；理论上不为空，做成可空只为防御。
  final Object? error;

  final Future<void> Function()? onRetry;

  /// 用户能实际执行的指引。
  ///
  /// 之前这里写的是「请在『应用设置 → 数据管理』导出数据后反馈」—— 那条路在
  /// 启动失败时**根本进不去**（数据管理页属于 App 内部），等于在最需要备份的
  /// 时刻给了用户一个点不到的建议。现在改成真的能做的事：先重试（瞬时错误有用），
  /// 再给出错误详情让用户截图反馈，最后才是不情愿的兜底（会丢数据，必须说清）。
  static const _hint =
      '本地数据库可能处于旧版本结构，或上次写入被中断。\n'
      '• 先点「重试」：如果只是上次写入被打断，重试通常就能恢复。\n'
      '• 一直失败的话，请把上面「错误详情」里的文字截图反馈，'
      '它会直接指出是哪张表、哪一列出的问题。\n'
      '• 最后的手段是清除应用数据后重新开始 —— '
      '这会删除本机的账本、药箱、对话与密码记录，且无法撤销。';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x6, Gap.page, Gap.x6),
          children: [
            IconTile(
              icon: Icons.report_gmailerrorred_outlined,
              tint: Tone.tintRed,
              color: Tone.error,
              size: 56,
            ),
            const SizedBox(height: Gap.x4),
            Text('应用启动失败', style: theme.textTheme.headlineSmall),
            const SizedBox(height: Gap.x2),
            Text(
              '数据没有被修改或删除，只是读取时出错了。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.x5),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Gap.card),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('错误详情', style: theme.textTheme.titleSmall),
                    const SizedBox(height: Gap.x2),
                    SelectableText(
                      '${error ?? '未知错误'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Gap.x4),
            Container(
              padding: const EdgeInsets.all(Gap.card),
              decoration: BoxDecoration(
                color: Tone.tintAmber,
                borderRadius: BorderRadius.circular(Gap.radius),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lightbulb_outline,
                    size: 20,
                    color: Tone.warning,
                  ),
                  const SizedBox(width: Gap.x3),
                  Expanded(
                    child: Text(_hint, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.x5),
            FilledButton.icon(
              onPressed: onRetry == null ? null : () => onRetry!(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
