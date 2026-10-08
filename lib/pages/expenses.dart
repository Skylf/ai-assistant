import 'package:flutter/material.dart';

import 'package:intl/intl.dart';

import '../core/stats.dart';
import '../core/util.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'expense_form.dart';

/// 账本页的三级视图。
///
/// 0.4B 改版：原先所有账本功能挤在一屏（本月三栏卡 → 分类筛选胶囊 → 日期行
/// → 当日明细 → 本月分类统计），窄屏上要滚很久才能看到自己刚记的那笔。
/// 现在拆成三级，用**顶部分区控件**切换（用户明确选择「点哪个看哪个」，
/// 不用横向滑动 —— 滑动会和 Android 系统的边缘返回手势抢）：
///
///  * [today] 记账主视图：日期导航 + 当天收支 + 记一笔 + 当天明细；
///  * [summary] 汇总：周/月/年的文字数据 + 支出柱状图；
///  * [category] 分类：周/月/年的分类占比。
///
/// 用户还要求去掉「家庭账本」大标题与「记录每一笔，过更有规划的生活」，
/// 所以这页**没有 PageTitle**：顶部直接就是分区控件。
/// 账本的三级视图。
///
/// 命名不带下划线是因为 [ExpensesPageState] 是 public（`createState` 返回它，
/// 测试要 `tester.state<ExpensesPageState>()`），它的字段出现在 public API 里，
/// 用私有类型会触发 `library_private_types_in_public_api`。
enum LedgerLevel {
  today('今日'),
  summary('汇总'),
  category('分类');

  const LedgerLevel(this.label);

  final String label;
}

class ExpensesPage extends StatefulWidget {
  const ExpensesPage({super.key, required this.store});

  final Store store;

  @override
  State<ExpensesPage> createState() => ExpensesPageState();
}

class ExpensesPageState extends State<ExpensesPage> {
  /// 第一级（今日）选中的日期。
  DateTime selected = DateTime.now();

  /// 第二、三级用的统计周期基准日（周/月/年由 [range] 决定怎么取整）。
  DateTime statsAnchor = DateTime.now();

  LedgerLevel level = LedgerLevel.today;
  StatsRange range = StatsRange.month;

  /// 金额隐藏开关。0.4A 在「本月收支」卡上有这个眼睛图标，卡拆掉后
  /// 保留到第一级的当天收支行，功能不能丢（用户会拿它挡旁人视线）。
  bool hideAmounts = false;

  void _shiftDay(int days) =>
      setState(() => selected = selected.add(Duration(days: days)));

