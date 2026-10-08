import 'package:flutter/material.dart';

import '../core/med_classify.dart';
import '../core/util.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/ui.dart';
import 'med_detail.dart';
import 'med_form.dart';

// 注意：`commonMedTag`（「常用」标记）与 `tagsOfMed` 定义在
// `core/med_classify.dart`，本文件 import 后直接用，**不要在这里再定义一份**
// —— 两份定义会在同时 import 两者的文件里变成 ambiguous_import 编译错误。

/// 药箱的两级视图。
///
/// 0.4B 改版（用户要求）：去掉顶部「家庭药箱」大标题与「科学用药，守护家人
/// 健康」副标题，去掉「全部/已过期/即将过期/常用药」四个统计卡，
/// 拆成两级用顶部分区控件切换：
///
///  * [list] 药品列表（含搜索）；
///  * [stats] 具体统计信息。
enum MedsLevel {
  list('药品'),
  stats('统计');

  const MedsLevel(this.label);

  final String label;
}

class MedsPage extends StatefulWidget {
  const MedsPage({super.key, required this.store});

  final Store store;

  @override
  State<MedsPage> createState() => MedsPageState();
}

class MedsPageState extends State<MedsPage> {
  final _search = TextEditingController();
  String _filter = '全部';
  String _query = '';

  /// 当前级别。public 是因为 [MedsPageState] 出现在 public API 里
  /// （`createState` 返回它，测试用 `tester.state<MedsPageState>()` 取）。
  MedsLevel level = MedsLevel.list;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 「常用」标记存在备注里的固定标签，写在这里便于表单与列表共用。
  static const commonTag = commonMedTag;

  static const _filters = ['全部', '常用', '内服', '外用', '儿童', '慢性病', '其他'];

  /// 除去「全部」之外的真实分类标签。
  static const _knownTags = knownMedTags;

  /// 依据名称、成分、规格与备注推断药品归类，用于筛选与统计。
  ///
  /// 0.4D：判定规则已抽到 `core/med_classify.dart`（带给药途径词典），
  /// 这里只做转发。保留这个方法是因为页面与测试都在用它，
  /// 顺手改签名会把改动面铺得比必要的大；真正的逻辑只有一份。
  static List<String> tagsOf(Map<String, dynamic> med) => tagsOfMed(
    med,
    explicit: med['form']?.toString(),
  );

  /// 这条药品是不是「自动分不出来」，界面据此提示可手动指定。
  static bool needsManualRoute(Map<String, dynamic> med) =>
      needsManualRouteFor(med, explicit: med['form']?.toString());

