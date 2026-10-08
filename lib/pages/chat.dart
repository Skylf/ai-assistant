import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/client.dart';
import '../ai/web_search.dart';
import '../core/chat_mode.dart';
import '../data/store.dart';
import '../theme.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/common.dart';

/// 根据输入内容猜测应该去哪个模块。
///
/// 0.4A 之后 AI 拆成两个独立模块，**发消息不再自动切换主题**（那会让用户在
/// 账本模块里问一句药就跑进健康模块，正是文档要消除的「混杂」）。这里只用于
/// 「从首页投递问题时该进哪个模块」这一个判断，模块选定后就不再改变。
ChatMode inferMode(String text) {
  const healthWords = [
    '药', '症状', '发烧', '咳嗽', '疼', '血压', '血糖', '剂量', '服用',
    '副作用', '感冒', '过敏', '就医', '健康', '体检', '睡眠', '疫苗',
  ];
  const financeWords = [
    '账', '支出', '收入', '花销', '省钱', '预算', '消费', '结余', '分类统计', '记账',
  ];
  final health = healthWords.where(text.contains).length;
  final finance = financeWords.where(text.contains).length;
  if (health > finance) return ChatMode.health;
  return ChatMode.finance;
}

/// 一个**还没有落库**的对话草稿（0.4C）。
///
/// ## 为什么要它
///
/// 用户的原话：「创建对话后，如果没有任何消息发送，则默认为不创建新的对话，
/// 不要点击创建就创建新对话，而是确实有消息发送才创建新对话」。
///
/// 原来的问题是：点一次「创建对话」立刻在库里写一行，于是**每次误触或点进去
/// 看看又退出来**，都留下一条「新对话」。侧滑菜单里很快堆满空对话，
/// 真正聊过的反而被挤下去 —— 这正是用户要治的毛病。
///
/// 现在的流程：点「创建对话」只打开一个**草稿**（内存对象，不碰数据库），
/// 直到用户真的发出第一条消息，才在那一瞬间落库并把它变成正式对话。
/// 只看一眼就退出 → 什么都没留下。
class ChatDraft {
  const ChatDraft({required this.mode, required this.title});

  /// 这个草稿属于哪个模块。发消息时用它建正式对话，保证模块归属不会被改错。
  final ChatMode mode;

  /// 落库时用的初始标题（之后会被首条消息内容自动替换）。
  final String title;
}

/// 对话页：某个模块里的一次具体对话。
///
/// 这一页**只放三样东西**：顶部一行（返回 + 对话名 + 记忆开关）、消息列表、
/// 底部输入框。介绍卡、能力清单、安全声明、建议问题、对话统计都在模块介绍页
/// （`lib/pages/module_home.dart`）上，不在这里出现 —— 聊天就是聊天。
///
/// 消息与输入的字号比正文小一档，长对话读起来更紧凑。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.store,
    required this.mode,
    this.draft,
  });

  final Store store;
  final ChatMode mode;

  /// 非空表示这一页是「还没落库的新对话」。
  ///
  /// 见 [ChatDraft] 的说明：点「创建对话」不再立刻写库，只有真发出消息才建。
  final ChatDraft? draft;

  @override
  State<ChatPage> createState() => ChatPageState();
}

class ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// 外部（首页 / 药品详情页）投递过来、等待自动发送的问题。
  final pending = ValueNotifier<String>('');

  bool _busy = false;
  int _elapsed = 0;

  /// 当前**真实**阶段（0.4F）。由 `Store` 在收到服务端事件时回调写入，
  /// 不是定时器演出来的 —— 见 [SearchPhase] 的说明。
  SearchPhase? _phase;
  Timer? _ticker;

  /// 当前这次提问的取消令牌。暂停时置为已取消。
  AskCancelToken? _cancel;

  /// 上一次回复是否被用户暂停。用于在消息流末尾显示一条安静的提示 ——
  /// 点了暂停却什么都不出现，用户会怀疑按钮没用。
  bool _lastPaused = false;

  /// 草稿是否还没被转成正式对话。
  bool _isDraft = false;

  Store get store => widget.store;

  ChatMode get mode => widget.mode;

  @override
  void initState() {
    super.initState();
    _isDraft = widget.draft != null;
    pending.addListener(_consumePending);
  }

  /// 把草稿转成正式对话。返回后 `store.activeConversation` 可用。
  ///
  /// **只在真的要发消息时调用**。它的存在就是「不点发送不建对话」这条规则的
  /// 唯一落点；任何别处都不该提前建。
  Future<void> _promoteDraft() async {
    final draft = widget.draft;
    if (!_isDraft || draft == null) return;
    await store.createConversation(
      title: draft.title,
      topic: draft.mode.topic,
    );
    if (mounted) setState(() => _isDraft = false);
  }

  @override
  void dispose() {
    pending.removeListener(_consumePending);
    _ticker?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _consumePending() {
    final question = pending.value;
    if (question.trim().isEmpty || _busy) return;
    pending.value = '';
    send(question);
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  /// 发送一条消息。
  ///
  /// 不推断主题：这一页属于哪个模块就发给哪个模块，在账本对话里问药品问题
  /// 也只会留在账本对话里。
  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _busy) return;
    // 0.4C：草稿在这里才变成真对话 —— 这是「发了消息才创建」的唯一落点。
    // 必须放在 store.ask 之前：ask 要去读 activeConversation 决定主题与记忆，
    // 对话还不存在的话它会退回默认主题，消息就挂错模块了。
    await _promoteDraft();
    if (!mounted) return;
    _input.clear();
    await _runWaiting(
      () => store.ask(
        text,
        cancel: _cancel!,
        onPhase: (p) {
          if (mounted) setState(() => _phase = p);
        },
      ),
    );
  }

  /// 修改一条已发出的消息并**重新提问**（0.4D）。
  ///
  /// 用户选定的语义是「原地替换：改的那条就是最终提问，旧回答删掉，再自动重问一次」，
  /// 数据层由 `Store.resendEditedMessage` 保证不产生重复消息。
  ///
  /// 这里复用 [_runWaiting] 而不是自己写一套等待逻辑：修改后重发与首次发送
  /// 在用户看来是同一件事（都在等模型回答），所以「转圈 / 暂停按钮 / 已暂停提示」
  /// 必须完全一致 —— 各写一套必然会慢慢跑偏。
  Future<void> resendEdited(String messageId, String newContent) async {
    if (_busy) return;
    await _runWaiting(
      () => store.resendEditedMessage(
        messageId,
        newContent,
        cancel: _cancel!,
        onPhase: (p) {
          if (mounted) setState(() => _phase = p);
        },
      ),
    );
  }

  /// 跑一次「等待模型回复」：转圈、计时、暂停令牌、结束后的提示，全在这里。
  ///
  /// [work] 内部要用 `_cancel!` 取当前令牌（它在调用前刚被建好）。
  ///
  /// 阶段提示（联网搜索中 / 正在整理）由 `Store` 通过 `onPhase` 回调驱动，
  /// 在 [send] / [resendEdited] 里直接写进 `_phase`。**它不是定时器演出来的**：
  /// 只有服务端真的回了 `server_tool_use`，界面才会显示「正在联网搜索」。
  Future<void> _runWaiting(Future<void> Function() work) async {
    final token = AskCancelToken();
    setState(() {
      _busy = true;
      _elapsed = 0;
      _cancel = token;
      _lastPaused = false;
      _phase = SearchPhase.thinking;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
    _jumpToBottom();
    var paused = false;
    try {
      await work();
      paused = token.cancelled;
    } finally {
      _ticker?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _cancel = null;
          _lastPaused = paused;
          _phase = null;
        });
      }
      _jumpToBottom();
    }
  }

  /// 暂停当前回复。
  ///
  /// 只做两件事：把令牌置为已取消（`Store.ask` 回来后会把结果丢掉）、
  /// 立刻结束等待状态让用户能继续输入。
  /// **不谎称已经中断了网络请求** —— `package:http` 没有取消能力，
  /// 请求会在后台跑完再被丢弃，省下的是等待时间。
  void stop() {
    final token = _cancel;
    if (token == null || token.cancelled) return;
    token.cancel();
    _ticker?.cancel();
    setState(() {
      _busy = false;
      _cancel = null;
      _lastPaused = true;
    });
    _jumpToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Tone.surfaceVariant,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            final active = store.activeConversation;
            // 只有当前对话属于本模块时才展示消息：切换的一瞬间
            // activeConversation 可能还是另一个模块的，直接渲染就会串消息。
            //
            // 0.4C 追加 `!_isDraft`：草稿页里 `activeConversation` 仍然指着
            // **上一个**对话（我们还没建新的），不带这个判断就会把上一个对话的
            // 消息显示在全新的空白对话里 —— 看起来像「新建的对话里怎么有旧内容」。
            final sameMode =
                !_isDraft && active != null && active.topic == mode.topic;
            final messages = sameMode ? store.messages : const <ChatMessage>[];
            final showEmpty = messages.isEmpty && !_busy;

            // 末尾多一格用于「思考中」或「已暂停」提示
            final extra = _busy || _lastPaused ? 1 : 0;

            return Column(
              children: [
                _header(_isDraft ? null : (sameMode ? active : null)),
                Expanded(
                  child: showEmpty
                      ? _emptyHint()
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(
                            Gap.page,
                            Gap.x2,
                            Gap.page,
                            Gap.x3,
                          ),
                          itemCount: messages.length + extra,
                          itemBuilder: (context, index) {
                            if (index >= messages.length) {
                              if (_busy) {
                                return Column(
                                  children: [
                                    ThinkingBubble(
                                      seconds: _elapsed,
                                      mode: mode,
                                      phase: _phase,
                                    ),
                                    const SizedBox(height: Gap.x2),
                                    const _PauseHint(),
                                  ],
                                );
                              }
                              return const _PausedNote();
                            }
                            final message = messages[index];
                            final previous = index == 0
                                ? null
                                : messages[index - 1];
                            final showDate =
                                previous == null ||
                                !DateSeparator.sameDay(
                                  previous.createdAt,
                                  message.createdAt,
                                );
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (showDate)
                                  DateSeparator(at: message.createdAt),
                                MessageBubble(
                                  message: message,
                                  mode: mode,
                                  onLongPress: () => messageActions(message),
                                ),
                              ],
                            );
                          },
                        ),
                ),
                ChatInputBar(
                  controller: _input,
                  busy: _busy,
                  onSend: () => send(_input.text),
                  onStop: stop,
                  mode: mode,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 顶部一行：返回 + 对话名 + 记忆开关。不放别的按钮。
  Widget _header(Conversation? conversation) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.x2, Gap.x1, Gap.x3, Gap.x2),
    child: Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
        Expanded(
          child: Text(
            conversation?.title ?? mode.title,
            style: Theme.of(context).textTheme.titleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        _memoryChip(conversation),
      ],
    ),
  );

  Widget _memoryChip(Conversation? conversation) {
    final scope = conversation?.memory ?? MemoryScope.local;
    return Tooltip(
      message: '当前对话记忆：${scope.label}',
      child: ActionChip(
        avatar: Icon(scope.icon, size: 14, color: mode.accent),
        label: Text(scope.shortLabel),
        onPressed: _pickMemory,
        backgroundColor: mode.accentContainer,
        side: BorderSide.none,
        labelStyle: TextStyle(
          fontSize: 11,
          color: mode.accent,
          fontWeight: FontWeight.w500,
        ),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _emptyHint() => Center(
    child: Text(
      '发一条消息开始对话',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );


  /// 长按一条消息：复制 / 修改 / 删除（0.4C）。
  ///
  /// 只有**用户自己发出的**消息能修改 —— 助手回复是「模型当时这么说的」记录，
  /// 允许编辑会让记录与实际回答不一致，之后排查问题就没有可信依据了。
  /// 复制则对两种消息都开放（用户常常想把助手的结论复制走）。
  Future<void> messageActions(ChatMessage message) async {
    final isUser = message.isUser;
    final action = await showModalBottomSheet<String>(
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
                  isUser ? '我发的消息' : '助手的回复',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制'),
              onTap: () => Navigator.of(sheetContext).pop('copy'),
            ),
            if (isUser)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('修改并重新发送'),
                subtitle: const Text(
                  '改完会替换这条，并让 AI 重新回答；旧回答会被删掉',
                  style: TextStyle(fontSize: 11),
                ),
                onTap: () => Navigator.of(sheetContext).pop('edit'),
              ),
            if (isUser)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: Tone.error,
                ),
                title: const Text('删除这条', style: TextStyle(color: Tone.error)),
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
            const SizedBox(height: Gap.x3),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.content));
        if (mounted) toast(context, '已复制');
      case 'edit':
        final text = await showDialog<String>(
          context: context,
          builder: (_) => RenameDialog(
            initial: message.content,
            title: '修改消息',
            hint: '改完会重新发送给 AI',
            confirmLabel: '保存并重发',
            maxLength: 2000,
            maxLines: 6,
          ),
        );
        if (text == null || !mounted) return;
        final trimmed = text.trim();
        if (trimmed.isEmpty) {
          toast(context, '内容不能为空');
          return;
        }
        // 先给一条即时反馈：重发要等模型，用户需要知道「改是改上了」。
        toast(context, '已替换，正在重新提问…');
        await resendEdited(message.id, trimmed);
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: '删除这条消息？',
          content: '删除后这条消息不再出现在对话里。',
          confirmLabel: '删除',
          destructive: true,
        );
        if (!ok || !mounted) return;
        await store.deleteMessage(message.id);
        if (mounted) toast(context, '已删除');
    }
  }

  Future<void> _pickMemory() async {
    final conversation = store.activeConversation;
    if (conversation == null) return;
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
                leading: IconTile(
                  icon: scope.icon,
                  tint: scope == MemoryScope.off
                      ? Tone.tintSlate
                      : mode.accentContainer,
                  color: scope == MemoryScope.off
                      ? Tone.iconSlate
                      : mode.accent,
                ),
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
  }
}

