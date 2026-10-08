import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../core/update.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/markdown.dart';
import 'settings.dart';

/// 检查更新（二级页）。
///
/// 对应 0.2A 文档设置里的「检查更新」条目。没有更新源时也会明确说明原因，
/// 并展示随包发布的更新日志，而不是留一个点了没反应的按钮。
class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key, required this.store});

  final Store store;

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  final _checker = const UpdateChecker();

  bool _checking = false;
  UpdateResult? _result;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    final result = await _checker.check(currentVersion: appVersion);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '检查更新',
    caption: '当前版本 $appVersion 开发版',
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x2, Gap.page, 0),
        child: _statusCard(context),
      ),
      SettingsGroup(
        title: '更新方式',
        children: [
          const SettingsRow(
            icon: Icons.download_outlined,
            tint: Tone.tintBlue,
            color: Tone.iconBlue,
            title: '开发者构建',
            subtitle: '本应用未上架应用商店，新版本由开发者构建 APK 后分发。',
          ),
          SettingsRow(
            icon: Icons.link,
            tint: Tone.tintSlate,
            color: Tone.iconSlate,
            title: '更新源',
            subtitle: UpdateChecker.manifestUrl.isEmpty
                ? '未配置（可用 --dart-define=UPDATE_MANIFEST_URL=… 指定 JSON 清单地址）'
                : UpdateChecker.manifestUrl,
          ),
        ],
      ),
      for (final entry in Changelog.entries) _changelogCard(context, entry),
      const SizedBox(height: Gap.x4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.page),
        child: Text(
          '更新不会上传你的任何数据。覆盖安装后账本、药箱与对话记录都会保留，'
          'API Key 仍存放在系统安全存储中。',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ],
  );

  Widget _statusCard(BuildContext context) {
    final result = _result;
    final IconData icon;
    final Color color;
    final Color tint;
    final String title;
    final String detail;

    if (_checking) {
      icon = Icons.sync;
      color = Tone.info;
      tint = Tone.tintBlue;
      title = '正在检查…';
      detail = '正在比对版本信息。';
    } else if (result == null) {
      icon = Icons.help_outline;
      color = Tone.textSecondary;
      tint = Tone.surfaceMuted;
      title = '尚未检查';
      detail = '点击下方按钮重新检查。';
    } else if (result.hasUpdate) {
      icon = Icons.system_update_alt;
      color = Tone.iconGreen;
      tint = Tone.tintGreen;
      title = '发现新版本 ${result.latestVersion}';
      detail = result.message;
    } else if (result.isReassuring) {
      icon = Icons.verified_outlined;
      color = Tone.income;
      tint = Tone.tintGreen;
      title = '已是最新版本';
      detail = result.message;
    } else if (result.status == UpdateStatus.notConfigured) {
      // 「没检查」不是「已是最新」：不能用绿勾与肯定语气，那会给用户错误的
      // 安全感。这里用中性色与「无法核对」的措辞，如实说明当前构建没配更新源。
      icon = Icons.help_outline;
      color = Tone.textSecondary;
      tint = Tone.surfaceMuted;
      title = '无法核对版本';
      detail = result.message;
    } else {
      icon = Icons.error_outline;
      color = Tone.warning;
      tint = Tone.tintAmber;
      title = '检查失败';
      detail = result.message;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(icon: icon, tint: tint, color: color, size: 48),
                const SizedBox(width: Gap.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: Gap.hairline),
                      Text(
                        detail,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (result != null && result.notes.isNotEmpty) ...[
              const SizedBox(height: Gap.x3),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Gap.x3),
                decoration: BoxDecoration(
                  color: Tone.surfaceMuted,
                  borderRadius: BorderRadius.circular(Gap.x3),
                ),
                child: Text(
                  result.notes,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: Gap.x3),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _checking ? null : _check,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
                    label: Text(_checking ? '检查中…' : '重新检查'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                  ),
                ),
                if (result != null && result.downloadUrl.isNotEmpty) ...[
                  const SizedBox(width: Gap.x3),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: result.downloadUrl),
                        );
                        if (!context.mounted) return;
                        toast(context, '下载地址已复制到剪贴板');
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('复制下载链接'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _changelogCard(BuildContext context, ChangelogEntry entry) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x3, Gap.page, 0),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Gap.x3,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: entry.version == appVersion
                        ? Tone.primaryContainer
                        : Tone.surfaceMuted,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    entry.version,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: entry.version == appVersion
                          ? Tone.primary
                          : Tone.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: Gap.x3),
                Expanded(
                  child: Text(
                    entry.title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (entry.version == appVersion)
                  Text('当前版本', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: Gap.x3),
            for (final line in entry.highlights)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.x2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Icon(
                        Icons.circle,
                        size: 5,
                        color: Tone.textTertiary,
                      ),
                    ),
                    const SizedBox(width: Gap.x2),
                    Expanded(
                      // 必须走 SimpleMarkdown，不能用裸 Text：
                      // 更新日志里写了 `**给药途径**` 这类行内加粗，
                      // 裸 Text 会把星号原样显示给用户（0.4D 真机上就是这么露出来的）。
                      // 外层已经有圆点图标了，所以把 Markdown 自己的列表符号关掉，
                      // 只让它处理行内格式。
                      child: SimpleMarkdown(
                        line,
                        baseStyle: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
