import 'package:flutter/material.dart';

import '../ai/client.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'settings.dart';

/// AI 服务配置（二级页）。
///
/// 旧版把 URL / 模型 / Key 直接摊在设置首屏，且「模型」是自由文本，很容易填错。
/// 这里改为：模型名从服务商 `/models` 拉取后点选（仍可手写），Key 默认隐藏，
/// 并提供「测试连接」。
///
/// 模型名为什么不再写死：它是服务商的事实，随时会新增/改名/下线。0.2C 的默认值
/// `deepseek-flash` 因此在开放平台上根本不存在，新用户第一次对话就 404。
class AiConfigPage extends StatefulWidget {
  const AiConfigPage({super.key, required this.store});

  final Store store;

  @override
  State<AiConfigPage> createState() => _AiConfigPageState();
}

class _AiConfigPageState extends State<AiConfigPage> {
  late final TextEditingController _url;
  late final TextEditingController _model;
  late final TextEditingController _key;

  bool _revealKey = false;
  bool _testing = false;
  bool _loadingModels = false;
  String _status = '';
  bool _ok = false;

  /// 从服务商 `/models` 拉到的模型 id。为空时退回到「手工输入」。
  List<String> _models = const [];

  /// 拉取失败时的说明。
  ///
  /// 只作为「模型区」的提示，不写进 [_status]：两者同时出现会让用户读到互相
  /// 矛盾的结论（红框「已保存」+ 黄框「拉取失败」）。拉取一开始就清空它。
  String _modelsError = '';

