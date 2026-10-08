import 'package:flutter/material.dart';

import '../core/chat_mode.dart';
import '../data/store.dart';
import '../data/widget_inbox.dart';
import 'ai_hub.dart';
import 'chat.dart';
import 'expense_form.dart';
import 'expenses.dart';
import 'home.dart';
import 'med_form.dart';
import 'meds.dart';
import 'settings.dart';

/// 应用外壳：五个 Tab 的容器。
///
/// 用 IndexedStack 而不是每次重建页面，这样切换 Tab 不会丢掉账本页选中的
/// 日期、AI 页的滚动位置；AI Tab 常驻的是模块入口页，进入具体模块后由
/// Navigator 压栈，返回即可回到入口。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.store});

  final Store store;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _hubKey = GlobalKey<AiHubPageState>();
  int _index = 0;

  void _openTab(int index) => setState(() => _index = index);

  @override
  void initState() {
    super.initState();
    // 0.5.2：桌面「AI 记账 / AI 记药」组件点开后要直接落在输入框上。
    //
    // 冷启动（`main()` 已把请求放进 inbox）与热启动（原生发通知）在这里统一处理：
    // 两条路径都只是「inbox 里出现了一个待处理请求」，界面侧不必区分。
    WidgetLaunchInbox.pending.addListener(_onWidgetLaunch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handleWidgetLaunch();
    });
  }

  @override
  void dispose() {
    WidgetLaunchInbox.pending.removeListener(_onWidgetLaunch);
    super.dispose();
  }

  void _onWidgetLaunch() {
    if (!mounted) return;
    // 等这一帧画完再压页面：回调可能发生在 build 期间，
    // 那时候 Navigator 不允许压栈（会抛 "setState during build"）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handleWidgetLaunch();
    });
  }

  /// 处理一次桌面组件请求。
  ///
  /// 只有 **AI 版**会走到这里。普通记账/记药在原生浮层里就记完了，
  /// 根本不会启动 App（见 `QuickEntryActivity` 的注释）。
  void _handleWidgetLaunch() {
    final request = WidgetLaunchInbox.take();
    if (request == null) return;

    final mode = ChatMode.fromWidgetKind(request.kind);
    setState(() => _index = 3); // 切到 AI Tab，返回时不会落在别的 Tab 上
    _openChatInput(mode);
  }

  /// 直接进入该模块的**空白对话**，让用户马上能说话。
  ///
  /// 为什么不是进模块介绍页：用户从桌面点「AI 记账」的意图是「我要说一句话」，
  /// 而不是「我要浏览这个模块」。多一层介绍页就多一次点击，与「快捷」相悖。
  ///
  /// 用草稿（[ChatDraft]）而不是立刻建对话：`ChatDraft` 不写数据库，
  /// 用户点开又退出去不会在侧滑菜单里留下一条空对话 —— 这正是 0.4C 定下的规则。
  void _openChatInput(ChatMode mode) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          store: widget.store,
          mode: mode,
          draft: ChatDraft(mode: mode, title: mode.defaultConversationTitle),
        ),
      ),
    );
  }

  /// 首页快捷入口 / 药品详情页：切到 AI Tab 并直接进入对应模块。
  ///
  /// 0.4A 之后 AI 分成两个独立模块，所以先按问题内容判断该进哪一个，
  /// 再交给入口页打开 —— 不再由对话页在两种主题间自动跳转。
  /// [question] 为空时只切到入口页，由用户自己选模块。
  void _openChat(String question) {
    if (question.trim().isEmpty) {
      _openTab(3);
      return;
    }
    final mode = inferMode(question);
    setState(() => _index = 3);
    // 入口页在 IndexedStack 中始终已挂载，但要等这一帧的切换生效。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hubKey.currentState?.open(mode, question: question);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: [
            HomePage(
              store: store,
              onOpenTab: _openTab,
              onOpenChat: _openChat,
              onAddExpense: () => showExpenseSheet(context, store),
              onAddMed: () => showMedSheet(context, store),
            ),
            ExpensesPage(store: store),
            MedsPage(store: store),
            AiHubPage(key: _hubKey, store: store),
            SettingsPage(store: store),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _openTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: '账本',
          ),
          NavigationDestination(
            icon: Icon(Icons.medication_outlined),
            selectedIcon: Icon(Icons.medication),
            label: '药箱',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'AI',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
