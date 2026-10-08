import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../core/util.dart';
import '../theme.dart';

/// 页面主标题（示例图中「家庭账本」「AI 助手」这类大标题 + 副标题）。
class PageTitle extends StatelessWidget {
  const PageTitle(
    this.title, {
    super.key,
    this.caption = '',
    this.trailing,
  });

  final String title;
  final String caption;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x4, Gap.page, Gap.x3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              if (caption.isNotEmpty) ...[
                const SizedBox(height: Gap.x1 + 2),
                Text(caption, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: Gap.x2), trailing!],
      ],
    ),
  );
}

/// 二级页面顶栏：圆形返回键 + 标题。
class DetailHeader extends StatelessWidget {
  const DetailHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x3, Gap.page, Gap.x2),
    child: Row(
      children: [
        _CircleButton(
          icon: Icons.arrow_back,
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: Gap.x3),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Tone.surface,
      shape: const CircleBorder(side: BorderSide(color: Tone.outline)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(Gap.x2 + 2),
          child: Icon(icon, size: 20, color: Tone.textPrimary),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 页面头图：渐变背景 + 大字标题 + 右侧插图位。
///
/// 示例图中每个主页面顶部都有一张带插图的头图。插图暂用内置图形组合代替，
/// 若后续提供图片资源，只需替换 [_HeroArt]。
class HeroBanner extends StatelessWidget {
  const HeroBanner({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.accent = Tone.primary,
    this.accentContainer = Tone.primaryContainer,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final Color accentContainer;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: const BorderRadius.vertical(
      bottom: Radius.circular(28),
    ),
    child: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Tone.heroGradient,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -40,
            top: -30,
            child: _Blob(size: 150, color: accentContainer.withValues(alpha: .5)),
          ),
          Positioned(
            right: 36,
            bottom: -46,
            child: _Blob(size: 96, color: accentContainer.withValues(alpha: .38)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x5, Gap.page, Gap.x5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (eyebrow.isNotEmpty) ...[
                        Text(
                          eyebrow,
                          style: const TextStyle(
                            color: Tone.iconSlateSoft,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: Gap.x2),
                      ],
                      Text(
                        title,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: Gap.x2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Tone.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Gap.x3),
                _HeroArt(icon: icon, accent: accent),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Blob extends StatelessWidget {
  const _Blob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// 头图右侧的插图占位：圆形底 + 主图标 + 装饰点。
class _HeroArt extends StatelessWidget {
  const _HeroArt({required this.icon, required this.accent});

  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 96,
    height: 96,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .75),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white),
          ),
        ),
        Icon(icon, size: 42, color: accent),
        Positioned(
          top: 4,
          right: 6,
          child: _Dot(color: accent.withValues(alpha: .35)),
        ),
        Positioned(
          bottom: 10,
          left: 0,
          child: _Dot(color: accent.withValues(alpha: .22)),
        ),
      ],
    ),
  );
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// 圆形图标块。示例图里每个列表项、统计项前面都是这种彩色圆底图标。
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.tint = Tone.tintBlue,
    this.color = Tone.iconBlue,
    this.size = 44,
    this.iconSize = 22,
  });

  final IconData icon;
  final Color tint;
  final Color color;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
    child: Icon(icon, size: iconSize, color: color),
  );
}

/// 统计项：大数字 + 标签 + 可选补充说明（如「30 天内」）。
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.sublabel = '',
    this.valueColor = Tone.primary,
    this.tint = Tone.tintBlue,
    this.onTap,
  });

  final String value;
  final String label;
  final String sublabel;
  final Color valueColor;
  final Color tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.x3, horizontal: Gap.x1),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
            child: Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: valueColor,
              ),
            ),
          ),
          const SizedBox(height: Gap.x2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: Tone.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (sublabel.isNotEmpty) ...[
            const SizedBox(height: Gap.hairline),
            Text(sublabel, style: Theme.of(context).textTheme.labelSmall),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Gap.x3),
      child: content,
    );
  }
}

/// 首页「快捷功能」里的图标按钮块。
class QuickTile extends StatelessWidget {
  const QuickTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tint = Tone.tintBlue,
    this.color = Tone.iconBlue,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color tint;
  final Color color;

  @override
  Widget build(BuildContext context) => Material(
    color: Tone.surfaceMuted,
    borderRadius: BorderRadius.circular(Gap.x4),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Gap.x4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconTile(icon: icon, tint: tint, color: color, size: 40),
            const SizedBox(height: Gap.x3),
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Gap.hairline),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ),
  );
}

