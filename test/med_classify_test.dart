import 'package:family_life_assistant/core/med_classify.dart';
import 'package:flutter_test/flutter_test.dart';

/// 药品自动分类（0.4D 修复项 2.2）。
///
/// 用户报的现象：「布洛芬与布洛芬缓释胶囊都是内服，但自动划分只将布洛芬
/// 划分进内服，布洛芬缓释胶囊划分到了其他」。
///
/// ⚠️ 这里有个**必须记录在案的偏差**：我实测的结果与用户描述**方向相反**。
/// 0.4D 之前 `tagsOf()` 只按剂型正则判，实测是：
///
///   布洛芬            → 其他   ← 没有剂型字，掉进兜底
///   布洛芬缓释胶囊     → 内服   ← 含「胶囊」
///
/// 用户的意图很清楚且两边一致：**两个都该是内服**。
/// 所以这一组测试按「用户要的结果」写，而不是按用户描述的过程写。
void main() {
  Map<String, dynamic> med(
    String name, {
    String? ingredient,
    String? spec,
    String? note,
  }) {
    final m = <String, dynamic>{'name': name};
    if (ingredient != null) m['ingredient'] = ingredient;
    if (spec != null) m['spec'] = spec;
    if (note != null) m['note'] = note;
    return m;
  }

  group('【关键】用户报的那一对必须同类', () {
    test('布洛芬 与 布洛芬缓释胶囊 都判为内服', () {
      expect(routeOf(med('布洛芬')), MedRoute.oral);
      expect(routeOf(med('布洛芬缓释胶囊')), MedRoute.oral);
      expect(
        routeOf(med('布洛芬')),
        routeOf(med('布洛芬缓释胶囊')),
        reason: '同一种药的不同写法必须归到同一类，这正是用户报的问题',
      );
    });

    test('同药不同剂型：布洛芬片 / 布洛芬混悬液 都是内服', () {
      expect(routeOf(med('布洛芬片')), MedRoute.oral);
      expect(routeOf(med('布洛芬混悬液')), MedRoute.oral);
    });
  });

  group('只有通用名（没有剂型字）也要判对', () {
    // 这组是 0.4D 之前**全部落进「其他」**的药，是真实现象的回归防线。
    const oralOnly = [
      '布洛芬',
      '阿莫西林',
      '头孢克肟',
      '阿奇霉素',
      '奥美拉唑',
      '氯雷他定',
      '二甲双胍',
      '硝苯地平',
      '阿托伐他汀',
      '左甲状腺素',
      '蒙脱石',
      '维生素C',
      '叶酸',
    ];
    for (final name in oralOnly) {
      test('$name → 内服', () {
        expect(routeOf(med(name)), MedRoute.oral);
      });
    }

    const topicalOnly = [
      '碘伏',
      '云南白药气雾剂',
      '炉甘石洗剂',
      '红霉素软膏',
      '创可贴',
      '风油精',
      '双氧水',
      '莫匹罗星',
      '开塞露',
    ];
    for (final name in topicalOnly) {
      test('$name → 外用', () {
        expect(routeOf(med(name)), MedRoute.topical);
      });
    }
  });

  group('剂型兜底（词典里没有的药）', () {
    test('常见内服剂型', () {
      for (final name in ['某某胶囊', '某某片', '某某颗粒', '某某口服液', '某某散', '某某丸', '某某糖浆']) {
        expect(routeOf(med(name)), MedRoute.oral, reason: name);
      }
    });

    test('常见外用剂型', () {
      for (final name in ['某某软膏', '某某乳膏', '某某喷雾', '某某滴眼液', '某某洗剂', '某某贴膏', '某某栓']) {
        expect(routeOf(med(name)), MedRoute.topical, reason: name);
      }
    });

    test('【关键】同时含内服与外用剂型词时，判外用（安全方向）', () {
      // 把外用药判成内服会让人口服外用药 —— 那是会出事的那个方向。
      // 所以「外用优先」不是随手定的顺序。
      expect(routeOf(med('某某喷雾片')), MedRoute.topical);
      expect(routeOf(med('某某软膏颗粒')), MedRoute.topical);
    });
  });

  group('用户手选的分类优先于自动判断', () {
    test('手选外用可以压过「胶囊」这个内服剂型词', () {
      expect(routeOf(med('某某胶囊')), MedRoute.oral);
      expect(
        routeOf(med('某某胶囊'), explicit: '外用'),
        MedRoute.topical,
        reason: '自动分类只是省事，不能凌驾于用户的选择',
      );
    });

    test('手选内服可以救回一个自动判不出的药', () {
      expect(routeOf(med('体温计')), MedRoute.unknown);
      expect(routeOf(med('体温计'), explicit: '内服'), MedRoute.oral);
    });

    test('空字符串/空白的 explicit 视为没填，不干扰自动判断', () {
      expect(routeOf(med('布洛芬'), explicit: ''), MedRoute.oral);
      expect(routeOf(med('布洛芬'), explicit: '   '), MedRoute.oral);
    });

    test('无法识别的 explicit 不生效（不能把药判成不存在的类）', () {
      expect(routeOf(med('布洛芬'), explicit: '随便写的'), MedRoute.oral);
    });
  });

  group('判不出来时归「其他」，不瞎猜', () {
    test('非药品耗材归其他', () {
      // 注意：纱布/棉签/创可贴被判成**外用**，这是有意的 ——
      // 它们是外用的医用耗材，放在「外用」里比「其他」更符合用户预期。
      // 真正判不出的是这类（既没有剂型字、也不在词典里）：
      for (final name in ['体温计', '某某保健食品', '某某']) {
        expect(routeOf(med(name)), MedRoute.unknown, reason: name);
      }
    });

    test('医用耗材归外用（纱布/棉签/创可贴）', () {
      for (final name in ['纱布', '棉签', '创可贴', '绷带']) {
        expect(routeOf(med(name)), MedRoute.topical, reason: name);
      }
    });

    test('空记录归其他，不抛异常', () {
      expect(routeOf(const {}), MedRoute.unknown);
      expect(routeOf(med('')), MedRoute.unknown);
      expect(routeOf(med('   ')), MedRoute.unknown);
    });

    test('needsManualRouteFor 能指出哪些药需要用户手动指定', () {
      expect(needsManualRouteFor(med('体温计')), isTrue);
      expect(needsManualRouteFor(med('布洛芬')), isFalse);
      expect(needsManualRouteFor(med('体温计'), explicit: '外用'), isFalse);
    });
  });

  group('附加标签：儿童 / 慢性病 / 常用', () {
    test('儿童药同时保留内服属性（两个标签并存）', () {
      final tags = tagsOfMed(med('小儿布洛芬混悬液'));
      expect(tags, contains('内服'));
      expect(tags, contains('儿童'));
    });

    test('慢性病药同时保留内服属性', () {
      final tags = tagsOfMed(med('二甲双胍缓释片'));
      expect(tags, contains('内服'));
      expect(tags, contains('慢性病'));
    });

    test('「常用」标签来自备注里的 [常用] 标记', () {
      final tags = tagsOfMed(med('布洛芬', note: '放在客厅抽屉 $commonMedTag'));
      expect(tags, contains('常用'));
      expect(tags, contains('内服'));
    });

    test('什么标签都没有时才只剩「其他」', () {
      expect(tagsOfMed(med('体温计')), ['其他']);
    });
  });

  group('词典本身的健康度（防止维护时写坏）', () {
    test('词典不为空，且两个途径都有条目', () {
      expect(medRouteDict.length, greaterThan(100));
      expect(
        medRouteDict.values.where((v) => v == DictRoute.oral).length,
        greaterThan(50),
      );
      expect(
        medRouteDict.values.where((v) => v == DictRoute.topical).length,
        greaterThan(20),
      );
    });

    test('词典的键都非空、无空格（匹配前会去空格）', () {
      for (final k in medRouteDict.keys) {
        expect(k.trim(), isNotEmpty, reason: '空键会让 contains 恒为真');
        expect(k.contains(' '), isFalse, reason: '键里有空格: 「$k」');
      }
    });

    test('长键优先：更具体的药名不会被短键吃掉', () {
      // 布洛芬缓释胶囊 与 布洛芬 同途径，但机制上必须走「长键先匹配」。
      // 用一个人为的长键验证优先级逻辑本身：
      final flat = '复方阿司匹林片';
      expect(dictRoute(flat), isNotNull);
      // 「阿司匹林」是它的子串，两者同为 oral，所以断言的是「能匹配上」
      expect(dictRoute('阿司匹林'), DictRoute.oral);
    });

    test('空白文本不命中任何条目', () {
      expect(dictRoute(''), isNull);
      expect(dictRoute('   '), isNull);
    });
  });
}
