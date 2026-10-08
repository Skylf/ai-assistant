import 'package:flutter/material.dart';

import '../core/med_classify.dart';
import '../core/util.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/ui.dart' show SectionLabel;
import 'expense_form.dart' show formatDateWithToday;

/// 添加 / 修改药品表单。
///
/// 对应 0.2C 示例图：底部抽屉 + 必填星号 + 字数计数 + 「库存数量」步进器 +
/// 「有效期 / 储存条件」选择行 + 备注多行 + 「取消 / 保存」。
///
/// 0.4D 改版：按**用途**分成三组，而不是把所有字段平铺成一长列：
///  ① 基本信息（名称/成分/规格/库存/有效期/储存）—— 药箱管理要用的；
///  ② 用法与药效（分类/用法用量/治疗范围/药效）—— 用药时要看的；
///  ③ 安全信息（不良反应/禁忌/注意事项/备注）—— 出事时要查的。
///
/// 这样分组不只是好看：用户 0.4D 的抱怨是「药品具体信息不完善」，
/// 而字段一多，平铺列表会让人找不到「禁忌在哪」。分组给了定位线索。
Future<void> showMedSheet(
  BuildContext context,
  Store store, {
  Map<String, dynamic>? existing,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => MedSheet(store: store, existing: existing),
);

class MedSheet extends StatefulWidget {
  const MedSheet({super.key, required this.store, this.existing});

  final Store store;
  final Map<String, dynamic>? existing;

  @override
  State<MedSheet> createState() => _MedSheetState();
}

class _MedSheetState extends State<MedSheet> {
  late final TextEditingController _name;
  late final TextEditingController _ingredient;
  late final TextEditingController _spec;
  late final TextEditingController _stock;
  late final TextEditingController _storage;
  late final TextEditingController _note;
  // ---- 0.4D 新增：详细信息字段 ----
  late final TextEditingController _usage;
  late final TextEditingController _indications;
  late final TextEditingController _efficacy;
  late final TextEditingController _adverse;
  late final TextEditingController _contraindications;
  late final TextEditingController _precautions;
  DateTime? _expiry;

  /// 用户手选的分类。为空表示「交给自动分类」。
  String _form = '';

  bool get _isEdit => widget.existing != null;

  /// 常见储存条件，点一下就能填，不用手打。
  static const _storagePresets = ['常温、避光、干燥', '阴凉处（≤20℃）', '冷藏 2-8℃', '密封防潮'];

  /// 分类可选项。第一项是「自动」，其余与 [MedRoute] 的 label 对齐。
  static const _formOptions = ['自动判断', '内服', '外用'];

  @override
  void initState() {
    super.initState();
    final row = widget.existing;
    _name = TextEditingController(text: row?['name']?.toString() ?? '');
    _ingredient = TextEditingController(
      text: row?['ingredient']?.toString() ?? '',
    );
    _spec = TextEditingController(text: row?['spec']?.toString() ?? '');
    _stock = TextEditingController(
      text: row?['stock'] == null ? '1' : '${row!['stock']}',
    );
    _storage = TextEditingController(text: row?['storage']?.toString() ?? '');
    _note = TextEditingController(text: row?['note']?.toString() ?? '');
    _usage = TextEditingController(text: row?['usage']?.toString() ?? '');
    _indications = TextEditingController(
      text: row?['indications']?.toString() ?? '',
    );
    _efficacy = TextEditingController(text: row?['efficacy']?.toString() ?? '');
    _adverse = TextEditingController(text: row?['adverse']?.toString() ?? '');
    _contraindications = TextEditingController(
      text: row?['contraindications']?.toString() ?? '',
    );
    _precautions = TextEditingController(
      text: row?['precautions']?.toString() ?? '',
    );
    _expiry = DateTime.tryParse(row?['expiry']?.toString() ?? '');
    _form = row?['form']?.toString() ?? '';
    // SelectField 读的是 _storage.text，需要跟着输入变化重建。
    _storage.addListener(_onStorageChanged);
    // 药品名会实时影响「自动判断」的结果，所以要监听它来刷新那行提示。
    _name.addListener(_onNameChanged);
  }

  void _onStorageChanged() {
    if (mounted) setState(() {});
  }

  void _onNameChanged() {
    if (mounted && _form.isEmpty) setState(() {});
  }

  @override
  void dispose() {
    _storage.removeListener(_onStorageChanged);
    _name.removeListener(_onNameChanged);
    _name.dispose();
    _ingredient.dispose();
    _spec.dispose();
    _stock.dispose();
    _storage.dispose();
    _note.dispose();
    _usage.dispose();
    _indications.dispose();
    _efficacy.dispose();
    _adverse.dispose();
    _contraindications.dispose();
    _precautions.dispose();
    super.dispose();
  }

  Future<void> _pickExpiry() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDate: _expiry ?? DateTime.now().add(const Duration(days: 365)),
      helpText: '选择有效期',
    );
    if (picked == null || !mounted) return;
    setState(() => _expiry = picked);
  }

  Future<void> _pickStorage() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.x3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.page,
                  0,
                  Gap.page,
                  Gap.x3,
                ),
                child: Text(
                  '常见储存条件',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final preset in _storagePresets)
                ListTile(
                  leading: const Icon(
                    Icons.thermostat_outlined,
                    color: Tone.iconTeal,
                  ),
                  title: Text(preset),
                  onTap: () => Navigator.of(sheetContext).pop(preset),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _storage.text = picked);
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      toast(context, '请填写药品名称');
      return;
    }
    final stock = parseCount(_stock.text);
    if (stock == null) {
      toast(context, '库存请填写 0 或正整数');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await widget.store.med(
      {
        'name': _name.text.trim(),
        'ingredient': _ingredient.text.trim(),
        'spec': _spec.text.trim(),
        'stock': stock,
        'expiry': _expiry == null ? '' : formatDate(_expiry!.toIso8601String()),
        'storage': _storage.text.trim(),
        // 空串 = 交回自动分类。故意写空串而不是省略这个键：
        // 用户从「内服」改回「自动判断」时，必须能把旧值真的清掉。
        'form': _form,
        // ---- 0.4D：详细信息 ----
        'usage': _usage.text.trim(),
        'indications': _indications.text.trim(),
        'efficacy': _efficacy.text.trim(),
        'adverse': _adverse.text.trim(),
        'contraindications': _contraindications.text.trim(),
        'precautions': _precautions.text.trim(),
        'note': _note.text.trim(),
      },
      existing: widget.existing,
    );
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(_isEdit ? '已保存修改' : '已加入药箱')));
  }

  Future<void> _delete() async {
    final confirmed = await confirmDialog(
      context,
      title: '删除这盒药品？',
      content: '删除后无法恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await widget.store.removeMed(widget.existing!['id'].toString());
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已删除该药品')));
  }

  @override
  Widget build(BuildContext context) => SheetScaffold(
    title: _isEdit ? '修改药品' : '添加药品',
    subtitle: '完善药品信息，便于管理和提醒',
    submitLabel: _isEdit ? '保存修改' : '保存',
    onDelete: _isEdit ? _delete : null,
    onSubmit: _submit,
    children: [
      // ============================================ ① 基本信息
      const _GroupTitle('基本信息', '药箱列表和过期提醒用的就是这些'),
      FormField2(
        label: '药品名称',
        controller: _name,
        hint: '请输入药品名称（如：布洛芬缓释胶囊）',
        required: true,
        leadingIcon: Icons.medication_outlined,
        maxLength: 50,
      ),
      FormField2(
        label: '通用名 / 成分',
        controller: _ingredient,
        hint: '如：布洛芬',
        optional: true,
        leadingIcon: Icons.science_outlined,
        maxLength: 50,
      ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: FormField2(
              label: '规格',
              controller: _spec,
              hint: '如：0.2g × 20 片',
              optional: true,
              leadingIcon: Icons.straighten_outlined,
              maxLength: 40,
            ),
          ),
          const SizedBox(width: Gap.x3),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('库存数量', style: Theme.of(context).textTheme.bodySmall),
                    const Text(
                      ' *',
                      style: TextStyle(color: Tone.error, fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.x2 - 2),
                CountStepper(controller: _stock),
                const SizedBox(height: Gap.x3),
              ],
            ),
          ),
        ],
      ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectField(
              label: '有效期',
              value: _expiry == null ? '' : formatDateWithToday(_expiry!),
              hint: '请选择日期',
              icon: Icons.event_outlined,
              required: true,
              onTap: _pickExpiry,
            ),
          ),
          const SizedBox(width: Gap.x3),
          Expanded(
            child: SelectField(
              label: '储存条件',
              value: _storage.text,
              hint: '如：常温、避光',
              icon: Icons.thermostat_outlined,
              optional: true,
              onTap: _pickStorage,
            ),
          ),
        ],
      ),

      // ============================================ ② 用法与药效
      const _GroupTitle('用法与药效', '用药时要看的内容'),
      _routePicker(context),
      FormField2(
        label: '用法用量',
        controller: _usage,
        hint: '如：口服，一次 1 粒，一日 2 次',
        optional: true,
        leadingIcon: Icons.schedule_outlined,
        maxLines: 2,
        maxLength: 300,
      ),
      FormField2(
        label: '治疗范围 / 适应症',
        controller: _indications,
        hint: '如：用于缓解轻至中度疼痛，如头痛、关节痛',
        optional: true,
        leadingIcon: Icons.my_location_outlined,
        maxLines: 2,
        maxLength: 300,
      ),
      FormField2(
        label: '药效 / 作用',
        controller: _efficacy,
        hint: '如：解热镇痛抗炎药，通过抑制前列腺素合成起效',
        optional: true,
        leadingIcon: Icons.bolt_outlined,
        maxLines: 2,
        maxLength: 300,
      ),

      // ============================================ ③ 安全信息
      const _GroupTitle('安全信息', '出现异常时要查的内容，建议按说明书抄录'),
      FormField2(
        label: '不良反应',
        controller: _adverse,
        hint: '如：偶见恶心、胃部不适、皮疹',
        optional: true,
        leadingIcon: Icons.warning_amber_outlined,
        maxLines: 2,
        maxLength: 300,
      ),
      FormField2(
        label: '禁忌',
        controller: _contraindications,
        hint: '如：对本品过敏者禁用；活动性消化道溃疡者禁用',
        optional: true,
        leadingIcon: Icons.block_outlined,
        maxLines: 2,
        maxLength: 300,
      ),
      FormField2(
        label: '注意事项',
        controller: _precautions,
        hint: '如：孕妇及哺乳期妇女慎用；避免与其他解热镇痛药同服',
        optional: true,
        leadingIcon: Icons.info_outline,
        maxLines: 3,
        maxLength: 400,
      ),
      FormField2(
        label: '备注',
        controller: _note,
        hint: '如：放在客厅抽屉第二层',
        optional: true,
        leadingIcon: Icons.description_outlined,
        maxLines: 2,
        maxLength: 200,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () {
            // 常用标记写入备注，配合药箱页的「常用」筛选。
            if (_note.text.contains(commonMedTag)) {
              _note.text = _note.text.replaceAll(commonMedTag, '').trim();
            } else {
              _note.text = '${_note.text.trim()} $commonMedTag'.trim();
            }
            setState(() {});
          },
          icon: Icon(
            _note.text.contains(commonMedTag) ? Icons.star : Icons.star_border,
            size: 18,
          ),
          label: Text(
            _note.text.contains(commonMedTag) ? '已标记为常用药' : '标记为常用药',
          ),
        ),
      ),
    ],
  );

  /// 分类选择行：让用户能直接指定内服/外用，而不是只能接受自动判断。
  ///
  /// 「自动判断」那一行会**实时显示判定结果**（或在判不出来时说明原因）——
  /// 否则用户选了一堆字段却不知道分类到底会变成什么，等于没得选。
  Widget _routePicker(BuildContext context) {
    final theme = Theme.of(context);
    // 用当前表单内容算一次「自动判断会判成什么」，让选择有依据。
    final auto = routeOf({
      'name': _name.text,
      'ingredient': _ingredient.text,
      'spec': _spec.text,
      'note': _note.text,
    });
    final autoText = auto == MedRoute.unknown
        ? '按名称判不出来，建议手动指定'
        : '按名称自动判为「${auto.label}」';
    final selected = _form.isEmpty ? '自动判断' : _form;

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('分类', style: theme.textTheme.bodySmall),
              const Spacer(),
              Text(
                _form.isEmpty ? autoText : '已手动指定为「$_form」',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
          const SizedBox(height: Gap.x2 - 2),
          Wrap(
            spacing: Gap.x2,
            runSpacing: Gap.x2,
            children: [
              for (final option in _formOptions)
                ChoiceChip(
                  label: Text(option),
                  selected: selected == option,
                  onSelected: (_) => setState(
                    () => _form = option == '自动判断' ? '' : option,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 表单里的分组标题。用 [SectionLabel] 保持与其他页面同一套视觉。
class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.title, this.hint);

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Gap.x2, bottom: Gap.x1),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(title),
        Text(hint, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: Gap.x2),
      ],
    ),
  );
}
