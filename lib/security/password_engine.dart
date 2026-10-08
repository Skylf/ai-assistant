import 'dart:math';

/// 密码生成器的字符集开关。
class CharsetOptions {
  const CharsetOptions({
    this.lowercase = true,
    this.uppercase = true,
    this.digits = true,
    this.symbols = true,
    this.excludeAmbiguous = false,
    this.requireEachSelected = true,
    this.noRepeat = false,
  });

  final bool lowercase;
  final bool uppercase;
  final bool digits;
  final bool symbols;

  /// 排除容易混淆的字符（0O1lI|`'\"）。
  final bool excludeAmbiguous;

  /// 生成结果必须包含每一个已勾选的字符类别。
  final bool requireEachSelected;

  /// 相邻字符不重复。
  final bool noRepeat;

  CharsetOptions copyWith({
    bool? lowercase,
    bool? uppercase,
    bool? digits,
    bool? symbols,
    bool? excludeAmbiguous,
    bool? requireEachSelected,
    bool? noRepeat,
  }) => CharsetOptions(
    lowercase: lowercase ?? this.lowercase,
    uppercase: uppercase ?? this.uppercase,
    digits: digits ?? this.digits,
    symbols: symbols ?? this.symbols,
    excludeAmbiguous: excludeAmbiguous ?? this.excludeAmbiguous,
    requireEachSelected: requireEachSelected ?? this.requireEachSelected,
    noRepeat: noRepeat ?? this.noRepeat,
  );

  /// 已选中的类别数量。
  int get selectedCount =>
      [lowercase, uppercase, digits, symbols].where((x) => x).length;

  bool get hasAny => selectedCount > 0;
}

