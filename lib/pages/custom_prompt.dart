import 'package:flutter/material.dart';

import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'settings.dart';

/// 「我的提示词」（二级页）。
///
/// 0.2B 评审要求把「写死的系统提示词」变成用户可补充的东西：每个主题一张卡，
/// 写在这里的要求会追加到系统提示词末尾，不影响内置的安全约束。
class CustomPromptPage extends StatefulWidget {
  const CustomPromptPage({super.key, required this.store});

  final Store store;

  @override
  State<CustomPromptPage> createState() => _CustomPromptPageState();
}

class _CustomPromptPageState extends State<CustomPromptPage> {
  late final TextEditingController _finance;
  late final TextEditingController _health;
  bool _saved = false;

  static const _financeExamples = [
    '用一句话总结，再列 3 条要点',
    '金额都用两位小数，不要写“约”',
    '优先关注餐饮和交通开销',
  ];

  static const _healthExamples = [
    '面向家里老人，用词尽量口语化',
    '每条建议都标注需要咨询药师的情形',
    '不要推荐具体品牌',
  ];

  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    _finance = TextEditingController(text: store.customPromptFinance);
    _health = TextEditingController(text: store.customPromptHealth);
  }

  @override
  void dispose() {
    _finance.dispose();
    _health.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await store.saveCustomPrompts(
      finance: _finance.text,
      health: _health.text,
    );
    if (!mounted) return;
    setState(() => _saved = true);
    toast(context, '提示词已保存');
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '我的提示词',
    caption: '这里的内容会追加到系统提示词末尾，属于你的个性化要求。',
    children: [
      _card(
        context,
        title: '账本分析',
        icon: Icons.insights_outlined,
        tint: Tone.tintBlue,
        color: Tone.iconBlue,
        controller: _finance,
        hint: '例如：先说结论，再列三条可执行的节省建议',
        examples: _financeExamples,
      ),
      _card(
        context,
        title: '健康科普',
        icon: Icons.health_and_safety_outlined,
        tint: Tone.tintTeal,
        color: Tone.iconTeal,
        controller: _health,
        hint: '例如：面向家里老人，用词口语化',
        examples: _healthExamples,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x2, Gap.page, 0),
        child: FilledButton.icon(
          onPressed: _save,
          icon: Icon(_saved ? Icons.check : Icons.save_outlined, size: 18),
          label: Text(_saved ? '已保存' : '保存提示词'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
          ),
        ),
      ),
      const SizedBox(height: Gap.x4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.page),
        child: Text(
          '内置的安全约束（不诊断、不开处方、不给个体化剂量、紧急情况提示就医）'
          '无法被这里的文字覆盖。',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ],
  );

  Widget _card(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color tint,
    required Color color,
    required TextEditingController controller,
    required String hint,
    required List<String> examples,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x3, Gap.page, 0),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(icon: icon, tint: tint, color: color, size: 40),
                const SizedBox(width: Gap.x3),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.x3),
            TextField(
              controller: controller,
              maxLines: 4,
              maxLength: 300,
              onChanged: (_) => setState(() => _saved = false),
              decoration: InputDecoration(hintText: hint),
            ),
            const SizedBox(height: Gap.x1),
            Wrap(
              spacing: Gap.x2,
              runSpacing: Gap.x2,
              children: [
                for (final example in examples)
                  ActionChip(
                    label: Text(
                      example,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () {
                      controller.text = example;
                      setState(() => _saved = false);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
