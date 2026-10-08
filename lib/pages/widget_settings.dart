import 'package:flutter/material.dart';

import '../data/store.dart';
import '../data/widget_launch.dart';
import '../data/widget_sync.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 桌面组件设置页（0.5.2）。
///
/// ## 这一页要解决的真实问题
///
/// 功能做完了不代表用户用得上。Android 添加桌面组件的标准路径是
/// 「长按桌面空白 → 小组件 → 在长长的列表里翻到我们的 App → 拖出来」，
/// 而**大多数人卡在第二步**：不知道要去哪找，或者翻了半天没找到。
///
/// 所以这一页做两件事：
///  ① 「添加到桌面」按钮调系统的 `requestPinAppWidget`（Android 8.0+），
///     直接弹系统确认框，用户点一下就好；
///  ② 系统不支持时（部分国产桌面没实现这个 API）**明确说明怎么手动加**，
///     而不是让按钮无声无息地什么都不做。
///
/// ## 为什么四种组件要分别列出并解释
///
/// 「普通记账」和「AI 记账」的区别不是外观，而是**点开之后发生什么**：
/// 前者在桌面上就地填表，后者要进 App 说话。用户选错会以为功能坏了
/// （「点了 AI 记账怎么还要我自己填表？」），所以每张卡上都写清楚。
class WidgetSettingsPage extends StatefulWidget {
  const WidgetSettingsPage({super.key, required this.store});

  final Store store;

  @override
  State<WidgetSettingsPage> createState() => _WidgetSettingsPageState();
}

class _WidgetSettingsPageState extends State<WidgetSettingsPage> {
  /// 最近一次请求的结果，用于给用户反馈。
  String _feedback = '';
  bool _feedbackIsWarning = false;