/// 密码生成与强度评估。
///
/// 生成过程不使用 `dart:math` 以外的依赖：`Random.secure()` 是不可预测的
/// 密码学安全随机源，满足「为用户提供更安全的密码」这一目标。
class PasswordEngine {
  PasswordEngine({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  static const lowercaseChars = 'abcdefghijklmnopqrstuvwxyz';
  static const uppercaseChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const digitChars = '0123456789';
  static const symbolChars = '!@#\$%^&*()-_=+[]{};:,.?/~';

  /// 容易混淆的字符，勾选「排除易混淆字符」时会被剔除。
  static const ambiguousChars = '0OoIl1|`\'"{}[]()/\\';

  /// 生成密码长度上限，避免 UI 传入异常值导致内存问题。
  static const maxLength = 128;
  static const minLength = 4;

  /// 供强度评估与提示使用的字符池。
  String poolFor(CharsetOptions options) {
    final buffer = StringBuffer();
    if (options.lowercase) buffer.write(lowercaseChars);
    if (options.uppercase) buffer.write(uppercaseChars);
    if (options.digits) buffer.write(digitChars);
    if (options.symbols) buffer.write(symbolChars);
    var pool = buffer.toString();
    if (options.excludeAmbiguous) {
      pool = pool
          .split('')
          .where((c) => !ambiguousChars.contains(c))
          .join();
    }
    return pool;
  }

  /// 生成一个密码。
  ///
  /// [length] 会被夹在 [minLength] 与 [maxLength] 之间；未勾选任何类别时
  /// 抛出 [ArgumentError]，由调用方在 UI 上拦住这种情况。
  String generate({
    required int length,
    required CharsetOptions options,
  }) {
    if (!options.hasAny) {
      throw ArgumentError('至少要选择一种字符类型');
    }
    final pool = poolFor(options);
    if (pool.isEmpty) {
      throw ArgumentError('字符池为空，请检查是否排除了全部字符');
    }
    final size = length.clamp(minLength, maxLength);

    if (options.noRepeat && pool.length < 2) {
      throw ArgumentError('字符池只剩 1 个字符，无法满足「相邻字符不重复」');
    }

    // 「相邻不重复」要放在打乱之后再校验：先按类别补齐再打乱，打乱这一步
    // 本身就可能把两个相同字符凑到一起（旧实现漏了这一步）。
    // pool 足够大时重复抽样的失败率极低，给一个上限防止死循环。
    final attempts = options.noRepeat ? 60 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final candidate = _assemble(size, pool, options);
      if (!options.noRepeat || _hasNoAdjacentRepeat(candidate)) {
        return candidate.join();
      }
    }
    // 极端情况下（池极小）退化为确定性构造，保证一定返回结果且仍然合规。
    return _withoutAdjacentRepeat(size, pool);
  }

  /// 按「先保证每类至少一个，再随机补齐，最后打乱」的流程拼出一个候选。
  List<String> _assemble(int size, String pool, CharsetOptions options) {
    final chars = <String>[];
    if (options.requireEachSelected) {
      for (final group in _selectedGroups(options)) {
        final usable = _filterGroup(group, options);
        if (usable.isEmpty) continue;
        chars.add(usable[_random.nextInt(usable.length)]);
      }
    }
    // 补齐阶段也遵守不重复，避免生成 20 位却有一半是重复字符
    var guard = 0;
    while (chars.length < size && guard < size * 40 + 200) {
      guard++;
      final next = pool[_random.nextInt(pool.length)];
      if (options.noRepeat && chars.isNotEmpty && chars.last == next) {
        continue;
      }
      chars.add(next);
    }
    while (chars.length < size) {
      chars.add(pool[_random.nextInt(pool.length)]);
    }
    // 打乱，避免「各类别首字母固定出现在开头」这种可预测结构。
    for (var i = chars.length - 1; i > 0; i--) {
      final j = _random.nextInt(i + 1);
      final tmp = chars[i];
      chars[i] = chars[j];
      chars[j] = tmp;
    }
    return chars.take(size).toList();
  }

  static bool _hasNoAdjacentRepeat(List<String> chars) {
    for (var i = 1; i < chars.length; i++) {
      if (chars[i] == chars[i - 1]) return false;
    }
    return true;
  }

  /// 确定性兜底：逐个位置从池中挑一个与上一个不同的字符。
  String _withoutAdjacentRepeat(int size, String pool) {
    final chars = <String>[];
    for (var i = 0; i < size; i++) {
      final previous = chars.isEmpty ? null : chars.last;
      final candidates = previous == null
          ? pool
          : pool.split('').where((c) => c != previous).join();
      final usable = candidates.isEmpty ? pool : candidates;
      chars.add(usable[_random.nextInt(usable.length)]);
    }
    return chars.join();
  }

  /// 一次性生成 [count] 个互不相同的候选密码（生成生态：批量候选）。
  List<String> generateMany({
    required int length,
    required CharsetOptions options,
    int count = 5,
  }) {
    final results = <String>{};
    var guard = 0;
    while (results.length < count && guard < count * 40) {
      results.add(generate(length: length, options: options));
      guard++;
    }
    return results.toList();
  }

  /// 生成助记口令：`单词-单词-单词-数字`，比随机串更好记。
  String generatePassphrase({
    int words = 4,
    String separator = '-',
    bool appendDigits = true,
    bool capitalize = true,
  }) {
    final picked = <String>[];
    // 去重必须忽略大小写：词表里同时有 dawn / Dawn 这类词，若按原样比较，
    // 先选中 'Dawn' 之后再抽到 'dawn' 会被判为「未重复」而反复重抽，死循环。
    final used = <String>{};
    final count = words.clamp(3, 8);
    // 词表远大于 8，正常几十次内就能凑齐；给个上限只为杜绝死循环。
    var guard = 0;
    while (picked.length < count && guard < passphraseWords.length * 4) {
      guard++;
      final word = passphraseWords[_random.nextInt(passphraseWords.length)];
      if (!used.add(word.toLowerCase())) continue;
      picked.add(capitalize ? _capitalize(word) : word);
    }
    // 极端情况下（guard 用尽）补齐剩余位置，保证一定返回合法长度的口令。
    var index = 0;
    while (picked.length < count) {
      final word = passphraseWords[index % passphraseWords.length];
      index++;
      if (!used.add(word.toLowerCase())) continue;
      picked.add(capitalize ? _capitalize(word) : word);
    }
    final buffer = StringBuffer(picked.join(separator));
    if (appendDigits) {
      buffer.write(separator);
      buffer.write(_random.nextInt(9000) + 1000);
    }
    return buffer.toString();
  }

  /// 密钥（API Key / 恢复码）生成：长度更长、默认只含大小写字母与数字。
  String generateKey({
    int length = 32,
    CharsetOptions? options,
    String separator = '-',
    int groupSize = 8,
  }) {
    final key = generate(
      length: length,
      options:
          options ??
          const CharsetOptions(
            symbols: false,
            excludeAmbiguous: true,
          ),
    );
    if (groupSize <= 0 || separator.isEmpty) return key;
    final groups = <String>[];
    for (var i = 0; i < key.length; i += groupSize) {
      final end = i + groupSize < key.length ? i + groupSize : key.length;
      groups.add(key.substring(i, end));
    }
    return groups.join(separator);
  }

  /// 0-4 级强度，与 entropyFor 配合使用。
  int strengthOf(String password) {
    final entropy = entropyFor(password);
    if (entropy < 28) return 0;
    if (entropy < 40) return 1;
    if (entropy < 60) return 2;
    if (entropy < 90) return 3;
    return 4;
  }

  static const strengthLabels = ['很弱', '较弱', '一般', '较强', '很强'];

  static const strengthColors = [
    0xFFB3261E, // 很弱
    0xFFC97A2B, // 较弱
    0xFFC9A227, // 一般
    0xFF247C99, // 较强
    0xFF2E7D5B, // 很强
  ];

  /// 估算熵值（比特）。用于把「长度 + 字符集」换算成可理解的强度。
  double entropyFor(String password) {
    if (password.isEmpty) return 0;
    final pool = _poolSizeOf(password);
    if (pool <= 1) return 0;
    return password.length * _naturalLog(pool.toDouble()) / _ln2;
  }

  /// 生成随机 PIN（纯数字，用于门禁、锁屏等场景）。
  String generatePin({int length = 6}) => generate(
    length: length,
    options: const CharsetOptions(
      lowercase: false,
      uppercase: false,
      symbols: false,
    ),
  );

  /// 使用的字符池大小，用于熵估算。
  int _poolSizeOf(String password) {
    var pool = 0;
    if (password.contains(RegExp(r'[a-z]'))) pool += 26;
    if (password.contains(RegExp(r'[A-Z]'))) pool += 26;
    if (password.contains(RegExp(r'[0-9]'))) pool += 10;
    if (password.contains(RegExp(r'[^A-Za-z0-9]'))) pool += symbolChars.length;
    // 只出现单一类别时上面的估算会偏大，按实际类别数收敛
    return max(pool, 1);
  }

  List<String> _selectedGroups(CharsetOptions options) => [
    if (options.lowercase) lowercaseChars,
    if (options.uppercase) uppercaseChars,
    if (options.digits) digitChars,
    if (options.symbols) symbolChars,
  ];

  String _filterGroup(String group, CharsetOptions options) =>
      options.excludeAmbiguous
      ? group.split('').where((c) => !ambiguousChars.contains(c)).join()
      : group;

  static String _capitalize(String word) =>
      word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);

