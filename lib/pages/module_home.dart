import 'package:flutter/material.dart';

import '../core/chat_mode.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/common.dart';
import '../widgets/ui.dart';
import 'chat.dart';
import 'settings.dart';

/// 模块介绍页（账本分析 / 健康科普）。
///
/// 这是点开 AI 里某个模块后先看到的页面：助手自我介绍、能力清单、安全声明，
/// 加「创建对话」按钮。**对话记录放在顶部菜单按钮拉出的侧滑抽屉里**。
///
/// ## 0.4B 为什么把对话列表搬进抽屉
///
/// 原先对话列表排在介绍卡下方（`ListView` 的一部分）。用户的原话是
/// 「一旦对话过多，则显示很难受」—— 对话攒到几十条以后，这一页被无限拉长，
/// 得一直往下滚才能碰到「创建对话」，而「对话记录」这个标题本身也失去了意义。
/// 现在抽屉是独立滚动区域，列表再长也不影响主页面。
///
/// 有意**不放输入框**：页面上没有能直接发消息的地方，必须先「创建对话」或
/// 从抽屉里选中一个已有对话进入对话页才开口。对话页本身也只放消息与输入框，
/// 不放介绍卡、建议胶囊、统计这类东西 —— 两层界面各自干净。
class ModuleHomePage extends StatefulWidget {
  const ModuleHomePage({
    super.key,
    required this.store,
    required this.mode,
    this.initialQuestion = '',
  });

  final Store store;
  final ChatMode mode;

  /// 从首页 / 药品详情页投递过来的问题：进入对话页后自动发送。
  final String initialQuestion;

  @override
  State<ModuleHomePage> createState() => ModuleHomePageState();
}

class ModuleHomePageState extends State<ModuleHomePage> {
  Store get store => widget.store;

  ChatMode get mode => widget.mode;

  /// 抽屉的开关句柄。建对话之后要能自动把它关掉。
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

  /// 本模块的对话，按更新时间倒序（Store 已排好序）。
  List<Conversation> get conversations =>
      store.conversations.where((c) => c.topic == mode.topic).toList();

