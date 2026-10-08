/// 常见药品的**给药途径**词典。
///
/// ## 为什么需要一张表，而不是只靠正则
///
/// 剂型正则只在药名恰好写了剂型字时才有效。真实药箱里大量药品只有通用名：
/// 「布洛芬」「阿莫西林」「碘伏」「云南白药气雾剂」—— 0.4D 之前它们**全部**
/// 掉进「其他」，而用户报的正是这个现象。
///
/// ## 维护规则（重要）
///
/// 1. **只收录「途径明确」的药。** 拿不准的药不要写进来 —— 让它落到
///    [MedRoute.unknown] 并由界面提示用户手选，比猜错安全。
/// 2. **同一成分不同剂型可以途径不同**（例如「西瓜霜」有喷剂外用、
///    也有片剂内服）。这种情况**不要把通用名写进表里**，交给剂型关键词判。
/// 3. 表里的键是**匹配用的子串**，按长度从长到短匹配，避免
///    「布洛芬」抢先命中「布洛芬缓释胶囊」而导致长名失去更精确的判断。
/// 4. 新增条目时**必须同时在 `test/med_classify_test.dart` 里加断言** ——
///    否则这张表就是没人验证的猜测。这个文件的价值完全取决于它准不准。
///
/// ## 为什么不用联网查
///
/// 这是**离线**的静态表，不是权威药学数据库。它只解决「内服还是外用」
/// 这一个粗粒度问题，不承担用法用量等临床信息的准确性 ——
/// 那类信息在药品详情页由说明书/联网查询承担，并明确标注来源。
library;

/// 给药途径：与 [MedRoute] 的 label 对应，这里用枚举名避免循环依赖。
enum DictRoute { oral, topical }

