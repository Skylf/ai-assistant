import 'package:flutter/material.dart';

import '../ai/chart.dart';
import '../theme.dart';

/// 聊天内图表渲染。
///
/// 0.2A 文档要求「ai 可以输出图表来增强分析表达」。数据由模型按约定格式
/// 给出，这里负责把它画成真实的分类对比 / 时间趋势图，而不是再打印一遍数字。
class AiChart extends StatelessWidget {
  const AiChart(this.chart, {super.key});

  final ChartBlock chart;

  @override
  Widget build(BuildContext context) {
    if (!chart.isValid) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(Gap.x4),
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(Gap.x4),
        border: Border.all(color: Tone.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (chart.title.isNotEmpty) ...[
            Text(chart.title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Gap.x2),
          ],
          if (chart.totalValue.isNotEmpty) ...[
            Text(
              chart.totalValue,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (chart.totalLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  chart.totalLabel,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            const SizedBox(height: Gap.x4),
          ],
          if (chart.type == 'trend')
            _TrendRows(chart: chart)
          else
            _CategoryGrid(chart: chart),
          if (chart.note.isNotEmpty) ...[
            const SizedBox(height: Gap.x3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.lightbulb_outline,
                  size: 16,
                  color: Tone.warning,
                ),
                const SizedBox(width: Gap.x2),
                Expanded(
                  child: Text(
                    chart.note,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 分类对比：两列网格，每项显示图标、名称、占比、金额和进度条。
class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({required this.chart});

  final ChartBlock chart;

  @override
  Widget build(BuildContext context) {
    // 模型没给 percent 时按金额自行计算，保证进度条始终可见。
    final sum = chart.categories.fold<double>(0, (acc, item) => acc + item.value);
    final items = chart.categories;
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _CategoryCell(chart: chart, item: items[i], sum: sum)),
            const SizedBox(width: Gap.x3),
            Expanded(
              child: i + 1 < items.length
                  ? _CategoryCell(chart: chart, item: items[i + 1], sum: sum)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: Gap.x4),
          rows[i],
        ],
      ],
    );
  }
}

class _CategoryCell extends StatelessWidget {
  const _CategoryCell({
    required this.chart,
    required this.item,
    required this.sum,
  });

  final ChartBlock chart;
  final ChartItem item;
  final double sum;

  @override
  Widget build(BuildContext context) {
    final style = Categories.of(item.label);
    final ratio = sum <= 0 ? 0.0 : item.value / sum;
    final percent = '${(ratio * 100).round()}%';
    final maxValue = chart.maxValue;
    final barRatio = maxValue <= 0 ? 0.0 : item.value / maxValue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(style.icon, size: 16, color: style.color),
            const SizedBox(width: Gap.x2 - 2),
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  color: Tone.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.x1),
        Text(
          percent,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Tone.textPrimary,
          ),
        ),
        const SizedBox(height: Gap.hairline),
        Text(
          item.display.isEmpty ? item.value.toStringAsFixed(2) : item.display,
          style: const TextStyle(fontSize: 12, color: Tone.textSecondary),
        ),
        const SizedBox(height: Gap.x2 - 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: barRatio.clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: Tone.surfaceMuted,
            valueColor: AlwaysStoppedAnimation<Color>(style.color),
          ),
        ),
      ],
    );
  }
}

/// 时间趋势：每行「日期 + 条形 + 金额」。
class _TrendRows extends StatelessWidget {
  const _TrendRows({required this.chart});

  final ChartBlock chart;

  @override
  Widget build(BuildContext context) {
    final maxValue = chart.maxValue;
    return Column(
      children: [
        for (final item in chart.categories) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.x3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.label,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Tone.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      item.display.isEmpty
                          ? item.value.toStringAsFixed(2)
                          : item.display,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Tone.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.x2 - 2),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: maxValue <= 0
                        ? 0
                        : (item.value / maxValue).clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: Tone.surfaceMuted,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Tone.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
