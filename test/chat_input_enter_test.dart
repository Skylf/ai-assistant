import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:family_life_assistant/core/chat_mode.dart';
import 'package:family_life_assistant/widgets/chat_widgets.dart';

/// 0.4F：AI 聊天输入框**回车换行，不发送**（用户要求）。
///
/// ## 用户报的现象
/// 「ai聊天框打字的时候点击键盘回车不是换行而是发送，改为回车换行」
///
/// 原因：输入框是 `maxLines: 4` 的**多行**框（说明本来就想支持换行），
/// 却配了 `textInputAction: TextInputAction.send` + `onSubmitted: onSend`
/// —— 多行框把换行键抢去当发送键用了，用户想分两段写就没机会。
///
/// ## ⚠️ 一个必须写下来的 Flutter 机制（我在这里判断错过一次）
///
/// 我原以为「改成 `TextInputAction.newline` 之后，回车动作会把 `\n` 插进文本」，
/// 于是写了一条断言：`receiveAction(newline)` 之后文本应为 `'第一行\n'` —— **它失败了**。
///
/// 去读 Flutter 源码（`editable_text.dart` 的 `performAction`）才看清：
///
/// ```dart
/// case TextInputAction.newline:
///   // If this is a multiline EditableText, do nothing for a "newline"
///   // action; The newline is already inserted.
///   if (!_isMultiline) { _finalizeEditing(action, shouldUnfocus: true); }
/// ```
///
/// **换行不是由这个「动作」插进去的**：多行框遇到 `newline` 动作是**故意什么都不做**
/// （换行符早已由平台通过文本更新通道送进来）；只有**单行**框才会把它当「结束编辑」。
///
/// 所以：想断言「换行真的进了文本」**不能用 `receiveAction`**（那是错的模型）。
/// 这组测试改为断言三件能可靠验证的事 ——
/// ① 配置正确（`newline` + 无 `onSubmitted` + 确实是多行框）；
/// ② 原始回车键**不会发送**（用户报的 bug 本身）；
/// ③ 多行内容能原样发出去（换行不会被吃掉）。
/// 真机上的实际换行手感属于人工验收项（见 doc/验收标准.md 的 F18/F19）。
void main() {
  Future<(TextEditingController, List<String>)> pumpBar(
    WidgetTester tester,
  ) async {
    final controller = TextEditingController();
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            busy: false,
            mode: ChatMode.health,
            onSend: () => sent.add(controller.text),
          ),
        ),
      ),
    );
    return (controller, sent);
  }

  Future<void> focusField(WidgetTester tester) async {
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
  }

  testWidgets('【关键】原始回车键不会把消息发出去（用户报的 bug）', (tester) async {
    final (controller, sent) = await pumpBar(tester);
    await focusField(tester);
    await tester.enterText(find.byType(TextField), '第一行');
    await tester.pump();

    // 真机接物理键盘时走的就是原始按键路径
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pumpAndSettle();

    expect(
      sent,
      isEmpty,
      reason: '回车**不能**触发发送 —— 用户就是这么被坑的',
    );
    expect(controller.text, '第一行', reason: '不该因为按回车就丢字');
    expect(
      tester.widget<TextField>(find.byType(TextField)).onSubmitted,
      isNull,
      reason: 'onSubmitted 还在的话，回车仍会被当提交（必须与动作类型成对改）',
    );
  });

  testWidgets('【关键】动作类型是 newline，且确实是多行框', (tester) async {
    await pumpBar(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.textInputAction,
      TextInputAction.newline,
      reason: '改回 send 会让回车重新变成「发送」',
    );
    // Flutter 只在**多行**框上让 newline 动作「什么都不做」（见文件头引的源码）。
    // 若哪天 maxLines 被改成 1，newline 会变成「结束编辑」而不再是换行 —— 所以这条要守。
    expect(
      field.maxLines,
      greaterThan(1),
      reason: '多行框才谈得上换行；单行框的 newline 是「结束编辑」不是换行',
    );
    expect(
      field.minLines,
      1,
      reason: '起始一行高，随内容长高（不要一上来就占四行）',
    );
  });

  testWidgets('newline 动作不会被当成发送（多行框上它是空操作）', (tester) async {
    final (controller, sent) = await pumpBar(tester);
    await focusField(tester);
    await tester.enterText(find.byType(TextField), '第一行');
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pumpAndSettle();

    expect(sent, isEmpty, reason: '换行动作绝不能触发发送');
    expect(controller.text, '第一行', reason: '多行框上这个动作不应改动文本');
  });

  testWidgets('多行内容原样发出去，换行没被吃掉', (tester) async {
    final (controller, sent) = await pumpBar(tester);
    await focusField(tester);

    await tester.enterText(find.byType(TextField), '药名：布洛芬\n问题：有什么禁忌');
    await tester.pump();
    expect(controller.text, contains('\n'), reason: '输入框要能装下换行');

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(sent.length, 1, reason: '点按钮必须能发出去');
    expect(
      sent.single,
      '药名：布洛芬\n问题：有什么禁忌',
      reason: '换行是用户故意敲的，必须原样带进问题里',
    );
  });

  testWidgets('忙态时按钮变成暂停，不会误发', (tester) async {
    final controller = TextEditingController();
    final sent = <String>[];
    var stopped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            busy: true,
            mode: ChatMode.health,
            onSend: () => sent.add(controller.text),
            onStop: () => stopped++,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pumpAndSettle();

    expect(stopped, 1, reason: '忙态点按钮应当是「暂停」');
    expect(sent, isEmpty, reason: '忙态不该把消息发出去');
  });
}