  /// 切换统计周期时，把基准日往前/往后挪一个周期。
  ///
  /// 用 [StatsRange.startOf] 先归到周期起点再挪，否则从「9 月 30 日」往后挪
  /// 一个月会得到「10 月 30 日」，而如果当时选的是 31 日就会溢出到 12 月。
  void _shiftRange(int direction) {
    setState(() {
      final start = StatsRange.startOf(range, statsAnchor);
      switch (range) {
        case StatsRange.week:
          statsAnchor = start.add(Duration(days: 7 * direction));
        case StatsRange.month:
          statsAnchor = DateTime(start.year, start.month + direction);
        case StatsRange.year:
          statsAnchor = DateTime(start.year + direction);
      }
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: selected,
    );
    if (picked == null || !mounted) return;
    setState(() => selected = picked);
  }

  /// 点周期标签时选择具体日期，再把统计周期归到那一天所属的周/月/年。
  Future<void> _pickStatsDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: statsAnchor,
      helpText: '选择该周期内的任意一天',
    );
    if (picked == null || !mounted) return;
    setState(() => statsAnchor = picked);
  }

  /// 长按账目：底部菜单选「修改」或「删除」。
  ///
  /// 0.4B 重写这页时我一度把它简化成「直接问是否删除」，
  /// `app_smoke_test` 的「长按账目出现修改菜单且不产生重复记录」立刻失败 ——
  /// 修改入口是既有功能，不能因为改版弄丢。用 `showModalBottomSheet`
  /// 而不是 `AlertDialog`：两个动作在手机上更好点。
  Future<void> _onLongPress(Map<String, dynamic> row) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x3, Gap.page, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      row['title']?.toString() ?? '',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Tone.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    money(row['amount'] ?? 0),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Tone.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.x2),
            const Hairline(),
            ListTile(
              leading: const Icon(Icons.edit_outlined, size: 20),
              title: const Text('修改'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, size: 20),
              title: const Text('删除'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            const SizedBox(height: Gap.x2),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    if (action == 'edit') {
      await showExpenseSheet(context, widget.store, existing: row);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这笔账目？'),
        content: Text('${row['title'] ?? ''}\n${money(row['amount'] ?? 0)}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.store.removeExpense(row['id'].toString());
  }

  String _amount(num value) => hideAmounts ? '¥ ****' : money(value);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 0.4B 去掉了「记一笔」悬浮按钮。
      //
      // 原来它和第一级里那个整宽按钮是**同一个动作的两个入口**，同时出现在
      // 一屏上（悬浮按钮压在列表右下，整宽按钮在统计卡下面）。用户这轮要求的
      // 正是「不要挤在一起」，留两个入口等于没改。保留文档里写明的那个：
      // 第一级 = 记账按钮 + 当天明细 + 当天收支。
      // 顺带的好处：整宽按钮在页面上方、拇指够得着，且不会遮住最后一条账目。
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Gap.page,
                Gap.x3,
                Gap.page,
                Gap.x1,
              ),
              child: SegmentedTabs<LedgerLevel>(
                key: const Key('ledger-level-tabs'),
                values: LedgerLevel.values,
                labels: [for (final l in LedgerLevel.values) l.label],
                selected: level,
                onChanged: (value) => setState(() => level = value),
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    switch (level) {
      case LedgerLevel.today:
        return _todayView();
      case LedgerLevel.summary:
        return _summaryView();
      case LedgerLevel.category:
        return _categoryView();
    }
  }

  // ------------------------------------------------------------ 第一级：今日

  Widget _todayView() {
    final store = widget.store;
    final rows = store.expenses.where((e) {
      final d = DateTime.tryParse(e['spentAt']?.toString() ?? '');
      return d != null && isSameDay(d, selected);
    }).toList()..sort((a, b) {
      // 后记的排在前面，与「刚记的马上能看到」一致
      final ta = DateTime.tryParse(a['spentAt']?.toString() ?? '');
      final tb = DateTime.tryParse(b['spentAt']?.toString() ?? '');
      if (ta == null || tb == null) return 0;
      return tb.compareTo(ta);
    });

    final income = store.dailyIncome(selected);
    final expense = store.dailyExpense(selected);
    final balance = income - expense;
    final isToday = isSameDay(selected, DateTime.now());

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        PeriodNav(
          label: isToday
              ? '今天 · ${DateFormat('M 月 d 日').format(selected)} ${_weekday(selected)}'
              : '${DateFormat('M 月 d 日').format(selected)} ${_weekday(selected)}',
          onShift: _shiftDay,
          onTapLabel: _pickDate,
          canGoForward: true,
        ),
        if (!isToday)
          Center(
            child: TextButton(
              onPressed: () => setState(() => selected = DateTime.now()),
              child: const Text('回到今天'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: _DayTotals(
            income: _amount(income),
            expense: _amount(expense),
            balance: _amount(balance),
            hideAmounts: hideAmounts,
            onToggleHide: () => setState(() => hideAmounts = !hideAmounts),
          ),
        ),
        const SizedBox(height: Gap.x3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () =>
                  showExpenseSheet(context, store, initialDate: selected),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('记一笔'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(R.control),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: Gap.x5),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: SectionLabel(
            '当天明细',
            trailing: rows.isEmpty
                ? null
                : Text(
                    '共 ${rows.length} 笔',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Tone.textTertiary,
                    ),
                  ),
          ),
        ),
        if (rows.isEmpty)
          QuietEmpty(
            icon: Icons.receipt_long_outlined,
            text: '当天还没有账目',
            hint: '点上面的「记一笔」开始记录',
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
            child: _Group(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  _EntryRow(
                    row: rows[i],
                    hideAmount: hideAmounts,
                    onLongPress: () => _onLongPress(rows[i]),
                  ),
                  if (i != rows.length - 1) const Hairline(indent: 40),
                ],
              ],
            ),
          ),
      ],
    );
  }

  String _weekday(DateTime d) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][d.weekday - 1];

  // ------------------------------------------------------------ 第二级：汇总

  Widget _summaryView() {
    final entries = widget.store.expenses;
    final s = RangeSummary.of(entries, range, statsAnchor);
    final bars = dailyTotals(entries, range, statsAnchor)
        .map((b) => (label: b.label, value: b.value))
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.x6),
      children: [
        _RangePicker(
          range: range,
          anchor: statsAnchor,
          onRangeChanged: (value) => setState(() => range = value),
          onShift: _shiftRange,
          onTapLabel: _pickStatsDate,
        ),
        const SizedBox(height: Gap.x4),
        SectionLabel('${range.label}度合计'),
        _Group(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.card),
              child: Column(
                children: [
                  StatLine(
                    label: '支出',
                    value: money(s.expense),
                    valueColor: Tone.expense,
                    emphasize: true,
                    note: '共 ${s.count} 笔',
                  ),
                  const Hairline(),
                  StatLine(
                    label: '收入',
                    value: money(s.income),
                    valueColor: Tone.income,
                  ),
                  const Hairline(),
                  StatLine(
                    label: '结余',
                    value: money(s.balance),
                    valueColor: s.balance < 0 ? Tone.expense : Tone.textPrimary,
                    note: '收入 − 支出',
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.x5),
        SectionLabel('日均支出'),
        _Group(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.card),
              child: StatLine(
                label: '平均每天',
                value: money(s.dailyAverage(DateTime.now())),
                // 「按已过天数算」必须写出来，否则用户会拿它乘 30 去核对
                note: _averageNote(),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.x5),
        // 0.4C：图表换成带标题/合计/峰值标注的卡片。
        // 原来是一排裸柱子贴在灰底上，没有文字锚点，看不出「这一排是什么」。
        ChartCard(
          title: range == StatsRange.year ? '各月支出' : '每天支出',
          totalLabel: '合计 ${money(s.expense)}',
          bars: bars,
        ),
      ],
    );
  }

  /// 日均口径说明。算出「除以几天」这件事必须对用户可见 ——
  /// 否则「本月初三天的日均」和「上个月的日均」看起来会像是同一套算法。
  String _averageNote() {
    final today = DateTime.now();
    final lastDay = StatsRange.endOf(range, statsAnchor)
        .subtract(const Duration(days: 1));
    if (today.isBefore(lastDay)) {
      // 周期还没过完，按已过天数
      final days =
          DateTime(today.year, today.month, today.day)
              .difference(StatsRange.startOf(range, statsAnchor))
              .inDays +
          1;
      return '按已过 $days 天算';
    }
    final days = lastDay
            .difference(StatsRange.startOf(range, statsAnchor))
            .inDays +
        1;
    return '按 $days 天算';
  }

  // ------------------------------------------------------------ 第三级：分类

  Widget _categoryView() {
    final entries = widget.store.expenses;
    final ranked = categoryTotals(entries, range, statsAnchor);
    final total = ranked.fold<double>(0, (a, b) => a + b.value);
    final incomeRanked = categoryTotals(
      entries,
      range,
      statsAnchor,
      income: true,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.x6),
      children: [
        _RangePicker(
          range: range,
          anchor: statsAnchor,
          onRangeChanged: (value) => setState(() => range = value),
          onShift: _shiftRange,
          onTapLabel: _pickStatsDate,
        ),
        const SizedBox(height: Gap.x4),
        SectionLabel('支出分类', trailing: Text(
          '合计 ${money(total)}',
          style: const TextStyle(fontSize: 12, color: Tone.textTertiary),
        )),
        if (ranked.isEmpty)
          QuietEmpty(
            icon: Icons.pie_chart_outline,
            text: '这个周期还没有支出',
            compact: true,
          )
        else
          _Group(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.card,
                  vertical: Gap.x1,
                ),
                child: Column(
                  children: [
                    for (final item in ranked)
                      CategoryStatRow(
                        name: item.key,
                        amount: money(item.value),
                        fraction: total <= 0 ? 0 : item.value / total,
                        color: Categories.of(item.key).color,
                        icon: Categories.of(item.key).icon,
                      ),
                  ],
                ),
              ),
            ],
          ),
        if (incomeRanked.isNotEmpty) ...[
          const SizedBox(height: Gap.x5),
          SectionLabel('收入分类'),
          _Group(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.card,
                  vertical: Gap.x1,
                ),
                child: Column(
                  children: [
                    for (final item in incomeRanked)
                      CategoryStatRow(
                        name: item.key,
                        amount: money(item.value),
                        fraction: incomeRanked.fold<double>(
                          0,
                          (a, b) => a + b.value,
                        ) <=
                                0
                            ? 0
                            : item.value /
                                incomeRanked.fold<double>(
                                  0,
                                  (a, b) => a + b.value,
                                ),
                        color: Tone.income,
                        icon: Icons.south_west,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 统一的分组容器：白底 + 细描边 + 小圆角，**没有阴影**。
///
/// 用描边替代 `Card` 的 elevation 是去 AI 味的关键一步：投影会让每个区块
/// 都「浮起来」，一圈圈的浮块正是模板化界面的特征。
class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(R.group),
        border: Border.all(color: Tone.outline),
      ),
      child: Column(children: children),
    );
  }
}

