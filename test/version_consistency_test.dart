import 'dart:io';

import 'package:family_life_assistant/core/update.dart';
import 'package:family_life_assistant/pages/settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// 版本号一致性。
///
/// 这个项目里版本号散在三处，历史上因此漂移了两版没人发现：
///
/// | 位置 | 用途 |
/// | --- | --- |
/// | `pubspec.yaml` 的 `version:` | 给 Android 的 `versionName` / `versionCode` |
/// | `lib/pages/settings.dart` 的 `appVersion` | App 内「关于」显示给用户的版本 |
/// | `lib/core/update.dart` 的 `Changelog` | 「关于」页的更新日志 |
///
/// 漂移的后果不是「不好看」，而是**用户装不上新包**：`versionCode` 不递增时
/// Android 会直接拒绝覆盖安装（报「应用未安装」），而更新页明确承诺「覆盖安装后
/// 账本、药箱与对话记录都会保留」。同时系统「应用信息」里显示的版本会与 App 内
/// 显示的版本自相矛盾，用户报障时无法判断他装的是哪个包。
void main() {
  /// 从 pubspec 读出 `version:` 的值，例如 `0.4.1+4`。
  String pubspecVersion() {
    final file = File('pubspec.yaml');
    expect(
      file.existsSync(),
      isTrue,
      reason: '测试的工作目录应该是项目根目录（flutter test 的约定）',
    );
    final line = file
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'), orElse: () => '');
    expect(line, isNotEmpty, reason: 'pubspec.yaml 里必须有 version: 行');
    return line.substring('version:'.length).trim();
  }

  /// 取版本串的数字部分：[leading] 表示取第几段。
  ///
  /// `appVersion` 可能是 `0.4A`，直接 `split('.')` 会得到 `['0','4A']` ——
  /// 第二段带着字母，不能按数字比较。这里只取数字前缀。
  String numericSegment(String version, int index) {
    final segments = version.split('.');
    if (index >= segments.length) return '0';
    final match = RegExp(r'^\d+').firstMatch(segments[index]);
    return match?.group(0) ?? '0';
  }

  group('版本号三处一致', () {
    test('pubspec 的 version 形如 <数字>.<数字>.<数字>+<数字>', () {
      // versionCode 部分（+ 后面）必须是数字：Android 用它判断能否覆盖安装。
      // versionName 只能是数字，所以 App 的开发代号（0.4A）在这里写作 0.4.0。
      expect(
        pubspecVersion(),
        matches(RegExp(r'^\d+\.\d+\.\d+\+\d+$')),
        reason: 'Android 要求 versionName 是三数字、versionCode 是整数',
      );
    });

    test('appVersion 只能是开发代号或三段式数字', () {
      // 版本号规则：开发版用字母（0.4A/0.4B），正式版用数字（0.4），
      // 阶段升级进新数字（0.5A）。历史包袱「0.2.0-c」这种写法不要再出现。
      expect(
        appVersion,
        matches(RegExp(r'^\d+\.\d+([A-Z]|\.[0-9A-Za-z]+)?$')),
        reason: '形如 0.4A（开发版）或 0.4 / 0.4.0（正式版）',
      );
    });

    test('pubspec 的 <major>.<minor> 与 App 内的 appVersion 一致', () {
      // 注意 appVersion 的 minor 可能带字母（0.4A 的「4A」），只比数字部分
      expect(
        '${numericSegment(pubspecVersion(), 0)}.'
        '${numericSegment(pubspecVersion(), 1)}',
        '${numericSegment(appVersion, 0)}.${numericSegment(appVersion, 1)}',
        reason:
            'pubspec 显示在系统「应用信息」里，appVersion 显示在 App 内，'
            '两者不一致时用户报障无法判断装的是哪个包',
      );
    });

    test('开发代号必须能被「检查更新」正确比较', () {
      // appVersion 用带字母的代号是**有意的**（用户要求的开发版规则），
      // 前提是 UpdateChecker.compareVersions 认得它。否则「检查更新」会失效。
      //
      // 比较规则：字母段是「预发布」性质 —— 数字正式版 > 带字母的开发版 >
      // 上一个阶段的版本。所以 0.4A 排在 0.4.0 之前、0.4.1 之后。
      expect(UpdateChecker.compareVersions('0.4B', '0.4A'), greaterThan(0));
      expect(UpdateChecker.compareVersions('0.4A', '0.4A'), 0);
      expect(UpdateChecker.compareVersions('0.4C', '0.4B'), greaterThan(0));
      expect(UpdateChecker.compareVersions('0.5A', '0.4C'), greaterThan(0));
      expect(UpdateChecker.compareVersions('0.4A', '0.3B'), greaterThan(0));
      // 开发版新于上一阶段的版本
      expect(
        UpdateChecker.compareVersions(appVersion, '0.3C'),
        greaterThan(0),
        reason: '开发版应新于上一阶段的版本',
      );
    });

    test('Changelog 最新一条与 App 内 appVersion 一致', () {
      expect(Changelog.latest, appVersion);
    });

    test('versionCode 已越过历史值，后续包才能覆盖安装', () {
      // 0.2C 之后长期停在 2，导致后续 APK 无法覆盖安装。这个下界是「曾经错过」
      // 的见证，低于它说明有人又把版本号改回去了。
      final code = int.parse(pubspecVersion().split('+').last);
      expect(
        code,
        greaterThanOrEqualTo(5),
        reason: 'versionCode 必须严格递增；0.4A 用的是 5',
      );
    });

    test('开发代号的字母是递增的：(A→B→C)，不得回退', () {
      // 「0.4C 之后又出现 0.4A」会让更新页把旧包当成新版
      final changelogDevCodes = Changelog.entries
          .map((e) => e.version)
          .where((v) => RegExp(r'^\d+\.\d+[A-Z]$').hasMatch(v))
          .toList();
      for (var i = 1; i < changelogDevCodes.length; i++) {
        expect(
          UpdateChecker.compareVersions(
            changelogDevCodes[i - 1],
            changelogDevCodes[i],
          ),
          greaterThan(0),
          reason: '${changelogDevCodes[i - 1]} 应新于 ${changelogDevCodes[i]}',
        );
      }
    });

    test('【关键】发行版的「当前版本」那一行不能写着「开发版」', () {
      // 这一条是**真发生过**的：版本号升到 0.5.1（发行版）之后，
      // 设置页「当前版本」那行还写着「0.5.1 开发版」——界面上等于对用户说错话。
      // 数字版却自称开发版，用户报障时会以为自己装的是测试包。
      //
      // 反过来也不行：开发版（带字母）不该自称发行版。
      //
      // ⚠️ 这里**必须只看代码行，不能搜整个文件**。第一版我写的是
      // `source.contains("'\$appVersion 发行版'")`，结果**反向验证不通过**：
      // 我在 appVersion 上方写的说明注释里正好也有 `$appVersion 发行版` 这段文字，
      // 于是无论代码里写的是什么，`contains` 都能命中注释 → 断言恒真 → 白写。
      // （这正是 G8 要防的「测试从不失败」。是反向验证把它抓出来的。）
      //
      // 现在的做法：只取 `trailingText:` 那一行（注释行以 `///` 开头，不会命中），
      // 再看它写的是哪个词。找不到这行就直接失败 —— 免得改版式后断言悄悄失效。
      final codeLine = File('lib/pages/settings.dart')
          .readAsLinesSync()
          .where((l) => l.trimLeft().startsWith('trailingText:'))
          .firstWhere(
            (l) => l.contains('appVersion'),
            orElse: () => '',
          );

      expect(
        codeLine,
        isNotEmpty,
        reason: '设置页里应当有一行 `trailingText: \'\$appVersion …\'`（已改版式？）',
      );

      final isRelease = !RegExp(r'[A-Za-z]').hasMatch(
        appVersion.replaceAll(RegExp(r'^\d+\.\d+'), ''),
      );

      if (isRelease) {
        expect(
          codeLine,
          contains('发行版'),
          reason: 'appVersion 是发行版（$appVersion），不该在界面上自称「开发版」。'
              '当前这一行是：${codeLine.trim()}',
        );
        expect(codeLine, isNot(contains('开发版')));
      } else {
        expect(
          codeLine,
          contains('开发版'),
          reason: 'appVersion 是开发版（$appVersion），应显示「开发版」。'
              '当前这一行是：${codeLine.trim()}',
        );
      }
    });
  });
}
