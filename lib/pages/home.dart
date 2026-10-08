import 'package:flutter/material.dart';

import 'package:intl/intl.dart';

import '../core/util.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 首页：产品控制中心。
///
/// 对应 0.2C 示例图：头图 + 「本月概览」双数据块 + 「快捷功能」四宫格 +
/// 隐私提示条 + 「最近记录」。
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.store,
    required this.onOpenTab,
    required this.onOpenChat,
    required this.onAddExpense,
    required this.onAddMed,
  });

  final Store store;

  /// 切换到指定 Tab（首页上的卡片可点击跳转）。
  final void Function(int index) onOpenTab;

  /// 带着预设问题跳到 AI 页面并直接发送。
  final void Function(String question) onOpenChat;

  /// 直接打开记账 / 添加药品表单。
  final VoidCallback onAddExpense;
  final VoidCallback onAddMed;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final thisMonth = store.monthlyExpense(now);
    final lastMonth = store.monthlyExpense(DateTime(now.year, now.month - 1));
    final expiringSoon = store.expiringWithin(90, now);
    final expired = store.expiredCount(now);

    return ListView(
      padding: const EdgeInsets.only(bottom: Gap.x5),
      children: [
        HeroBanner(
          eyebrow: '${_greeting(now)}！',
          title: '家庭生活助手',
          subtitle: '让生活更有条理，更安心',
          icon: Icons.home_outlined,
        ),
        const SizedBox(height: Gap.x4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.x4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '本月概览',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => onOpenTab(1),
                        child: Row(
                          children: [
                            Text(DateFormat('yyyy 年 M 月').format(now)),
                            const Icon(Icons.chevron_right, size: 18),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.x2),
                  Row(
                    children: [
                      Expanded(
                        child: _OverviewTile(
                          icon: Icons.account_balance_wallet_outlined,
                          tint: Tone.tintBlue,
                          color: Tone.iconBlue,
                          label: '本月支出',
                          value: money(thisMonth),
                          footnote: _monthTrend(thisMonth, lastMonth),
                          onTap: () => onOpenTab(1),
                        ),
                      ),
                      const SizedBox(width: Gap.x3),
                      Expanded(
                        child: _OverviewTile(
                          icon: Icons.medication_outlined,
                          tint: Tone.tintGreen,
                          color: Tone.iconGreen,
                          label: '90 天内到期',
                          value: '$expiringSoon 项',
                          footnote: expired > 0
                              ? '另有 $expired 项已过期'
                              : '守护家人健康',
                          onTap: () => onOpenTab(2),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        _sectionTitle(context, '快捷功能'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: QuickTile(
                      icon: Icons.receipt_long_outlined,
                      title: '记一笔账',
                      subtitle: '记录收支，掌握开销',
                      tint: Tone.tintBlue,
                      color: Tone.iconBlue,
                      onTap: onAddExpense,
                    ),
                  ),
                  const SizedBox(width: Gap.x3),
                  Expanded(
                    child: QuickTile(
                      icon: Icons.medication_outlined,
                      title: '添加药品',
                      subtitle: '管理药箱，按时用药',
                      tint: Tone.tintTeal,
                      color: Tone.iconTeal,
                      onTap: onAddMed,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.x3),
              Row(
                children: [
                  Expanded(
                    child: QuickTile(
                      icon: Icons.auto_awesome,
                      title: '问问 AI',
                      subtitle: '分析账本 / 健康科普',
                      tint: Tone.tintPurple,
                      color: Tone.iconPurple,
                      // 0.4A：AI 已拆成两个模块，这里交给外壳切到 AI 入口页，
                      // 让用户先选账本分析还是健康科普，而不是直接落到某个模块。
                      onTap: () => onOpenChat(''),
                    ),
                  ),
                  const SizedBox(width: Gap.x3),
                  Expanded(
                    child: QuickTile(
                      icon: Icons.settings_outlined,
                      title: '应用设置',
                      subtitle: '模型、数据与偏好',
                      tint: Tone.tintSlate,
                      color: Tone.iconSlate,
                      onTap: () => onOpenTab(4),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Gap.x4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: Container(
            padding: const EdgeInsets.all(Gap.card),
            decoration: BoxDecoration(
              color: Tone.heroTint,
              borderRadius: BorderRadius.circular(Gap.radius),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '本地优先 · API Key 安全保存',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(color: Tone.primary),
                      ),
                      const SizedBox(height: Gap.x2),
                      Text(
                        '数据仅保存在本机，不做诊断、处方或个体化用药剂量。'
                        '紧急症状请直接拨打 120。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Gap.x3),
                const Icon(
                  Icons.verified_user_outlined,
                  size: 40,
                  color: Tone.heroAccent,
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            Expanded(child: _sectionTitle(context, '最近记录')),
            Padding(
              padding: const EdgeInsets.only(right: Gap.page, top: Gap.x4),
              child: TextButton(
                onPressed: () => onOpenTab(1),
                child: const Text('查看全部'),
              ),
            ),
          ],
        ),
        ..._recentTiles(context),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x4, Gap.page, Gap.x2),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  /// 最近 5 条账目与药品动态。
  List<Widget> _recentTiles(BuildContext context) {
    final items = <({DateTime at, Widget tile})>[];

    for (final e in store.expenses.take(5)) {
      final at = DateTime.tryParse(e['spentAt']?.toString() ?? '');
      if (at == null) continue;
      final isIncome = e['entryType'] == 'income';
      final amount = e['amount'] is num ? (e['amount'] as num).toDouble() : 0.0;
      final style = Categories.of(e['category']?.toString());
      items.add((
        at: at,
        tile: ListTile(
          leading: IconTile(icon: style.icon, tint: style.tint, color: style.color),
          title: Text(e['title']?.toString() ?? '未命名'),
          subtitle: Text(
            '${isIncome ? '收入' : '支出'} · '
            '${formatDate(e['spentAt'], unknown: '日期未知')}',
          ),
          trailing: Text(
            '${isIncome ? '+' : '-'}${money(amount)}',
            style: TextStyle(
              color: isIncome ? Tone.income : Tone.expense,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ));
    }

    for (final m in store.meds.take(5)) {
      final info = ExpiryInfo.parse(m['expiry']);
      final at = info.date;
      if (at == null) continue;
      final badge = expiryBadge(m, DateTime.now());
      items.add((
        at: at,
        tile: ListTile(
          leading: const IconTile(
            icon: Icons.medication,
            tint: Tone.tintTeal,
            color: Tone.iconTeal,
          ),
          title: Text(m['name']?.toString() ?? '未命名药品'),
          subtitle: Text('有效期 ${formatDate(m['expiry'])}'),
          trailing: Text(
            badge.text,
            style: TextStyle(color: badge.color, fontSize: 12),
          ),
        ),
      ));
    }

    if (items.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: Card(
            child: EmptyState(
              icon: Icons.description_outlined,
              title: '暂无记录',
              detail: '开始记录，让生活更有条理吧！',
              actionLabel: '记一笔账',
              onAction: onAddExpense,
            ),
          ),
        ),
      ];
    }
    items.sort((a, b) => b.at.compareTo(a.at));
    return items
        .take(5)
        .map(
          (item) => Padding(
            padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.x2),
            child: Card(child: item.tile),
          ),
        )
        .toList();
  }

  static String _greeting(DateTime now) {
    final h = now.hour;
    if (h < 6) return '夜深了';
    if (h < 11) return '早上好';
    if (h < 14) return '中午好';
    if (h < 18) return '下午好';
    return '晚上好';
  }

  static String _monthTrend(double current, double previous) {
    if (previous <= 0) {
      return current <= 0 ? '本月还没有支出' : '较上月 —';
    }
    final delta = (current - previous) / previous * 100;
    final sign = delta >= 0 ? '+' : '';
    return '较上月 $sign${delta.toStringAsFixed(0)}%';
  }
}

/// 首页概览里的小数据块：图标 + 标签 + 数值 + 补充说明。
class _OverviewTile extends StatelessWidget {
  const _OverviewTile({
    required this.icon,
    required this.tint,
    required this.color,
    required this.label,
    required this.value,
    required this.footnote,
    required this.onTap,
  });

  final IconData icon;
  final Color tint;
  final Color color;
  final String label;
  final String value;
  final String footnote;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Tone.surfaceMuted,
    borderRadius: BorderRadius.circular(Gap.x4),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Gap.x4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(icon: icon, tint: tint, color: color, size: 40),
                const Spacer(),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Tone.textTertiary,
                ),
              ],
            ),
            const SizedBox(height: Gap.x3),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: Gap.x1),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: Gap.hairline),
            Text(
              footnote,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    ),
  );
}