  /// 队列里还有多少条没同步（正常情况下是 0，非 0 说明 App 还没入库）。
  int? _pending;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final status = await WidgetSync.status();
    if (!mounted) return;
    setState(() => _pending = status.pending);
  }

  Future<void> _requestPin(String kind, String label) async {
    final ok = await WidgetLaunch.requestPin(kind);
    if (!mounted) return;
    setState(() {
      _feedbackIsWarning = !ok;
      _feedback = ok
          ? '已向系统请求添加「$label」组件，请在弹窗里点「确定」。'
          // 不支持时**必须说清楚原因并给出手动路径**。只说「失败了」等于
          // 把问题丢回给用户，而他本来就不知道该怎么做。
          : '你的桌面不支持由应用直接添加组件（部分国产桌面是这样）。\n'
                '请手动添加：长按桌面空白处 → 选「小组件 / 小工具」→ '
                '找到「家庭生活助手」→ 把「$label」拖到桌面。';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('桌面组件')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Gap.page,
          Gap.x2,
          Gap.page,
          Gap.x6,
        ),
        children: [
          _Intro(pending: _pending),
          const SizedBox(height: Gap.x4),
          SettingsGroup(
            title: '记账',
            children: [
              _WidgetRow(
                kind: WidgetLaunch.kindExpense,
                icon: Icons.add_card_outlined,
                tint: Tone.tintBlue,
                color: Tone.iconBlue,
                title: '记账',
                detail: '点一下，桌面上直接填金额、分类、日期、备注，'
                    '和 App 里的记账表单一样',
                onAdd: _requestPin,
              ),
              _WidgetRow(
                kind: WidgetLaunch.kindExpenseAi,
                icon: Icons.auto_awesome,
                tint: Tone.tintTeal,
                color: Tone.iconTeal,
                title: 'AI 记账',
                detail: '点一下进 App，说一句「今天买菜 20」，'
                    'AI 解析后自动记账',
                onAdd: _requestPin,
              ),
            ],
          ),
          const SizedBox(height: Gap.x3),
          SettingsGroup(
            title: '药箱',
            children: [
              _WidgetRow(
                kind: WidgetLaunch.kindMed,
                icon: Icons.medication_outlined,
                tint: Tone.tintGreen,
                color: Tone.iconGreen,
                title: '记药',
                detail: '点一下，桌面上直接填药名、规格、数量、有效期',
                onAdd: _requestPin,
              ),
              _WidgetRow(
                kind: WidgetLaunch.kindMedAi,
                icon: Icons.healing_outlined,
                tint: Tone.tintPurple,
                color: Tone.iconPurple,
                title: 'AI 记药',
                detail: '点一下进 App，说一句「布洛芬两盒」，'
                    'AI 解析后自动入药箱',
                onAdd: _requestPin,
              ),
            ],
          ),
          if (_feedback.isNotEmpty) ...[
            const SizedBox(height: Gap.x4),
            Container(
              padding: const EdgeInsets.all(Gap.x3),
              decoration: BoxDecoration(
                color: _feedbackIsWarning ? Tone.tintAmber : Tone.tintGreen,
                borderRadius: BorderRadius.circular(Gap.radius),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _feedbackIsWarning
                        ? Icons.info_outline
                        : Icons.check_circle_outline,
                    size: 18,
                    color: _feedbackIsWarning ? Tone.warning : Tone.iconGreen,
                  ),
                  const SizedBox(width: Gap.x2),
                  Expanded(
                    child: Text(
                      _feedback,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: Tone.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: Gap.x5),
          const _Notes(),
        ],
      ),
    );
  }
}

/// 顶部说明。顺带把「队列里还有未同步记录」这种异常状态如实显示出来 ——
/// 正常情况下它永远是 0，非 0 就意味着 App 还没把桌面记的东西入库。
class _Intro extends StatelessWidget {
  const _Intro({required this.pending});

  final int? pending;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(Gap.x3),
    decoration: BoxDecoration(
      color: Tone.surfaceMuted,
      borderRadius: BorderRadius.circular(Gap.radius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '在桌面直接记账、记药',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Tone.textPrimary,
          ),
        ),
        const SizedBox(height: Gap.x1 + 2),
        const Text(
          '四种组件可以同时放多个。「记账 / 记药」在桌面上就地填完，'
          '不用等 App 打开；「AI 记账 / AI 记药」会进 App 让你说一句话，'
          '由 AI 解析后自动录入。',
          style: TextStyle(fontSize: 13, height: 1.6, color: Tone.textSecondary),
        ),
        if (pending != null && pending! > 0) ...[
          const SizedBox(height: Gap.x2),
          Row(
            children: [
              const Icon(Icons.sync_problem, size: 16, color: Tone.warning),
              const SizedBox(width: Gap.x1 + 2),
              Expanded(
                child: Text(
                  '还有 $pending 条桌面记录等待写入，回到 App 首页即可自动完成。',
                  style: const TextStyle(fontSize: 12, color: Tone.warning),
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

class _WidgetRow extends StatelessWidget {
  const _WidgetRow({
    required this.kind,
    required this.icon,
    required this.tint,
    required this.color,
    required this.title,
    required this.detail,
    required this.onAdd,
  });

  final String kind;
  final IconData icon;
  final Color tint;
  final Color color;
  final String title;
  final String detail;
  final Future<void> Function(String kind, String label) onAdd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.x3, Gap.x2 + 2, Gap.x3, Gap.x2 + 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: tint,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 19, color: color),
        ),
        const SizedBox(width: Gap.x2 + 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Tone.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Tone.textSecondary,
                ),
              ),
              const SizedBox(height: Gap.x1 + 2),
              TextButton.icon(
                onPressed: () => onAdd(kind, title),
                icon: const Icon(Icons.add_to_home_screen, size: 16),
                label: const Text('添加到桌面'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.x2),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 使用注意。每一条都对应一个**真实的实现约束**，不是客套话。
class _Notes extends StatelessWidget {
  const _Notes();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(Gap.x3),
    decoration: BoxDecoration(
      color: Tone.surfaceMuted,
      borderRadius: BorderRadius.circular(Gap.radius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('几点说明', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: Gap.x2),
        for (final (icon, text) in const [
          (
            Icons.sync_outlined,
            '桌面记的内容会先存在本机，回到 App 后自动写入账本/药箱；'
                '汇总数字也会随数据更新。',
          ),
          (
            Icons.wifi_off_outlined,
            '桌面组件本身不联网。上面显示的汇总来自 App 上次算好的数据。',
          ),
          (
            Icons.lock_outline,
            '记录只写在本机数据库，不上传任何服务器。',
          ),
          (
            Icons.info_outline,
            '组件能放多少、能不能放，由你的桌面决定；'
                '部分桌面会限制数量或自动回收不常用的组件。',
          ),
        ]) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: Tone.textTertiary),
              const SizedBox(width: Gap.x2),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: Tone.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.x1 + 2),
        ],
      ],
    ),
  );
}