/// 常见药 → 给药途径。
///
/// 键统一**不含空格**；匹配时会先去掉文本里的空格再比对。
const Map<String, DictRoute> medRouteDict = {
  // ---------------------------------------------------------------- 解热镇痛 / 抗炎
  '布洛芬': DictRoute.oral,
  '对乙酰氨基酚': DictRoute.oral,
  '扑热息痛': DictRoute.oral,
  '泰诺': DictRoute.oral,
  '芬必得': DictRoute.oral,
  '美林': DictRoute.oral,
  '阿司匹林': DictRoute.oral,
  '双氯芬酸': DictRoute.oral,
  '扶他林': DictRoute.topical, // 扶他林以凝胶剂知名，口服是「双氯芬酸钠」
  '塞来昔布': DictRoute.oral,
  '吲哚美辛': DictRoute.oral,
  '洛索洛芬': DictRoute.oral,
  '安乃近': DictRoute.oral,
  '去痛片': DictRoute.oral,
  '止痛片': DictRoute.oral,

  // ---------------------------------------------------------------- 抗感染
  '阿莫西林': DictRoute.oral,
  '氨苄西林': DictRoute.oral,
  '头孢': DictRoute.oral, // 头孢类口服为主，注射剂由剂型词「注射液」另判
  '阿奇霉素': DictRoute.oral,
  '克拉霉素': DictRoute.oral,
  '罗红霉素': DictRoute.oral,
  '红霉素': DictRoute.oral,
  '左氧氟沙星': DictRoute.oral,
  '诺氟沙星': DictRoute.oral,
  '环丙沙星': DictRoute.oral,
  '甲硝唑': DictRoute.oral,
  '奥硝唑': DictRoute.oral,
  '氟康唑': DictRoute.oral,
  '阿昔洛韦': DictRoute.oral,
  '利巴韦林': DictRoute.oral,
  '奥司他韦': DictRoute.oral,
  '青霉素': DictRoute.oral,
  '阿莫西林克拉维酸': DictRoute.oral,
  '复方磺胺甲噁唑': DictRoute.oral,
  '黄连素': DictRoute.oral,
  '小檗碱': DictRoute.oral,

  // ---------------------------------------------------------------- 消化系统
  '奥美拉唑': DictRoute.oral,
  '泮托拉唑': DictRoute.oral,
  '兰索拉唑': DictRoute.oral,
  '雷贝拉唑': DictRoute.oral,
  '埃索美拉唑': DictRoute.oral,
  '法莫替丁': DictRoute.oral,
  '雷尼替丁': DictRoute.oral,
  '铝碳酸镁': DictRoute.oral,
  '硫糖铝': DictRoute.oral,
  '蒙脱石': DictRoute.oral,
  '蒙脱石散': DictRoute.oral,
  '洛哌丁胺': DictRoute.oral,
  '易蒙停': DictRoute.oral,
  '多潘立酮': DictRoute.oral,
  '吗丁啉': DictRoute.oral,
  '莫沙必利': DictRoute.oral,
  '甲氧氯普胺': DictRoute.oral,
  '胃复安': DictRoute.oral,
  '乳果糖': DictRoute.oral,
  '聚乙二醇': DictRoute.oral,
  '开塞露': DictRoute.topical, // 直肠给药，归外用（不是口服）
  '双歧杆菌': DictRoute.oral,
  '益生菌': DictRoute.oral,
  '整肠生': DictRoute.oral,
  '健胃消食片': DictRoute.oral,
  '复方消化酶': DictRoute.oral,
  '熊去氧胆酸': DictRoute.oral,
  '消旋山莨菪碱': DictRoute.oral,
  '颠茄': DictRoute.oral,

  // ---------------------------------------------------------------- 呼吸 / 抗过敏
  '氯雷他定': DictRoute.oral,
  '西替利嗪': DictRoute.oral,
  '扑尔敏': DictRoute.oral,
  '氯苯那敏': DictRoute.oral,
  '苯海拉明': DictRoute.oral,
  '依巴斯汀': DictRoute.oral,
  '孟鲁司特': DictRoute.oral,
  '氨溴索': DictRoute.oral,
  '溴己新': DictRoute.oral,
  '乙酰半胱氨酸': DictRoute.oral,
  '右美沙芬': DictRoute.oral,
  '复方甲氧那明': DictRoute.oral,
  '阿斯美': DictRoute.oral,
  '沙丁胺醇': DictRoute.topical, // 气雾吸入为主
  '布地奈德': DictRoute.topical, // 吸入/鼻喷为主
  '沙美特罗': DictRoute.topical,
  '氟替卡松': DictRoute.topical,
  '连花清瘟': DictRoute.oral,
  '感冒灵': DictRoute.oral,
  '板蓝根': DictRoute.oral,
  '双黄连': DictRoute.oral,
  '蓝芩': DictRoute.oral,
  '蒲地蓝': DictRoute.oral,
  '川贝': DictRoute.oral,
  '急支糖浆': DictRoute.oral,
  '念慈菴': DictRoute.oral,

  // ---------------------------------------------------------------- 心血管 / 代谢（多为慢性病）
  '硝苯地平': DictRoute.oral,
  '氨氯地平': DictRoute.oral,
  '左氨氯地平': DictRoute.oral,
  '非洛地平': DictRoute.oral,
  '厄贝沙坦': DictRoute.oral,
  '缬沙坦': DictRoute.oral,
  '氯沙坦': DictRoute.oral,
  '替米沙坦': DictRoute.oral,
  '培哚普利': DictRoute.oral,
  '依那普利': DictRoute.oral,
  '贝那普利': DictRoute.oral,
  '美托洛尔': DictRoute.oral,
  '比索洛尔': DictRoute.oral,
  '普萘洛尔': DictRoute.oral,
  '卡维地洛': DictRoute.oral,
  '氢氯噻嗪': DictRoute.oral,
  '呋塞米': DictRoute.oral,
  '螺内酯': DictRoute.oral,
  '吲达帕胺': DictRoute.oral,
  '单硝酸异山梨酯': DictRoute.oral,
  '硝酸甘油': DictRoute.oral, // 舌下含服
  '阿托伐他汀': DictRoute.oral,
  '瑞舒伐他汀': DictRoute.oral,
  '辛伐他汀': DictRoute.oral,
  '普伐他汀': DictRoute.oral,
  '非诺贝特': DictRoute.oral,
  '依折麦布': DictRoute.oral,
  '华法林': DictRoute.oral,
  '利伐沙班': DictRoute.oral,
  '达比加群': DictRoute.oral,
  '氯吡格雷': DictRoute.oral,
  '替格瑞洛': DictRoute.oral,
  '二甲双胍': DictRoute.oral,
  '格列美脲': DictRoute.oral,
  '格列齐特': DictRoute.oral,
  '格列吡嗪': DictRoute.oral,
  '阿卡波糖': DictRoute.oral,
  '瑞格列奈': DictRoute.oral,
  '西格列汀': DictRoute.oral,
  '达格列净': DictRoute.oral,
  '恩格列净': DictRoute.oral,
  '左甲状腺素': DictRoute.oral,
  '优甲乐': DictRoute.oral,
  '甲巯咪唑': DictRoute.oral,
  '丙硫氧嘧啶': DictRoute.oral,
  '别嘌醇': DictRoute.oral,
  '非布司他': DictRoute.oral,
  '苯溴马隆': DictRoute.oral,
  '碳酸钙': DictRoute.oral,
  '阿仑膦酸': DictRoute.oral,
  '骨化三醇': DictRoute.oral,

  // ---------------------------------------------------------------- 神经 / 精神
  '卡马西平': DictRoute.oral,
  '丙戊酸': DictRoute.oral,
  '左乙拉西坦': DictRoute.oral,
  '奥卡西平': DictRoute.oral,
  '拉莫三嗪': DictRoute.oral,
  '苯妥英钠': DictRoute.oral,
  '艾司唑仑': DictRoute.oral,
  '阿普唑仑': DictRoute.oral,
  '地西泮': DictRoute.oral,
  '佐匹克隆': DictRoute.oral,
  '唑吡坦': DictRoute.oral,
  '舍曲林': DictRoute.oral,
  '帕罗西汀': DictRoute.oral,
  '氟西汀': DictRoute.oral,
  '艾司西酞普兰': DictRoute.oral,
  '文拉法辛': DictRoute.oral,
  '米氮平': DictRoute.oral,
  '多奈哌齐': DictRoute.oral,
  '美金刚': DictRoute.oral,
  '甲钴胺': DictRoute.oral,
  '维生素B': DictRoute.oral,
  '谷维素': DictRoute.oral,
  '氟桂利嗪': DictRoute.oral,
  '倍他司汀': DictRoute.oral,
  '尼莫地平': DictRoute.oral,

  // ---------------------------------------------------------------- 外用 / 皮肤 / 消毒
  '碘伏': DictRoute.topical,
  '聚维酮碘': DictRoute.topical,
  '碘酒': DictRoute.topical,
  '酒精': DictRoute.topical,
  '乙醇': DictRoute.topical,
  '双氧水': DictRoute.topical,
  '过氧化氢': DictRoute.topical,
  '高锰酸钾': DictRoute.topical,
  '云南白药': DictRoute.topical, // 气雾剂/膏为主；胶囊另由剂型词判
  '红花油': DictRoute.topical,
  '活络油': DictRoute.topical,
  '风油精': DictRoute.topical,
  '清凉油': DictRoute.topical,
  '花露水': DictRoute.topical,
  '炉甘石': DictRoute.topical,
  '莫匹罗星': DictRoute.topical,
  '百多邦': DictRoute.topical,
  '红霉素软膏': DictRoute.topical,
  '金霉素': DictRoute.topical,
  '复方醋酸地塞米松': DictRoute.topical,
  '皮炎平': DictRoute.topical,
  '糠酸莫米松': DictRoute.topical,
  '丁酸氢化可的松': DictRoute.topical,
  '曲安奈德': DictRoute.topical,
  '他克莫司': DictRoute.topical,
  '卡泊三醇': DictRoute.topical,
  '阿达帕林': DictRoute.topical,
  '维A酸': DictRoute.topical,
  '过氧苯甲酰': DictRoute.topical,
  '水杨酸': DictRoute.topical,
  '尿素': DictRoute.topical,
  '复方酮康唑': DictRoute.topical,
  '酮康唑': DictRoute.topical,
  '特比萘芬': DictRoute.topical,
  '咪康唑': DictRoute.topical,
  '克霉唑': DictRoute.topical,
  '阿昔洛韦乳膏': DictRoute.topical,
  '复方甘草': DictRoute.oral, // 复方甘草片是口服
  '开喉剑': DictRoute.topical,
  '西瓜霜喷剂': DictRoute.topical,
  '金嗓子': DictRoute.oral, // 含片，经口
  '草珊瑚': DictRoute.oral,

  // ---------------------------------------------------------------- 眼 / 耳 / 鼻
  '左氧氟沙星滴眼液': DictRoute.topical,
  '玻璃酸钠': DictRoute.topical,
  '人工泪液': DictRoute.topical,
  '妥布霉素': DictRoute.topical,
  '氯霉素滴眼液': DictRoute.topical,
  '色甘酸钠': DictRoute.topical,
  '奥洛他定': DictRoute.topical,
  '氮卓斯汀': DictRoute.topical,
  '糠酸氟替卡松': DictRoute.topical,
  '盐酸羟甲唑啉': DictRoute.topical,
  '碳酸氢钠滴耳液': DictRoute.topical,

  // ---------------------------------------------------------------- 维生素 / 营养
  '维生素C': DictRoute.oral,
  '维生素B1': DictRoute.oral,
  '维生素B2': DictRoute.oral,
  '维生素B6': DictRoute.oral,
  '维生素B12': DictRoute.oral,
  '维生素D': DictRoute.oral,
  '维生素E': DictRoute.oral,
  '维生素A': DictRoute.oral,
  '叶酸': DictRoute.oral,
  '铁剂': DictRoute.oral,
  '硫酸亚铁': DictRoute.oral,
  '琥珀酸亚铁': DictRoute.oral,
  '葡萄糖酸锌': DictRoute.oral,
  '钙片': DictRoute.oral,
  '鱼油': DictRoute.oral,
  '蛋白粉': DictRoute.oral,
  '口服补液盐': DictRoute.oral,
};

/// 按长键优先匹配，返回途径；没命中返回 null。
///
/// 为什么长键优先：`布洛芬` 是 `布洛芬缓释胶囊` 的子串，
/// 若短键先命中，长名就永远走不到更精确的条目（将来若给长名单独设途径，
/// 短的会把它吃掉）。按长度倒序可以让更具体的条目胜出。
DictRoute? dictRoute(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), '');
  if (flat.isEmpty) return null;

  // 长键优先：预先把键按长度倒序排好，命中即返回。
  for (final entry in _sortedEntries) {
    if (flat.contains(entry.key)) return entry.value;
  }
  return null;
}

/// 长度倒序的词典条目（惰性构建一次）。
final List<MapEntry<String, DictRoute>> _sortedEntries = () {
  final list = medRouteDict.entries.toList();
  list.sort((a, b) => b.key.length.compareTo(a.key.length));
  return list;
}();
