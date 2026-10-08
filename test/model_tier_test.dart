import 'package:flutter_test/flutter_test.dart';
import 'package:family_life_assistant/ai/client.dart';

/// 0.4H：模型档位收敛到 Flash，**不给 Pro 出现在可选项里**。
///
/// 用户原话：「按照你拉取的模型名称来，默认 flash，**不支持 pro**
/// （因为这点货不需要更贵的 pro）」。
///
/// ## 为什么这是「省钱」而不是「省事」
/// 模型选择器把 `/models` 返回的**全部**模型渲染成可点胶囊。只要 Pro 在里面，
/// 就可能被误点一下 —— 而误点的代价是**之后每次请求都按 Pro 计费**，
/// 界面却没有任何提示。从源头上不让它出现，比事后提示更可靠。
void main() {
  group('默认模型', () {
    test('是 deepseek-flash（用户指定、也是 /models 真实返回的名字）', () {
      expect(AiClient.defaultModel, 'deepseek-flash');
    });

    test('不是别名 v4.1 flash —— 用接口返回的真名，避免服务商不认', () {
      expect(AiClient.defaultModel, isNot(contains('v4.1')));
      expect(AiClient.defaultModel, isNot(contains(' ')));
    });
  });

  group('【关键】Pro 不进可选项（省钱的第一道闸）', () {
    test('含 pro 的模型被判为不支持（大小写不敏感）', () {
      for (final id in [
        'deepseek-v4-pro',
        'deepseek-pro',
        'DeepSeek-V5-Pro',
        'some-PRO-model',
      ]) {
        expect(AiClient.isUnsupportedModel(id), isTrue, reason: id);
      }
    });

    test('正常模型不被误判', () {
      for (final id in [
        'deepseek-flash',
        'deepseek-chat',
        'deepseek-reasoner',
        'deepseek-v4-flash',
      ]) {
        expect(AiClient.isUnsupportedModel(id), isFalse, reason: id);
      }
    });

    test('【关键】真实接口列表里 Pro 被滤掉，其余保留', () {
      // 这就是真机《获取可用模型》拉回来的那份列表
      const real = [
        'deepseek-chat',
        'deepseek-reasoner',
        'deepseek-flash',
        'deepseek-v4-pro',
      ];
      final sel = AiClient.selectableModels(real);

      expect(
        sel,
        isNot(contains('deepseek-v4-pro')),
        reason: 'Pro 出现在胶囊里就可能被误点，误点后每次请求都按 Pro 计费',
      );
      expect(sel, contains('deepseek-flash'));
      expect(sel, contains('deepseek-chat'));
      expect(sel, contains('deepseek-reasoner'));
    });

    test('判据是「含 pro」而不是写死名字 —— 将来 v5-pro 也拦得住', () {
      final sel = AiClient.selectableModels(['deepseek-flash', 'deepseek-v9-pro']);
      expect(sel, ['deepseek-flash']);
    });

    test('【边界】万一服务商只剩 Pro，回退显示全部，不能把用户堵死', () {
      // 显示一个空胶囊列表 = 用户在设置页无法选择任何模型，
      // 比「能选到贵的」更糟 —— 至少贵的能跑通。
      final sel = AiClient.selectableModels(['deepseek-v4-pro']);
      expect(sel, ['deepseek-v4-pro']);
    });

    test('空列表不崩', () {
      expect(AiClient.selectableModels(const []), isEmpty);
    });
  });

  group('当前模型该不该被拉回默认', () {
    test('优先 deepseek-flash', () {
      expect(
        AiClient.preferredModel(['deepseek-chat', 'deepseek-flash']),
        'deepseek-flash',
      );
    });

    test('没有 flash 时退而取含 flash 的便宜档', () {
      expect(
        AiClient.preferredModel(['deepseek-chat', 'deepseek-v4-flash']),
        'deepseek-v4-flash',
      );
    });

    test('一个 flash 都没有时取第一个（不返回不存在的名字）', () {
      final sel = ['deepseek-chat', 'deepseek-reasoner'];
      final picked = AiClient.preferredModel(sel);
      expect(sel, contains(picked), reason: '必须返回列表里真实存在的名字');
    });

    test('空列表返回默认值而不是崩', () {
      expect(AiClient.preferredModel(const []), AiClient.defaultModel);
    });
  });
}
