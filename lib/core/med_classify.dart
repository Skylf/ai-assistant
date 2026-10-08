/// 药品分类：按**给药途径**把药品归到「内服 / 外用 / 儿童 / 慢性病 / 其他」。
///
/// ## 为什么单独抽一个文件
///
/// 0.4D 之前这套规则写在 `pages/meds.dart` 的 `tagsOf()` 里，全是一串正则：
///
/// ```dart
/// if (RegExp(r'胶囊|片|颗粒|口服液|散|丸|糖浆').hasMatch(text)) tags.add('内服');
/// if (RegExp(r'软膏|乳膏|喷雾|贴|滴眼|外用|洗剂').hasMatch(text)) tags.add('外用');
/// ```
///
/// 它只看**剂型词**，所以只要药名里没带剂型，就一律掉进「其他」。
/// 实测（0.4D 排查）：
///
/// | 药名 | 0.4D 之前 | 应该是 |
/// | --- | --- | --- |
/// | 布洛芬 | **其他** | 内服 |
/// | 阿莫西林 | **其他** | 内服 |
/// | 云南白药气雾剂 | **其他** | 外用 |
/// | 碘伏 | **其他** | 外用 |
///
/// 也就是说「其他」这一档混进了大量本该归类明确的药 —— 用户报的现象
/// （布洛芬与布洛芬缓释胶囊被分到不同类）的根因就在这里：**分不分得对，
/// 取决于药名里有没有恰好写上一个剂型字**，而不是这药实际怎么用。
///
/// ## 判定顺序（从强到弱）
///
/// 1. **用户手填的分类**（`med['form']`）—— 用户说的永远算，用户能改才叫分类；
/// 2. **给药途径词典**（`medRouteDict`）—— 常见药按通用名/别名直接定途径；
/// 3. **剂型关键词** —— 兜底，外用优先于内服；
/// 4. 都不命中 →「其他」，但**界面会提示可手动指定**，不再默默归错。
///
/// 第 3 步里**外用必须排在前面**：把外用药误判成内服，是会出事的那个方向。
library;

import 'med_dict.dart';

// 词典与 DictRoute 一起转出去：调用方（和测试）只 import 这一个文件就够了，
// 不必知道「分类逻辑」与「药品词典」被拆成了两个文件。
export 'med_dict.dart' show DictRoute, medRouteDict, dictRoute;

/// 「常用」标记存在备注里的固定标签。
///
/// 这是历史遗留的设计（见 `meds.dart`）：没有独立的布尔列，
/// 靠 `note` 里有没有 `[常用]` 判断。迁移成本高于收益，保留。
const commonMedTag = '[常用]';

/// 给药途径。
enum MedRoute {
  /// 口服 / 经消化道给药。
  oral('内服'),

  /// 皮肤、黏膜、眼耳鼻等局部给药。
  topical('外用'),

  /// 确定不了 —— 界面要提示用户手动指定。
  unknown('其他');

  const MedRoute(this.label);

  /// 界面与筛选器用的中文标签。
  final String label;
}

/// 除「全部」外的真实分类标签。
///
/// 顺序就是筛选条的顺序：「常用」在最前（最常用），「其他」在最后（兜底）。
const knownMedTags = ['常用', '内服', '外用', '儿童', '慢性病'];

/// 剂型关键词：**外用优先**。
///
/// 顺序敏感：先判外用，避免把 `西瓜霜喷剂` 这类同时像内服的判成内服。
/// 每个词都必须是真的剂型/给药方式，不能是泛化词（例如不能加「药」）。
final _topicalForms = RegExp(
  r'软膏|乳膏|凝胶|搽剂|涂剂|酊剂|洗剂|擦剂|贴膏|贴剂|膏药|'
  r'滴眼|滴耳|滴鼻|眼膏|滴剂|喷雾|喷剂|气雾|吸入|'
  r'栓剂|栓|灌肠|开塞露|'
  r'外用|敷料|创可贴|纱布|棉签|绷带|碘伏|酒精|消毒液|'
  r'眼药水|鼻喷|阴道|肛门|皮肤',
);

