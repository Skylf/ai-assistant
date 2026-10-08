import 'package:flutter/material.dart';

import '../data/store.dart';
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
