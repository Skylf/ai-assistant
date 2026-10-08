import 'package:flutter/material.dart';

import 'data/store.dart';
import 'pages/boot_error.dart';
import 'pages/home_shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = Store();
  try {
    await store.load();
  } catch (error) {
    // 启动失败也必须给出可见的错误页。
    // 之前这里是裸的 `await store.load()`：本地数据库一抛异常，runApp 根本
    // 不会执行，用户端看到的就是纯白屏，连一句提示都没有，排查只能靠 logcat。
    debugPrint('启动加载失败：$error');
    debugPrintStack();
  }
  runApp(FamilyLifeAssistantApp(store: store));
}

class FamilyLifeAssistantApp extends StatelessWidget {
  const FamilyLifeAssistantApp({super.key, required this.store});

  final Store store;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '家庭生活助手',
      theme: buildAppTheme(),
      // 就绪状态以 Store 为准（而不是启动时的一次性判断），这样错误页上的
      // 「重试」按钮修复问题后能真正进入应用。
      home: store.isReady
          ? HomeShell(store: store)
          : BootErrorPage(
              error: store.bootError,
              onRetry: () async {
                // load() 会把失败信息记在 store.bootError 上并通知界面，
                // 这里吞掉异常，让错误页自己刷新。
                try {
                  await store.load();
                } catch (_) {}
              },
            ),
    ),
  );
}
