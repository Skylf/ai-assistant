import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../ai/med_info.dart';
import '../ai/web_search.dart';
import '../core/chat_mode.dart';
import '../core/med_classify.dart';
import '../core/util.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/ui.dart' show Hairline;
import 'med_form.dart';
import 'module_home.dart';

/// 药品详情页。
///
/// ## 0.4D 修的两件事（用户原话：「药品具体信息点进去 ui 尺寸适配有问题，
/// 且 ui 布局需要逻辑性优化」）
///
/// ### ① 尺寸适配：卡片宽度不一致
///
/// 根因是下面那个 `Column` **没有写 `crossAxisAlignment`**，于是用了默认的
/// `CrossAxisAlignment.center`，子项按**自身固有宽度**居中排布 ——
/// 于是「库存卡」（含 64px 图标 + 文字 + 按钮，固有宽度大）几乎占满一行，
/// 而「信息卡」（只有文字，固有宽度小）缩成窄窄一条，两张卡左右边缘都对不齐。
/// 修法是显式 `CrossAxisAlignment.stretch`，让子项一律撑满可用宽度。
///
/// ### ② 布局逻辑性：按「看信息的顺序」分区
///
/// 改版前所有字段平铺在一张卡里（成分/规格/储存/备注），字段一多就找不着。
/// 现在按用户真正会怎么读它来分区：
///   状态（还能不能吃）→ 基本信息（这是什么）→ 用法（怎么用）
///   → 安全信息（什么情况别用）→ 资料出处（这些字是谁说的）。
/// 「资料出处」必须挨着安全信息，因为那些字段的可信度直接取决于来源。
class MedicineDetailPage extends StatelessWidget {
  const MedicineDetailPage({super.key, required this.store, required this.med});

  final Store store;
  final Map<String, dynamic> med;

