import 'package:flutter/material.dart';

import '../theme.dart';

/// 0.4B 的界面基元。
///
/// ## 为什么单独一个文件
///
/// 0.4A 的界面「一眼看出是 AI 做的」，根因集中在几处**装饰性**写法上：
///
///  1. **大圆角**：`Gap.radius = 20` 用在所有卡片上，配上 `Card` 的默认阴影，
///     形成那种「一坨一坨浮起来的圆角块」；
///  2. **彩色图标底板**：`IconTile` 给每个图标套一个浅色 pastel 方块
///     （`Tone.tintBlue/tintTeal/…` 共 7 组），颜色与功能没有语义关系，
///     纯粹是装饰 —— 这是最典型的「AI 生成感」；
///  3. **渐变头图**：`HeroBanner` 的 `heroGradient` + 装饰圆点 + `_Blob`；
///  4. **强调色滥用**：主色、容器色、选中胶囊色同时出现。
///
/// 专业记账类 App（钱迹、随手记、MoneyWiz）的做法正好相反：**靠排版和分隔线
/// 建立层级，而不是靠颜色和圆角**。所以这里提供的是替代基元 ——
/// 小圆角、无阴影、细线图标、单色、靠字重与间距分层。
///
/// ## 为什么不直接改 theme.dart 的 Gap.radius
///
/// `Gap.radius` 被 15 个页面引用，直接改会让**还没重构的页面**（如密码工具、
/// 设置）一半新一半旧，比原来更难看。所以新基元自成一套，页面逐个迁移；
/// 全部迁完后再回收旧 token（见 `doc/需求缺口与优先级.md` 的未收敛项清单）。
class R {
  const R._();

  /// 卡片/容器圆角。8 是「看起来是方角但又不太硬」的常规取值。
  static const card = 10.0;

  /// 小控件圆角（分区控件、输入框、按钮）。
  static const control = 8.0;

  /// 分组容器圆角（比卡片略大，用于承载多个子项）。
  static const group = 12.0;
}

/// 细线分隔线。替代卡片阴影来划分区块。
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.indent = 0});

  /// 左侧缩进，用于让分隔线不与图标对齐、视觉上更轻。
  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: indent),
    child: const Divider(
      height: 1,
      thickness: 1,
      color: Tone.outline,
    ),
  );
}

/// 分区控件（segmented control）。
///
/// 0.4B 用它替代「滑动切换层级」：用户明确选择「点哪个看哪个」，
/// 因为横向滑动会和 Android 系统自带的「边缘右滑返回」抢手势。
///
/// 视觉上刻意做得**轻**：只有选中项有底色，其余是灰字，无边框无阴影 ——
/// 一列圆角胶囊加投影是典型 AI 排版。
class SegmentedTabs<T> extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.dense = false,
  });

  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;

  /// 紧凑模式：用于「周/月/年」这类次级切换，高度更小。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    assert(
      values.length == labels.length,
      'SegmentedTabs: values 与 labels 长度必须一致',
    );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Tone.surfaceMuted,
        borderRadius: BorderRadius.circular(R.control),
      ),
      child: Row(
        children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              child: _Tab(
                label: labels[i],
                active: values[i] == selected,
                dense: dense,
                onTap: () => onChanged(values[i]),
              ),
            ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.active,
    required this.dense,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool dense;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? Tone.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(R.control - 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.control - 2),
        child: Container(
          height: dense ? 30 : 36,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: dense ? 13 : 14,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? Tone.textPrimary : Tone.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 时间区间导航：`‹  2026 年 9 月  ›`。
///
/// [onShift] 传 -1 / +1；[onTapLabel] 为 null 时不显示可点样式。
class PeriodNav extends StatelessWidget {
  const PeriodNav({
    super.key,
    required this.label,
    required this.onShift,
    this.onTapLabel,
    this.canGoForward = true,
  });

  final String label;
  final ValueChanged<int> onShift;
  final VoidCallback? onTapLabel;

  /// 是否允许往后翻。看「未来」的统计没有意义，但也可能是补记账目，
  /// 所以默认允许，由调用方决定。
  final bool canGoForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: () => onShift(-1),
          icon: const Icon(Icons.chevron_left, size: 22),
          color: Tone.textSecondary,
          visualDensity: VisualDensity.compact,
          tooltip: '上一个',
        ),
        Expanded(
          child: InkWell(
            onTap: onTapLabel,
            borderRadius: BorderRadius.circular(R.control),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.x2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Tone.textPrimary,
                    ),
                  ),
                  if (onTapLabel != null) ...[
                    const SizedBox(width: Gap.x1),
                    const Icon(
                      Icons.expand_more,
                      size: 16,
                      color: Tone.textTertiary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: canGoForward ? () => onShift(1) : null,
          icon: const Icon(Icons.chevron_right, size: 22),
          color: Tone.textSecondary,
          visualDensity: VisualDensity.compact,
          tooltip: '下一个',
        ),
      ],
    );
  }
}