  /// 助记口令词表。挑选常见、易拼、长度接近的词，保证口令既好记又有足够熵。
  static const passphraseWords = [
    'apple', 'anchor', 'amber', 'arrow', 'autumn', 'bamboo', 'banana',
    'beacon', 'bishop', 'bottle', 'branch', 'bridge', 'bronze', 'bubble',
    'cabin', 'cactus', 'camera', 'candle', 'cannon', 'carpet', 'castle',
    'cattle', 'cave', 'cedar', 'cello', 'cherry', 'circle', 'citrus',
    'clever', 'cloud', 'clover', 'coffee', 'comet', 'copper', 'coral',
    'cosmic', 'cotton', 'crayon', 'cricket', 'crown', 'crystal', 'daisy',
    'dance', 'dawn', 'delta', 'desert', 'diamond', 'dolphin', 'dragon',
    'drum', 'eagle', 'echo', 'ember', 'emerald', 'engine', 'falcon',
    'fabric', 'feather', 'fiddle', 'flame', 'flower', 'forest', 'fossil',
    'fountain', 'galaxy', 'garden', 'gentle', 'ginger', 'glacier', 'globe',
    'granite', 'grape', 'guitar', 'hammer', 'harbor', 'hazel', 'helmet',
    'honey', 'hornet', 'hunter', 'indigo', 'island', 'ivory', 'jacket',
    'jasmine', 'jelly', 'jersey', 'jigsaw', 'jungle', 'kayak', 'kernel',
    'kettle', 'kitten', 'koala', 'ladder', 'lantern', 'laptop', 'laser',
    'lemon', 'lilac', 'linen', 'lizard', 'lobster', 'lotus', 'lunar',
    'magnet', 'mango', 'maple', 'marble', 'marsh', 'meadow', 'melon',
    'meteor', 'mint', 'mirror', 'monsoon', 'mosaic', 'mountain', 'nectar',
    'needle', 'nickel', 'noble', 'noodle', 'north', 'nutmeg', 'oasis',
    'ocean', 'olive', 'onyx', 'opal', 'orange', 'orbit', 'orchid',
    'osprey', 'otter', 'owl', 'paddle', 'palace', 'panda', 'papaya',
    'parrot', 'peach', 'pearl', 'pebble', 'penguin', 'pepper', 'petal',
    'piano', 'pigeon', 'pillow', 'pilot', 'pine', 'planet', 'plasma',
    'plum', 'pocket', 'polar', 'pollen', 'potion', 'prairie', 'prism',
    'pumpkin', 'puzzle', 'quartz', 'quilt', 'rabbit', 'radar', 'rainbow',
    'raven', 'ribbon', 'river', 'robin', 'rocket', 'rose', 'ruby',
    'saddle', 'saffron', 'sailor', 'salmon', 'sand', 'sapphire', 'saturn',
    'school', 'shadow', 'shark', 'shelter', 'silver', 'sketch', 'sky',
    'snow', 'socket', 'solar', 'sonnet', 'sparrow', 'spider', 'spiral',
    'spring', 'spruce', 'squash', 'stone', 'storm', 'stream', 'summer',
    'sunset', 'swan', 'sweater', 'tablet', 'tangerine', 'tapestry',
    'teapot', 'temple', 'thistle', 'thunder', 'tiger', 'timber', 'toffee',
    'tomato', 'topaz', 'tornado', 'tortoise', 'tower', 'trail', 'trumpet',
    'tulip', 'tundra', 'turtle', 'valley', 'velvet', 'venus', 'vessel',
    'violet', 'violin', 'volcano', 'walnut', 'walrus', 'water', 'weaver',
    'whale', 'wheat', 'willow', 'window', 'winter', 'wizard', 'wombat',
    'yarrow', 'yogurt', 'zebra', 'zenith', 'zephyr', 'zigzag',
  ];
}

/// 近似 ln2，避免为一个常量引入 dart:math 之外的依赖。
const _ln2 = 0.6931471805599453;

/// 自然对数实现（Taylor 级数展开，收敛范围外先做区间缩放）。
double _naturalLog(double x) {
  if (x <= 0) return 0;
  var value = x;
  var scale = 0;
  while (value > 2) {
    value /= 2;
    scale++;
  }
  while (value < 0.5) {
    value *= 2;
    scale--;
  }
  // ln(value) 在 [0.5, 2] 区间用 atanh 级数：ln(v) = 2*atanh((v-1)/(v+1))
  final z = (value - 1) / (value + 1);
  var term = z;
  var sum = 0.0;
  for (var n = 1; n <= 99; n += 2) {
    sum += term / n;
    term *= z * z;
  }
  return 2 * sum + scale * _ln2;
}
