import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面组件「AI 版」把用户送进 App 的入口。
///
/// ## 为什么 AI 版要进 App，而普通版不用
///
/// 用户要的是「点桌面组件就能快速记一笔」。普通版做到了：点开是原生浮层
/// （[QuickEntryActivity]，见原生侧注释），在桌面上就地填完，不等 App 冷启动。
///
/// 但 AI 版做不到，原因是**系统限制**：桌面组件用 `RemoteViews` 渲染，
/// 而 RemoteViews **不支持 `EditText`** —— 组件里放不了输入框。
/// 所以「说一句话让 AI 帮你记」只能落到 App 内部：点组件 → 打开 App →
/// 弹出 AI 输入框。这不是偷懒，是没有第二种做法（Android 12 之前连尝试都不必）。
///
/// 于是分工是：
///  · 普通记账/记药 → 原生浮层，最快；
///  · AI 记账/记药 → 进 App，用已有的 ActionPlan 链路（模型理解人话后产出结构化动作）。
class WidgetLaunch {
  const WidgetLaunch._();

  /// 与原生 `MainActivity.CHANNEL` **必须逐字一致**。
  ///
  /// 不一致的表现很隐蔽：点 AI 组件**会**打开 App（Activity 正常启动），
  /// 只是不弹输入框 —— 用户以为「组件坏了」，其实是两边通道名对不上。
  /// `test/widget_bridge_test.dart` 会读 .kt 文件断言这个字符串。
  static const channelName = 'family_life_assistant/widget_launch';

  static const _channel = MethodChannel(channelName);

  /// 记录类型（与原生 `WidgetKind.id` 一致）。
  static const kindExpense = 'expense';
  static const kindExpenseAi = 'expense_ai';
  static const kindMed = 'med';
  static const kindMedAi = 'med_ai';

  /// App 启动/热启动时，问一次「是哪个桌面组件把我叫起来的」。
  ///
  /// 原生侧**取走即清空**，所以这个请求只会成功一次 —— 这正是我们要的：
  /// 用户每次从后台切回来不该被反复弹输入框。
  ///
  /// 返回 null 表示不是从组件进来的（正常点图标启动），或者已经在非 Android
  /// 平台上（桌面组件是 Android 独有的）。
  static Future<WidgetLaunchRequest?> takeLaunchRequest() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('takeLaunchWidget');
      return parseLaunch(raw);
    } on MissingPluginException {
      // 非 Android 平台（或原生侧没注册）：不是错误，就是没有组件。
      return null;
    } on PlatformException catch (error) {
      debugPrint('[widget] 读取启动来源失败：$error');
      return null;
    }
  }

  /// 解析原生返回的 `{kind, ai}`。抽成纯函数以便离线测试。
  @visibleForTesting
  static WidgetLaunchRequest? parseLaunch(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind']?.toString().trim() ?? '';
    if (kind.isEmpty) return null;
    if (!isKnownKind(kind)) return null;
    // `ai` 缺失时按 kind 自己推断 —— 原生两个字段理论上总是一起发，
    // 但只用其中一个就能得出答案时，不必依赖另一个也正确。
    final aiFlag = raw['ai'];
    final isAi = aiFlag is bool ? aiFlag : kind.endsWith('_ai');
    return WidgetLaunchRequest(kind: kind, isAi: isAi);
  }

  /// 是不是我们认识的组件类型。
  @visibleForTesting
  static bool isKnownKind(String kind) => const {
    kindExpense,
    kindExpenseAi,
    kindMed,
    kindMedAi,
  }.contains(kind);

  /// 该组件要操作的是账本还是药箱。
  @visibleForTesting
  static bool isExpenseKind(String kind) => kind.startsWith('expense');

  /// 是否已放的桌面组件能显示实时汇总（由原生读取汇总文件决定）。
  /// 这里不做检查 —— 汇总是否可读由原生侧自己兜底成占位文案。

  /// 请系统把某个组件钉到桌面（Android 8.0+）。
  ///
  /// 返回 true 表示系统接受了请求（会弹确认框让用户点确定）；
  /// false 表示**这台设备或这个桌面不支持**，调用方应退回「手动添加」的文字说明
  /// —— 而不是假装成功。
  ///
  /// 为什么要有这个：让用户自己去「长按桌面 → 小组件 → 在长列表里找我们」
  /// 是绝大多数人放弃的地方。`requestPinAppWidget` 能直接用系统的确认框完成，
  /// 但它的支持度**依赖桌面实现**（华为/小米某些桌面不支持），所以必须有降级路径。
  static Future<bool> requestPin(String kind) async {
    if (!isKnownKind(kind)) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'requestPinWidget',
        <String, Object?>{'kind': kind},
      );
      return ok ?? false;
    } on MissingPluginException {
      return false; // 非 Android
    } on PlatformException catch (error) {
      debugPrint('[widget] 请求添加组件失败：$error');
      return false;
    }
  }

  /// 注册热启动回调：App 已在后台时点组件，原生会主动通知。
  ///
  /// 只做冷启动的版本在开发机上测不出问题（每次都冷启动），
  /// 而真实使用中 App 常年挂在后台 —— 那时候点组件必须也能弹出来。
  static void listenForLaunch(void Function() onLaunch) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'widgetLaunch') onLaunch();
      return null;
    });
  }

  /// 取消注册（热重载/退出时）。
  static void stopListening() {
    _channel.setMethodCallHandler(null);
  }
}

/// 一次「从桌面组件进来」的请求。
@immutable
class WidgetLaunchRequest {
  const WidgetLaunchRequest({required this.kind, required this.isAi});

  /// 四选一：`expense` / `expense_ai` / `med` / `med_ai`。
  final String kind;

  /// AI 版：要打开 AI 输入框，而不是普通表单。
  ///
  /// 普通版**不该**走这里 —— 它在原生浮层里就记完了，根本不会启动 App。
  /// 所以正常情况这里恒为 true；留着这个字段是为了万一将来普通版也走这条路
  /// （比如用户关掉了原生浮层的某条路径）时不用改数据形状。
  final bool isAi;

  bool get isExpense => WidgetLaunch.isExpenseKind(kind);

  @override
  String toString() => 'WidgetLaunchRequest(kind: $kind, isAi: $isAi)';

  @override
  bool operator ==(Object other) =>
      other is WidgetLaunchRequest && other.kind == kind && other.isAi == isAi;

  @override
  int get hashCode => Object.hash(kind, isAi);
}