  @override
  void initState() {
    super.initState();
    if (widget.initialQuestion.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) createConversation(question: widget.initialQuestion);
      });
    }
  }

  /// 打开一个**新对话草稿**（0.4C）。
  ///
  /// 关键点：这里**不写数据库**。用户要求「不要点击创建就创建新对话，而是确实
  /// 有消息发送才创建新对话」，所以点这个按钮只是打开一页空白对话，
  /// 真正的落库发生在发出第一条消息的那一刻（见 `ChatPageState._promoteDraft`）。
  ///
  /// 于是「点进去看一眼又退出来」不会在侧滑菜单里留下一条空对话 ——
  /// 那正是用户抱怨的现象。
  Future<void> createConversation({String question = ''}) async {
    final key = GlobalKey<ChatPageState>();
    final pushed = Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          key: key,
          store: store,
          mode: mode,
          draft: ChatDraft(mode: mode, title: mode.defaultConversationTitle),
        ),
      ),
    );
    if (question.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        key.currentState?.pending.value = question;
      });
    }
    await pushed;
  }

  /// 进入某个对话。带 [question] 时进入后自动发送。
  Future<void> openConversation(String id, {String question = ''}) async {
    await store.selectConversation(id);
    if (!mounted) return;
    // 从抽屉点进来时先把抽屉收掉，否则返回时会看到抽屉还开着
    if (scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    final key = GlobalKey<ChatPageState>();
    final pushed = Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(key: key, store: store, mode: mode),
      ),
    );
    if (question.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        key.currentState?.pending.value = question;
      });
    }
    await pushed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: scaffoldKey,
      backgroundColor: Tone.surfaceVariant,
      drawer: _historyDrawer(theme),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                Gap.page,
                Gap.x2,
                Gap.page,
                Gap.x6,
              ),
              children: [
                _header(theme),
                const SizedBox(height: Gap.x4),
                ModeHeroCard(mode: mode),
                const SizedBox(height: Gap.x5),
                _createButton(),
                if (!store.hasApiKey) ...[
                  const SizedBox(height: Gap.x4),
                  _apiKeyNotice(),
                ],
                // 对话记录已移入抽屉；这里只在一条对话都没有时给个提示，
                // 否则用户会以为「以前的对话去哪了」。
                if (conversations.isEmpty) ...[
                  const SizedBox(height: Gap.x5),
                  _empty(theme),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// 顶部栏：返回 + 标题 + **历史对话菜单按钮**。
  ///
  /// 菜单按钮放在右侧（拇指够得到），并在有历史时显示条数 ——
  /// 否则用户不知道抽屉里有没有东西，也不会想到去点它。
  Widget _header(ThemeData theme) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final count = conversations.length;
      return Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
          ),
          const SizedBox(width: Gap.x1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mode.title,
                  style: theme.textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: Gap.hairline),
                Text(
                  '与本机${mode.shortLabel}数据关联',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => scaffoldKey.currentState?.openDrawer(),
            icon: const Icon(Icons.menu),
            tooltip: '历史对话',
          ),
          if (count > 0)
            Container(
              margin: const EdgeInsets.only(right: Gap.x2),
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.x2,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: mode.accentContainer,
                borderRadius: BorderRadius.circular(Gap.x2),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: mode.accent,
                ),
              ),
            ),
        ],
      );
    },
  );

  /// 侧滑抽屉：本模块的全部历史对话。
  ///
  /// 只列**本模块**的对话（`conversations` 已按 topic 过滤）——
  /// 账本与健康两个模块的对话互不可见，这是 0.4A 定下的隔离规则，
  /// 搬进抽屉不能破坏它。
  Widget _historyDrawer(ThemeData theme) => Drawer(
    backgroundColor: Tone.surface,
    child: SafeArea(
      child: AnimatedBuilder(
        animation: store,
        builder: (context, _) {
          final items = conversations;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.page,
                  Gap.x4,
                  Gap.x3,
                  Gap.x2,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '历史对话',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Tone.textPrimary,
                            ),
                          ),
                          const SizedBox(height: Gap.hairline),
                          Text(
                            '${mode.title} · ${items.length} 条',
                            style: theme.textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 20),
                      tooltip: '关闭',
                    ),
                  ],
                ),
              ),
              const Hairline(),
              Expanded(
                child: items.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(Gap.x5),
                          child: Text(
                            '还没有对话\n点下面的「创建对话」开始',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: Tone.textTertiary,
                              height: 1.6,
                            ),
                          ),
                        ),
                      )
                    : _conversationList(items),
              ),
              const Hairline(),
              Padding(
                padding: const EdgeInsets.all(Gap.x3),
                child: FilledButton.icon(
                  onPressed: () => createConversation(),
                  icon: const Icon(Icons.add_comment_outlined, size: 18),
                  label: const Text('创建对话'),
                  style: FilledButton.styleFrom(
                    backgroundColor: mode.accent,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(R.control),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  /// 对话列表：置顶区与普通区**分开渲染，中间有明确分界**（0.4C）。
  ///
  /// 用户的要求：「历史对话新增置顶功能，并且在置顶与非置顶之间要有明确分界线」。
  ///
  /// 「明确」的含义是**不能只靠排序**：只把置顶项排到最前，用户看到的是一个
  /// 普通列表，会以为置顶没生效、或者以为排序乱了。所以这里给两区各自加标题，
  /// 并在两区之间画一条带间距的实线分隔 + 标题，让它一眼看出这是两个区块。
  ///
  /// 分界只在**两区都非空**时出现：只有置顶对话时不画多余的分隔（否则列表末尾
  /// 挂一个空标题很难看）。
  Widget _conversationList(List<Conversation> items) {
    final pinned = items.where((c) => c.isPinned).toList();
    final rest = items.where((c) => !c.isPinned).toList();
    final showDivider = pinned.isNotEmpty && rest.isNotEmpty;

    Widget tile(Conversation item) => Padding(
      padding: const EdgeInsets.only(bottom: Gap.x1),
      child: ConversationTile(
        conversation: item,
        mode: mode,
        active: item.id == store.activeConversationId,
        onTap: () => openConversation(item.id),
        onLongPress: () => conversationActions(item),
      ),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.x3, Gap.x2, Gap.x3, Gap.x2),
      children: [
        if (pinned.isNotEmpty) ...[
          _sectionHeader('置顶', pinned.length, pinned: true),
          for (final item in pinned) tile(item),
        ],
        if (showDivider) ...[
          const SizedBox(height: Gap.x2),
          // 明确分界线：两端留白的实线，比紧贴内容的分隔线更像「区块边界」
          const Hairline(),
          const SizedBox(height: Gap.x2),
        ],
        if (rest.isNotEmpty) ...[
          if (pinned.isNotEmpty) _sectionHeader('其他对话', rest.length),
          for (final item in rest) tile(item),
        ],
      ],
    );
  }

  /// 区块小标题。置顶区带图钉图标，与普通区在视觉上直接区分开。
  Widget _sectionHeader(String label, int count, {bool pinned = false}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.x1, Gap.x2, Gap.x1, Gap.x2),
        child: Row(
          children: [
            if (pinned) ...[
              Icon(Icons.push_pin, size: 12, color: mode.accent),
              const SizedBox(width: Gap.x1),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: pinned ? mode.accent : Tone.textTertiary,
              ),
            ),
            const SizedBox(width: Gap.x2),
            Text(
              '$count',
              style: const TextStyle(fontSize: 12, color: Tone.textTertiary),
            ),
          ],
        ),
      );

  Widget _createButton() => FilledButton.icon(
    onPressed: () => createConversation(),
    icon: const Icon(Icons.add_comment_outlined, size: 20),
    label: const Text('创建对话'),
    style: FilledButton.styleFrom(
      backgroundColor: mode.accent,
      minimumSize: const Size.fromHeight(50),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(R.control),
      ),
    ),
  );

  Widget _apiKeyNotice() => Container(
    padding: const EdgeInsets.all(Gap.x3),
    decoration: BoxDecoration(
      color: Tone.warningContainer,
      borderRadius: BorderRadius.circular(R.control),
    ),
    child: Row(
      children: [
        const Icon(Icons.key_outlined, size: 18, color: Tone.warning),
        const SizedBox(width: Gap.x2),
        Expanded(
          child: Text(
            '还没有配置 API Key，对话无法得到回复。',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SettingsPage(store: store),
            ),
          ),
          child: const Text('去配置'),
        ),
      ],
    ),
  );

  Widget _empty(ThemeData theme) => Container(
    padding: const EdgeInsets.symmetric(vertical: Gap.x5, horizontal: Gap.x4),
    decoration: BoxDecoration(
      color: Tone.surface,
      borderRadius: BorderRadius.circular(R.group),
      border: Border.all(color: Tone.outline),
    ),
    child: Column(
      children: [
        Icon(mode.icon, size: 24, color: mode.iconColor),
        const SizedBox(height: Gap.x3),
        Text(mode.emptyTitle, style: theme.textTheme.titleSmall),
        const SizedBox(height: Gap.x1),
        Text(
          mode.emptyDetail,
          style: theme.textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );

  // ------------------------------------------------------- 对话管理菜单

  /// 长按一条对话：重命名 / 记忆范围 / 清空 / 删除。
  Future<void> conversationActions(Conversation conversation) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        // 0.4C 加了「置顶对话」之后这个菜单变成 5 项，在 360×800 上实测
        // **溢出 37 像素**（RenderFlex overflowed by 37 pixels）。
        // 原来用 `Column(mainAxisSize: min)` 不滚动，项数一多就必然溢出。
        // 改成可滚动并限制最大高度，以后再加项也不会炸。
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Gap.page,
                    Gap.x4,
                    Gap.page,
                    Gap.x2,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      conversation.title,
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(
                    conversation.isPinned
                        ? Icons.push_pin
                        : Icons.push_pin_outlined,
                    color: conversation.isPinned ? mode.accent : null,
                  ),
                  title: Text(conversation.isPinned ? '取消置顶' : '置顶对话'),
                  subtitle: conversation.isPinned
                      ? null
                      : const Text(
                          '置顶后固定显示在列表最上方',
                          style: TextStyle(fontSize: 11),
                        ),
                  onTap: () => Navigator.of(sheetContext).pop('pin'),
                ),
                ListTile(
                  leading: const Icon(Icons.drive_file_rename_outline),
                  title: const Text('重命名'),
                  onTap: () => Navigator.of(sheetContext).pop('rename'),
                ),
                ListTile(
                  leading: const Icon(Icons.psychology_outlined),
                  title: const Text('记忆范围'),
                  subtitle: Text(conversation.memory.label),
                  onTap: () => Navigator.of(sheetContext).pop('memory'),
                ),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('清空消息'),
                  onTap: () => Navigator.of(sheetContext).pop('clear'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Tone.error,
                  ),
                  title: const Text(
                    '删除对话',
                    style: TextStyle(color: Tone.error),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop('delete'),
                ),
                const SizedBox(height: Gap.x3),
              ],
            ),
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'pin':
        final next = await store.toggleConversationPin(conversation.id);
        if (mounted) toast(context, next ? '已置顶' : '已取消置顶');
      case 'rename':
        await _rename(conversation);
      case 'memory':
        await _pickMemory(conversation);
      case 'clear':
        final ok = await confirmDialog(
          context,
          title: '清空这个对话？',
          content: '对话里的消息会被删除，对话本身与设置保留。',
          confirmLabel: '清空',
          destructive: true,
        );
        if (ok) await store.clearConversation(conversation.id);
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: '删除这个对话？',
          content: '「${conversation.title}」及其消息会被永久删除。',
          confirmLabel: '删除',
          destructive: true,
        );
        if (ok) await store.deleteConversation(conversation.id);
    }
  }

  Future<void> _rename(Conversation conversation) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(initial: conversation.title),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await store.updateConversation(conversation.id, title: name);
  }

  Future<void> _pickMemory(Conversation conversation) async {
    final picked = await showModalBottomSheet<MemoryScope>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Gap.page,
                Gap.x4,
                Gap.page,
                Gap.x2,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '对话记忆',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
            ),
            for (final scope in MemoryScope.values)
              ListTile(
                leading: Icon(scope.icon, size: 20, color: mode.accent),
                title: Text(scope.label),
                subtitle: Text(
                  scope.detail,
                  style: Theme.of(sheetContext).textTheme.labelSmall,
                ),
                trailing: scope == conversation.memory
                    ? Icon(Icons.check_circle, color: mode.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(scope),
              ),
            const SizedBox(height: Gap.x3),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await store.updateConversation(conversation.id, memory: picked);
    if (mounted) toast(context, '记忆范围已设为「${picked.label}」');
  }
}