/// 一条「标签 —— 数值」的统计行。
///
/// 汇总页的「文字数据」就是若干条这个：右对齐的等宽数字列比一排大卡片
/// 更容易一眼比大小，也更像专业记账工具。
class StatLine extends StatelessWidget {
  const StatLine({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.emphasize = false,
    this.note,
  });

  final String label;
  final String value;
  final Color? valueColor;

  /// 主数值（如「支出合计」）用更大的字号。
  final bool emphasize;

  final String? note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.x3 - 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: emphasize ? 14 : 14,
              color: Tone.textSecondary,
            ),
          ),
          if (note != null) ...[
            const SizedBox(width: Gap.x2),
            Expanded(
              child: Text(
                note!,
                style: const TextStyle(fontSize: 12, color: Tone.textTertiary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: emphasize ? 18 : 15,
              fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
              color: valueColor ?? Tone.textPrimary,
              // 等宽数字：数字列右对齐时不会因字形宽度跳动
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 占比条。分类统计里替代饼图 —— 饼图在窄屏上很难比较相近的比例，
/// 横条可以精确对齐、附带金额与百分比。
class ShareBar extends StatelessWidget {
  const ShareBar({
    super.key,
    required this.fraction,
    required this.color,
  });

  /// 0~1。
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final clamped = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Stack(
        children: [
          Container(height: 6, color: Tone.surfaceMuted),
          FractionallySizedBox(
            widthFactor: clamped,
            child: Container(height: 6, color: color),
          ),
        ],
      ),
    );
  }
}

/// 空状态。刻意做得安静：一个细线图标 + 一行说明，不要插画和渐变大图。
///
/// 注意：`common.dart` 里已有一个 `EmptyState`（带 action 按钮的版本）。
/// 这里**故意改名**而不是复用：那个是「引导你去操作」的重空状态（图标带
/// 彩色底板、有行动按钮），这个是「这里就是空的」的轻提示，同屏可能出现
/// 多个，视觉重量必须不同。同名会让同时 import 两个文件的地方产生歧义。
class QuietEmpty extends StatelessWidget {
  const QuietEmpty({
    super.key,
    required this.icon,
    required this.text,
    this.hint,
    this.compact = false,
  });

  final IconData icon;
  final String text;
  final String? hint;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? Gap.x6 : Gap.x6 * 2),
      child: Column(
        children: [
          Icon(icon, size: 28, color: Tone.textTertiary),
          const SizedBox(height: Gap.x3),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Tone.textSecondary),
          ),
          if (hint != null) ...[
            const SizedBox(height: Gap.x1),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Tone.textTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

/// 区块标题。比 `titleMedium`(17/w600) 更小更轻，避免满屏粗体大标题。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.x2),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Tone.textSecondary,
              letterSpacing: 0.3,
            ),
          ),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 图表
//
// 注：`widgets/chart.dart` 已经存在，但那是 **AI 聊天里的图表渲染**
// （`AiChart` / `_CategoryGrid` / `_TrendRows`，数据来自模型输出的 chart 块）。
// 这里是账本页自己算出来的统计图，两者数据来源与用途都不同，
// 不要合并 —— 混在一起会让「改聊天图表」意外改动账本页面。

/// 图表卡片：标题行（标题 + 右侧总计）+ 柱状图。
///
/// 0.4C 新增。0.4B 时图表是裸的柱子直接贴在灰底上，没有任何文字锚点 ——
/// 用户看到的第一反应是「这一排柱子是什么」。给它一个标题、一个总计、
/// 一个「最高」标注，图形才成为一个**能读的图表**而不是装饰。
///
/// 卡片用 1px 描边而不是阴影（与 0.4B 的视觉方向一致）。
class ChartCard extends StatelessWidget {
  const ChartCard({
    super.key,
    required this.title,
    required this.bars,
    this.totalLabel,
    this.note,
    this.barColor = Tone.primary,
    this.emptyHint = '这个周期还没有支出',
    this.height = 132,
  });

  final String title;

  /// 右上角的总计文字（如 `合计 ¥1090.80`）。
  final String? totalLabel;

  /// 标题下方的小字说明。
  final String? note;

  final List<({String label, double value})> bars;
  final Color barColor;
  final String emptyHint;
  final double height;

  @override
  Widget build(BuildContext context) {
    // 峰值用于在说明里点出「最高的一天/月」
    final peak = bars.isEmpty
        ? null
        : bars.reduce((a, b) => b.value > a.value ? b : a);

    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.x4, Gap.x3, Gap.x4, Gap.x3),
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(R.group),
        border: Border.all(color: Tone.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Tone.textPrimary,
                  ),
                ),
              ),
              if (totalLabel != null)
                Text(
                  totalLabel!,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Tone.textPrimary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          if (note != null || (peak != null && peak.value > 0)) ...[
            const SizedBox(height: Gap.x1),
            Text(
              note ??
                  '最高 ${peak!.label} · ¥${peak.value.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 11,
                color: Tone.textTertiary,
              ),
            ),
          ],
          const SizedBox(height: Gap.x3),
          SpendBars(
            bars: bars,
            height: height,
            barColor: barColor,
            emptyHint: emptyHint,
          ),
        ],
      ),
    );
  }
}

