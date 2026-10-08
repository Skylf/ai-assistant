import 'dart:async';

import 'package:flutter/foundation.dart';

import 'store.dart';
import 'widget_bridge.dart';

/// 把桌面组件记下的内容同步进数据库，并把汇总写回组件。
///
/// ## 为什么单独一层，而不是塞进 [Store.load]
///
/// 桌面组件是**可选功能**（Android 专属，且用户可能一个组件都没放）。
/// 把它的逻辑写进 `Store.load()` 会让「启动」这条最关键的路径多出一堆
/// 与启动无关的分支，而启动路径已经因为「清了数据就崩」出过一次事故。
///
/// 这里做成显式的一次调用（[drainPending]），由 `main.dart` 在 store 加载
/// **成功之后**触发；失败只记日志，不影响 App 使用。
///
/// ## 数据流
///
/// ```
/// 桌面组件（原生） --追加一行--> widget_pending.jsonl
///                                      |
///                    App 启动/回到前台 | drainPending()
///                                      v
///                         Store.expense() / Store.med()
///                                      |
///                             入库成功后才删行
/// ```
///
/// **顺序很关键**：必须「先入库、再删行」。反过来的话，删了行而入库失败，
/// 用户那笔账就永久消失了 —— 而队列是唯一的交接通道，删掉就再也没有第二份。
/// 即使中间断电，最多是下次启动重复入库，而入库是按 id 的 `INSERT OR REPLACE`，
/// 重复执行不会产生第二条记录。
class WidgetSync {
  const WidgetSync._();

  /// 把队列里待入库的记录写进数据库，并把已成功入库的行从队列里删掉。
  ///
  /// 返回真正入库的条数（用于界面提示「已同步 N 条」）。
  ///
  /// 单条失败**不中断整批**：一条金额非法的记录不该堵住后面所有记录。
  /// 失败的那条会被**保留在队列里**（不删），下次启动再试 —— 但也因此
  /// 需要一条「没救的记录」的出口：见 [normalize] 返回 null 的处理，
  /// 那种记录直接丢弃并删除，否则它会永远卡在队列里、每次启动都重试。
  static Future<int> drainPending(Store store) async {
    if (!store.isReady) return 0;
    List<Map<String, dynamic>> pending;
    try {
      pending = await WidgetBridge.readPending();
    } on Exception catch (error) {
      debugPrint('[widget] 读取队列失败：$error');
      return 0;
    }
    if (pending.isEmpty) return 0;

    final keep = <Map<String, dynamic>>[];
    var imported = 0;
    for (final raw in pending) {
      final normalized = WidgetBridge.normalize(raw);
      if (normalized == null) {
        // 没救的记录（缺 id/名称、金额非法）：**丢弃**。
        // 保留它会让每次启动都重试同一条坏数据，而它永远不会成功。
        debugPrint('[widget] 丢弃无法解析的桌面记录：$raw');
        continue;
      }
      try {
        if (raw[WidgetBridge.keyKind]?.toString() == WidgetBridge.kindMed) {
          await store.med(normalized);
        } else {
          await store.expense(normalized);
        }
        imported += 1;
      } on Exception catch (error) {
        // 入库失败：**保留**在队列里等下次重试。丢了就真没了。
        debugPrint('[widget] 入库失败，保留待重试：$error');
        keep.add(raw);
      }
    }

    await WidgetBridge.writePending(keep);
    // 数据变了，组件上的汇总要跟着变。失败不影响入库结果。
    await refreshSummary(store);
    return imported;
  }

  /// 按当前数据库内容重算汇总并写给原生组件。
  static Future<void> refreshSummary(Store store) async {
    if (!store.isReady) return;
    try {
      await WidgetBridge.writeSummary(
        WidgetBridge.buildSummary(
          expenses: store.expenses,
          meds: store.meds,
          now: DateTime.now(),
        ),
      );
    } on Exception catch (error) {
      debugPrint('[widget] 刷新汇总失败：$error');
    }
  }

  /// 桌面是否放了组件、队列里是否还有没同步的记录 —— 供设置页显示状态。
  static Future<({int pending})> status() async {
    try {
      final pending = await WidgetBridge.readPending();
      return (pending: pending.length);
    } on Exception {
      return (pending: 0);
    }
  }

  /// 订阅 [Store] 的变化，自动把汇总写回桌面组件。
  ///
  /// ## 为什么需要
  ///
  /// 没有它的话，组件上那行「今日支出 ¥50 共 2 笔」只在**两次**时机更新：
  /// App 启动、以及 App 从后台回到前台。用户打开 App 删了一笔账、再按 Home
  /// 回桌面，组件上还是旧数字 —— 看起来像没保存成功。
  ///
  /// ## 为什么必须防抖
  ///
  /// `Store.notifyListeners()` 在一次操作里可能触发很多次（每个 `_refresh`
  /// 之后都会通知）。每次通知都写一遍文件，等于在打字/滚动时反复做磁盘 I/O。
  /// 这里合并到 800ms 内只写一次：既跟得上用户操作，又不会变成 I/O 风暴。
  ///
  /// 返回的函数用于取消订阅（测试与 dispose 用得到）。
  static VoidCallback watchStore(Store store, {Duration debounce = const Duration(milliseconds: 800)}) {
    Timer? timer;
    void listener() {
      timer?.cancel();
      timer = Timer(debounce, () {
        refreshSummary(store);
      });
    }

    store.addListener(listener);
    return () {
      timer?.cancel();
      store.removeListener(listener);
    };
  }
}