  /// 在健康科普模块里追问这盒药。
  ///
  /// 这里**不再自己挑对话、自己调 `store.ask`**：早先的写法用
  /// `where(topic == health).firstOrNull` 取「最近更新的健康对话」，而 `store.ask`
  /// 的作用域由**当前对话**决定，于是用户正在看 A 对话时，这次问答会落进 B 对话
  /// —— 他既看不到问答，也得不到任何提示。而且它绕开了 0.4A 的两层结构（介绍页
  /// → 创建对话 → 对话页），是唯一一条不经「创建对话」就产生对话的路径。
  ///
  /// 现在改为把问题投递给健康科普模块的介绍页：由它按正常流程新建对话、进入
  /// 对话页并自动发送，等待反馈交给对话页的思考气泡（不再自己弹 loading 弹窗，
  /// 也就没有了「弹窗没有 try/finally 会永久驻留」的问题）。
  Future<void> _askAi(BuildContext context) async {
    final question =
        '请仅根据我的药箱资料介绍 ${med['name']} 的信息、储存方式和需要咨询药师的情况。';
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModuleHomePage(
          store: store,
          mode: ChatMode.health,
          initialQuestion: question,
        ),
      ),
    );
  }

  /// 整理这盒药的说明书级信息并回填到详情字段（0.4D 引入，0.4F 改为**真正联网**）。
  ///
  /// 0.4F 之前这个按钮叫「让 AI 补充资料」，因为那时**确实没有联网能力**
  /// （往 chat/completions 发内置 web_search 工具会被静默忽略）。
  /// 0.4F 换到 Anthropic 兼容 `/messages` + `web_search_20250305` 之后
  /// **真的能联网了**，所以按钮文案跟着改回「联网查询资料」——
  /// 名字必须跟着能力走：能力没有时不许叫联网，能力有了也不该藏着。
  ///
  /// 对话框里那句「不是联网查证」也已去掉，改成如实说明会**联网检索公开网页**，
  /// 并提醒网页质量参差、以说明书为准。
  ///
  /// 真正权威的路仍然是「去药监局查询」（见 [_copyNameForNmpa]）。
  Future<void> _lookupInfo(BuildContext context) async {
    final confirmed = await confirmDialog(
      context,
      title: '联网查询「${med['name']}」的资料？',
      content:
          '会把这盒药的名称发给 AI 服务，让它**联网检索公开网页**，'
          '整理用法用量、不良反应、禁忌、注意事项等说明书级信息，'
          '并**记录检索到的来源网址**。\n\n'
          '⚠️ 检索到的是公开网页，质量参差（有医院与厂家说明书页，'
          '也有电商与资讯站）。结果里会标出来源等级，请以随药说明书为准。\n\n'
          '要最权威的，用下方的「去药监局查询」——那是官方数据库。',
      confirmLabel: '联网查询',
    );
    if (!confirmed || !context.mounted) return;

    // 阶段提示用**真实发生的阶段**驱动（联网搜索中 / 正在整理），
    // 不是定时器假装出来的。
    final phases = ValueNotifier<SearchPhase?>(SearchPhase.thinking);
    var found = 0;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('联网查询中'),
        content: ValueListenableBuilder<SearchPhase?>(
          valueListenable: phases,
          builder: (context, phase, _) => Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: Gap.x3),
              Flexible(
                child: Text(
                  found > 0
                      ? '${phase?.label ?? '正在联网搜索…'}（已找到 $found 条来源）'
                      : (phase?.label ?? SearchPhase.thinking.label),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final result = await lookupMedInfo(
      context: context,
      store: store,
      med: med,
      onPhase: (p) => phases.value = p,
      onSources: (sources) => found = sources.length,
    );

    // 关掉进度框（它可能已经被用户手动关掉，所以先判断再 pop）。
    phases.dispose();
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      await dialog;
    }
    if (!context.mounted) return;

    // 失败 / 没解析出来 / 成功，三种情况给三种不同的说法。
    // 0.4D 真机上的问题就是这三种被合成了一句「没有查到」，
    // 用户看到「资料出处：暂无」根本不知道是配置问题还是模型不听话。
    if (!result.ok) {
      toast(context, '查询失败：${result.error}');
    } else if (result.fields.isEmpty) {
      toast(
        context,
        result.note.isEmpty ? '没有可保存的内容' : result.note,
      );
    } else if (result.searched) {
      toast(
        context,
        '已补充 ${result.fields.length} 项（联网检索到 ${result.sources.length} 条来源）',
      );
    } else {
      // 请求成功但没检索到 —— 如实说，不借「联网」二字撑场面。
      toast(context, '已补充 ${result.fields.length} 项（模型已有知识，未检索到网页）');
    }
  }

  /// 复制一条来源网址。
  ///
  /// 不直接打开：本机离线装不了 `url_launcher`，而且**跳外部浏览器会把用户
  /// 带到一个我们无法核实的页面**。复制走，让他自己决定是否打开，更稳也更诚实。
  Future<void> _copyUrl(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    toast(context, '已复制网址，可粘贴到浏览器打开');
  }

  /// 把药名复制走，并告诉用户去哪儿核对。
  ///
  /// 这是本功能里唯一真正「可靠准确权威」的来源：国家药监局官方数据库。
  ///
  /// 两个刻意的设计决定：
  ///  ① **不按药名拼查询串** —— 官方查询地址不稳定，拼错还会把用户带到仿冒站点；
  ///     只给入口页 + 复制药名，用户自己粘一下，稳且安全。
  ///  ② **不引 `url_launcher` 依赖** —— 本机离线装不了包；而且为一个「复制 + 看网址」
  ///     引一个插件不划算（多一个原生平台依赖、多一处失败点）。
  ///     直接把网址原样显示成可选中文本，用户想点就自己复制。
  Future<void> _copyNameForNmpa(BuildContext context) async {
    final name = med['name']?.toString().trim() ?? '';
    if (name.isEmpty) {
      toast(context, '这盒药没有名称，直接上药监局搜通用名');
    } else {
      await Clipboard.setData(ClipboardData(text: name));
      if (!context.mounted) return;
      toast(context, '已复制「$name」，去药监局粘贴搜索');
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('去药监局查询'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '在浏览器打开国家药监局数据查询，粘贴药名即可看到官方说明书信息。',
            ),
            const SizedBox(height: Gap.x3),
            // 可选中，方便复制；不用 TextButton 假装是链接（点了不会开浏览器）。
            SelectableText(
              nmpaSearchUrl,
              style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                color: Tone.iconBlue,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = med['name']?.toString() ?? '药品详情';
    final badge = expiryBadge(med, DateTime.now());
    final stock = med['stock'] is num ? (med['stock'] as num).toInt() : 0;
    final autoRoute = routeOf(med);
    final route = routeOf(med, explicit: med['form']?.toString());
    final manual = (med['form']?.toString() ?? '').isNotEmpty;

    // 分组内容。空值一律返回 null，由 _Section 决定怎么呈现「整组都空」。
    final basic = <_Field>[
      _Field('通用名 / 成分', med['ingredient']),
      _Field('规格', med['spec']),
      _Field('储存条件', med['storage']),
    ];
    final usage = <_Field>[
      _Field('用法用量', med['usage']),
      _Field('治疗范围 / 适应症', med['indications']),
      _Field('药效 / 作用', med['efficacy']),
    ];
    final safety = <_Field>[
      _Field('不良反应', med['adverse']),
      _Field('禁忌', med['contraindications']),
      _Field('注意事项', med['precautions']),
      _Field('备注', med['note']),
    ];

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: Gap.x5),
          children: [
            DetailHeader(name),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.page),
              // ⚠️ stretch 是**尺寸修复的关键**，见类注释 ①。
              // 少了它，下面每张 Card 都按自身固有宽度居中，宽度就对不齐。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ---------------------------------------------- 状态
                  _StatusCard(
                    badge: badge,
                    stock: stock,
                    expiryText: med['expiry']?.toString() ?? '',
                    route: route,
                    manual: manual,
                    onEdit: () => showMedSheet(context, store, existing: med),
                  ),
                  const SizedBox(height: Gap.x4),

                  // ---------------------------------------------- 基本信息
                  _Section(
                    title: '基本信息',
                    icon: Icons.assignment_outlined,
                    fields: basic,
                  ),
                  const SizedBox(height: Gap.x4),

                  // ---------------------------------------------- 用法与药效
                  _Section(
                    title: '用法与药效',
                    icon: Icons.schedule_outlined,
                    fields: usage,
                    emptyHint: '还没有用法用量与药效资料，点下方「联网查询资料」或手动补充',
                  ),
                  const SizedBox(height: Gap.x4),

                  // ---------------------------------------------- 安全信息
                  _Section(
                    title: '安全信息',
                    icon: Icons.health_and_safety_outlined,
                    fields: safety,
                    emptyHint: '还没有不良反应与禁忌资料 —— 这类信息建议照说明书抄录',
                    accent: Tone.warning,
                  ),
                  const SizedBox(height: Gap.x3),

                  // ---------------------------------------------- 资料出处
                  _SourceNote(med: med, onCopyUrl: (url) => _copyUrl(context, url)),
                  const SizedBox(height: Gap.x4),

                  // ---------------------------------------------- 分类提示
                  if (!manual && autoRoute == MedRoute.unknown)
                    _RouteHint(
                      onEdit: () =>
                          showMedSheet(context, store, existing: med),
                    ),
                  if (!manual && autoRoute == MedRoute.unknown)
                    const SizedBox(height: Gap.x3),

                  // ---------------------------------------------- 操作
                  OutlinedButton.icon(
                    onPressed: () => _lookupInfo(context),
                    icon: const Icon(Icons.travel_explore_outlined, size: 20),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    label: const Text('联网查询资料'),
                  ),
                  const SizedBox(height: Gap.x2),
                  // 真正权威的那条路单独放一个按钮：药监局官方库。
                  OutlinedButton.icon(
                    onPressed: () => _copyNameForNmpa(context),
                    icon: const Icon(Icons.verified_outlined, size: 20),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    label: const Text('去药监局查询（权威来源）'),
                  ),
                  const SizedBox(height: Gap.x2),
                  FilledButton.icon(
                    onPressed: () => _askAi(context),
                    icon: const Icon(Icons.auto_awesome, size: 20),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                    label: const Text('询问 AI'),
                  ),
                  const SizedBox(height: Gap.x3),
                  Text(
                    '健康科普不替代医生诊断或处方。用药前请阅读说明书，'
                    '孕哺期、儿童、老人及多药联用请咨询药师或医生。',
                    style: Theme.of(context).textTheme.labelSmall,
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

/// 一条字段：标签 + 值。值为空时记为空串，由 [_Section] 统一处理。
class _Field {
  const _Field(this.label, this.value);

  final String label;
  final dynamic value;

  String get text => value?.toString().trim() ?? '';

  bool get isEmpty => text.isEmpty;
}

/// 状态卡：库存 / 有效期 / 分类 / 修改入口。
///
/// 这一张是「我还能不能吃这盒药」的答案，所以放最上面，且库存与有效期
/// 用颜色直接表达状态（过期/缺货是红的），不用读完数字再自己判断。
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.badge,
    required this.stock,
    required this.expiryText,
    required this.route,
    required this.manual,
    required this.onEdit,
  });

  final ({String text, Color color}) badge;
  final int stock;
  final String expiryText;
  final MedRoute route;
  final bool manual;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Tone.surfaceMuted,
                    borderRadius: BorderRadius.circular(Gap.x3),
                  ),
                  child: Icon(
                    Icons.medication_outlined,
                    size: 28,
                    color: badge.color,
                  ),
                ),
                const SizedBox(width: Gap.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '库存 $stock 盒',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: stock <= 0 ? Tone.error : Tone.textPrimary,
                        ),
                      ),
                      const SizedBox(height: Gap.x1),
                      Text(badge.text, style: TextStyle(color: badge.color)),
                    ],
                  ),
                ),
                TextButton(onPressed: onEdit, child: const Text('修改')),
              ],
            ),
            const SizedBox(height: Gap.x3),
            const Hairline(),
            const SizedBox(height: Gap.x3),
            // 有效期与分类并排：两个短信息，各占一半，避免一行只放一条太浪费。
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: '有效期',
                    value: expiryText.trim().isEmpty
                        ? '未填写'
                        : formatDate(expiryText),
                    emphasize: badge.color == Tone.error,
                  ),
                ),
                const SizedBox(width: Gap.x3),
                Expanded(
                  child: _MiniStat(
                    label: manual ? '分类（手动指定）' : '分类（自动判断）',
                    value: route == MedRoute.unknown ? '未分类' : route.label,
                    emphasize: route == MedRoute.unknown,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片内的两个小统计格之一。
class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: Gap.x1),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: emphasize ? Tone.warning : Tone.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// 一个内容分组：标题 + 若干字段。
///
/// **字段标签永远显示，包括值为空时**（空值显示灰色「未填写」）。
///
/// 早先的做法是「整组都空就只显示一句提示、把字段全藏起来」。实测下来不好：
/// 用户点进详情页**看不到这个 App 到底能记哪些信息**，也就不知道可以填什么、
/// 更不会想到去点「联网查询资料」。字段列表本身就是「这里能有什么」的说明书。
///
/// 所以改成：字段照常列出（值是「未填写」），整组都空时在**上方**额外加一句
/// [emptyHint] 说明下一步该做什么 —— 两者不冲突，一个回答「有什么」，
/// 一个回答「怎么办」。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.fields,
    this.emptyHint,
    this.accent,
  });

  final String title;
  final IconData icon;
  final List<_Field> fields;
  final String? emptyHint;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allEmpty = fields.every((f) => f.isEmpty);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: accent ?? Tone.iconSlate),
                const SizedBox(width: Gap.x2),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: accent ?? Tone.textPrimary,
                  ),
                ),
              ],
            ),
            if (allEmpty && emptyHint != null) ...[
              const SizedBox(height: Gap.x2),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.x2,
                  vertical: Gap.x2,
                ),
                decoration: BoxDecoration(
                  color: Tone.surfaceMuted,
                  borderRadius: BorderRadius.circular(Gap.x2),
                ),
                child: Text(
                  emptyHint!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Tone.textSecondary,
                  ),
                ),
              ),
            ],
            const SizedBox(height: Gap.x3),
            for (var i = 0; i < fields.length; i++)
              _FieldRow(field: fields[i], last: i == fields.length - 1),
          ],
        ),
      ),
    );
  }
}