/// 主题选择卡（AI 页「账本分析 / 健康科普」）。
class TopicCard extends StatelessWidget {
  const TopicCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? Tone.primaryContainer : Tone.surface,
    borderRadius: BorderRadius.circular(Gap.x4),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Gap.x4),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.x4,
          vertical: Gap.x3 + 2,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Gap.x4),
          border: Border.all(
            color: selected ? Tone.selectedChip : Tone.outline,
          ),
        ),
        child: Row(
          children: [
            IconTile(
              icon: icon,
              size: 34,
              iconSize: 18,
              tint: selected ? Colors.white : Tone.surfaceMuted,
              color: selected ? Tone.primary : Tone.textSecondary,
            ),
            const SizedBox(width: Gap.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: selected ? Tone.primary : Tone.textPrimary,
                    ),
                  ),
                  const SizedBox(height: Gap.hairline),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 可横向滚动的筛选胶囊（示例图里的「全部 / 日常 / 餐饮 …」）。
class FilterPills extends StatelessWidget {
  const FilterPills({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: Gap.page),
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: padding,
      itemCount: options.length,
      separatorBuilder: (context, index) => const SizedBox(width: Gap.x2),
      itemBuilder: (context, index) {
        final option = options[index];
        final isActive = option == selected;
        final style = Categories.of(option);
        return GestureDetector(
          onTap: () => onSelected(option),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: Gap.x4),
            decoration: BoxDecoration(
              color: isActive ? Tone.primary : Tone.surfaceMuted,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              option,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: isActive
                    ? Colors.white
                    : (option == '全部' ? Tone.textSecondary : style.color),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// 表单字段：标签在输入框上方，符合示例图的现代表单样式。
///
/// 支持必填星号、选填标记、前置图标、字数计数与只读选择器模式。
class FormField2 extends StatefulWidget {
  const FormField2({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.required = false,
    this.optional = false,
    this.leadingIcon,
    this.maxLength,
    this.keyboardType,
    this.digitsOnly = false,
    this.maxLines = 1,
    this.onTap,
    this.readOnly = false,
    this.obscure = false,
    this.trailingText = '',
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool required;
  final bool optional;
  final IconData? leadingIcon;
  final int? maxLength;
  final TextInputType? keyboardType;
  final bool digitsOnly;
  final int maxLines;
  final VoidCallback? onTap;
  final bool readOnly;
  final bool obscure;

  /// 输入框右侧固定文案（例如「人民币」）。
  final String trailingText;

  @override
  State<FormField2> createState() => _FormField2State();
}

class _FormField2State extends State<FormField2> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant FormField2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counter = widget.maxLength == null
        ? null
        : '${widget.controller.text.characters.length}/${widget.maxLength}';

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(widget.label, style: theme.textTheme.bodySmall),
              if (widget.required)
                const Text(
                  ' *',
                  style: TextStyle(color: Tone.error, fontSize: 13),
                ),
              const Spacer(),
              if (widget.optional)
                Text('选填', style: theme.textTheme.labelSmall)
              else if (widget.trailingText.isNotEmpty)
                Text(widget.trailingText, style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: Gap.x2 - 2),
          TextField(
            controller: widget.controller,
            keyboardType: widget.keyboardType,
            readOnly: widget.readOnly,
            onTap: widget.onTap,
            obscureText: widget.obscure,
            maxLines: widget.obscure ? 1 : widget.maxLines,
            maxLength: widget.maxLength,
            inputFormatters: widget.digitsOnly
                ? [FilteringTextInputFormatter.digitsOnly]
                : null,
            decoration: InputDecoration(
              hintText: widget.hint,
              counterText: '',
              prefixIcon: widget.leadingIcon == null
                  ? null
                  : Icon(widget.leadingIcon, size: 20),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 44,
                minHeight: 20,
              ),
              suffixIcon: widget.readOnly
                  ? const Icon(Icons.chevron_right, size: 20)
                  : (counter == null
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(right: Gap.x3),
                            child: Center(
                              widthFactor: 1,
                              child: Text(
                                counter,
                                style: theme.textTheme.labelSmall,
                              ),
                            ),
                          )),
            ),
          ),
        ],
      ),
    );
  }
}

/// 可选值行：标签在上、下方是一个可点击的选择器（日期、储存条件等）。
///
/// 与 [FormField2] 的区别是它没有输入焦点，只是一个「点了就弹选择器」的行，
/// 对应示例图里的「日期 / 储存条件」字段。
class SelectField extends StatelessWidget {
  const SelectField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.hint = '请选择',
    this.icon = Icons.event_outlined,
    this.required = false,
    this.optional = false,
    this.trailingLabel = '',
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final String hint;
  final IconData icon;
  final bool required;
  final bool optional;

