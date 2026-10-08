import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/db.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'settings.dart';

/// 数据管理（二级页）。
///
/// 把「查看数据量 / 导出 JSON / 分表清空」集中到一个页面，危险操作都带二次确认。
class DataSettingsPage extends StatefulWidget {
  const DataSettingsPage({super.key, required this.store});

  final Store store;

  @override
  State<DataSettingsPage> createState() => _DataSettingsPageState();
}

class _DataSettingsPageState extends State<DataSettingsPage> {
  Store get store => widget.store;

  Future<void> _export() async {
    final json = await store.exportJson();
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    await infoDialog(
      context,
      '导出完成',
      '已生成 JSON（${json.length} 字符）并复制到剪贴板。\n\n'
          '内容包含：账目、药箱、对话与消息、密码记录的名称与备注、'
          '以及各表数量统计。\n\n'
          '出于安全考虑，API Key 与密码明文不会被导出。',
    );
  }

  Future<void> _clear({
    required String title,
    required String content,
    required List<String> tables,
  }) async {
    final ok = await confirmDialog(
      context,
      title: title,
      content: content,
      confirmLabel: '清空',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await store.clearData(tables: tables);
    if (!mounted) return;
    toast(context, '已清空');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final counts = store.dataCounts;
      return SettingsScaffold(
        title: '数据管理',
        caption: '所有内容都保存在本机数据库，不经过任何服务器。',
        children: [
          SettingsGroup(
            title: '本地数据',
            children: [
              SettingsRow(
                icon: Icons.receipt_long_outlined,
                tint: Tone.tintBlue,
                color: Tone.iconBlue,
                title: '账目',
                subtitle: '记账记录条数',
                trailingText: '${counts['expenses'] ?? 0} 条',
              ),
              SettingsRow(
                icon: Icons.medication_outlined,
                tint: Tone.tintTeal,
                color: Tone.iconTeal,
                title: '药品',
                subtitle: '药箱中的药品数量',
                trailingText: '${counts['medicines'] ?? 0} 条',
              ),
              SettingsRow(
                icon: Icons.forum_outlined,
                tint: Tone.tintPurple,
                color: Tone.iconPurple,
                title: 'AI 对话',
                subtitle: '对话数量（消息含在各对话内）',
                trailingText: '${counts['conversations'] ?? 0} 个',
              ),
              SettingsRow(
                icon: Icons.password,
                tint: Tone.tintSlate,
                color: Tone.iconSlate,
                title: '密码记录',
                subtitle: '只保存名称、备注与强度，不保存明文',
                trailingText: '${counts['passwords'] ?? 0} 条',
              ),
            ],
          ),
          SettingsGroup(
            title: '导出',
            children: [
              SettingsRow(
                icon: Icons.ios_share,
                tint: Tone.tintGreen,
                color: Tone.iconGreen,
                title: '导出为 JSON',
                subtitle: '复制到剪贴板，便于自行备份',
                onTap: _export,
              ),
            ],
          ),
          SettingsGroup(
            title: '清空数据',
            children: [
              SettingsRow(
                icon: Icons.delete_sweep_outlined,
                tint: Tone.tintAmber,
                color: Tone.iconAmber,
                title: '清空账本',
                subtitle: '删除全部账目记录',
                onTap: () => _clear(
                  title: '清空全部账目？',
                  content: '${counts['expenses'] ?? 0} 条账目记录将被永久删除。',
                  tables: const [T.expenses],
                ),
              ),
              SettingsRow(
                icon: Icons.delete_sweep_outlined,
                tint: Tone.tintAmber,
                color: Tone.iconAmber,
                title: '清空药箱',
                subtitle: '删除全部药品记录',
                onTap: () => _clear(
                  title: '清空全部药品？',
                  content: '${counts['medicines'] ?? 0} 条药品记录将被永久删除。',
                  tables: const [T.meds],
                ),
              ),
              SettingsRow(
                icon: Icons.delete_sweep_outlined,
                tint: Tone.tintRed,
                color: Tone.error,
                titleColor: Tone.error,
                title: '清空全部对话',
                subtitle: '删除所有对话与消息，并自动新建一个空对话',
                onTap: () => _clear(
                  title: '清空全部对话？',
                  content: '${counts['conversations'] ?? 0} 个对话及其消息将被永久删除。'
                      '记忆设置会一并重置。',
                  tables: const [T.conversations, T.chats],
                ),
              ),
              SettingsRow(
                icon: Icons.delete_forever_outlined,
                tint: Tone.tintRed,
                color: Tone.error,
                titleColor: Tone.error,
                title: '清空密码记录',
                subtitle: '删除保存过的密码条目（不影响明文，明文从未保存）',
                onTap: () => _clear(
                  title: '清空密码记录？',
                  content: '${counts['passwords'] ?? 0} 条记录将被永久删除。',
                  tables: const [T.passwords],
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.x4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
            child: Text(
              '清空操作不可撤销。如需保留，请先导出 JSON 备份。',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      );
    },
  );
}