/// 周/月/年选择器。两个分区控件叠放：上层选周期，下层是周期导航。
class _RangePicker extends StatelessWidget {
  const _RangePicker({
    required this.range,
    required this.anchor,
    required this.onRangeChanged,
    required this.onShift,
    required this.onTapLabel,
  });

  final StatsRange range;
  final DateTime anchor;
  final ValueChanged<StatsRange> onRangeChanged;
  final ValueChanged<int> onShift;
  final VoidCallback onTapLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SegmentedTabs<StatsRange>(
          values: StatsRange.values,
          labels: [for (final r in StatsRange.values) r.label],
          selected: range,
          onChanged: onRangeChanged,
          dense: true,
        ),
        const SizedBox(height: Gap.x2),
        PeriodNav(
          label: StatsRange.periodLabel(range, anchor),
          onShift: onShift,
          onTapLabel: onTapLabel,
        ),
      ],
    );
  }
}

/// 第一级的当天收支三栏。
///
/// 与旧版「本月收支」卡的区别：去掉图标与 pastel 底板，去掉「较上月 —」
/// 这种占位脚注（它永远显示破折号，是没实现完的痕迹），改为一行字重分明的数字。
class _DayTotals extends StatelessWidget {
  const _DayTotals({
    required this.income,
    required this.expense,
    required this.balance,
    required this.hideAmounts,
    required this.onToggleHide,
  });

