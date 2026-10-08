import 'package:family_life_assistant/security/password_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final engine = PasswordEngine();

  group('字符池', () {
    test('按勾选的类别拼装', () {
      final pool = engine.poolFor(
        const CharsetOptions(
          lowercase: true,
          uppercase: false,
          digits: false,
          symbols: false,
        ),
      );
      expect(pool, PasswordEngine.lowercaseChars);
    });

    test('排除易混淆字符后池里不含 0 O o I l 1 |', () {
      final pool = engine.poolFor(
        const CharsetOptions(excludeAmbiguous: true),
      );
      for (final char in ['0', 'O', 'o', 'I', 'l', '1', '|', '`']) {
        expect(pool.contains(char), isFalse, reason: '字符池仍包含 $char');
      }
      expect(pool, isNotEmpty);
    });

    test('全部类别都关闭时池为空', () {
      final pool = engine.poolFor(
        const CharsetOptions(
          lowercase: false,
          uppercase: false,
          digits: false,
          symbols: false,
        ),
      );
      expect(pool, isEmpty);
      expect(
        const CharsetOptions(
          lowercase: false,
          uppercase: false,
          digits: false,
          symbols: false,
        ).hasAny,
        isFalse,
      );
    });
  });

  group('生成随机密码', () {
    test('长度与字符集都符合要求', () {
      for (final length in [4, 8, 16, 32, 64]) {
        final password = engine.generate(
          length: length,
          options: const CharsetOptions(),
        );
        expect(password.length, length);
        expect(RegExp(r'^[A-Za-z0-9!@#\$%^&*()\-_=+\[\]{};:,.?/~]+$').hasMatch(password), isTrue);
      }
    });

    test('勾选「每类至少一次」时四类字符都出现', () {
      for (var i = 0; i < 30; i++) {
        final password = engine.generate(
          length: 12,
          options: const CharsetOptions(requireEachSelected: true),
        );
        expect(password.contains(RegExp(r'[a-z]')), isTrue);
        expect(password.contains(RegExp(r'[A-Z]')), isTrue);
        expect(password.contains(RegExp(r'[0-9]')), isTrue);
        expect(password.contains(RegExp(r'[^A-Za-z0-9]')), isTrue);
      }
    });

    test('只选数字时结果全是数字', () {
      final password = engine.generate(
        length: 6,
        options: const CharsetOptions(
          lowercase: false,
          uppercase: false,
          symbols: false,
        ),
      );
      expect(RegExp(r'^\d+$').hasMatch(password), isTrue);
    });

    test('「相邻不重复」生效', () {
      for (var i = 0; i < 20; i++) {
        final password = engine.generate(
          length: 40,
          options: const CharsetOptions(noRepeat: true, requireEachSelected: false),
        );
        for (var j = 1; j < password.length; j++) {
          expect(password[j], isNot(password[j - 1]));
        }
      }
    });

    test('长度超界被夹到合法区间', () {
      expect(
        engine.generate(
          length: 1,
          options: const CharsetOptions(),
        ).length,
        PasswordEngine.minLength,
      );
      expect(
        engine.generate(
          length: 9999,
          options: const CharsetOptions(),
        ).length,
        PasswordEngine.maxLength,
      );
    });

    test('未选任何类别时抛 ArgumentError，而不是返回空串', () {
      expect(
        () => engine.generate(
          length: 12,
          options: const CharsetOptions(
            lowercase: false,
            uppercase: false,
            digits: false,
            symbols: false,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('连续生成的密码不重复', () {
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        seen.add(engine.generate(length: 16, options: const CharsetOptions()));
      }
      expect(seen.length, 50);
    });

    test('批量生成长度一致且互不相同', () {
      final list = engine.generateMany(
        length: 16,
        options: const CharsetOptions(),
        count: 5,
      );
      expect(list.length, 5);
      expect(list.toSet().length, 5);
      expect(list.every((p) => p.length == 16), isTrue);
    });
  });

  group('助记口令', () {
    test('单词数与分隔符正确', () {
      for (final words in [3, 4, 6, 8]) {
        final passphrase = engine.generatePassphrase(
          words: words,
          separator: '-',
        );
        // 结尾还有一个 4 位数字，所以段数是 words + 1
        expect(passphrase.split('-').length, words + 1);
      }
    });

    test('首字母大写在开启时生效', () {
      final passphrase = engine.generatePassphrase(
        words: 4,
        capitalize: true,
        appendDigits: false,
      );
      for (final word in passphrase.split('-')) {
        expect(word[0], word[0].toUpperCase());
      }
    });

    test('关闭大写时全小写', () {
      final passphrase = engine.generatePassphrase(
        words: 5,
        capitalize: false,
        appendDigits: false,
      );
      expect(passphrase, passphrase.toLowerCase());
    });

    test('关闭附加数字时结尾不含数字', () {
      final passphrase = engine.generatePassphrase(
        words: 4,
        appendDigits: false,
      );
      expect(RegExp(r'\d$').hasMatch(passphrase), isFalse);
    });

    test('单词不重复', () {
      // 词表里有 dawn / Dawn 这类大小写不同的同形词，去重必须忽略大小写，
      // 否则会反复抽到同一个词而卡死（曾经的实现就有这个死循环）。
      for (var i = 0; i < 200; i++) {
        final passphrase = engine.generatePassphrase(
          words: 8,
          appendDigits: false,
        );
        final words = passphrase.split('-');
        expect(words.length, 8);
        final lower = words.map((w) => w.toLowerCase()).toList();
        expect(lower.toSet().length, 8, reason: '出现重复单词：$passphrase');
      }
    });

    test('单词数超界被夹到 3-8', () {
      expect(
        engine.generatePassphrase(words: 1, appendDigits: false).split('-').length,
        3,
      );
      expect(
        engine.generatePassphrase(words: 99, appendDigits: false).split('-').length,
        8,
      );
    });
  });

  group('密钥', () {
    test('按分组长度插入分隔符且不含易混淆字符', () {
      final key = engine.generateKey(length: 32, groupSize: 8);
      expect(key.split('-').length, 4);
      expect(key.replaceAll('-', '').length, 32);
      for (final char in ['0', 'O', 'I', 'l', '1']) {
        expect(key.contains(char), isFalse);
      }
    });

    test('groupSize 为 0 或分隔符为空时不分组', () {
      final flat = engine.generateKey(length: 20, groupSize: 0);
      expect(flat.length, 20);
      expect(flat.contains('-'), isFalse);

      final noSep = engine.generateKey(length: 20, separator: '');
      expect(noSep.length, 20);
    });

    test('分组长度不整除时最后一段更短，且不丢字符', () {
      final key = engine.generateKey(length: 20, groupSize: 8);
      final groups = key.split('-');
      expect(groups.map((g) => g.length).toList(), [8, 8, 4]);
      expect(groups.join().length, 20);
    });
  });

  group('PIN', () {
    test('全数字且长度正确', () {
      for (final length in [4, 6, 8]) {
        final pin = engine.generatePin(length: length);
        expect(pin.length, length);
        expect(RegExp(r'^\d+$').hasMatch(pin), isTrue);
      }
    });
  });

  group('强度评估', () {
    test('空密码强度为 0、熵为 0', () {
      expect(engine.strengthOf(''), 0);
      expect(engine.entropyFor(''), 0);
    });

    test('长度和字符集越大，熵越高', () {
      final weak = engine.entropyFor('abcd');
      final medium = engine.entropyFor('aB3dE7gH');
      final strong = engine.entropyFor('aB3dE7gH!kL9mN2p');
      expect(weak, lessThan(medium));
      expect(medium, lessThan(strong));
    });

    test('熵与强度等级单调对应', () {
      expect(engine.strengthOf('abc'), 0);
      expect(engine.strengthOf('aB3dE7gH'), lessThanOrEqualTo(2));
      expect(engine.strengthOf('aB3dE7gH!kL9mN2p'), greaterThanOrEqualTo(2));
      final long = engine.generate(length: 32, options: const CharsetOptions());
      expect(engine.strengthOf(long), 4);
      expect(PasswordEngine.strengthLabels[engine.strengthOf(long)], '很强');
    });

    test('强度标签与颜色数量一致，避免越界', () {
      expect(PasswordEngine.strengthLabels.length, 5);
      expect(PasswordEngine.strengthColors.length, 5);
      for (var i = 0; i < PasswordEngine.strengthColors.length; i++) {
        expect(
          PasswordEngine.strengthLabels[engine.strengthOf('x' * (i + 1))],
          isNotNull,
        );
      }
    });

    test('熵值计算不会因单类别被高估', () {
      // 纯数字 8 位：log2(10^8) ≈ 26.6 bit
      final entropy = engine.entropyFor('12345678');
      expect(entropy, greaterThan(25));
      expect(entropy, lessThan(28));
    });
  });

  group('CharsetOptions', () {
    test('copyWith 只改指定字段', () {
      const base = CharsetOptions();
      final changed = base.copyWith(symbols: false);
      expect(changed.symbols, isFalse);
      expect(changed.lowercase, isTrue);
      expect(changed.digits, isTrue);
      expect(base.symbols, isTrue, reason: '原对象不应被修改');
    });

    test('selectedCount 统计已选类别', () {
      expect(const CharsetOptions().selectedCount, 4);
      expect(const CharsetOptions(symbols: false).selectedCount, 3);
      expect(
        const CharsetOptions(
          lowercase: false,
          uppercase: false,
          digits: false,
          symbols: false,
        ).selectedCount,
        0,
      );
    });
  });
}
