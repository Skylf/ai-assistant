import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../data/store.dart';
import '../security/password_engine.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 密码生成器（0.3A 模块）。
///
/// 三个生成模式 + 一个本地记录页：
///  - 随机密码：长度、字符集、易混淆字符、重复字符、强制包含各类别
///  - 助记口令：单词数量、分隔符、是否附加数字
///  - 密钥：分组展示的长随机串，适合 API Key / 恢复码
///  - 记录：只保存用途与强度，绝不保存明文
class PasswordToolPage extends StatefulWidget {
  const PasswordToolPage({super.key, required this.store, this.engine});

  final Store store;

  /// 生成器。默认使用 `Random.secure()`；测试与预览出图时可注入固定种子，
  /// 让结果可复现。
  final PasswordEngine? engine;

  @override
  State<PasswordToolPage> createState() => _PasswordToolPageState();
}

class _PasswordToolPageState extends State<PasswordToolPage>
    with SingleTickerProviderStateMixin {
  late final PasswordEngine _engine = widget.engine ?? PasswordEngine();
  late final TabController _tabs = TabController(length: 4, vsync: this);

  // 随机密码
  int _length = 16;
  CharsetOptions _options = const CharsetOptions();
  String _password = '';
  List<String> _candidates = const [];

  // 助记口令
  int _words = 4;
  String _separator = '-';
  bool _appendDigits = true;
  bool _capitalize = true;
  String _passphrase = '';

  // 密钥
  int _keyLength = 32;
  int _groupSize = 8;
  String _key = '';

  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    _regenerate();
    _regeneratePassphrase();
    _regenerateKey();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 生成逻辑

  void _regenerate() {
    try {
      _password = _engine.generate(length: _length, options: _options);
      _candidates = _engine.generateMany(
        length: _length,
        options: _options,
        count: 5,
      );
    } on ArgumentError catch (error) {
      _password = '';
      _candidates = const [];
      toast(context, error.message.toString());
    }
  }

  void _regeneratePassphrase() {
    _passphrase = _engine.generatePassphrase(
      words: _words,
      separator: _separator,
      appendDigits: _appendDigits,
      capitalize: _capitalize,
    );
  }

  void _regenerateKey() {
    _key = _engine.generateKey(
      length: _keyLength,
      groupSize: _groupSize,
      separator: '-',
    );
  }

  Future<void> _copy(String value, String label) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    toast(context, '$label已复制到剪贴板');
  }

  Future<void> _saveRecord(String value, String kind) async {
    if (value.isEmpty) return;
    final label = await _askLabel(kind);
    if (label == null || label.isEmpty || !mounted) return;
    await store.savePasswordRecord(
      label: label,
      site: kind,
      length: value.length,
      strength: _engine.strengthOf(value),
      entropy: _engine.entropyFor(value),
    );
    if (!mounted) return;
    toast(context, '已保存记录（不含明文）');
  }

  Future<String?> _askLabel(String kind) => showDialog<String>(
    context: context,
    builder: (_) => _LabelDialog(kind: kind),
  );

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          const DetailHeader('密码生成器'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
            child: Container(
              padding: const EdgeInsets.all(Gap.x3),
              decoration: BoxDecoration(
                color: Tone.tintAmber,
                borderRadius: BorderRadius.circular(Gap.x3),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lock_outline, size: 18, color: Tone.warning),
                  const SizedBox(width: Gap.x2),
                  Expanded(
                    child: Text(
                      '密码在本机用安全随机数生成，不联网、不上传。'
                      '请把生成结果保存到你的密码管理器。',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Gap.x3),
          TabBar(
            controller: _tabs,
            labelColor: Tone.primary,
            unselectedLabelColor: Tone.textSecondary,
            indicatorColor: Tone.primary,
            tabs: const [
              Tab(text: '随机密码'),
              Tab(text: '助记口令'),
              Tab(text: '密钥'),
              Tab(text: '记录'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _randomTab(),
                _passphraseTab(),
                _keyTab(),
                _recordsTab(),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _randomTab() {
    final strength = _engine.strengthOf(_password);
    return ListView(
      padding: const EdgeInsets.all(Gap.page),
      children: [
        _ResultCard(
          value: _password,
          strength: strength,
          entropy: _engine.entropyFor(_password),
          onRefresh: () => setState(_regenerate),
          onCopy: () => _copy(_password, '密码'),
          onSave: () => _saveRecord(_password, '随机密码'),
        ),
        const SizedBox(height: Gap.x4),
        _slider(
          label: '密码长度',
          value: _length.toDouble(),
          min: PasswordEngine.minLength.toDouble(),
          max: 64,
          display: '$_length 位',
          onChanged: (value) => setState(() {
            _length = value.round();
            _regenerate();
          }),
        ),
        const SizedBox(height: Gap.x3),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('字符类型', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: Gap.x2),
                _switchTile(
                  title: '小写字母 a-z',
                  value: _options.lowercase,
                  onChanged: (value) => _update(
                    _options.copyWith(lowercase: value),
                  ),
                ),
                _switchTile(
                  title: '大写字母 A-Z',
                  value: _options.uppercase,
                  onChanged: (value) => _update(
                    _options.copyWith(uppercase: value),
                  ),
                ),
                _switchTile(
                  title: '数字 0-9',
                  value: _options.digits,
                  onChanged: (value) => _update(_options.copyWith(digits: value)),
                ),
                _switchTile(
                  title: '特殊符号 !@#\$…',
                  value: _options.symbols,
                  onChanged: (value) => _update(_options.copyWith(symbols: value)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.x3),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('高级选项', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: Gap.x2),
                _switchTile(
                  title: '排除易混淆字符',
                  subtitle: '去掉 0 O o I l 1 | 等看着像的字符',
                  value: _options.excludeAmbiguous,
                  onChanged: (value) => _update(
                    _options.copyWith(excludeAmbiguous: value),
                  ),
                ),
                _switchTile(
                  title: '每类字符至少出现一次',
                  subtitle: '保证大小写与数字都真的被用到',
                  value: _options.requireEachSelected,
                  onChanged: (value) => _update(
                    _options.copyWith(requireEachSelected: value),
                  ),
                ),
                _switchTile(
                  title: '相邻字符不重复',
                  subtitle: '避免出现 aa11 这类连续重复',
                  value: _options.noRepeat,
                  onChanged: (value) => _update(_options.copyWith(noRepeat: value)),
                ),
              ],
            ),
          ),
        ),
        if (_candidates.isNotEmpty) ...[
          const SizedBox(height: Gap.x4),
          Text('其它候选', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Gap.x2),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < _candidates.length; i++) ...[
                  ListTile(
                    dense: true,
                    title: Text(
                      _candidates[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                      ),
                    ),
                    trailing: IconButton(
                      onPressed: () => _copy(_candidates[i], '候选密码'),
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: '复制',
                    ),
                  ),
                  if (i != _candidates.length - 1)
                    const Divider(height: 1, indent: Gap.x4),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _update(CharsetOptions options) => setState(() {
    _options = options;
    _regenerate();
  });

  Widget _passphraseTab() {
    final strength = _engine.strengthOf(_passphrase);
    return ListView(
      padding: const EdgeInsets.all(Gap.page),
      children: [
        _ResultCard(
          value: _passphrase,
          strength: strength,
          entropy: _engine.entropyFor(_passphrase),
          onRefresh: () => setState(_regeneratePassphrase),
          onCopy: () => _copy(_passphrase, '口令'),
          onSave: () => _saveRecord(_passphrase, '助记口令'),
        ),
        const SizedBox(height: Gap.x4),
        _slider(
          label: '单词数量',
          value: _words.toDouble(),
          min: 3,
          max: 8,
          display: '$_words 个单词',
          onChanged: (value) => setState(() {
            _words = value.round();
            _regeneratePassphrase();
          }),
        ),
        const SizedBox(height: Gap.x3),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('口令格式', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: Gap.x2),
                Wrap(
                  spacing: Gap.x2,
                  children: [
                    for (final separator in ['-', '.', '_', ' '])
                      ChoiceChip(
                        label: Text(separator == ' ' ? '空格' : separator),
                        selected: _separator == separator,
                        onSelected: (_) => setState(() {
                          _separator = separator;
                          _regeneratePassphrase();
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: Gap.x2),
                _switchTile(
                  title: '首字母大写',
                  value: _capitalize,
                  onChanged: (value) => setState(() {
                    _capitalize = value;
                    _regeneratePassphrase();
                  }),
                ),
                _switchTile(
                  title: '结尾附加 4 位数字',
                  value: _appendDigits,
                  onChanged: (value) => setState(() {
                    _appendDigits = value;
                    _regeneratePassphrase();
                  }),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.x3),
        Text(
          '助记口令由常见单词组成，比同长度的随机串更好记，'
          '适合作为主密码或密码管理器的解锁口令。',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }

  Widget _keyTab() {
    final strength = _engine.strengthOf(_key);
    return ListView(
      padding: const EdgeInsets.all(Gap.page),
      children: [
        _ResultCard(
          value: _key,
          strength: strength,
          entropy: _engine.entropyFor(_key),
          onRefresh: () => setState(_regenerateKey),
          onCopy: () => _copy(_key, '密钥'),
          onSave: () => _saveRecord(_key, '密钥'),
        ),
        const SizedBox(height: Gap.x4),
        _slider(
          label: '密钥长度',
          value: _keyLength.toDouble(),
          min: 16,
          max: PasswordEngine.maxLength.toDouble(),
          display: '$_keyLength 位',
          onChanged: (value) => setState(() {
            _keyLength = value.round();
            _regenerateKey();
          }),
        ),
        const SizedBox(height: Gap.x3),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.card),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('分组长度', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: Gap.x2),
                Wrap(
                  spacing: Gap.x2,
                  children: [
                    for (final size in [0, 4, 8, 16])
                      ChoiceChip(
                        label: Text(size == 0 ? '不分组' : '每 $size 位'),
                        selected: _groupSize == size,
                        onSelected: (_) => setState(() {
                          _groupSize = size;
                          _regenerateKey();
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: Gap.x2),
                Text(
                  '默认排除易混淆字符、只含大小写字母与数字，方便抄写与粘贴。',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _recordsTab() => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      if (store.savedPasswords.isEmpty) {
        return ListView(
          padding: const EdgeInsets.all(Gap.page),
          children: const [
            Card(
              child: EmptyState(
                icon: Icons.password,
                title: '还没有密码记录',
                detail: '生成密码后点「保存记录」，这里会记下用途、长度与强度，'
                    '方便回看当时的强度选择。',
              ),
            ),
          ],
        );
      }
      final sorted = [...store.savedPasswords]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return ListView(
        padding: const EdgeInsets.all(Gap.page),
        children: [
          Container(
            padding: const EdgeInsets.all(Gap.x3),
            decoration: BoxDecoration(
              color: Tone.tintGreen,
              borderRadius: BorderRadius.circular(Gap.x3),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.verified_user_outlined,
                  size: 18,
                  color: Tone.income,
                ),
                const SizedBox(width: Gap.x2),
                Expanded(
                  child: Text(
                    '记录里不包含密码明文，只有用途与强度指标。',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.x3),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < sorted.length; i++) ...[
                  _RecordRow(
                    record: sorted[i],
                    onDelete: () => _deleteRecord(sorted[i]),
                  ),
                  if (i != sorted.length - 1)
                    const Divider(height: 1, indent: 72),
                ],
              ],
            ),
          ),
        ],
      );
    },
  );

  Future<void> _deleteRecord(SavedPassword record) async {
    final ok = await confirmDialog(
      context,
      title: '删除这条记录？',
      content: '「${record.label}」的记录将被删除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok) return;
    await store.removePasswordRecord(record.id);
    if (mounted) toast(context, '已删除该记录');
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(Gap.card, Gap.x3, Gap.card, Gap.x2),
      child: Column(
        children: [
          Row(
            children: [
              Text(label, style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Text(
                display,
                style: const TextStyle(
                  color: Tone.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: (max - min).round(),
            label: display,
            onChanged: onChanged,
          ),
        ],
      ),
    ),
  );

  Widget _switchTile({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String subtitle = '',
  }) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
    subtitle: subtitle.isEmpty
        ? null
        : Text(subtitle, style: Theme.of(context).textTheme.labelSmall),
    value: value,
    onChanged: onChanged,
  );
}

/// 生成结果卡片：等宽大字 + 强度条 + 三个操作。
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.value,
    required this.strength,
    required this.entropy,
    required this.onRefresh,
    required this.onCopy,
    required this.onSave,
  });

  final String value;
  final int strength;
  final double entropy;
  final VoidCallback onRefresh;
  final VoidCallback onCopy;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final color = Color(PasswordEngine.strengthColors[strength]);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              value.isEmpty ? '—' : value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 18,
                height: 1.5,
                fontWeight: FontWeight.w600,
                letterSpacing: .5,
              ),
            ),
            const SizedBox(height: Gap.x3),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (strength + 1) / 5,
                      minHeight: 6,
                      backgroundColor: Tone.surfaceMuted,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                ),
                const SizedBox(width: Gap.x3),
                Text(
                  PasswordEngine.strengthLabels[strength],
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.x1),
            Text(
              '约 ${entropy.toStringAsFixed(0)} 位熵 · ${value.length} 个字符',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: Gap.x3),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重新生成'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                ),
                const SizedBox(width: Gap.x2),
                IconButton.filledTonal(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: '复制',
                ),
                const SizedBox(width: Gap.x1),
                IconButton.filledTonal(
                  onPressed: onSave,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  tooltip: '保存记录',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 保存记录的命名弹窗。
///
/// 做成 StatefulWidget 有两个原因：controller 需要有人负责 dispose（在
/// showDialog 的 builder 里现场 new 一个，每次重建都会新建并丢掉旧的），
/// 而且不能在 showDialog 返回后立刻 dispose —— 弹窗还有退场动画，
/// TextField 仍会在那一帧里读它。
class _LabelDialog extends StatefulWidget {
  const _LabelDialog({required this.kind});

  final String kind;

  @override
  State<_LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<_LabelDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('保存为密码记录'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 40,
            decoration: const InputDecoration(
              hintText: '用途，例如：邮箱 / 路由器后台',
            ),
          ),
          const SizedBox(height: Gap.x2),
          Text(
            '出于安全考虑，只保存用途、长度与强度，不保存密码明文。'
            '需要密码时请当场复制到密码管理器。',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        child: const Text('保存'),
      ),
    ],
  );
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record, required this.onDelete});

  final SavedPassword record;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final color = Color(
      PasswordEngine.strengthColors[record.strength.clamp(0, 4)],
    );
    return ListTile(
      leading: const IconTile(
        icon: Icons.password,
        tint: Tone.tintSlate,
        color: Tone.iconSlate,
      ),
      title: Text(record.label.isEmpty ? '未命名' : record.label),
      subtitle: Text(
        '${record.site} · ${record.length} 位 · '
        '${DateFormat('yyyy/M/d HH:mm').format(record.createdAt)}',
        style: Theme.of(context).textTheme.labelSmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            PasswordEngine.strengthLabels[record.strength.clamp(0, 4)],
            style: TextStyle(color: color, fontSize: 12),
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: '删除',
          ),
        ],
      ),
    );
  }
}