  /// 右侧补充说明（例如「点击选择」）。
  final String trailingLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasValue = value.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              if (required)
                const Text(
                  ' *',
                  style: TextStyle(color: Tone.error, fontSize: 13),
                ),
              const Spacer(),
              if (optional)
                Text('选填', style: theme.textTheme.labelSmall)
              else if (trailingLabel.isNotEmpty)
                Text(trailingLabel, style: theme.textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: Gap.x2 - 2),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Gap.inputRadius),
            child: Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: Gap.x3),
              decoration: BoxDecoration(
                color: Tone.cardSubtle,
                borderRadius: BorderRadius.circular(Gap.inputRadius),
                border: Border.all(color: Tone.outline),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: Tone.textSecondary),
                  const SizedBox(width: Gap.x3),
                  Expanded(
                    child: Text(
                      hasValue ? value : hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        color: hasValue ? Tone.textPrimary : Tone.textTertiary,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: Tone.textTertiary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 数量步进器（示例图「库存数量」的 − 1 +）。
class CountStepper extends StatelessWidget {
  const CountStepper({
    super.key,
    required this.controller,
    this.min = 0,
    this.max = 9999,
  });

  final TextEditingController controller;
  final int min;
  final int max;

  void _bump(int delta) {
    final current = int.tryParse(controller.text.trim()) ?? min;
    final next = (current + delta).clamp(min, max);
    controller.text = '$next';
  }

  @override
  Widget build(BuildContext context) => Container(
    height: 52,
    decoration: BoxDecoration(
      color: Tone.cardSubtle,
      borderRadius: BorderRadius.circular(Gap.inputRadius),
      border: Border.all(color: Tone.outline),
    ),
    child: Row(
      children: [
        _StepButton(icon: Icons.remove, onTap: () => _bump(-1), tooltip: '减少'),
        Expanded(
          child: TextField(
            controller: controller,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Tone.textPrimary,
            ),
          ),
        ),
        _StepButton(icon: Icons.add, onTap: () => _bump(1), tooltip: '增加'),
      ],
    ),
  );
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Gap.x3),
      child: SizedBox(
        width: 48,
        height: 50,
        child: Icon(icon, size: 20, color: Tone.primary),
      ),
    ),
  );
}

/// 底部抽屉容器：顶部把手 + 标题 + 副标题 + 可滚动内容 + 常驻双按钮底栏。
///
/// 内容区用 [Flexible] + [SingleChildScrollView] 包裹，底栏单独放在 Column 末尾：
/// 表单字段多、屏幕又矮（例如 360×800）时，只有内容区滚动，取消 / 保存按钮
/// 始终贴在抽屉底部可点。曾经整个抽屉共用一个 ScrollView，矮屏上按钮会被推到
/// 视口之外，用户根本点不到。
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    required this.title,
    required this.children,
    required this.onSubmit,
    this.subtitle = '',
    this.submitLabel = '保存',
    this.cancelLabel = '取消',
    this.onDelete,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final VoidCallback onSubmit;
  final String submitLabel;
  final String cancelLabel;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: Gap.page,
      right: Gap.page,
      top: Gap.x3,
      bottom: MediaQuery.viewInsetsOf(context).bottom + Gap.page,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Tone.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: Gap.x4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: Gap.x1 + 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            if (onDelete != null)
              Tooltip(
                message: '删除',
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onDelete,
                  child: Container(
                    padding: const EdgeInsets.all(Gap.x2 + 2),
                    decoration: const BoxDecoration(
                      color: Tone.tintRed,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: Tone.error,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: Gap.x1),
            Tooltip(
              message: '关闭',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.of(context).maybePop(),
                child: Container(
                  padding: const EdgeInsets.all(Gap.x2 + 2),
                  decoration: const BoxDecoration(
                    color: Tone.surfaceMuted,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    size: 20,
                    color: Tone.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.x5),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
        const SizedBox(height: Gap.x3),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: Tone.surfaceMuted,
                  side: BorderSide.none,
                  foregroundColor: Tone.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Gap.inputRadius),
                  ),
                ),
                child: Text(cancelLabel),
              ),
            ),
            const SizedBox(width: Gap.x3),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: onSubmit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Gap.inputRadius),
                  ),
                ),
                child: Text(submitLabel),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// 空状态：图标 + 主文案 + 补充说明 + 可选按钮。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.detail = '',
    this.icon = Icons.inbox_outlined,
    this.actionLabel = '',
    this.onAction,
  });

  final String title;
  final String detail;
  final IconData icon;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: Gap.page,
      vertical: Gap.x5,
    ),
    child: Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: const BoxDecoration(
            color: Tone.surfaceMuted,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 36, color: Tone.textTertiary),
        ),
        const SizedBox(height: Gap.x4),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (detail.isNotEmpty) ...[
          const SizedBox(height: Gap.x2),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (actionLabel.isNotEmpty && onAction != null) ...[
          const SizedBox(height: Gap.x4),
          FilledButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.add, size: 18),
            label: Text(actionLabel),
          ),
        ],
      ],
    ),
  );
}

