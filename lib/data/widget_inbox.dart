import 'package:flutter/foundation.dart';

import 'widget_launch.dart';

/// 「从桌面组件进来」这件事的**全局待办**（0.5.2）。
///
/// ## 为什么需要一个全局对象
///
/// 一次点击会发生在两个完全不同的时机，而它们必须走同一条处理路径：
///
///  · **冷启动**：用户点组件时 App 没在跑。`main()` 里要先把请求取出来，
///    但那时连 `MaterialApp` 都还没建 —— 没地方弹输入框，只能先存着；
///  · **热启动**：App 已在后台。原生发来 `widgetLaunch` 通知，此时界面已经在了，
///    应当立刻处理。
///
/// 用一个 `ValueNotifier` 把两种时机统一成「有一个待处理的请求」，
/// 界面侧只订阅这一个信号，不必关心它是怎么来的。
///
/// ## 为什么不直接把请求传给 HomeShell 的构造参数
///
/// 那样只能处理冷启动。热启动时 `HomeShell` 早就建好了，构造参数不会再变，
/// 用户点第二次组件就什么都不会发生 —— 而这正是「开发机上测不出来」的那类 bug
/// （开发时每次都是冷启动）。
class WidgetLaunchInbox {
  const WidgetLaunchInbox._();

  /// 待处理的请求；`null` 表示没有。
  ///
  /// 用 [ValueNotifier] 而不是普通字段：界面要能在它变化时**立刻**反应。
  static final pending = ValueNotifier<WidgetLaunchRequest?>(null);

  /// 由 `main()` 在启动时取一次冷启动请求。
  static Future<void> captureColdStart() async {
    final request = await WidgetLaunch.takeLaunchRequest();
    if (request != null) pending.value = request;
  }

  /// 订阅热启动通知。
  static void listen() {
    WidgetLaunch.listenForLaunch(() async {
      final request = await WidgetLaunch.takeLaunchRequest();
      if (request != null) pending.value = request;
    });
  }

  /// 取走待处理请求（取走即清空）。
  ///
  /// **必须清空**：不清的话，用户每次从后台切回来都会被再弹一次输入框
  /// ——因为 `ValueNotifier` 的值还在，订阅者会反复看到同一个请求。
  static WidgetLaunchRequest? take() {
    final request = pending.value;
    pending.value = null;
    return request;
  }

  /// 热重载 / 退出时断开原生回调。
  static void reset() {
    pending.value = null;
    WidgetLaunch.stopListening();
  }
}
