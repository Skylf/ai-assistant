import 'package:flutter/material.dart';

import '../core/util.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 记账 / 改账表单。
///
/// 对应 0.2C 示例图：底部抽屉 + 「支出 / 收入」分段选择 + 大号金额输入 +
/// 分类图标网格 + 日期选择行 + 备注，底部「取消 / 保存」。
///
/// 传入 [existing] 即为编辑：沿用原 id 走 upsert，不再产生重复记录。
Future<void> showExpenseSheet(
  BuildContext context,
  Store store, {
  Map<String, dynamic>? existing,
  DateTime? initialDate,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => ExpenseSheet(
    store: store,
    existing: existing,
    initialDate: initialDate,
  ),
);

class ExpenseSheet extends StatefulWidget {
  const ExpenseSheet({
    super.key,
    required this.store,
    this.existing,
    this.initialDate,
  });

  final Store store;
  final Map<String, dynamic>? existing;
  final DateTime? initialDate;

  @override
  State<ExpenseSheet> createState() => _ExpenseSheetState();
}

class _ExpenseSheetState extends State<ExpenseSheet> {
  late final TextEditingController _title;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  late String _category;
  late bool _isIncome;
  late DateTime _when;
  bool _showAllCategories = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final row = widget.existing;
    _title = TextEditingController(text: row?['title']?.toString() ?? '');
    _amount = TextEditingController(
      text: row?['amount'] == null ? '' : _trimZero(row!['amount']),
    );
    _note = TextEditingController(text: row?['note']?.toString() ?? '');
    final category = row?['category']?.toString().trim() ?? '';
    _category = category.isEmpty ? '餐饮' : category;
    _isIncome = row?['entryType'] == 'income';
    _when =
        DateTime.tryParse(row?['spentAt']?.toString() ?? '') ??
        widget.initialDate ??
        DateTime.now();
  }

  static String _trimZero(Object value) {
    if (value is num) {
      final asDouble = value.toDouble();
      return asDouble == asDouble.roundToDouble()
          ? asDouble.round().toString()
          : asDouble.toString();
    }
    return value.toString();
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: _when,
    );
    if (picked == null || !mounted) return;
    setState(() => _when = picked);
  }

  Future<void> _submit() async {
    final value = parseAmount(_amount.text);
    if (value == null) {
      toast(context, '请填写有效的金额');
      return;
    }
    if (value == 0) {
      toast(context, '金额需要大于 0');
      return;
    }
    // 名称为空时用分类兜底，避免账本里出现一堆「未命名」。
    final title = _title.text.trim().isEmpty ? _category : _title.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await widget.store.expense(
      {
        'title': title,
        'amount': value,
        'category': _category,
        'note': _note.text.trim(),
        'entryType': _isIncome ? 'income' : 'expense',
        'spentAt': _when.toIso8601String(),
      },
      existing: widget.existing,
    );
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(_isEdit ? '已保存修改' : '已记入账本')));
  }

  Future<void> _delete() async {
    final confirmed = await confirmDialog(
      context,
      title: '删除这笔账目？',
      content: '删除后无法恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await widget.store.removeExpense(widget.existing!['id'].toString());
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已删除该账目')));
  }

  List<String> get _visibleCategories => _showAllCategories
      ? Categories.all
      : Categories.quick;

  @override
  Widget build(BuildContext context) => SheetScaffold(
    title: _isEdit ? '修改账目' : '新增账目',
    subtitle: _isEdit ? '调整这笔记录的信息' : '记录一笔收支，让生活更有规划',
    submitLabel: _isEdit ? '保存修改' : '保存',
    onDelete: _isEdit ? _delete : null,
    onSubmit: _submit,
    children: [
      _TypeToggle(
        isIncome: _isIncome,
        onChanged: (value) => setState(() => _isIncome = value),
      ),
      const SizedBox(height: Gap.x4),
      _AmountField(controller: _amount),
      const SizedBox(height: Gap.x4),
      Row(
        children: [
          Text('分类', style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          if (!_showAllCategories)
            TextButton(
              onPressed: () => setState(() => _showAllCategories = true),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Row(
                children: [
                  Text('更多分类'),
                  Icon(Icons.chevron_right, size: 16),
                ],
              ),
            ),
        ],
      ),
      const SizedBox(height: Gap.x2 - 2),
      Wrap(
        spacing: Gap.x2,
        runSpacing: Gap.x3,
        children: [
          for (final name in _visibleCategories)
            _CategoryChip(
              name: name,
              selected: name == _category,
              onTap: () => setState(() => _category = name),
            ),
        ],
      ),
      const SizedBox(height: Gap.x4),
      FormField2(
        label: '名称',
        controller: _title,
        hint: '如：午餐、地铁（留空则用分类名）',
        optional: true,
        leadingIcon: Icons.edit_note_outlined,
        maxLength: 50,
      ),
      SelectField(
        label: '日期',
        value: formatDateWithToday(_when),
        icon: Icons.event_outlined,
        onTap: _pickDate,
      ),
      FormField2(
        label: '备注',
        controller: _note,
        hint: '简单记录一下…',
        optional: true,
        leadingIcon: Icons.notes_outlined,
        maxLines: 3,
        maxLength: 100,
      ),
    ],
  );
}

/// 日期文案，今天额外标注「（今天）」。
String formatDateWithToday(DateTime date) {
  final now = DateTime.now();
  final suffix = date.year == now.year &&
          date.month == now.month &&
          date.day == now.day
      ? '（今天）'
      : '';
  return '${date.year} 年 ${date.month} 月 ${date.day} 日$suffix';
}

/// 「支出 / 收入」分段选择。
class _TypeToggle extends StatelessWidget {
  const _TypeToggle({required this.isIncome, required this.onChanged});

  final bool isIncome;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _ToggleTile(
          label: '支出',
          icon: Icons.arrow_downward,
          selected: !isIncome,
          color: Tone.expense,
          onTap: () => onChanged(false),
        ),
      ),
      const SizedBox(width: Gap.x3),
      Expanded(
        child: _ToggleTile(
          label: '收入',
          icon: Icons.arrow_upward,
          selected: isIncome,
          color: Tone.income,
          onTap: () => onChanged(true),
        ),
      ),
    ],
  );
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? Tone.primaryContainer : Tone.surface,
    borderRadius: BorderRadius.circular(Gap.inputRadius),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Gap.inputRadius),
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Gap.inputRadius),
          border: Border.all(
            color: selected ? Tone.selectedChip : Tone.outline,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: selected ? color : Tone.surfaceMuted,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 14,
                color: selected ? Colors.white : Tone.textSecondary,
              ),
            ),
            const SizedBox(width: Gap.x2),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: selected ? Tone.primary : Tone.textSecondary,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 大号金额输入框。
class _AmountField extends StatelessWidget {
  const _AmountField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('金额', style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: Gap.x2 - 2),
      TextField(
        controller: controller,
        autofocus: false,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: Tone.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: '0.00',
          hintStyle: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: Tone.textTertiary,
          ),
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: Gap.x4, right: Gap.x2),
            child: Text(
              '¥',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Tone.textSecondary,
              ),
            ),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: const Padding(
            padding: EdgeInsets.only(right: Gap.x3),
            child: Icon(
              Icons.calculate_outlined,
              color: Tone.textSecondary,
            ),
          ),
          suffixIconConstraints: const BoxConstraints(minWidth: 44),
          contentPadding: const EdgeInsets.symmetric(vertical: Gap.x4),
        ),
      ),
    ],
  );
}

/// 分类图标网格单元。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = Categories.of(name);
    return SizedBox(
      width: 64,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Gap.x3),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: style.tint,
                borderRadius: BorderRadius.circular(Gap.x3),
                border: Border.all(
                  color: selected ? style.color : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Icon(style.icon, size: 22, color: style.color),
            ),
            const SizedBox(height: Gap.x1 + 2),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? style.color : Tone.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
