import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/common.dart';
import 'settings.dart';

/// 使用说明（二级页）：把主要能力、AI 与本地记录的边界讲清楚。
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const _steps = [
    (
      Icons.key_outlined,
      '先配置 AI',
      '设置 → AI 服务，填 Base URL、模型与 API Key，点「测试连接」确认可用。',
    ),
    (
      Icons.receipt_long_outlined,
      '记第一笔账',
      '账本页右下角「记一笔」，或直接在 AI 里说「午餐花了 32 元」，会自动入账。',
    ),
    (
      Icons.medication_outlined,
      '建立家庭药箱',
      '药箱页「添加药品」，填名称与有效期；30 天内到期会在首页与列表里提示。',
    ),
    (
      Icons.auto_awesome,
      '让 AI 按你的数据分析',
      'AI 页选主题后提问，例如「本月哪一类花得最多？」；数据摘要会随问题一起发送。',
    ),
  ];

  static const _faq = [
    (
      '数据会上传到服务器吗？',
      '不会。账目、药箱、对话都保存在本机数据库。只有你主动提问时，才会把'
          '必要的摘要与问题发送给模型服务商。',
    ),
    (
      '为什么有时不回答、只给一段说明？',
      '如果问题涉及急症（如胸痛、呼吸困难、大出血），应用会直接给出就医提示，'
          '不再调用模型，这是刻意设置的安全兜底。',
    ),
    (
      '可以问吃药剂量吗？',
      '应用不会提供个体化剂量建议，只会给出说明书级别的常识与「需要咨询药师」的'
          '情形。具体用量请遵医嘱或咨询药师。',
    ),
    (
      'AI 回答里的图表是怎么来的？',
      '模型会按固定格式输出一段图表数据，应用在本地渲染成分类对比或趋势图，'
          '不依赖外部图片。',
    ),
    (
      '换手机怎么迁移数据？',
      '设置 → 数据管理 → 导出为 JSON，复制到剪贴板后自行保存；'
          'API Key 与密码明文不会被导出。',
    ),
  ];

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '使用说明',
    caption: '家庭生活助手把「记账」「药箱」「AI 助手」放在一个应用里。',
    children: [
      SettingsGroup(
        title: '四步上手',
        children: [
          for (var i = 0; i < _steps.length; i++)
            SettingsRow(
              icon: _steps[i].$1,
              tint: i.isEven ? Tone.tintBlue : Tone.tintTeal,
              color: i.isEven ? Tone.iconBlue : Tone.iconTeal,
              title: '${i + 1}. ${_steps[i].$2}',
              subtitle: _steps[i].$3,
            ),
        ],
      ),
      SettingsGroup(
        title: '常见问题',
        children: [
          for (final item in _faq)
            SettingsRow(
              icon: Icons.help_outline,
              tint: Tone.tintSlate,
              color: Tone.iconSlate,
              title: item.$1,
              subtitle: item.$2,
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x4, Gap.page, 0),
        child: Container(
          padding: const EdgeInsets.all(Gap.card),
          decoration: BoxDecoration(
            color: Tone.tintRed,
            borderRadius: BorderRadius.circular(Gap.radius),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.emergency_outlined, color: Tone.error),
              const SizedBox(width: Gap.x3),
              Expanded(
                child: Text(
                  '安全提示：出现胸痛、呼吸困难、意识障碍、大出血等紧急症状，'
                  '请立即拨打 120，不要依赖本应用。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Tone.error,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
