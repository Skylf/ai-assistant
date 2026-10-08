import 'package:flutter/material.dart';

import '../theme.dart';

/// 极简 Markdown 渲染，用于 AI 回复。
///
/// 旧版本把原始 Markdown（`## 标题`、`**重点**`）直接当纯文本显示，
/// 0.2B 评审里点名这会破坏成品感。这里不引入额外依赖，只做安全、无副作用的
/// 降级渲染：标题 / 列表 / 分隔线 / 行内加粗，其余按普通段落输出。
class SimpleMarkdown extends StatelessWidget {
  const SimpleMarkdown(this.source, {super.key, this.baseStyle});

  final String source;
  final TextStyle? baseStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = baseStyle ?? theme.textTheme.bodyMedium ?? const TextStyle();
    final blocks = _blocks(source);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: Gap.x2),
          _render(context, blocks[i], body, theme),
        ],
      ],
    );
  }

  Widget _render(
    BuildContext context,
    _Block block,
    TextStyle body,
    ThemeData theme,
  ) {
    switch (block.kind) {
      case _Kind.heading:
        return Text(
          block.text,
          style: body.copyWith(fontWeight: FontWeight.w700, fontSize: 16),
        );
      case _Kind.bullet:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7, right: Gap.x2),
              child: Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  color: Tone.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Expanded(child: _inline(block.text, body)),
          ],
        );
      case _Kind.numbered:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${block.index}.',
                style: body.copyWith(
                  color: Tone.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(child: _inline(block.text, body)),
          ],
        );
      case _Kind.rule:
        return const Divider(height: Gap.x4);
      case _Kind.paragraph:
        return _inline(block.text, body);
    }
  }

  /// 行内 `**加粗**` 与反引号处理。
  static Widget _inline(String text, TextStyle body) {
    final parts = text.split('**');
    if (parts.length == 1) {
      return Text(_stripCode(text), style: body);
    }
    return Text.rich(
      TextSpan(
        style: body,
        children: [
          for (var i = 0; i < parts.length; i++)
            TextSpan(
              text: _stripCode(parts[i]),
              style: i.isOdd ? const TextStyle(fontWeight: FontWeight.w700) : null,
            ),
        ],
      ),
    );
  }

  static String _stripCode(String text) => text.replaceAll('`', '');

  static List<_Block> _blocks(String source) {
    final result = <_Block>[];
    var counter = 0;
    for (final raw in source.split('\n')) {
      final line = raw.trimRight();
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        counter = 0;
        continue;
      }
      if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
        result.add(const _Block(_Kind.rule, ''));
        counter = 0;
        continue;
      }
      final heading = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        result.add(_Block(_Kind.heading, heading.group(1)!.trim()));
        counter = 0;
        continue;
      }
      final bullet = RegExp(r'^[-*+]\s+(.*)$').firstMatch(trimmed);
      if (bullet != null) {
        result.add(_Block(_Kind.bullet, bullet.group(1)!.trim()));
        continue;
      }
      final numbered = RegExp(r'^(\d+)[.)]\s+(.*)$').firstMatch(trimmed);
      if (numbered != null) {
        counter = int.tryParse(numbered.group(1)!) ?? (counter + 1);
        result.add(
          _Block(_Kind.numbered, numbered.group(2)!.trim(), index: counter),
        );
        continue;
      }
      result.add(_Block(_Kind.paragraph, trimmed));
    }
    return result;
  }
}

enum _Kind { heading, bullet, numbered, paragraph, rule }

class _Block {
  const _Block(this.kind, this.text, {this.index = 0});

  final _Kind kind;
  final String text;
  final int index;
}
