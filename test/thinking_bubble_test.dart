import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:family_life_assistant/ai/web_search.dart';
import 'package:family_life_assistant/core/chat_mode.dart';
import 'package:family_life_assistant/widgets/chat_widgets.dart';

/// 0.4F：思考气泡要**如实**反映「正在联网搜索」。
///
/// 用户原话：「**思考文字要体现出正在联网搜索**」。
///
/// 这个需求的难点不在显示那句话，而在**什么时候不显示**：
/// 0.4D 的教训就是界面在描述一件没发生的事（文案说「未真正联网核实」，
/// 而那条分支从未执行过）。所以这一组测试里的**否定断言比肯定断言更重要**。
void main() {
  Future<void> pump(WidgetTester tester, SearchPhase? phase) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThinkingBubble(seconds: 3, mode: ChatMode.health, phase: phase),
        ),
      ),
    );
  }

  testWidgets('【关键】联网阶段显示「正在联网搜索…」并带联网图标', (tester) async {
    await pump(tester, SearchPhase.searching);

    expect(find.text('正在联网搜索…'), findsOneWidget);
    // 图标是给「扫一眼」用的：用户不必读字就知道它在联网
    expect(find.byIcon(Icons.travel_explore_outlined), findsOneWidget);
  });

  testWidgets('【关键】非联网阶段不许出现「联网」字样，也不带联网图标', (tester) async {
    for (final phase in [
      null,
      SearchPhase.thinking,
      SearchPhase.composing,
    ]) {
      await pump(tester, phase);

      expect(
        find.textContaining('联网'),
        findsNothing,
        reason: 'phase=$phase 时界面不该说在联网（说了就是在演）',
      );
      expect(
        find.byIcon(Icons.travel_explore_outlined),
        findsNothing,
        reason: 'phase=$phase 时不该出现联网图标',
      );
    }
  });

  testWidgets('三个阶段各自显示自己的文案', (tester) async {
    await pump(tester, SearchPhase.thinking);
    expect(find.text(SearchPhase.thinking.label), findsOneWidget);

    await pump(tester, SearchPhase.composing);
    expect(find.text(SearchPhase.composing.label), findsOneWidget);
  });

  testWidgets('phase 为 null 时退回按模块定义的默认文案（不崩、不留空）', (tester) async {
    await pump(tester, null);

    // 不该出现任何阶段的文案（因为一个阶段都没发生）
    for (final phase in SearchPhase.values) {
      expect(
        find.text(phase.label),
        findsNothing,
        reason: 'phase=null 时不该显示「${phase.label}」',
      );
    }
    // 但气泡里必须**有字**（空白气泡等于界面坏了）
    expect(find.byType(Text), findsWidgets);
  });

  testWidgets('阶段文案会随 phase 变化实时更新', (tester) async {
    await pump(tester, SearchPhase.thinking);
    expect(find.text('正在联网搜索…'), findsNothing);

    await pump(tester, SearchPhase.searching);
    expect(find.text('正在联网搜索…'), findsOneWidget);

    await pump(tester, SearchPhase.composing);
    expect(find.text('正在联网搜索…'), findsNothing);
    expect(find.byIcon(Icons.travel_explore_outlined), findsNothing);
  });

  testWidgets('每个阶段的文案都非空（避免出现空气泡）', (tester) async {
    for (final phase in SearchPhase.values) {
      expect(phase.label.trim(), isNotEmpty, reason: '$phase 的文案是空的');
    }
    // 「正在联网搜索」必须真的带「联网搜索」四个字 —— 用户就是这么要求的
    expect(SearchPhase.searching.label, contains('联网搜索'));
  });
}