  List<Map<String, dynamic>> get _visible {
    final now = DateTime.now();
    return widget.store.meds.where((med) {
      if (_query.isNotEmpty) {
        final haystack = [
          med['name'],
          med['ingredient'],
          med['spec'],
          med['note'],
        ].map((v) => v?.toString().toLowerCase() ?? '').join(' ');
        if (!haystack.contains(_query.toLowerCase())) return false;
      }
      final tags = tagsOf(med);
      if (_filter == '全部') return true;
      if (_filter == '其他') return !_knownTags.any(tags.contains);
      return tags.contains(_filter);
    }).toList()..sort((a, b) {
      final aLeft = ExpiryInfo.parse(a['expiry']).daysLeft(now);
      final bLeft = ExpiryInfo.parse(b['expiry']).daysLeft(now);
      if (aLeft == null && bLeft == null) return 0;
      if (aLeft == null) return 1;
      if (bLeft == null) return -1;
      return aLeft.compareTo(bLeft);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: level == MedsLevel.list
          ? FloatingActionButton.extended(
              // 与账本页的 FAB 区分开，避免 Hero tag 冲突。
              heroTag: 'fab-meds',
              onPressed: () => _openForm(),
              label: const Text('添加药品'),
              icon: const Icon(Icons.add),
            )
          : null,
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
              child: SegmentedTabs<MedsLevel>(
                key: const Key('meds-level-tabs'),
                values: MedsLevel.values,
                labels: [for (final l in MedsLevel.values) l.label],
                selected: level,
                onChanged: (value) => setState(() => level = value),
              ),
            ),
            Expanded(
              child: level == MedsLevel.list ? _listView() : _statsView(),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------- 第一级：药品列表

  Widget _listView() {
    final store = widget.store;
    final rows = _visible;

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        const SizedBox(height: Gap.x3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: TextField(
            controller: _search,
            onChanged: (value) => setState(() => _query = value.trim()),
            decoration: InputDecoration(
              hintText: '搜索药品名称 / 通用名 / 成分',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '清空搜索',
                    ),
            ),
          ),
        ),
        const SizedBox(height: Gap.x2),
        FilterPills(
          options: _filters,
          selected: _filter,
          onSelected: (value) => setState(() => _filter = value),
        ),
        const SizedBox(height: Gap.x3),
        if (rows.isEmpty)
          EmptyState(
            icon: store.meds.isEmpty
                ? Icons.medication_outlined
                : Icons.search_off_outlined,
            title: store.meds.isEmpty ? '还没有药品' : '没有匹配的药品',
            detail: store.meds.isEmpty
                ? '把家里的常备药录进来，到期前会提醒你。'
                : '试试换一个关键词或筛选条件。',
            actionLabel: store.meds.isEmpty ? '添加药品' : '',
            onAction: store.meds.isEmpty ? _openForm : null,
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
            child: SectionLabel(
              '药品列表',
              trailing: Text(
                '共 ${rows.length} 种',
                style: const TextStyle(
                  fontSize: 12,
                  color: Tone.textTertiary,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
            child: Container(
              decoration: BoxDecoration(
                color: Tone.surface,
                borderRadius: BorderRadius.circular(R.group),
                border: Border.all(color: Tone.outline),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    _MedRow(
                      med: rows[i],
                      now: DateTime.now(),
                      onTap: () => _openDetail(rows[i]),
                      onLongPress: () => _onLongPress(rows[i]),
                    ),
                    if (i != rows.length - 1) const Hairline(indent: 40),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ 第二级：统计

  Widget _statsView() {
    final store = widget.store;
    final now = DateTime.now();
    final total = store.meds.length;
    final soon = store.expiringWithin(30, now);
    final expired = store.expiredCount(now);
    final common = store.meds.where((m) => tagsOf(m).contains('常用')).length;
    final noExpiry = store.meds
        .where((m) => ExpiryInfo.parse(m['expiry']).date == null)
        .length;

    // 按筛选标签统计各类药品数量，用于「分类分布」
    final byTag = <String, int>{};
    for (final med in store.meds) {
      for (final tag in tagsOf(med)) {
        byTag[tag] = (byTag[tag] ?? 0) + 1;
      }
    }
    final tagRows = byTag.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x4, Gap.page, Gap.x6),
      children: [
        SectionLabel('药箱概览'),
        _Group(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.card),
              child: Column(
                children: [
                  StatLine(
                    label: '全部药品',
                    value: '$total 种',
                    emphasize: true,
                  ),
                  const Hairline(),
                  StatLine(
                    label: '已过期',
                    value: '$expired 种',
                    valueColor: expired > 0 ? Tone.error : null,
                    note: expired > 0 ? '建议尽快清理' : '没有过期的药',
                  ),
                  const Hairline(),
                  StatLine(
                    label: '即将过期',
                    value: '$soon 种',
                    valueColor: soon > 0 ? Tone.warning : null,
                    note: '30 天内到期',
                  ),
                  const Hairline(),
                  StatLine(label: '常用药', value: '$common 种', note: '已标记'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.x5),
        SectionLabel('保质期完整性'),
        _Group(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Gap.card,
                Gap.x4,
                Gap.card,
                Gap.x4,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${total - noExpiry}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Tone.textPrimary,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        ' / $total 种已填保质期',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Tone.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.x3),
                  // 填了保质期的比例。没填的药不会有过期提醒，
                  // 所以这个数字直接关系到「提醒可不可信」，值得显示。
                  ShareBar(
                    fraction: total <= 0 ? 0 : (total - noExpiry) / total,
                    color: noExpiry == 0 ? Tone.income : Tone.warning,
                  ),
                  if (noExpiry > 0) ...[
                    const SizedBox(height: Gap.x3),
                    Text(
                      '还有 $noExpiry 种没填保质期，这些药不会有到期提醒。',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Tone.warning,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (tagRows.isNotEmpty) ...[
          const SizedBox(height: Gap.x5),
          SectionLabel('分类分布'),
          _Group(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.card,
                  vertical: Gap.x1,
                ),
                child: Column(
                  children: [
                    for (final row in tagRows)
                      CategoryStatRow(
                        name: row.key,
                        amount: '${row.value} 种',
                        fraction: total <= 0 ? 0 : row.value / total,
                        color: _tagColor(row.key),
                        icon: _tagIcon(row.key),
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

  /// 分类标签对应的颜色。集中在这里，避免散落的魔法色。
  static Color _tagColor(String tag) {
    switch (tag) {
      case '常用':
        return Tone.iconPurple;
      case '内服':
        return Tone.iconBlue;
      case '外用':
        return Tone.iconTeal;
      case '儿童':
        return Tone.iconGreen;
      case '慢性病':
        return Tone.iconAmber;
      default:
        return Tone.iconSlate;
    }
  }

  static IconData _tagIcon(String tag) {
    switch (tag) {
      case '常用':
        return Icons.star_outline;
      case '内服':
        return Icons.medication_outlined;
      case '外用':
        return Icons.healing_outlined;
      case '儿童':
        return Icons.child_care_outlined;
      case '慢性病':
        return Icons.favorite_outline;
      default:
        return Icons.inventory_2_outlined;
    }
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async =>
      showMedSheet(context, widget.store, existing: existing);

  /// 打开药品详情页。详情是整页 `MedicineDetailPage`，
  /// 不是 sheet —— 它内部有「在健康科普里追问这盒药」的入口。
  Future<void> _openDetail(Map<String, dynamic> med) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MedicineDetailPage(store: widget.store, med: med),
      ),
    );
  }

  Future<void> _onLongPress(Map<String, dynamic> med) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个药品？'),
        content: Text(med['name']?.toString() ?? ''),
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
    await widget.store.removeMed(med['id'].toString());
  }
}

/// 分组容器。与账本页同样的处理：白底 + 细描边 + 小圆角，无阴影。
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

/// 一条药品。保留原有的到期状态呈现，但去掉 pastel 图标底板。
class _MedRow extends StatelessWidget {
  const _MedRow({
    required this.med,
    required this.now,
    required this.onTap,
    required this.onLongPress,
  });

  final Map<String, dynamic> med;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final info = ExpiryInfo.parse(med['expiry']);
    final daysLeft = info.daysLeft(now);
    final expired = info.isExpired(now);
    final soon = info.isExpiringWithin(30, now);
    final stock = med['stock'];
    final tags = MedsPageState.tagsOf(med);

    final statusColor = expired
        ? Tone.error
        : (soon ? Tone.warning : Tone.textTertiary);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.card,
          vertical: Gap.x3 + 2,
        ),
        child: Row(
          children: [
            Icon(
              Icons.medication_outlined,
              size: 18,
              color: expired ? Tone.error : Tone.iconTeal,
            ),
            const SizedBox(width: Gap.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          med['name']?.toString() ?? '',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Tone.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (stock != null && stock.toString() != '1') ...[
                        const SizedBox(width: Gap.x2),
                        Text(
                          '×$stock',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Tone.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: Gap.hairline),
                  Row(
                    children: [
                      Text(
                        [
                          if (tags.isNotEmpty && tags.first != '其他')
                            tags.first,
                          if (info.date != null)
                            _expiryText(info, daysLeft, expired, soon)
                          else
                            '未填保质期',
                        ].join(' · '),
                        style: TextStyle(fontSize: 12, color: statusColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: Gap.x2),
            const Icon(Icons.chevron_right, size: 18, color: Tone.textTertiary),
          ],
        ),
      ),
    );
  }

  static String _expiryText(
    ExpiryInfo info,
    int? daysLeft,
    bool expired,
    bool soon,
  ) {
    final date = info.date!;
    final label = '${date.year}-${date.month.toString().padLeft(2, '0')}';
    if (expired) {
      return '$label 已过期';
    }
    if (soon && daysLeft != null) {
      return '$label 剩 $daysLeft 天';
    }
    return '$label 到期';
  }
}
