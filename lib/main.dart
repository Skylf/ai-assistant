import 'package:flutter/material.dart';

import 'data/store.dart';
import 'data/widget_inbox.dart';
import 'data/widget_sync.dart';
import 'pages/boot_error.dart';
import 'pages/home_shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0.5.2：先取一次「是不是桌面组件把我叫起来的」。
  // 必须早于 runApp —— 否则界面先画出来一帧「首页」，再跳去 AI 输入框，
  // 用户看到的是闪一下的空白首页。取走即清空（见 WidgetLaunchInbox）。
  await WidgetLaunchInbox.captureColdStart();

  final store = Store();
  try {
    await store.load();
    // 0.5.2：把桌面组件记下的内容同步进账本/药箱。
    //
    // 放在 load() **之后**、runApp **之前**：桌面组件的数据要先于界面出现，
    // 否则用户点开 App 会看到「刚在桌面记的那笔不在账本里」，过一会儿才冒出来。
    //
    // 整段包在 try 里：桌面同步失败绝不能挡住启动 —— 它是可选功能，
    // 而启动失败是用户完全无法使用的严重问题（0.4I 刚修过一次）。
    await WidgetSync.drainPending(store);
  } catch (error) {
    // 启动失败也必须给出可见的错误页。
    // 之前这里是裸的 `await store.load()`：本地数据库一抛异常，runApp 根本
    // 不会执行，用户端看到的就是纯白屏，连一句提示都没有，排查只能靠 logcat。
    debugPrint('启动加载失败：$error');
    debugPrintStack();
  }
  runApp(FamilyLifeAssistantApp(store: store));
}

class FamilyLifeAssistantApp extends StatefulWidget {
  const FamilyLifeAssistantApp({super.key, required this.store});

  final Store store;

  @override
  State<FamilyLifeAssistantApp> createState() => _FamilyLifeAssistantAppState();
}

class _FamilyLifeAssistantAppState extends State<FamilyLifeAssistantApp>
    with WidgetsBindingObserver {
  /// 取消订阅 Store 变化（防抖写汇总）。
  VoidCallback? _stopWatchingStore;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 热启动：App 在后台时点桌面组件，原生会主动通知。
    // 只做冷启动的话，用户「用了一整天、App 一直在后台」时点组件毫无反应 ——
    // 开发机上每次都冷启动，测不出这个问题。
    WidgetLaunchInbox.listen();
    // 数据一变就把汇总写回桌面组件（已防抖）。没有它的话，用户删掉一笔账
    // 回到桌面，组件上还是旧数字，看起来像没保存成功。
    _stopWatchingStore = WidgetSync.watchStore(widget.store);
  }

  @override
  void dispose() {
    _stopWatchingStore?.call();
    WidgetLaunchInbox.reset();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 回到前台时补一次同步。
  ///
  /// 为什么必须有这一条：用户可能**一直不退出 App**，只是在桌面和 App 之间来回切。
  /// 只靠 `main()` 里那次同步的话，他在桌面上记的账要等到下次冷启动才出现 ——
  /// 而那可能是一整天以后。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 不 await：生命周期回调里等待 I/O 会拖住恢复过程，用户感觉是「切回来卡一下」。
    // 同步本身是幂等的（按 id 入库），并发触发也不会产生重复记录。
    WidgetSync.drainPending(widget.store).then((imported) {
      if (imported > 0) {
        debugPrint('[widget] 从桌面同步了 $imported 条记录');
      }
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '家庭生活助手',
      theme: buildAppTheme(),
      // 就绪状态以 Store 为准（而不是启动时的一次性判断），这样错误页上的
      // 「重试」按钮修复问题后能真正进入应用。
      home: widget.store.isReady
          ? HomeShell(store: widget.store)
          : BootErrorPage(
              error: widget.store.bootError,
              onRetry: () async {
                // load() 会把失败信息记在 store.bootError 上并通知界面，
                // 这里吞掉异常，让错误页自己刷新。
                try {
                  await widget.store.load();
                  await WidgetSync.drainPending(widget.store);
                } catch (_) {}
              },
            ),
    ),
  );
}