/// 设置分组：组标题 + 一张卡片内的多行。
///
/// 对应示例图里「AI 服务」「数据与隐私」这种分组卡片。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.x4, Gap.page, Gap.x2),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.page),
        child: Card(
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1)
                  const Divider(height: 1, indent: 72),
              ],
            ],
          ),
        ),
      ),
    ],
  );
}

/// 设置分组内的一行：彩色图标块 + 标题 + 副标题 + 右侧说明 + 箭头。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.tint = Tone.tintBlue,
    this.color = Tone.iconBlue,
    this.trailingText = '',
    this.trailing,
    this.titleColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color tint;
  final Color color;
  final String trailingText;
  final Widget? trailing;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Gap.x4,
        vertical: Gap.x3 + 2,
      ),
      child: Row(
        children: [
          IconTile(icon: icon, tint: tint, color: color),
          const SizedBox(width: Gap.x3 + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: Gap.hairline + 1),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
          if (trailingText.isNotEmpty) ...[
            const SizedBox(width: Gap.x2),
            Text(
              trailingText,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: Gap.x2),
            trailing!,
          ],
          if (onTap != null || trailing != null) ...[
            const SizedBox(width: Gap.x1),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: Tone.textTertiary,
            ),
          ],
        ],
      ),
    ),
  );
}

/// 纯信息弹窗。
Future<void> infoDialog(
  BuildContext context,
  String title,
  String content,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(title),
    content: SingleChildScrollView(child: Text(content)),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('知道了'),
      ),
    ],
  ),
);

/// 二次确认弹窗。返回 true 表示用户确认。
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = '确认',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: Tone.error)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 统一的提示条。
void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// 药品有效期的语义化描述与配色。
///
/// 文案一律是**「还有多久」**，不重复日期本身。
///
/// 早先 `> 90 天` 这一档返回的是「有效期 2027-05-01」（直接把日期塞进状态文字），
/// 而药品详情页的状态卡里**另有一格**专门显示「有效期 2027-05-01」——
/// 于是一张卡上同一个日期出现两次，而且状态行本来该回答的是「还有多久」。
/// 状态说时间、字段说日期，两者各司其职。
({String text, Color color}) expiryBadge(
  Map<String, dynamic> med,
  DateTime now,
) {
  final info = ExpiryInfo.parse(med['expiry']);
  final left = info.daysLeft(now);
  if (left == null) {
    return (text: '未填写有效期', color: Tone.textSecondary);
  }
  if (left < 0) return (text: '已过期 ${-left} 天', color: Tone.error);
  if (left == 0) return (text: '今天到期', color: Tone.error);
  if (left <= 30) return (text: '即将过期 · $left 天', color: Tone.warning);
  if (left <= 90) return (text: '还有 $left 天到期', color: Tone.info);
  return (text: '还有 $left 天到期', color: Tone.textSecondary);
}

/// 长按条目的操作。
enum EntryAction { edit, delete }

/// 长按条目的「修改 / 删除」菜单。
Future<EntryAction?> entryActionSheet(BuildContext context) =>
    showModalBottomSheet<EntryAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('修改'),
              onTap: () => Navigator.of(sheetContext).pop(EntryAction.edit),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Tone.error),
              title: const Text('删除', style: TextStyle(color: Tone.error)),
              onTap: () => Navigator.of(sheetContext).pop(EntryAction.delete),
            ),
          ],
        ),
      ),
    );

/// 圆形 AI 头像，用于欢迎卡片与助手消息。
///
/// [tint] / [color] 让不同模式的 AI 有各自的配色（账本偏蓝、健康偏青），
/// 使两个模块在视觉上也能一眼区分。
class AssistantAvatar extends StatelessWidget {
  const AssistantAvatar({
    super.key,
    this.size = 34,
    this.icon = Icons.smart_toy_outlined,
    this.tint = Tone.primaryContainer,
    this.color = Tone.primary,
  });

  final double size;
  final IconData icon;
  final Color tint;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
    child: Icon(icon, size: size * .6, color: color),
  );
}
