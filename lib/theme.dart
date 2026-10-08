import 'package:flutter/material.dart';

/// 视觉规范：8pt Grid + 字号层级 + 语义色 Token。
///
/// 对应 0.2B 评审文档里提出的「不要再凭感觉空 37 或 53」：所有间距都只从
/// [Gap] 里取，所有颜色都只从 [Tone] / [Categories] 里取。
///
/// **字号目前还没有对应的 token 类。** 这里原先写着「字号与颜色也只从 `Type` /
/// [Tone] 里取」，但 `Type` 这个类从来没有被写出来过 —— 规范要求了一个不存在
/// 的东西，于是 `lib/` 里 43 处 `fontSize: <数字>` 无处可依，只能就地硬编码
/// （取值 11/12/13/14/15/16/17/18/20/22/28，多数与 [buildAppTheme] 里的
/// `textTheme` 重复）。这是**已知未收敛项**，不是「已经规范了」：
/// 要么补一个 `Type` 常量类并逐个替换（需要逐屏回归），要么把这条规范降级成
/// 「优先使用 `Theme.of(context).textTheme`」。见 `doc/需求缺口与优先级.md`。
class Gap {
  const Gap._();

  /// 紧凑微间距：用于标题与它的副标题之间这类「视觉上属于同一块」的行间距。
  ///
  /// 它小于 [x1]（4），落在 8pt 网格之外 —— 这是刻意的：一个标题和它自己的
  /// 副标题不该按 8pt 网格分开，否则会显得散。原先这个值以裸数字 `2` 散落在
  /// 15 个地方，0.4A 收尾时收口成常量：**允许小于网格，但不允许无名**。
  static const hairline = 2.0;

  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 24.0;
  static const x6 = 32.0;

  /// 页面左右边距。
  static const page = 20.0;

  /// 卡片内部留白。
  static const card = 18.0;

  /// 卡片圆角。
  static const radius = 20.0;

  /// 输入框圆角。
  static const inputRadius = 14.0;
}

/// 语义色 Token。
///
/// 0.2B 评审指出旧版「所有强调操作都在使用同一种高饱和青蓝」，这里按语义
/// 拆分：品牌色、收支色、状态色、以及分类图标用的固定 pastel 色板。
class Tone {
  const Tone._();

  static const primary = Color(0xff145A72);
  static const primaryContainer = Color(0xffDCEEF2);

  /// 健康科普模块的品牌色。
  ///
  /// 0.4A 把 AI 拆成两个独立模块后，健康科普有了自己的入口与页面，
  /// 用一个与账本可区分的青色系，避免两个模块看起来是同一个东西。
  static const primaryHealth = Color(0xff11756E);
  static const primaryHealthContainer = Color(0xffD8F0ED);
  static const surface = Color(0xffFEFEFF);
  static const surfaceVariant = Color(0xffF5F7FA);
  static const surfaceMuted = Color(0xffF0F3F5);
  static const outline = Color(0xffE1E7EA);
  static const textPrimary = Color(0xff1B2429);
  static const textSecondary = Color(0xff68747C);
  static const textTertiary = Color(0xff9AA6AD);
  static const error = Color(0xffB3261E);
  static const income = Color(0xff2E7D5B);
  static const expense = Color(0xffB55252);
  static const warning = Color(0xffC97A2B);
  static const warningContainer = Color(0xffFFF4E6);
  static const info = Color(0xff247C99);

  /// 首页头图渐变。
  static const heroGradient = [Color(0xffE8F6FA), Color(0xffFBFDFF)];

  // 图标块固定色板（与示例图一致：同一功能在任何页面都是同一颜色）
  static const tintBlue = Color(0xffE3F0FA); // 记账 / 账本
  static const tintTeal = Color(0xffDFF1F3); // 药箱 / 医疗
  static const tintGreen = Color(0xffE4F5EA); // 数据 / 正向
  static const tintPurple = Color(0xffEFE7FB); // 个性化 / 娱乐
  static const tintAmber = Color(0xffFCF1DC); // 日常 / 提醒
  static const tintRed = Color(0xffFBE7E7); // 删除 / 过期
  static const tintSlate = Color(0xffECEFF2); // 中性 / 设置

  static const iconBlue = Color(0xff2C7BB6);
  static const iconTeal = Color(0xff14808C);
  static const iconGreen = Color(0xff2E9E63);
  static const iconPurple = Color(0xff7C4DBE);
  static const iconAmber = Color(0xffC08A2E);
  static const iconRed = Color(0xffC0453F);
  static const iconSlate = Color(0xff5B6B76);

  // --- 以下 5 个 token 是 0.4A 收尾时补的 ---
  //
  // 它们原本散落在 expense_form / home / common 三个文件里硬编码，其中
  // `selectedChip` 与 `cardSubtle` 各出现两次。0.2B 的复核要求「颜色只能来自
  // Tone」，重复的魔法值正是这条规范要防的东西：改一处忘一处就会出现两个
  // 看起来该一样、实际不一样的颜色。这里统一收口成 token。