/// 支出柱状图（0.4C 重绘）。
///
/// ## 0.4B 那版为什么被说「太丑」
///
/// 原版是**一排纯色实心方块**：顶部圆角 2、单一主色、没有任何参照物。
/// 问题不在配色，而在**它不像图表，像一堆柱子**：
///  1. 没有基线/网格线，柱子悬在空白里，看不出「0 在哪」；
///  2. 柱顶没有视觉锚点，高低差只能靠猜；
///  3. 柱子顶部是直角切平，30 根密排时糊成一片色带；
///  4. 峰值只靠「颜色深一点」区分，弱到几乎看不出。
///
/// ## 这一版的做法（学专业记账 App 的图表）
///
///  · **基线 + 两档网格线**：给出金额参照；网格线用最浅的 `Tone.outline`，
///    只画 0 / 50% / 100% 三条，不堆刻度数字（窄屏放不下）；
///  · **柱顶圆角 + 竖向渐变**：顶部实、底部淡，柱子有「立起来」的体积感，
///    密排时也不糊；
///  · **峰值柱加重**：主色满饱和 + 顶部一个小圆点 + 数值标签，一眼找到最高点；
///  · **峰值为 0 时不画标签**：没数据时不该出现「0.0」浮在图上；
///  · **零值画一条 2px 的浅色底线**：完全不画会让人以为那天缺数据；
///  · **横轴标签与图之间留一条细分隔线**：把图和轴分开，是图表的标准做法。
///
/// 依然**不引图表库**（本机离线不能 `pub add`），依然**不画 Y 轴刻度文字**。
class SpendBars extends StatelessWidget {
  const SpendBars({
    super.key,
    required this.bars,
    this.height = 132,
    this.highlightLabel = true,
    this.barColor = Tone.primary,
    this.emptyHint = '这个周期还没有支出',
  });

  /// 每根柱子的标签与数值。标签为空则不画横轴文字。
  final List<({String label, double value})> bars;

  final double height;

  /// 是否在最高的柱子上标出金额。
  final bool highlightLabel;

  final Color barColor;

