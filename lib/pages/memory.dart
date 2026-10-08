import 'package:flutter/material.dart';

import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'settings.dart';

/// 全局记忆（二级页）。
///
/// 对话记忆设为「全局记忆」时，这段文字会随每次提问一起进入系统提示词，
/// 用来记录跨对话的长期偏好（例如家人年龄段、记账口径）。
class GlobalMemoryPage extends StatefulWidget {
  const GlobalMemoryPage({super.key, required this.store});

  final Store store;

  @override
  State<GlobalMemoryPage> createState() => _GlobalMemoryPageState();
}

class _GlobalMemoryPageState extends State<GlobalMemoryPage> {
  late final TextEditingController _controller;
  bool _saved = true;

  static const _examples = [
    '家里有 2 位老人和 1 个 6 岁孩子',
    '记账时「餐饮」包含外卖和饮料',
    '回答尽量简短，先说结论',
  ];

  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: store.globalMemory);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await store.saveGlobalMemory(_controller.text);
    if (!mounted) return;
    setState(() => _saved = true);
    toast(context, '全局记忆已保存');
  }

  Future<void> _clear() async {
    final ok = await confirmDialog(
      context,
      title: '清空全局记忆？',
      content: '清空后，使用「全局记忆」档位的对话不会再带上这段内容。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!ok) return;
    _controller.clear();
    await _save();
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '全局记忆',
    caption: '记录长期不变的信息，让不同对话都能用上同一套背景。',
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x2, Gap.page, 0),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _controller,
                  maxLines: 6,
                  maxLength: 500,
                  onChanged: (_) => setState(() => _saved = false),
                  decoration: const InputDecoration(
                    hintText: '例如：家里有 2 位老人和 1 个 6 岁孩子；记账时餐饮包含外卖。',
                  ),
                ),
                const SizedBox(height: Gap.x3),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _clear,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                        ),
                        child: const Text('清空'),
                      ),
                    ),
                    const SizedBox(width: Gap.x3),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _save,
                        icon: Icon(
                          _saved ? Icons.check : Icons.save_outlined,
                          size: 18,
                        ),
                        label: Text(_saved ? '已保存' : '保存'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      const SettingsGroup(
        title: '写点什么？',
        children: [
          SettingsRow(
            icon: Icons.lightbulb_outline,
            tint: Tone.tintAmber,
            color: Tone.iconAmber,
            title: '家庭情况',
            subtitle: '例如：家里有 2 位老人和 1 个 6 岁孩子',
          ),
          SettingsRow(
            icon: Icons.lightbulb_outline,
            tint: Tone.tintAmber,
            color: Tone.iconAmber,
            title: '记账口径',
            subtitle: '例如：餐饮包含外卖和饮料',
          ),
          SettingsRow(
            icon: Icons.lightbulb_outline,
            tint: Tone.tintAmber,
            color: Tone.iconAmber,
            title: '回答偏好',
            subtitle: '例如：尽量简短，先说结论',
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x4, Gap.page, 0),
        child: Wrap(
          spacing: Gap.x2,
          runSpacing: Gap.x2,
          children: [
            for (final example in _examples)
              ActionChip(
                label: Text(example, style: const TextStyle(fontSize: 12)),
                onPressed: () {
                  _controller.text = example;
                  setState(() => _saved = false);
                },
              ),
          ],
        ),
      ),
      const SizedBox(height: Gap.x4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.page),
        child: Text(
          '只有把某个对话的记忆档位设为「全局记忆」时，这段内容才会被发送给模型。'
          '其余档位下发的内容仅为当前对话历史。',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ],
  );
}