  final String income;
  final String expense;
  final String balance;
  final bool hideAmounts;
  final VoidCallback onToggleHide;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.card, Gap.x4, Gap.x1, Gap.x4),
      decoration: BoxDecoration(
        color: Tone.surface,
        borderRadius: BorderRadius.circular(R.group),
        border: Border.all(color: Tone.outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Total(label: '收入', value: income, color: Tone.income),
          const _ThinDivider(),
          _Total(label: '支出', value: expense, color: Tone.expense),
          const _ThinDivider(),
          _Total(label: '结余', value: balance, color: Tone.textPrimary),
          IconButton(
            onPressed: onToggleHide,
            icon: Icon(
              hideAmounts
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 17,
            ),
            color: Tone.textTertiary,
            visualDensity: VisualDensity.compact,
            tooltip: hideAmounts ? '显示金额' : '隐藏金额',
          ),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Tone.textTertiary),
          ),
          const SizedBox(height: Gap.x1),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThinDivider extends StatelessWidget {
  const _ThinDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 30,
    margin: const EdgeInsets.symmetric(horizontal: Gap.x2),
    color: Tone.outline,
  );
}

/// 一条账目。左侧分类图标（直接用分类色细线画，不再套 pastel 方块）。
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.row,
    required this.hideAmount,
    required this.onLongPress,
  });

  final Map<String, dynamic> row;
  final bool hideAmount;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final category = row['category']?.toString().trim() ?? '';
    final style = Categories.of(category.isEmpty ? '其他' : category);
    final amount = row['amount'] is num ? row['amount'] as num : 0;
    final income = isIncome(row);
    final note = row['note']?.toString().trim() ?? '';
    final at = DateTime.tryParse(row['spentAt']?.toString() ?? '');

    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.card,
          vertical: Gap.x3 + 2,
        ),
        child: Row(
          children: [
            Icon(style.icon, size: 18, color: style.color),
            const SizedBox(width: Gap.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row['title']?.toString() ?? '',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Tone.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: Gap.hairline),
                  Text(
                    [
                      if (category.isNotEmpty) category,
                      if (at != null) DateFormat('HH:mm').format(at),
                      if (note.isNotEmpty) note,
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Tone.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: Gap.x2),
            Text(
              '${income ? '+' : '−'}${hideAmount ? '****' : money(amount.abs()).substring(1)}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: income ? Tone.income : Tone.expense,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