  /// 无数据时的提示文案。
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    final max = bars.fold<double>(0, (a, b) => b.value > a ? b.value : a);
    if (bars.isEmpty || max <= 0) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            emptyHint,
            style: const TextStyle(fontSize: 13, color: Tone.textTertiary),
          ),
        ),
      );
    }

    // 柱子多时（月视图 28~31 根）间距要收窄，否则柱子细得看不见
    final compact = bars.length > 20;
    // 横轴标签太密会糊成一片，超过 12 根就不显示
    final showAxis = bars.length <= 12;

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              children: [
                // 网格线画在最底层，柱子盖在上面
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GridPainter(color: Tone.outline),
                  ),
                ),
                Positioned.fill(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final bar in bars)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: compact ? 1.0 : 2.0,
                            ),
                            child: _Bar(
                              label: bar.label,
                              value: bar.value,
                              max: max,
                              barColor: barColor,
                              highlight: highlightLabel && bar.value == max,
                              showAxis: false,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 图与横轴之间的分隔线：把数据区和标签区分开
          Container(height: 1, color: Tone.outline),
          SizedBox(
            height: 18,
            child: showAxis
                ? Row(
                    children: [
                      for (final bar in bars)
                        Expanded(
                          child: bar.label.isEmpty
                              ? const SizedBox.shrink()
                              : Center(
                                  child: FittedBox(
                                    child: Text(
                                      bar.label,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Tone.textTertiary,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                    ],
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// 网格线：0 / 50% / 100% 三条水平线。
///
/// 只画三条是有意的 —— 窄屏上刻度文字会吃掉三分之一宽度，而三条线已经足够
/// 判断「这根柱子大概占最高值的一半还是全部」。
class _GridPainter extends CustomPainter {
  const _GridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    // 顶部线（最高值）用更浅的颜色，避免和柱子顶端抢注意力
    final top = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, 0.5), Offset(size.width, 0.5), top);
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      paint,
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.label,
    required this.value,
    required this.max,
    required this.barColor,
    required this.highlight,
    required this.showAxis,
  });

  final String label;
  final double value;
  final double max;
  final Color barColor;
  final bool highlight;
  final bool showAxis;

  @override
  Widget build(BuildContext context) {
    final ratio = max <= 0 ? 0.0 : value / max;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 数值标签占 13，柱顶圆点占 4，其余给柱子
        const labelArea = 13.0;
        final barArea = (constraints.maxHeight - labelArea).clamp(8.0, 1e6);
        // 有值时至少 3px，否则「花了 1 元」和「没花」看起来一样
        final h = value <= 0 ? 2.0 : (barArea * ratio).clamp(3.0, barArea);

        return Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SizedBox(
              height: labelArea,
              child: highlight
                  ? FittedBox(
                      child: Text(
                        _short(value),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: barColor,
                        ),
                      ),
                    )
                  : null,
            ),
            Container(
              height: h,
              decoration: BoxDecoration(
                // 顶部实、底部淡：柱子有「立起来」的体积感，密排时也不糊
                gradient: value <= 0
                    ? null
                    : LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: highlight
                            ? [barColor, barColor.withValues(alpha: 0.72)]
                            : [
                                barColor.withValues(alpha: 0.55),
                                barColor.withValues(alpha: 0.22),
                              ],
                      ),
                color: value <= 0 ? Tone.surfaceMuted : null,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(3),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 图表上方的数值标签必须短：`¥1234.00` 会撑爆一根柱子的宽度。
  String _short(double v) {
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
    if (v >= 100) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }
}

/// 分类统计的一行：图标 + 名称 + 金额 + 百分比 + 占比条。
///
/// 与 AI 聊天里的 `_CategoryCell` 区别：去掉两列网格（窄屏上每个分类只剩
/// 一半宽度），改单列；图标不用 pastel 底板，直接以分类色细线绘制。
class CategoryStatRow extends StatelessWidget {
  const CategoryStatRow({
    super.key,
    required this.name,
    required this.amount,
    required this.fraction,
    required this.color,
    required this.icon,
  });

  final String name;
  final String amount;

  /// 0~1 的占比。
  final double fraction;

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final pct = fraction * 100;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.x3),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: Gap.x2),
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Tone.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Gap.x2),
              Text(
                amount,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Tone.textPrimary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: Gap.x3),
              SizedBox(
                width: 40,
                child: Text(
                  // 小于 10% 时保留一位小数，否则 1.4% 会显示成 1%
                  '${pct.toStringAsFixed(pct >= 10 ? 0 : 1)}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Tone.textTertiary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.x2),
          ShareBar(fraction: fraction, color: color),
        ],
      ),
    );
  }
}