/// 剂型关键词：内服。
final _oralForms = RegExp(
  r'胶囊|片|颗粒|口服液|口服|散|丸|糖浆|胶浆|混悬|乳剂|合剂|'
  r'酊|浸膏|煎膏|茶|滴丸|咀嚼|含片|泡腾|肠溶|缓释|控释|'
  r'溶液|注射液|针|口服补液',
);

/// 儿童专用药的关键词。
final _childHints = RegExp(r'儿童|小儿|宝宝|婴幼儿|婴儿');

/// 慢性病长期用药的关键词。
///
/// 这里放的是**适应症**而不是剂型：高血压、糖尿病、降脂、抗凝、癫痫、
/// 甲减、哮喘、痛风、骨质疏松等通常需要长期服用。
final _chronicHints = RegExp(
  r'高血压|降压|糖尿病|降糖|血糖|二甲双胍|格列|胰岛素|'
  r'他汀|降脂|血脂|阿司匹林|华法林|氯吡格雷|抗凝|'
  r'癫痫|丙戊酸|卡马西平|左乙拉西坦|'
  r'甲减|甲状腺|左甲状腺素|优甲乐|'
  r'哮喘|慢阻肺|布地奈德|沙美特罗|孟鲁司特|'
  r'痛风|别嘌醇|非布司他|苯溴马隆|'
  r'骨质疏松|阿仑膦酸|碳酸钙|维生素D|'
  r'长期|慢性|每日|终生|维持治疗',
);

/// 把一条药品记录判成 [MedRoute]。
///
/// [explicit] 是用户在表单里手选的分类标签（可为空）。它是**最高优先级**：
/// 自动分类只是省事，不能凌驾于用户的选择之上。
MedRoute routeOf(Map<String, dynamic> med, {String? explicit}) {
  if (explicit != null && explicit.trim().isNotEmpty) {
    final v = explicit.trim();
    for (final r in MedRoute.values) {
      if (r.label == v) return r;
    }
  }

  final text = _haystack(med);
  if (text.isEmpty) return MedRoute.unknown;

  // ② 给药途径词典：药名/成分命中就直接定途径。
  // 词典用自己的轻量枚举（避免两个文件互相 import），所以这里做一次映射。
  final byDict = dictRoute(text);
  if (byDict != null) {
    return byDict == DictRoute.topical ? MedRoute.topical : MedRoute.oral;
  }

  // ③ 剂型关键词兜底：外用先判。
  if (_topicalForms.hasMatch(text)) return MedRoute.topical;
  if (_oralForms.hasMatch(text)) return MedRoute.oral;

  // ④ 判不出来。**不要瞎猜** —— 猜错的代价是用户按错误的用法用药。
  return MedRoute.unknown;
}

/// 计算一条药品的全部标签。
///
/// 返回的是**筛选器用的标签集合**，与「给药途径」的关系是：
///  · 内服 / 外用 来自 [routeOf]；
///  · 儿童 / 慢性病 是额外的属性标签，可与内服/外用**并存**
///    （「小儿布洛芬混悬液」既是内服也是儿童）；
///  · 其他 只在**什么都没有**时才出现。
List<String> tagsOfMed(Map<String, dynamic> med, {String? explicit}) {
  final text = _haystack(med);
  final tags = <String>[];

  if (text.contains(commonMedTag)) tags.add('常用');

  final route = routeOf(med, explicit: explicit);
  if (route != MedRoute.unknown) tags.add(route.label);

  if (_childHints.hasMatch(text)) tags.add('儿童');
  if (_chronicHints.hasMatch(text)) tags.add('慢性病');

  if (tags.isEmpty) tags.add(MedRoute.unknown.label);
  return tags;
}

/// 供界面提示用：这条药是不是「自动分不出来」。
///
/// 单独开放这个判断，是为了让界面能明确提示「点『修改』可以手动选分类」，
/// 而不是让用户看到「其他」却不知道为什么、也不知道能改。
bool needsManualRouteFor(Map<String, dynamic> med, {String? explicit}) =>
    routeOf(med, explicit: explicit) == MedRoute.unknown;

String _haystack(Map<String, dynamic> med) => [
  med['name'],
  med['ingredient'],
  med['note'],
  med['spec'],
].map((v) => v?.toString() ?? '').join(' ').trim();
