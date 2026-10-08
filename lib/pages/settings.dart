import 'package:flutter/material.dart';

import '../data/store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'api_config.dart';
import 'chat_settings.dart';
import 'custom_prompt.dart';
import 'data_settings.dart';
import 'help.dart';
import 'memory.dart';
import 'password_tool.dart';
import 'update.dart';
import 'widget_settings.dart';

/// 界面展示的版本号。
///
/// 版本号规则：**开发版用字母，正式版用数字。**
///
/// | 写法 | 含义 |
/// | --- | --- |
/// | `0.4A` `0.4B` `0.4C` | 0.4 阶段的开发版，小更新依次用 A/B/C |
/// | `0.4` | 0.4 阶段的正式版（正式发布才去掉字母） |
/// | `0.5.1` `0.5.2` `0.5.3` | 0.5 阶段的发行版，小更新递增末位 |
///
/// 与 `pubspec.yaml` 的关系：Android 的 versionName 不接受字母，所以开发版时期
/// 那里写 `0.4.0` 表示同一个版本，两者的 `<major>.<minor>` 必须一致（由
/// `test/version_consistency_test.dart` 断言）。
///
/// 「检查更新」用它和更新清单比对：[UpdateChecker.compareVersions] 明确支持
/// `0.3A` 这类带字母的写法（字母段按字母序比较，数字段按数值比较），
/// 所以开发代号可以直接用来比大小，不必为了比较而改成三段式数字。
///
/// 改动这里时必须同步三处：`pubspec.yaml` 的 `version:`（并把 `versionCode`
/// 加一，否则 Android 拒绝覆盖安装）、[Changelog.entries] 的第一条、
/// 以及 `test/update_test.dart` 里的清单样例。`test/version_consistency_test.dart`
/// 会拦截漏改。
///
/// ⚠️ 「当前版本」那一行显示的是 `$appVersion 发行版`。**发行版不能再写「开发版」**
/// —— 0.5.1 之后这个字串漏改过一次（版本号升到 `0.5.1` 了，标签还写着「开发版」），
/// 界面上等于对用户说错话。`test/version_consistency_test.dart` 现在会拦它。
const appVersion = '0.5.4';

/// 设置页：多级信息架构（0.2B 评审要求）。
///
/// 一级页按「账户与 AI / 数据与隐私 / 实用工具 / 关于」分组，二级页各自独立，
/// 每行使用语义化的彩色圆角图标；不再把所有开关都堆在一屏里。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.store});

  final Store store;

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.only(bottom: Gap.x5),
      children: [
        const PageTitle('设置', caption: '按你的习惯调整这个应用'),
        SettingsGroup(
          title: '账户与 AI',
          children: [
            SettingsRow(
              icon: Icons.auto_awesome,
              tint: Tone.tintTeal,
              color: Tone.iconTeal,
              title: 'AI 服务',
              subtitle: store.hasApiKey
                  ? '已配置 · ${store.model}'
                  : '未配置 API Key，AI 功能不可用',
              onTap: () => _push(context, AiConfigPage(store: store)),
            ),
            SettingsRow(
              icon: Icons.tune,
              tint: Tone.tintBlue,
              color: Tone.iconBlue,
              title: 'AI 对话设置',
              subtitle: '主题识别与记忆机制说明',
              onTap: () => _push(context, ChatSettingsPage(store: store)),
            ),
            SettingsRow(
              icon: Icons.edit_note,
              tint: Tone.tintPurple,
              color: Tone.iconPurple,
              title: '我的提示词',
              subtitle: '为账本与健康主题补充专属要求',
              onTap: () => _push(context, CustomPromptPage(store: store)),
            ),
          ],
        ),
        SettingsGroup(
          title: '数据与隐私',
          children: [
            SettingsRow(
              icon: Icons.folder_outlined,
              tint: Tone.tintGreen,
              color: Tone.iconGreen,
              title: '数据管理',
              subtitle: '查看本地数据量、导出与清空',
              onTap: () => _push(context, DataSettingsPage(store: store)),
            ),
            SettingsRow(
              icon: Icons.psychology_outlined,
              tint: Tone.tintAmber,
              color: Tone.iconAmber,
              title: '全局记忆',
              subtitle: store.globalMemory.trim().isEmpty
                  ? '未设置 · 可记录长期偏好'
                  : '已设置 · ${store.globalMemory.trim().length} 字',
              onTap: () => _push(context, GlobalMemoryPage(store: store)),
            ),
            const SettingsRow(
              icon: Icons.shield_outlined,
              tint: Tone.tintSlate,
              color: Tone.iconSlate,
              title: '隐私说明',
              subtitle: '数据仅保存在本机，密钥存于系统安全区',
            ),
          ],
        ),
        SettingsGroup(
          title: '实用工具',
          children: [
            SettingsRow(
              icon: Icons.widgets_outlined,
              tint: Tone.tintTeal,
              color: Tone.iconTeal,
              title: '桌面组件',
              subtitle: '在桌面直接记账、记药，共四种组件',
              onTap: () => _push(context, WidgetSettingsPage(store: store)),
            ),
            SettingsRow(
              icon: Icons.password,
              tint: Tone.tintBlue,
              color: Tone.iconBlue,
              title: '密码生成器',
              subtitle: '生成高强度密码与口令，可本地保存',
              trailingText: store.savedPasswords.isEmpty
                  ? ''
                  : '${store.savedPasswords.length} 条记录',
              onTap: () => _push(context, PasswordToolPage(store: store)),
            ),
          ],
        ),
        SettingsGroup(
          title: '关于',
          children: [
            SettingsRow(
              icon: Icons.system_update_alt,
              tint: Tone.tintBlue,
              color: Tone.iconBlue,
              title: '检查更新',
              subtitle: '与更新源比对版本，并查看各版本更新日志',
              onTap: () => _push(context, UpdatePage(store: store)),
            ),
            SettingsRow(
              icon: Icons.info_outline,
              tint: Tone.tintSlate,
              color: Tone.iconSlate,
              title: '使用说明',
              subtitle: '三分钟了解全部功能',
              onTap: () => _push(context, const HelpPage()),
            ),
            const SettingsRow(
              icon: Icons.verified_outlined,
              tint: Tone.tintGreen,
              color: Tone.iconGreen,
              title: '当前版本',
              subtitle: '家庭生活助手',
              trailingText: '$appVersion 发行版',
            ),
          ],
        ),
        const SizedBox(height: Gap.x4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: Text(
            '本应用的数据全部保存在你的设备上。AI 分析仅在你配置 API Key 并主动提问时'
            '才会把必要的账目 / 药箱摘要发送给模型服务商。',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    ),
  );
}

/// 二级设置页统一外壳：返回顶栏 + 说明文字 + 内容。
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    this.caption = '',
  });

  final String title;
  final String caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: Gap.x5),
        children: [
          DetailHeader(title),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.x2),
              child: Text(
                caption,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ...children,
        ],
      ),
    ),
  );
}