  /// 选中态胶囊/标签的底色（分类选择、筛选项共用）。
  static const selectedChip = Color(0xffBFE3EC);

  /// 卡片内的弱底色，比 [surfaceVariant] 更接近白色，用于卡片中的卡片。
  static const cardSubtle = Color(0xffF7F9FB);

  /// 首页头图的装饰性描边色（仅在 [heroGradient] 上使用）。
  static const heroAccent = Color(0xff9CC9D6);

  /// 首页头图的浅色块，用于给图标打底。
  static const heroTint = Color(0xffE9F5F8);

  /// 头图装饰与次级图标的灰蓝色。
  static const iconSlateSoft = Color(0xff54808A);
}

/// 记账分类的图标与配色。
///
/// 0.2B 评审建议「账本要有自己的数据语义」，所以每个分类有固定的颜色与图标，
/// 在列表、筛选、统计图表中保持一致。
class CategoryStyle {
  const CategoryStyle(this.icon, this.color, this.tint);

  final IconData icon;
  final Color color;
  final Color tint;
}

class Categories {
  const Categories._();

  /// 记账表单里直接展示的常用分类。
  static const quick = ['餐饮', '购物', '交通', '医疗', '娱乐', '日常'];

  /// 「更多分类」里的补充分类。
  static const more = ['教育', '住房', '通讯', '人情', '收入', '其他'];

  static const all = [...quick, ...more];

  static const _styles = <String, CategoryStyle>{
    '餐饮': CategoryStyle(Icons.restaurant, Tone.iconBlue, Tone.tintBlue),
    '购物': CategoryStyle(Icons.shopping_cart, Tone.iconGreen, Tone.tintGreen),
    '交通': CategoryStyle(Icons.directions_bus, Tone.iconBlue, Tone.tintBlue),
    '医疗': CategoryStyle(Icons.medical_services, Tone.iconRed, Tone.tintRed),
    '娱乐': CategoryStyle(Icons.sports_esports, Tone.iconPurple, Tone.tintPurple),
    '日常': CategoryStyle(Icons.home_outlined, Tone.iconAmber, Tone.tintAmber),
    '教育': CategoryStyle(Icons.school_outlined, Tone.iconTeal, Tone.tintTeal),
    '住房': CategoryStyle(Icons.apartment, Tone.iconSlate, Tone.tintSlate),
    '通讯': CategoryStyle(Icons.phone_iphone, Tone.iconBlue, Tone.tintBlue),
    '人情': CategoryStyle(Icons.card_giftcard, Tone.iconPurple, Tone.tintPurple),
    '收入': CategoryStyle(Icons.savings_outlined, Tone.iconGreen, Tone.tintGreen),
    '其他': CategoryStyle(Icons.category_outlined, Tone.iconSlate, Tone.tintSlate),
    'AI 录入': CategoryStyle(Icons.auto_awesome, Tone.iconTeal, Tone.tintTeal),
  };

  static const _fallback = CategoryStyle(
    Icons.label_outline,
    Tone.iconSlate,
    Tone.tintSlate,
  );

  /// 未登记的分类取稳定哈希，保证同一分类名始终是同一颜色。
  static CategoryStyle of(String? name) {
    final key = name?.trim() ?? '';
    final known = _styles[key];
    if (known != null) return known;
    if (key.isEmpty) return _fallback;
    final palette = [
      _styles['餐饮']!,
      _styles['购物']!,
      _styles['交通']!,
      _styles['娱乐']!,
      _styles['教育']!,
      _styles['住房']!,
    ];
    var hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Tone.primary,
    brightness: Brightness.light,
    surface: Tone.surface,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Tone.surfaceVariant,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Tone.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Gap.radius),
        side: const BorderSide(color: Tone.outline),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xffF7F9FB),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Gap.inputRadius),
        borderSide: const BorderSide(color: Tone.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Gap.inputRadius),
        borderSide: const BorderSide(color: Tone.outline),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 13,
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
      indicatorColor: Color(0x1A145A72),
      iconTheme: WidgetStatePropertyAll(IconThemeData(size: 24)),
    ),
    dividerTheme: const DividerThemeData(
      space: 1,
      thickness: 1,
      color: Tone.outline,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    appBarTheme: const AppBarTheme(
      backgroundColor: Tone.surfaceVariant,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Tone.textPrimary,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Tone.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        color: Tone.textPrimary,
        height: 1.15,
      ),
      headlineSmall: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: Tone.textPrimary,
        height: 1.2,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Tone.textPrimary,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Tone.textPrimary,
      ),
      bodyMedium: TextStyle(fontSize: 15, color: Tone.textPrimary, height: 1.4),
      bodySmall: TextStyle(fontSize: 13, color: Tone.textSecondary, height: 1.35),
      labelSmall: TextStyle(fontSize: 12, color: Tone.textTertiary),
    ),
  );
}

/// 是否深色模式。0.2C 的示例图全部是浅色，这里只保留接口不做强制。
bool prefersDark(BuildContext context) =>
    MediaQuery.platformBrightnessOf(context) == Brightness.dark;
