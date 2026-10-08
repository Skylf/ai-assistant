import 'package:family_life_assistant/widgets/markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, String source) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SimpleMarkdown(source))),
  );

  testWidgets('去掉 Markdown 标记只留正文', (tester) async {
    await pump(tester, '**重点** 和 `code`');
    expect(find.text('重点 和 code'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('`'), findsNothing);
  });

  testWidgets('标题去掉井号', (tester) async {
    await pump(tester, '## 本月趋势');
    expect(find.text('本月趋势'), findsOneWidget);
  });

  testWidgets('列表项去掉项目符号', (tester) async {
    await pump(tester, '- 餐饮\n- 交通');
    expect(find.text('餐饮'), findsOneWidget);
    expect(find.text('交通'), findsOneWidget);
    expect(find.textContaining('- 餐饮'), findsNothing);
  });

  testWidgets('有序列表保留序号', (tester) async {
    await pump(tester, '1. 第一步\n2. 第二步');
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('第一步'), findsOneWidget);
    expect(find.text('第二步'), findsOneWidget);
  });

  testWidgets('分隔线渲染为 Divider', (tester) async {
    await pump(tester, '上文\n---\n下文');
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('纯文本原样显示', (tester) async {
    await pump(tester, '本月没有异常支出。');
    expect(find.text('本月没有异常支出。'), findsOneWidget);
  });

  testWidgets('空输入不抛异常', (tester) async {
    await pump(tester, '');
    expect(tester.takeException(), isNull);
  });
}