  /// 请求代号。只有最新一次请求的结果才允许上屏。
  ///
  /// 「测试连接」与「获取可用模型」都是异步的，用户完全可能在一次飞行中再点
  /// 另一次。没有这个代号时，后返回的旧请求会覆盖新请求的结论，屏幕上就同时
  /// 挂着「连接成功」和「地址或 Key 有误」。
  int _requestSeq = 0;

  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: store.url);
    _model = TextEditingController(text: store.model);
    _key = TextEditingController(text: store.key);
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    if (url.isNotEmpty && !url.startsWith('http')) {
      setState(() {
        _ok = false;
        _status = '接口地址需要以 http:// 或 https:// 开头';
      });
      return;
    }
    await store.saveSettings(
      url: url.isEmpty ? store.url : url,
      model: _model.text.trim().isEmpty ? store.model : _model.text.trim(),
      apiKey: _key.text,
    );
    if (!mounted) return;
    setState(() {
      _ok = true;
      _status = '已保存到系统安全存储';
      // 用户已经手工填了模型名，拉取失败的旧提示不该再挂着
      _modelsError = '';
    });
  }

  Future<void> _test() async {
    final seq = ++_requestSeq;
    setState(() {
      _testing = true;
      _status = '';
    });
    // 先保存，保证测的就是待生效的配置。
    await store.saveSettings(
      url: _url.text.trim().isEmpty ? store.url : _url.text.trim(),
      model: _model.text.trim().isEmpty ? store.model : _model.text.trim(),
      apiKey: _key.text,
    );
    final result = await store.testConnection();
    if (!mounted || seq != _requestSeq) return;
    setState(() {
      _testing = false;
      _ok = result.ok;
      _status = result.ok
          ? '连接成功，模型「${store.model}」可用'
          : '连接失败：${result.display}';
    });
  }

  /// 问服务商要真实的模型列表。
  ///
  /// 模型名由服务商决定、随时会变，写死在客户端里迟早过期，所以这里直接拉取。
  /// 拉不到不报错，退回手工输入。
  ///
  /// **这是一个只读操作：绝不落盘。** 之前这里先 `saveSettings` 再请求，导致
  /// 「清空 Key 输入框 → 点拉取」会把安全存储里已保存的 Key 抹成空串，用户
  /// 之前配好的 Key 就永久丢了。现在改成直接构造一次性客户端。
  Future<void> _loadModels() async {
    final seq = ++_requestSeq;
    setState(() {
      _loadingModels = true;
      _modelsError = '';
      // 顺手清掉「已保存到系统安全存储」这类上一次操作留下的结论。
      // 否则红框说「已保存」、黄框说「拉取失败」，用户读到的是自相矛盾的状态。
      _status = '';
    });

    final url = _url.text.trim().isEmpty ? store.url : _url.text.trim();
    final key = _key.text.trim();
    if (key.isEmpty) {
      // 唯一确定的事实是「压根没填 Key」，别让用户去怀疑服务商不支持 /models
      setState(() {
        _loadingModels = false;
        _modelsError = '请先填写 API Key，再用它去拉取该地址下的模型列表。';
      });
      return;
    }

    List<String>? models;
    final client = AiClient(baseUrl: url, model: '', apiKey: key);
    try {
      models = await client.listModels();
    } finally {
      // 两件事都要做，缺一不可：
      // 1. 关掉这次请求建的连接池 —— 若只复位 loading 而忘了 close，每点一次
      //    「获取可用模型」就泄漏一个 keep-alive 连接池（这正是本轮修掉的
      //    AiClient.close() 死代码问题，别在这里重新引入）。
      // 2. 复位 loading，否则按钮会永远停在禁用的「获取中…」上。
      client.close();
      if (mounted && seq == _requestSeq) {
        setState(() => _loadingModels = false);
      }
    }
    if (!mounted || seq != _requestSeq) return;
    setState(() {
      // 0.4H：只显示本 App **该用**的模型（滤掉 Pro 这类又贵又没收益的档位，
      // 见 `AiClient.selectableModels`）。用户明确说「不支持 pro」。
      if (models != null && models.isNotEmpty) {
        _models = AiClient.selectableModels(models);
        final current = _model.text.trim();
        // ⚠️ 只在「当前这个值**不该继续用**」时才改写它。
        //
        // 判据必须同时满足两条，缺一不可：
        //  · `isUnsupportedModel(current)` —— 是 Pro 这类我们不再支持的档位
        //    （老版本界面上点过 Pro，留着它就会继续按 Pro 计费）；
        //  · `!_models.contains(current)` —— 它**也已经不在**服务商返回的列表里了。
        //
        // 一开始我写的是「不在列表里 **或** 不是默认值就改」，结果**把所有
        // 合法的非默认模型都覆盖掉了**：用户手选 `deepseek-chat`，拉一次列表
        // 就被悄悄改成 `deepseek-flash`。`api_config_test` 的
        // 「模型名渲染成可点选的胶囊」当场就红了（`deepseek-chat` 同时出现在
        // 输入框和胶囊上，变成 2 个）。**用户的选择不该被拉列表这个动作改掉。**
        final shouldReset =
            current.isEmpty ||
            (AiClient.isUnsupportedModel(current) && !_models.contains(current));
        if (shouldReset) {
          _model.text = AiClient.preferredModel(_models);
        }
      } else {
        _models = const [];
      }
      if (models == null) {
        _modelsError =
            '没能获取到模型列表（该服务可能未提供 /models 接口，或地址 / Key 有误）。'
            '可以直接在下面手工填写模型名。';
      }
    });
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: 'AI 服务',
    caption: '仅在你主动提问时才会联网调用，账目与药箱摘要按需最小化发送。',
    children: [
      _field(
        context,
        label: '接口地址（Base URL）',
        controller: _url,
        hint: 'https://api.deepseek.com',
        icon: Icons.link,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x2, Gap.page, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('模型', style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: _loadingModels ? null : _loadModels,
                  icon: _loadingModels
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_outlined, size: 16),
                  label: Text(_loadingModels ? '获取中…' : '获取可用模型'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            if (_models.isNotEmpty) ...[
              const SizedBox(height: Gap.x1),
              Text(
                '以下是当前 Key 在该地址下真实可用的模型，点选即可',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: Gap.x2),
              Wrap(
                spacing: Gap.x2,
                runSpacing: Gap.x1,
                children: [
                  for (final name in _models)
                    ChoiceChip(
                      label: Text(name),
                      selected: _model.text.trim() == name,
                      onSelected: (_) {
                        _model.text = name;
                        setState(() {});
                      },
                    ),
                ],
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: Gap.x1),
                child: Text(
                  _modelsError.isEmpty
                      ? '不知道填什么？先点右上角「获取可用模型」拉取真实模型名。'
                      : _modelsError,
                  style: TextStyle(
                    fontSize: 12,
                    color: _modelsError.isEmpty
                        ? Tone.textTertiary
                        : Tone.warning,
                  ),
                ),
              ),
          ],
        ),
      ),
      _field(
        context,
        label: '模型名称（也可手工填写）',
        controller: _model,
        hint: store.model.isEmpty ? 'deepseek-chat' : store.model,
        icon: Icons.memory,
        // 用户开始手工填模型名，就说明拉取失败的提示已经没有意义了，顺手清掉，
        // 免得「请手工填写」的红字一直挂在一个已经填好的输入框下面。
        onChanged: () => setState(() {
          if (_model.text.trim().isNotEmpty) _modelsError = '';
        }),
      ),
      _field(
        context,
        label: 'API Key',
        controller: _key,
        hint: 'sk-…',
        icon: Icons.key_outlined,
        obscure: !_revealKey,
        trailing: IconButton(
          onPressed: () => setState(() => _revealKey = !_revealKey),
          icon: Icon(
            _revealKey ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: 20,
          ),
          tooltip: _revealKey ? '隐藏' : '显示',
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x2, Gap.page, 0),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: Text(_testing ? '正在测试…' : '测试连接'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
            const SizedBox(width: Gap.x3),
            Expanded(
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
          ],
        ),
      ),
      if (_status.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x3, Gap.page, 0),
          child: Container(
            padding: const EdgeInsets.all(Gap.x3),
            decoration: BoxDecoration(
              color: _ok ? Tone.tintGreen : Tone.tintRed,
              borderRadius: BorderRadius.circular(Gap.x3),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _ok ? Icons.check_circle_outline : Icons.error_outline,
                  size: 18,
                  color: _ok ? Tone.income : Tone.error,
                ),
                const SizedBox(width: Gap.x2),
                Expanded(
                  child: Text(
                    _status,
                    style: TextStyle(
                      fontSize: 13,
                      color: _ok ? Tone.income : Tone.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      const SettingsGroup(
        title: '反向录入',
        children: [],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 0),
        child: Text(
          '在对话里说「添加药品 a,b,c」「记一笔 买菜 32」时，谁来理解这句话。',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
      const SizedBox(height: Gap.x2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.page),
        child: Column(
          children: [
            for (final mode in ActionInputMode.values)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.x2),
                child: _ModeTile(
                  mode: mode,
                  selected: store.actionMode == mode,
                  onTap: () => store.saveActionMode(mode),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: Gap.x4),
      const SettingsGroup(
        title: '常见问题',
        children: [
          SettingsRow(
            icon: Icons.help_outline,
            tint: Tone.tintSlate,
            color: Tone.iconSlate,
            title: '提示 401 / 鉴权失败',
            subtitle: 'API Key 不正确或已失效，请到服务商控制台重新生成。',
          ),
          SettingsRow(
            icon: Icons.help_outline,
            tint: Tone.tintSlate,
            color: Tone.iconSlate,
            title: '提示 404 / 模型不存在',
            subtitle: '模型名与服务商不匹配，请核对「模型名称」是否拼写正确。',
          ),
          SettingsRow(
            icon: Icons.help_outline,
            tint: Tone.tintSlate,
            color: Tone.iconSlate,
            title: '提示 402 / 余额不足',
            subtitle: '账户余额不足，请先充值后再试。',
          ),
          SettingsRow(
            icon: Icons.help_outline,
            tint: Tone.tintSlate,
            color: Tone.iconSlate,
            title: '我的 Key 安全吗？',
            subtitle: 'Key 保存在系统安全存储（Keychain / Keystore），不会写入数据库，'
                '导出数据时也会被排除。',
          ),
        ],
      ),
    ],
  );

  Widget _field(
    BuildContext context, {
    required String label,
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? trailing,
    VoidCallback? onChanged,
  }) {
    final child = TextField(
      controller: controller,
      obscureText: obscure,
      onChanged: onChanged == null ? null : (_) => onChanged(),
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, size: 20),
        suffixIcon: trailing,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x3, Gap.page, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Gap.x2 - 2),
          child,
        ],
      ),
    );
  }
}

/// 「反向录入」的一个模式选项。
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ActionInputMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Gap.inputRadius),
      child: Container(
        padding: const EdgeInsets.all(Gap.x3),
        decoration: BoxDecoration(
          color: selected ? Tone.tintBlue : Tone.surface,
          borderRadius: BorderRadius.circular(Gap.inputRadius),
          border: Border.all(
            color: selected ? Tone.selectedChip : Tone.outline,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? Tone.iconBlue : Tone.textTertiary,
            ),
            const SizedBox(width: Gap.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mode.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Gap.hairline),
                  Text(
                    mode.description,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