/// 等待回复时的那行小字提示：告诉用户按钮已经变成暂停。
///
/// 不写这句的话，忙态按钮从一个转圈变成一个方块图标，用户不一定敢点。
class _PauseHint extends StatelessWidget {
  const _PauseHint();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: Gap.x2),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '正在生成…点右下角可暂停',
        style: TextStyle(fontSize: 11, color: Tone.textTertiary),
      ),
    ),
  );
}

/// 暂停后的提示。
///
/// 措辞刻意说清「已停下、没有回答」，而不是「已取消请求」——
/// 请求其实还在后台跑（`http` 无法中断），只是结果被丢弃了。
/// 用「已暂停」而不是「已取消」，不承诺做不到的事；同时提醒用户
/// 提问本身已保留，不会因为暂停就丢。
class _PausedNote extends StatelessWidget {
  const _PausedNote();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.x3),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.x3,
          vertical: Gap.x2,
        ),
        decoration: BoxDecoration(
          color: Tone.surfaceMuted,
          borderRadius: BorderRadius.circular(Gap.x2),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.stop_circle_outlined, size: 14, color: Tone.textTertiary),
            SizedBox(width: Gap.x2),
            Text(
              '已暂停，这条提问没有收到回复',
              style: TextStyle(fontSize: 12, color: Tone.textSecondary),
            ),
          ],
        ),
      ),
    ),
  );
}