/// 一条字段的呈现：标签在上、值在下；空值显示灰色的「未填写」。
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field, required this.last});

  final _Field field;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : Gap.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(field.label, style: theme.textTheme.labelSmall),
          const SizedBox(height: Gap.x1),
          if (field.isEmpty)
            Text(
              '未填写',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Tone.textTertiary,
              ),
            )
          else
            // 用法用量这类内容可能很长，且含换行（用户从说明书抄的），
            // 用 SelectableText 让用户能长按复制走 —— 抄给药师时很有用。
            SelectableText(field.text, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// 资料出处：这些字是「谁说的、什么时候抄的」。
///
/// 这一块不是装饰。用法用量、禁忌这类字段**只有配上来源才有意义**：
/// 没有来源的说明书级内容，读者无从判断它是抄的还是编的。
/// 用户 0.4D 明确要求「信息来源一定要可靠准确权威」，所以来源必须露出，
/// 并且要**诚实地说清楚它可能不够权威**。
///
/// 0.4F 起这里还会列出**真实检索到的 URL**，并按可信度分级显示。
/// 加分级的原因是实测数据：查「布洛芬缓释胶囊」拿到 16 条来源，
/// 里面只有 2 条是医院/药企说明书页，其余是卖药电商与资讯站。
/// 只把 URL 平铺出来、不标注等级，用户会默认它们同等可信。
class _SourceNote extends StatelessWidget {
  const _SourceNote({required this.med, required this.onCopyUrl});

  final Map<String, dynamic> med;
  final void Function(String url) onCopyUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = med['infoSource']?.toString().trim() ?? '';
    final checkedAt = med['infoCheckedAt']?.toString().trim() ?? '';
    final urls = (med['infoUrls']?.toString() ?? '')
        .split('\n')
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList();

    return Container(
      padding: const EdgeInsets.all(Gap.x3),
      decoration: BoxDecoration(
        color: Tone.surfaceMuted,
        borderRadius: BorderRadius.circular(Gap.x3),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.source_outlined, size: 16, color: Tone.iconSlate),
          const SizedBox(width: Gap.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.isEmpty ? '资料出处：暂无（以下内容由你手动填写）' : '资料出处：$source',
                  style: theme.textTheme.labelSmall,
                ),
                if (checkedAt.isNotEmpty) ...[
                  const SizedBox(height: Gap.x1),
                  Text('查询时间：$checkedAt', style: theme.textTheme.labelSmall),
                ],
                if (urls.isNotEmpty) ...[
                  const SizedBox(height: Gap.x2),
                  Text(
                    '检索到的来源（按可信度排列，点一下复制网址）',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Tone.textTertiary,
                    ),
                  ),
                  const SizedBox(height: Gap.x1),
                  for (final url in urls.take(8)) _SourceRow(url: url, onTap: onCopyUrl),
                  if (urls.length > 8)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.x1),
                      child: Text(
                        '另有 ${urls.length - 8} 条未显示',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Tone.textTertiary,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: Gap.x1),
                Text(
                  urls.isEmpty
                      ? '用法用量、禁忌等属于说明书级信息，请以手上的说明书为准；'
                            '本次没有检索到网页来源，内容来自模型已有知识，未经核实。'
                      : '用法用量、禁忌等属于说明书级信息，请以手上的说明书为准；'
                            '网页来源质量参差，注意看上面的等级标注。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Tone.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条来源 URL：等级徽标 + 可点复制的网址。
///
/// 为什么不做成可点击跳转：本机离线装不了 `url_launcher`，
/// 而且**跳转到外部浏览器会把用户带去一个我们无法核实的页面** ——
/// 复制网址让他自己决定是否打开，更稳也更诚实。
class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.url, required this.onTap});

  final String url;
  final void Function(String url) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tier = tierOfSource(url);
    final (color, label) = switch (tier) {
      SourceTier.official => (Tone.iconGreen, tier.label),
      SourceTier.institutional => (Tone.iconBlue, tier.label),
      SourceTier.general => (Tone.textTertiary, tier.label),
    };

    return InkWell(
      onTap: () => onTap(url),
      borderRadius: BorderRadius.circular(Gap.x1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 2, right: Gap.x2),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontSize: 10,
                ),
              ),
            ),
            Expanded(
              child: Text(
                // 去掉协议前缀省地方；完整网址点一下复制得到。
                url.replaceFirst(RegExp(r'^https?://'), ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Tone.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自动分类判不出来时的提示条：告诉用户可以手选，并给出入口。
class _RouteHint extends StatelessWidget {
  const _RouteHint({required this.onEdit});

  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Gap.x3),
      decoration: BoxDecoration(
        color: Tone.surfaceMuted,
        borderRadius: BorderRadius.circular(Gap.x3),
        border: Border.all(color: Tone.outline),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.help_outline,
            size: 16,
            color: Tone.iconAmber,
          ),
          const SizedBox(width: Gap.x2),
          Expanded(
            child: Text(
              '这个药没能按名称自动分类，会落在「其他」里。',
              style: theme.textTheme.labelSmall,
            ),
          ),
          TextButton(onPressed: onEdit, child: const Text('手动指定')),
        ],
      ),
    );
  }
}
