import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../ai/action.dart';
import '../ai/client.dart';
import '../ai/prompt.dart';
import '../ai/web_search.dart';
import '../core/stats.dart';
import '../core/util.dart';
import 'db.dart';
import 'models.dart';

export 'models.dart';

/// 一次对话的落库记录（供 UI 直接按字段读取，避免到处 `x['role']`）。
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.topic,
    required this.createdAt,
    this.conversationId = '',
  });

  final String id;
  final String role;
  final String content;
  final Topic topic;
  final DateTime createdAt;

  /// 所属对话。v2 及更早的数据为空，迁移时会归入默认对话。
  final String conversationId;

  bool get isUser => role == 'user';

  static ChatMessage fromRow(Map<String, dynamic> row) => ChatMessage(
    id: row['id']?.toString() ?? '',
    role: row['role']?.toString() ?? 'assistant',
    content: row['content']?.toString() ?? '',
    topic: Topic.fromCode(row['topic']),
    createdAt:
        DateTime.tryParse(row['createdAt']?.toString() ?? '') ?? DateTime.now(),
    conversationId: row['conversationId']?.toString() ?? '',
  );
}

/// 用户在聊天里说「加个药」「记一笔」时，App 怎么理解这句话。
///
/// 这个开关存在的意义：理解中文自然语言的录入意图**本质上该由模型做**，靠关键词
/// 穷举必然漏（`还有两盒`「下个月过期」「剩3个」都覆盖不到）。但模型调用要花时间
/// 和 token，所以给出三档让用户自己权衡。
enum ActionInputMode {
  /// 先本地正则，失败再交给模型（默认）。
  ///
  /// 常见写法零成本即时命中；正则覆盖不到的说法由模型理解。
  smart('smart', '智能（推荐）', '先本地即时识别，识别不了再交给 AI 理解'),

  /// 只让模型理解，不用本地正则。
  ///
  /// 适合想说各种口语化说法、且不在意多一次调用的场景。代价是每次录入都要等
  /// 一次网络往返，比 [smart] 慢。
  aiOnly('ai', '仅 AI 理解', '全部交给 AI 理解，支持各种口语说法，但每次录入都会联网'),

  /// 只用本地正则，完全不联网。
  ///
  /// 没配 API Key 时的可用档；也是「不想为记账消耗额度」的选项。
  /// 只认固定写法（`添加药品 a,b,c 库存 2 有效期 2027-05-01`）。
  localOnly('local', '仅本地识别', '不联网，只识别固定写法，不消耗额度');

  const ActionInputMode(this.code, this.label, this.description);

  final String code;
  final String label;
  final String description;

  /// 从安全存储里的字符串还原；未知值退回 [smart]。
  static ActionInputMode fromCode(String? code) => values.firstWhere(
    (m) => m.code == code,
    orElse: () => ActionInputMode.smart,
  );
}

/// 全局状态与业务逻辑。
class Store extends ChangeNotifier {
  Store({LocalDb? db, FlutterSecureStorage? storage})
    : db = db ?? SqfliteDb(),
      _storage = storage ?? const FlutterSecureStorage();

  final LocalDb db;
  final FlutterSecureStorage _storage;
  final _uuid = const Uuid();

  static const _kUrl = 'url';
  static const _kModel = 'model';
  static const _kKey = 'key';
  static const _kGlobalMemory = 'globalMemory';
  static const _kCustomPrompts = 'customPrompts';
  static const _kActionMode = 'actionMode';

  // ------------------------------------------------------------ 本地数据

  List<Map<String, dynamic>> expenses = const [];
  List<Map<String, dynamic>> meds = const [];
  List<Conversation> conversations = const [];
  List<SavedPassword> savedPasswords = const [];

  /// 当前打开对话的消息。按对话懒加载，避免消息总量增长后一次性全读。
  List<ChatMessage> messages = const [];

  String _activeConversationId = '';

  /// 当前对话 id；没有对话时为空字符串。
  String get activeConversationId => _activeConversationId;

  Conversation? get activeConversation => conversations
      .where((c) => c.id == _activeConversationId)
      .cast<Conversation?>()
      .firstOrNull;

  // ---------------------------------------------------------------- 设置

  String url = AiClient.defaultBaseUrl;
  String model = AiClient.defaultModel;
  String key = '';

  /// 全局记忆正文。对话记忆设为「存入全局记忆」时，其要点会追加到这里。
  String globalMemory = '';

  /// 用户自定义提示词，按主题保存，会追加到系统提示词末尾。
  String customPromptFinance = '';
  String customPromptHealth = '';

  /// 「反向录入」的理解方式。见 [ActionInputMode]。
  ActionInputMode actionMode = ActionInputMode.smart;

  bool get hasApiKey => key.trim().isNotEmpty;

  /// 启动加载是否成功。失败时界面会显示错误页而不是白屏。
  bool get isReady => _ready;

  bool _ready = false;

  /// 启动阶段（打开数据库 / 读取设置 / 首次装配对话）发生的异常。
  Object? bootError;

  Future<void> load() async {
    try {
      await db.open();
      await _loadSettings();
      await reloadLocal();
      await ensureConversations();
      _ready = true;
      bootError = null;
    } catch (error) {
      _ready = false;
      bootError = error;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _loadSettings() async {
    // 安全存储可能因为密钥库损坏而整体读不出来（真机上出现过
    // `EncryptedSharedPreferences ... bad base-64`，插件退回自定义加密后仍可能报错）。
    // 设置读失败不应该让应用起不来：退回默认值，用户重新填一次 API Key 即可。
    url = await _read(_kUrl) ?? url;
    model = await _read(_kModel) ?? model;
    key = await _read(_kKey) ?? '';
    // 这里曾经有一条「静默迁移」：把 `deepseek-flash` 改写成 `deepseek-chat`，
    // 理由是「DeepSeek 上不存在这个模型」。**那是错的** —— 真机上点「获取可用
    // 模型」拉回来的列表里就有 `deepseek-flash` 和 `deepseek-v4-pro`。
    // 后果很严重：用户手选的有效模型名会在每次启动时被悄悄换成一个该服务商
    // 根本没有的名字，而且立刻回写，用户永远查不出为什么一直 404。
    //
    // 教训：**不要凭猜改用户的模型名**。模型名是否正确只有服务商知道，
    // 要做也是拿「获取可用模型」的真实列表来比对，而不是写死一张表。
    globalMemory = await _read(_kGlobalMemory) ?? '';
    customPromptFinance = await _read('${_kCustomPrompts}_f') ?? '';
    customPromptHealth = await _read('${_kCustomPrompts}_h') ?? '';
    actionMode = ActionInputMode.fromCode(await _read(_kActionMode));
  }

  /// 读取一项安全存储设置，失败时返回 null（调用方使用默认值）。
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (error) {
      debugPrint('读取安全存储「$key」失败，使用默认值：$error');
      return null;
    }
  }

  /// 只重读本地数据（账本 / 药箱 / 对话 / 密码记录），不动设置。
  Future<void> reloadLocal() async {
    expenses = await db.all(T.expenses);
    meds = await db.all(T.meds);
    await _reloadConversations();
    savedPasswords = (await db.all(T.passwords))
        .map(SavedPassword.fromRow)
        .toList();
    if (_activeConversationId.isNotEmpty) {
      await _loadMessages(_activeConversationId);
    }
  }

  // ------------------------------------------------------------ 对话管理

  /// 保证至少有一个对话，并把没有归属的旧消息认领回来。
  ///
  /// 0.2A 之前所有消息都只有 topic 字段，没有对话概念；另外 v3 的迁移曾经漏
  /// 给 chats 加 `conversationId`，导致部分设备升上来后老消息的该字段为空。
  /// 两种情况都在这里处理：按主题为这些消息找到（或新建）对应的对话挂上去，
  /// 保证升级后历史记录不丢、也不会因为查不到对话而白屏。
  Future<void> ensureConversations() async {
    // 先取出没有归属的消息。注意顺序：不能先判断 conversations 是否为空，
    // 因为「已升到过坏版本 v3」的设备正是「有对话、但老消息 conversationId
    // 为空」这种状态，必须先认领再决定是否新建对话。
    final orphans = (await db.all(T.chats))
        .where((row) => (row['conversationId']?.toString() ?? '').isEmpty)
        .toList();

    if (conversations.isEmpty && orphans.isEmpty) {
      await createConversation();

      return;
    }

    if (orphans.isNotEmpty) {
      // 第一遍：尽量复用已有对话，避免用户已经建过同名对话时又冒出一个
      for (final topic in Topic.values) {
        final owned = orphans
            .where((row) => Topic.fromCode(row['topic']) == topic)
            .toList();
        if (owned.isEmpty) continue;
        var target = conversations
            .where((c) => c.topic == topic)
            .cast<Conversation?>()
            .firstOrNull;
        target ??= await createConversation(
          title: topic == Topic.health ? '默认健康科普' : '默认账本分析',
          topic: topic,
        );
        for (final row in owned) {
          final id = row['id']?.toString() ?? _uuid.v4();
          await db.put(T.chats, {
            ...row,
            'id': id,
            'conversationId': target.id,
          });
        }
      }
      await _reloadConversations();
    }

    if (_activeConversationId.isEmpty && conversations.isNotEmpty) {
      await selectConversation(conversations.first.id);
    }
  }

  /// 新建对话并切换过去。
  Future<Conversation> createConversation({
    String title = '',
    Topic topic = Topic.finance,
    MemoryScope memory = MemoryScope.defaultScope,
  }) async {
    final now = DateTime.now();
    final conversation = Conversation(
      id: _uuid.v4(),
      title: title.trim().isEmpty ? '新对话' : title.trim(),
      topic: topic,
      memory: memory,
      createdAt: now,
      updatedAt: now,
    );
    await db.put(T.conversations, conversation.toRow());
    await _reloadConversations();
    await selectConversation(conversation.id);
    notifyListeners();
    return conversation;
  }

  /// 切换当前对话，并加载它的消息。
  Future<void> selectConversation(String id) async {
    _activeConversationId = id;
    await _loadMessages(id);
    notifyListeners();
  }

  /// 切到指定主题的对话；没有就建一个（0.5.2 为桌面 AI 组件加的）。
  ///
  /// ## 为什么需要它
  ///
  /// 桌面「AI 记账 / AI 记药」组件点开后，要让用户在**该主题**的对话里说话，
  /// 否则会出现「在账本里说『布洛芬两盒』，模型给出 `med_add` 动作、
  /// 却被主题过滤丢弃」——用户看到的是「记了但什么也没发生」。
  /// 主题归属必须由**打开组件这件事本身**决定，不能交给模型猜。
  ///
  /// 复用第一个同主题对话而不是每次新建：用户从桌面说五句话，不该多出五个对话。
  Future<Conversation> ensureConversationForTopic(Topic topic) async {
    final existing = conversations
        .where((c) => c.topic == topic)
        .cast<Conversation?>()
        .firstOrNull;
    if (existing != null) {
      if (_activeConversationId != existing.id) {
        await selectConversation(existing.id);
      }
      return existing;
    }
    return createConversation(
      title: topic == Topic.health ? '默认健康科普' : '默认账本分析',
      topic: topic,
    );
  }

  Future<void> _loadMessages(String conversationId) async {
    final rows = await db.query(
      T.chats,
      where: 'conversationId=?',
      whereArgs: [conversationId],
    );
    messages = rows.map(ChatMessage.fromRow).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// 重新从库里读对话，并按显示顺序排好。
  ///
  /// 顺序规则（0.4C 加入置顶后定下）：**先置顶、后其他**；两组内部各自按
  /// 时间倒序（置顶组用置顶时间，普通组用更新时间）。
  ///
  /// 排序放在这里而不是 SQL 的 `orderBy`：SQLite 里 `pinnedAt DESC` 会让
  /// NULL 排在最前（视作最小值），正好把「未置顶」顶到最上面 —— 与需求相反。
  /// 与其写 `ORDER BY pinnedAt IS NULL, pinnedAt DESC` 这种容易读错的表达式，
  /// 不如在 Dart 里显式排一次，语义一眼可见。
  Future<void> _reloadConversations() async {
    final list = (await db.all(T.conversations))
        .map(Conversation.fromRow)
        .toList();
    list.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      if (a.isPinned) {
        final byPin = b.pinnedAt!.compareTo(a.pinnedAt!);
        // 时间戳**完全相等**时用 id 兜底，保证顺序是确定的。
        //
        // 什么时候会相等：`DateTime.now()` 在 Windows 上只有微秒精度，
        // 两次连续调用可能落在同一微秒（测试里实测撞到过）。此时若直接
        // 返回 0，顺序就取决于底层 HashMap 的遍历顺序 —— 同一个列表每次
        // 排序结果可能不同，表现为「置顶的两条偶尔换位置」。
        // 真实点击不可能同微秒，但没有兜底 key 时这个不确定性是**真的**。
        return byPin != 0 ? byPin : a.id.compareTo(b.id);
      }
      final byUpdate = b.updatedAt.compareTo(a.updatedAt);
      return byUpdate != 0 ? byUpdate : a.id.compareTo(b.id);
    });
    conversations = list;
  }

  /// 更新对话属性（标题 / 主题 / 记忆作用域 / 置顶）。
  Future<void> updateConversation(
    String id, {
    String? title,
    Topic? topic,
    MemoryScope? memory,
    bool? pinned,
  }) async {
    final current = conversations.firstWhere((c) => c.id == id);
    final updated = current.copyWith(
      title: title,
      topic: topic,
      memory: memory,
      // 置顶/取消置顶不要碰 updatedAt：它表示「最后一条消息的时间」，
      // 置顶是个整理动作，不该让对话在「最近」排序里往前跳。
      updatedAt: title != null || topic != null || memory != null
          ? DateTime.now()
          : null,
      pinnedAt: (pinned ?? false) ? DateTime.now() : null,
      clearPin: pinned == false,
    );
    await db.put(T.conversations, updated.toRow());
    await _reloadConversations();
    notifyListeners();
  }

  /// 切换置顶状态。返回切换后的状态，便于调用方提示。
  Future<bool> toggleConversationPin(String id) async {
    final current = conversations.firstWhere((c) => c.id == id);
    final next = !current.isPinned;
    await updateConversation(id, pinned: next);
    return next;
  }

  /// 尚未处于 [MemoryScope.global] 档位的对话条数。
  ///
  /// 给「一键全部改成全局记忆」做影响面预览用 —— 确认框里必须出现**真实数字**，
  /// 否则用户点下去不知道会动几条。
  int countConversationsNotGlobal() =>
      conversations.where((c) => c.memory != MemoryScope.global).length;

  /// 把所有对话的记忆档位批量改成 [scope]，返回实际改动的条数。
  ///
  /// 为什么需要它：`createConversation` 的默认值只作用于**新建**那一刻，
  /// 升级前就存在的对话保留自己 `memory` 列存的值（刻意的，见
  /// `MemoryScope.defaultScope` 的注释）。于是用户升级到 0.5.3 之后
  /// 会发现「新建的是全局记忆、老的还是仅本对话」，而且**只能一条条点胶囊改**。
  /// 这个批量操作就是补上那个缺口。
  ///
  /// 刻意**不做成升级时自动迁移**：那会在用户不知情的情况下把「仅当前对话」
  /// 和「不记忆」的对话一并改成全局 —— 对「不记忆」的对话尤其严重，
  /// 它本来是「完全不向模型发送历史」，被改成全局之后**历史会开始被发出去**。
  /// 所以必须是用户显式点击的主动作。
  ///
  /// 只改档位不同的那几条，已经是目标档位的跳过：省掉无谓的写库，
  /// 也避免把 `updatedAt` 白改一遍（它参与「最近」排序）。
  Future<int> setAllConversationMemory(MemoryScope scope) async {
    final targets = conversations.where((c) => c.memory != scope).toList();
    for (final conversation in targets) {
      await updateConversation(conversation.id, memory: scope);
    }
    return targets.length;
  }

  /// 删除对话及其全部消息。删除最后一个对话时会自动补一个空对话。
  Future<void> deleteConversation(String id) async {
    await db.remove(T.conversations, id);
    await db.removeWhere(T.chats, 'conversationId=?', [id]);
    await _reloadConversations();
    if (conversations.isEmpty) {
      await createConversation();
      return;
    }
    if (_activeConversationId == id) {
      await selectConversation(conversations.first.id);
      return;
    }
    notifyListeners();
  }

  /// 清空某个对话的消息，保留对话本身与其设置。
  Future<void> clearConversation(String id) async {
    await db.removeWhere(T.chats, 'conversationId=?', [id]);
    if (_activeConversationId == id) {
      messages = const [];
    }
    notifyListeners();
  }

  /// 所有对话中标记为「全局记忆」的内容，会被拼进系统提示词。
  List<String> globalMemoryNotes() {
    final notes = <String>[];
    if (globalMemory.trim().isNotEmpty) notes.add(globalMemory.trim());
    return notes;
  }

  Future<void> saveGlobalMemory(String text) async {
    globalMemory = text.trim();
    await _storage.write(key: _kGlobalMemory, value: globalMemory);
    notifyListeners();
  }

  Future<void> saveCustomPrompts({
    required String finance,
    required String health,
  }) async {
    customPromptFinance = finance.trim();
    customPromptHealth = health.trim();
    await _storage.write(
      key: '${_kCustomPrompts}_f',
      value: customPromptFinance,
    );
    await _storage.write(
      key: '${_kCustomPrompts}_h',
      value: customPromptHealth,
    );
    notifyListeners();
  }

  // ---------------------------------------------------------------- 账目

  /// 新增或更新一笔账目。
  ///
  /// 传 [existing] 即为「修改」：沿用原 id，不会产生重复记录（旧实现在这里
  /// 会新插一条 uuid，等于改一次多一条）。
  Future<void> expense(
    Map<String, dynamic> input, {
    Map<String, dynamic>? existing,
  }) async {
    final row = <String, dynamic>{
      ...?existing,
      ...input,
      'id': existing?['id'] ?? input['id'] ?? _uuid.v4(),
      'spentAt':
          input['spentAt'] ??
          existing?['spentAt'] ??
          DateTime.now().toIso8601String(),
      'entryType': input['entryType'] ?? existing?['entryType'] ?? 'expense',
    };
    await db.put(T.expenses, row);
    await _refresh(T.expenses);
  }

  /// 在药箱里按名称找已有药品。
  ///
  /// 名称两端去空格后**完全相等**才算同一个药。这里刻意不做模糊匹配：
  /// 「布洛芬缓释胶囊」与「布洛芬」是不同规格的不同产品，自动合并会把两个
  /// 真实存在的药品并成一个，用户丢的是数据而不是麻烦。
  /// 名字里的品牌/规格差异也一样（「护肝片(某牌)」≠「护肝片」）。
  ///
  /// 真要支持「同成分合并」得先让用户确认，不能靠猜。
  Map<String, dynamic>? findMedByName(String name) {
    final target = name.trim();
    if (target.isEmpty) return null;
    for (final m in meds) {
      if ((m['name']?.toString() ?? '').trim() == target) return m;
    }
    return null;
  }

  /// 写入药品。
  ///
  /// [addStock] 为 true 时，把 [input] 里的库存**加到**已有库存上，而不是覆盖。
  /// 这是「我又有 3 盒护肝片」的正确语义 —— 家里现在有 5 盒，而不是「改成了 3 盒」
  /// 也不是「多了一条同名记录」。
  Future<void> med(
    Map<String, dynamic> input, {
    Map<String, dynamic>? existing,
    bool addStock = false,
  }) async {
    var stock = input['stock'];
    if (addStock && existing != null) {
      stock = _asInt(existing['stock']) + _asInt(input['stock']);
    }
    final row = <String, dynamic>{
      ...?existing,
      ...input,
      'id': existing?['id'] ?? input['id'] ?? _uuid.v4(),
      'stock': ?stock,
    };
    await db.put(T.meds, row);
    await _refresh(T.meds);
  }

  /// 只更新一盒药的**资料字段**（0.4D 引入，0.4F 支持联网来源）。
  ///
  /// 为什么不复用 [med]：那个方法接收的是「表单整份内容」，会用传入的键
  /// 覆盖同名字段。而这里只想动资料字段，**必须不碰** 名称、库存、有效期 ——
  /// 联网查询顺手改掉用户的库存，是那种「看起来正常、其实很严重」的 bug。
  ///
  /// [fields] 里只允许出现白名单里的键（就是 v6 新增的那些），
  /// 传别的键直接忽略，避免调用方一不留神把 `stock` 写进去。
  ///
  /// [sources] 是**联网检索到的真实 URL**。只有真的联网了才传 ——
  /// 没联网却存一堆 URL，等于伪造出处，比不存更糟。
  Future<void> updateMedInfo(
    String id, {
    required Map<String, String> fields,
    required String source,
    required DateTime checkedAt,
    List<String> sources = const [],
  }) async {
    final existing = meds.where((m) => m['id']?.toString() == id).firstOrNull;
    if (existing == null) return;
    final patch = <String, dynamic>{
      for (final entry in fields.entries)
        if (_writableMedInfoKeys.contains(entry.key)) entry.key: entry.value,
      'infoSource': source,
      'infoCheckedAt': _formatCheckedAt(checkedAt),
      'infoUrls': sources.isEmpty ? '' : sources.join('\n'),
    };
    await db.put(T.meds, {...existing, ...patch});
    await _refresh(T.meds);
  }

  /// 允许被 [updateMedInfo] 写入的键。**故意是白名单而不是黑名单**：
  /// 黑名单要穷举所有不该改的字段，将来加一个字段就会漏掉一个。
  static const _writableMedInfoKeys = <String>{
    'usage',
    'indications',
    'efficacy',
    'adverse',
    'contraindications',
    'precautions',
  };

  /// 查询时间的存储格式：`2026-09-30 19:05`。
  ///
  /// 不用 ISO8601 是因为它只给用户看（「这些资料什么时候查的」），
  /// 带 T 和微秒的字符串在界面上很难读。**不参与任何比较或排序**，
  /// 所以不需要可解析性。
  static String _formatCheckedAt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  /// 一次性的原始补全调用，供药品资料查询这类**非对话**场景使用（0.4D）。
  ///
  /// 与 [ask] 的区别：不写任何消息、不走紧急分流、不做反向录入解析、
  /// 不读对话记忆 —— 它就是「把两段文字发给模型，把回答拿回来」。
  ///
  /// 这里**没有** `webSearch` 参数：0.4D 曾加过，但实测与官方文档都确认
  /// DeepSeek 开放平台会**静默忽略**内置工具（详见 `AiClient.complete` 的说明），
  /// 那个参数只会让调用方误以为联网发生过。要加回来必须先真实验证。
  Future<AiResult> rawComplete({
    required String system,
    required List<Map<String, String>> messages,
    double temperature = 0.3,
  }) => _withClient(
    (client) => client.complete(
      system: system,
      messages: messages,
      temperature: temperature,
    ),
  );

  /// 构造联网搜索客户端（0.4F）。
  ///
  /// 注意基址是**推导出来的**：用户只填了 chat-completions 的 Base URL，
  /// 而联网搜索在 Anthropic 兼容端点上，两者基址不同。映射规则见
  /// [AiWebSearchClient.anthropicBaseFrom] —— 它**不会**擅自改写非官方地址，
  /// 避免把请求发到用户没指定的主机。
  AiWebSearchClient _webSearchClient() => AiWebSearchClient(
    apiKey: key,
    baseUrl: AiWebSearchClient.anthropicBaseFrom(url),
  );

  /// 把「系统提示词 + 历史」拼成一次联网搜索请求的正文。
  ///
  /// ## 为什么把系统提示词塞进用户消息里
  ///
  /// Anthropic 协议是有顶层 `system` 字段的，但 [AiWebSearchClient.buildBody]
  /// 只发单条 user 消息 —— 因为联网搜索的**调用方不止对话**（药品资料查询
  /// 也用它），两边共用同一个薄客户端更简单。
  ///
  /// 代价是对话在这里少了一层「系统指令」与「用户输入」的隔离。
  /// 所以用清晰的分隔标题写明哪部分是系统设定、哪部分是对话，
  /// 并**把历史放在系统设定之后**：模型读到最后一条 user 消息就是当前问题。
  @visibleForTesting
  static String buildChatSearchQuery({
    required String system,
    required List<Map<String, String>> history,
  }) {
    final buffer = StringBuffer()
      ..writeln('【系统设定】')
      ..writeln(system)
      ..writeln()
      ..writeln('【对话】')
      ..writeln('（以下是用户与助手的往来记录，最后一条是用户当前的问题）')
      ..writeln();

    for (final message in history) {
      final role = message['role'] == 'assistant' ? '助手' : '用户';
      buffer
        ..writeln('$role：${message['content'] ?? ''}')
        ..writeln();
    }

    buffer
      ..writeln('【要求】')
      ..writeln(
        '请回答最后一条用户消息。**需要外部事实时（药品说明、健康科普、'
        '政策、价格、新闻等）先联网检索再回答**；纯粹记账、查询本机数据、'
        '打招呼这类不需要外部信息的问题，直接回答即可，不要为了搜索而搜索。',
      )
      ..writeln('引用到的内容请保留来源。');

    return buffer.toString();
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> removeExpense(String id) async {
    await db.remove(T.expenses, id);
    await _refresh(T.expenses);
  }

  Future<void> removeMed(String id) async {
    await db.remove(T.meds, id);
    await _refresh(T.meds);
  }

  Future<void> _refresh(String table) async {
    if (table == T.expenses) {
      expenses = await db.all(T.expenses);
    } else {
      meds = await db.all(T.meds);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ 统计口径

  /// 某月支出。旧实现的首页「本月支出」没有过滤收入，把收入也算了进去。
  double monthlyExpense(DateTime month) =>
      sumEntries(expenses, month, income: false);

  /// 某月收入。
  double monthlyIncome(DateTime month) =>
      sumEntries(expenses, month, income: true);

  /// 某日支出。
  double dailyExpense(DateTime day) =>
      sumEntries(expenses, day, income: false, month: false);

  /// 某日收入。
  double dailyIncome(DateTime day) =>
      sumEntries(expenses, day, income: true, month: false);

  /// 某月结余。
  double monthlyBalance(DateTime month) =>
      monthlyIncome(month) - monthlyExpense(month);

  /// 未来 [days] 天内到期的药品数。
  int expiringWithin(int days, [DateTime? now]) {
    final today = now ?? DateTime.now();
    return meds
        .where((m) => ExpiryInfo.parse(m['expiry']).isExpiringWithin(days, today))
        .length;
  }

  int expiredCount([DateTime? now]) {
    final today = now ?? DateTime.now();
    return meds
        .where((m) => ExpiryInfo.parse(m['expiry']).isExpired(today))
        .length;
  }

  // ---------------------------------------------------------------- 设置

  Future<void> saveSettings({
    required String url,
    required String model,
    required String apiKey,
  }) async {
    this.url = url.trim();
    this.model = model.trim();
    key = apiKey.trim();
    await _storage.write(key: _kUrl, value: this.url);
    await _storage.write(key: _kModel, value: this.model);
    await _storage.write(key: _kKey, value: key);
    notifyListeners();
  }

  /// 保存「反向录入」的理解方式。
  Future<void> saveActionMode(ActionInputMode mode) async {
    actionMode = mode;
    await _storage.write(key: _kActionMode, value: mode.code);
    notifyListeners();
  }

  /// 设置页的「测试连接」：发一条最小请求验证配置是否可用。
  Future<AiResult> testConnection() => _withClient(
    (client) => client.complete(
      system: '你是连通性测试助手，只回复“OK”。',
      messages: const [
        {'role': 'user', 'content': '回复 OK'},
      ],
    ),
  );

  /// 设置页的「获取可用模型」：问服务商要当前真实的模型 id 列表。
  ///
  /// 返回 null 表示拿不到（没填 Key、网络不通、接口不兼容），界面据此提示用户
  /// 手工填写 —— 不把「拉不到」当成错误弹出，因为不是所有兼容服务都实现 /models。
  ///
  /// 当前设置页改为直接构造一次性客户端来调 [AiClient.listModels]（因为那个操作
  /// 绝不能落盘），所以这里**暂时没有生产调用点**。保留它是因为它是 Store 这一层
  /// 对外承诺的最小接口，测试也仍在用；接新调用方时不必再想一遍关客户端的事。
  Future<List<String>?> availableModels() => _withClient(
    (client) => client.listModels(),
  );

  /// 建一个用完即关的 [AiClient]。
  ///
  /// 为什么必须关：无参 `http.Client()` 会建一个带 keep-alive 连接池的
  /// `IOClient`。早先每次调用都 `AiClient(...)` 且从不 `close()`（那个方法因此
  /// 沦为死代码），于是**在对话页每发一条消息就泄漏一个连接池** —— 一天几十条
  /// 消息就是几十个未释放的 socket 与内存。无论成功、失败还是抛异常都必须关。
  Future<T2> _withClient<T2>(Future<T2> Function(AiClient client) body) async {
    final client = _client();
    try {
      return await body(client);
    } finally {
      client.close();
    }
  }

  AiClient _client() => AiClient(baseUrl: url, model: model, apiKey: key);

  // ---------------------------------------------------------------- 会话

  /// 向当前对话追加一条消息。
  ///
  /// 用户消息与助手回复都只在这里写一次，调用方不要再补写（旧实现在
  /// `Chat.send` 里又补写了一次，属于死代码且容易演化成重复消息）。
  Future<ChatMessage> addMessage(String role, String content) async {
    final topic = activeConversation?.topic ?? Topic.finance;
    final conversationId = _activeConversationId;
    final now = DateTime.now();
    final message = ChatMessage(
      id: _uuid.v4(),
      role: role,
      content: content,
      topic: topic,
      createdAt: now,
      conversationId: conversationId,
    );
    await db.put(T.chats, {
      'id': message.id,
      'role': message.role,
      'content': message.content,
      'topic': message.topic.code,
      'createdAt': now.toIso8601String(),
      'conversationId': conversationId,
    });
    messages = [...messages, message];
    // 首条用户消息顺便作为对话标题，避免列表里全是「新对话」。
    final conversation = activeConversation;
    if (conversation != null) {
      final shouldRename =
          role == 'user' && conversation.title == _defaultTitle;
      final updated = conversation.copyWith(
        title: shouldRename ? _titleFrom(content) : null,
        updatedAt: now,
      );
      await db.put(T.conversations, updated.toRow());
      await _reloadConversations();
    }
    notifyListeners();
    return message;
  }

  static const _defaultTitle = '新对话';

  /// 修改已发出的一条消息的正文（0.4C）。
  ///
  /// 有意**只改正文，不改时间、不重发、不重算**：
  ///  · 不重发 —— 用户点「修改」是要修错字或补一句，不是要重新问一遍。
  ///    如果顺手重发，等于把「改一下」变成「再问一次」，可能重复记账；
  ///  · 不改 createdAt —— 消息在时间轴上的位置不该因为改字而跳动；
  ///  · 只允许改**用户自己**发出的消息，助手回复是记录，不允许被编辑
  ///    （改了就与模型实际回答不一致了）。
  ///
  /// 返回是否真的改了。
  Future<bool> updateMessage(String id, String content) async {
    final text = content.trim();
    if (text.isEmpty) return false;
    final index = messages.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    final old = messages[index];
    if (!old.isUser) return false;
    if (old.content == text) return false;

    final updated = ChatMessage(
      id: old.id,
      role: old.role,
      content: text,
      topic: old.topic,
      createdAt: old.createdAt,
      conversationId: old.conversationId,
    );
    await db.put(T.chats, {
      'id': updated.id,
      'role': updated.role,
      'content': updated.content,
      'topic': updated.topic.code,
      'createdAt': updated.createdAt.toIso8601String(),
      'conversationId': updated.conversationId,
    });
    final next = [...messages];
    next[index] = updated;
    messages = next;

    // 若这条正是被用来命名对话的首条消息，标题也要跟着改 ——
    // 否则「改了错字，侧滑菜单里的标题还是错的」。
    final conversation = activeConversation;
    if (conversation != null &&
        messages.isNotEmpty &&
        messages.first.id == id &&
        conversation.title == _titleFrom(old.content)) {
      await db.put(
        T.conversations,
        conversation.copyWith(title: _titleFrom(text)).toRow(),
      );
      await _reloadConversations();
    }
    notifyListeners();
    return true;
  }

  /// 删除一条消息（0.4C）。返回是否真的删了。
  Future<bool> deleteMessage(String id) async {
    final index = messages.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    await db.remove(T.chats, id);
    final next = [...messages]..removeAt(index);
    messages = next;
    notifyListeners();
    return true;
  }

  /// 发给模型的最近消息条数（一问一答算 2 条）。
  ///
  /// 为什么要限制：真机上出现过**模型拿旧消息当依据**的情况 —— 用户先说
  /// 「今天买菜50，吃饭250，加到账本里去」，下一句只说「今天买菜20」，
  /// 模型却在「依据」里引用**上一句**，并照抄那两笔旧的金额，把当前这句话
  /// 完全忽略。历史越长，模型越容易把某条陈年消息当成当前指令。
  ///
  /// 为什么不直接不发历史：跨轮追问（「那它呢」）需要上下文，而且
  /// **当前账目/药箱数据本来就完整写在系统提示词里**，所以砍掉旧对话
  /// 不会丢数据，只会减少干扰。
  static const historyLimit = 8;

  /// 裁剪历史，保留「最初的请求 + 最近的若干轮」。
  ///
  /// 保留首条是有意的：它通常是这次对话的原始意图（「帮我把布洛芬加到药箱」），
  /// 后续省略的部分用一句话注明，避免模型以为没有更早的对话。
  static List<ChatMessage> _historyForModel(List<ChatMessage> all) {
    if (all.length <= historyLimit) return all;
    final head = all.first;
    // 减 2 是给「首条 + 省略说明」留位置，保证总条数不超过 historyLimit。
    final tail = all.sublist(all.length - (historyLimit - 2));
    if (tail.contains(head)) return tail;
    return [
      head,
      ChatMessage(
        id: '__omitted__',
        role: 'user',
        content: '（此处省略了较早的 ${all.length - historyLimit} 条消息，'
            '只保留了你最初的请求和最近的对话。'
            '请只依据**最后一条**用户消息行动。）',
        topic: head.topic,
        createdAt: head.createdAt,
      ),
      ...tail,
    ];
  }

  static String _titleFrom(String content) {
    final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return _defaultTitle;
    return flat.length <= 16 ? flat : '${flat.substring(0, 16)}…';
  }

  /// 提问入口。流程：紧急分流 → 反向操作 → AI 请求。
  ///
  /// [cancel] 用于「暂停 AI 回复」：用户在等待时点暂停，就立刻停止等待并把
  /// 这次请求作废。**已发出的 HTTP 请求无法真正中断**（`package:http` 不支持），
  /// 所以这里做的是「等回来也丢掉」—— 详见 [AskCancelToken] 的说明。
  /// 取消后返回空串，且**不会写入任何消息**（半截回复比没有回复更让人困惑）。
  Future<String> ask(
    String question, {
    AskCancelToken? cancel,
    void Function(SearchPhase phase)? onPhase,
  }) async {
    final q = question.trim();
    if (q.isEmpty) return '';
    await addMessage('user', q);
    return _respondTo(q, cancel: cancel, onPhase: onPhase);
  }

  /// 修改一条**已经发出去的**用户消息，并让模型针对新内容重新回答（0.4D）。
  ///
  /// ## 语义（用户 0.4D 明确选定的方案）
  ///
  /// 「原地替换：改的那条就是最终提问，旧回答删掉，再自动重问一次」。
  ///
  /// 所以这个函数做三件事，顺序不能变：
  ///  1. **原地改写**那条用户消息（同一个 id、同一个时间戳）——
  ///     时间轴上始终只有**一条**提问，不会出现改前改后两份；
  ///  2. **删掉它之后的所有助手回复** —— 那些回复是针对旧问题说的，
  ///     留着会和新答案并存，用户分不清哪个才对；
  ///  3. **重新向模型提问**，写入一条新的助手回复。
  ///
  /// ## 为什么不能直接调 ask()
  ///
  /// `ask()` 会先 `addMessage('user', q)` 再多出一条用户消息 ——
  /// 那就正好违反了「不能与前一次的消息重复」。所以必须绕开那一步，
  /// 直接复用 [_respondTo]（ask 的后半段）。
  ///
  /// 返回模型的新回复；空串表示没发出（空内容/取消/无 API Key 时那条
  /// 引导语仍会作为助手消息写入）。
  Future<String> resendEditedMessage(
    String id,
    String newContent, {
    AskCancelToken? cancel,
    void Function(SearchPhase phase)? onPhase,
  }) async {
    final text = newContent.trim();
    if (text.isEmpty) return '';

    final index = messages.indexWhere((m) => m.id == id);
    if (index < 0) return '';
    final target = messages[index];
    // 只允许改用户自己发的：助手回复是「模型当时这么回答」的记录。
    if (!target.isUser) return '';

    // ---- ① 原地改写 ----
    final updated = ChatMessage(
      id: target.id,
      role: target.role,
      content: text,
      topic: target.topic,
      createdAt: target.createdAt,
      conversationId: target.conversationId,
    );
    await db.put(T.chats, {
      'id': updated.id,
      'role': updated.role,
      'content': updated.content,
      'topic': updated.topic.code,
      'createdAt': updated.createdAt.toIso8601String(),
      'conversationId': updated.conversationId,
    });
    final next = [...messages];
    next[index] = updated;
    messages = next;

    // 标题若来自这条首条消息，跟着改
    final conversation = activeConversation;
    if (conversation != null &&
        messages.isNotEmpty &&
        messages.first.id == id &&
        conversation.title == _titleFrom(target.content)) {
      await db.put(
        T.conversations,
        conversation.copyWith(title: _titleFrom(text)).toRow(),
      );
      await _reloadConversations();
    }

    // ---- ② 删掉这条之后的所有助手回复 ----
    // 只删助手消息：用户可能连着说了好几句，那几句都还有效，不能一起删。
    //
    // ⚠️ **必须按位置切，不能按时间戳比大小。**
    //
    // 这里原本写的是 `m.createdAt.isAfter(target.createdAt)`，看着很对，
    // 实际会随机漏删：`ask()` 里「写入用户消息」与「写入助手回复」两次
    // `DateTime.now()` 有可能落在**同一微秒**（实测打印出来两行时间戳完全一样
    // `...54.349665`），于是 `isAfter` 为 false，那条旧回复被判定为「不在这条之后」
    // 而保留下来 —— 新旧两个答案并存，正是用户说的「重复」。
    //
    // 时间戳在这里只是**排序用的显示数据**，不是顺序的真相；顺序的真相是列表下标。
    // 用下标切：目标之后的所有非用户消息一律删掉。确定、无时序依赖。
    final doomed = messages
        .skip(index + 1)
        .where((m) => !m.isUser)
        .map((m) => m.id)
        .toList();
    for (final doomedId in doomed) {
      await db.remove(T.chats, doomedId);
    }
    if (doomed.isNotEmpty) {
      messages = messages.where((m) => !doomed.contains(m.id)).toList();
    }
    notifyListeners();

    // ---- ③ 重新提问 ----
    return _respondTo(text, cancel: cancel, onPhase: onPhase);
  }

  /// 针对 [q] 生成回复并落库。**不写入用户消息** —— 调用方负责那条消息。
  ///
  /// [q] 必须已经存在于 `messages` 里（`_historyForModel` 要能取到它），
  /// 这是 0.4A 那个「取快照位置写错」事故留下的约束，见下。
  Future<String> _respondTo(
    String q, {
    AskCancelToken? cancel,
    void Function(SearchPhase phase)? onPhase,
  }) async {
    final topic = activeConversation?.topic ?? Topic.finance;
    final memory = activeConversation?.memory ?? MemoryScope.defaultScope;

    // 必须在**用户消息已经落库之后**取历史。
    //
    // 这里原本是在 addMessage 之前取快照，结果发出去的 messages **不含当前
    // 这条提问** —— 模型只能看到上一轮的对话，于是把上一轮的内容当成当前指令
    // 执行。真机上正是这样：用户又说「今天买菜20」，模型却在「依据」里引用
    // 上一句「今天买菜50，吃饭250」，并照抄那两笔旧金额。
    // 一个「取快照的位置」写错，表现却是「模型答非所问」，极难从现象反推。
    final history = memory == MemoryScope.off
        ? const <ChatMessage>[]
        : _historyForModel(messages);

    final urgent = topic == Topic.health ? urgentAdvice(q) : null;
    if (urgent != null) {
      await addMessage('assistant', urgent);
      return urgent;
    }

    // 暂停检查点：紧急分流与本地动作解析都是**瞬时**的（不走网络），
    // 用户几乎不可能在这里点暂停。真正的检查点在网络调用之后。
    if (cancel?.cancelled ?? false) return '';

    final actions = parseActions(q, topic);
    if (actions.isNotEmpty) {
      final lines = <String>[];
      var merged = 0;
      for (final action in actions) {
        if (action.type == 'med') {
          // 与模型路径同样的规则：同名药品叠加库存，不新建条目。
          // 两条路径必须行为一致，否则「说一下」和「好好说」结果不同。
          final existing = findMedByName(action.row['name']?.toString() ?? '');
          if (existing == null) {
            await med(action.row);
            lines.add(action.summary);
          } else {
            await med(action.row, existing: existing, addStock: true);
            merged++;
            lines.add(
              '${action.row['name']}：原有 ${_asInt(existing['stock'])} 盒 + '
              '新增 ${_asInt(action.row['stock'])} 盒 → 共 '
              '${_asInt(existing['stock']) + _asInt(action.row['stock'])} 盒',
            );
          }
        } else {
          await expense(action.row);
          lines.add(action.summary);
        }
      }
      final reply = _actionReply(actions, lines: lines, merged: merged);
      await addMessage('assistant', reply);
      return reply;
    }

    if (!hasApiKey) {
      const reply = '请先在「设置 → AI 服务 → API 配置」中填写 API Key。数据仍然只保存在本机。';
      await addMessage('assistant', reply);
      return reply;
    }

    final system = PromptBuilder.build(
      topic: topic,
      expenses: expenses,
      meds: meds,
      now: DateTime.now(),
      customPrompt: topic == Topic.health
          ? customPromptHealth
          : customPromptFinance,
      globalMemory: memory == MemoryScope.global ? globalMemoryNotes() : const [],
      memoryScope: memory,
      allowActions: actionMode != ActionInputMode.localOnly,
    );

    // 0.4F：主对话也联网。
    //
    // ## 为什么「总是带上联网工具」而不是先判断该不该搜
    //
    // 判断「这句话需不需要联网」本身就该由模型做 —— 用关键词表去猜
    // （「最新」「价格」「副作用」…）正是用户批评过的「非得自己写解析」。
    // 所以这里**始终把 web_search 工具挂上**，搜不搜由服务端模型决定：
    //  · 问「今天买菜20」→ 模型不调工具，**不会有任何检索开销**
    //    （实测：不调用时 `server_tool_use.web_search_requests` 为 0）
    //  · 问「布洛芬有什么副作用」→ 模型自己决定去搜
    //
    // 副作用其实更好：界面上那句「正在联网搜索」**只有真搜了才会出现**，
    // 因为它是被服务端返回的 `server_tool_use` 事件驱动的。
    // 若预先按关键词猜「这次要联网」，就会出现「显示在搜、实际没搜」——
    // 那正是 0.4D 的错。
    final payload = history
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    AiResult result;
    final search = await _webSearchClient().search(
      buildChatSearchQuery(system: system, history: payload),
      onPhase: onPhase,
      cancel: cancel,
    );
    if (search.ok) {
      result = AiResult(
        text: search.answer,
        sources: search.sources.map((s) => s.url).toList(),
        searched: search.searched,
      );
    } else {
      result = AiResult(text: '', error: search.error);
    }

    // 用户的提问已经落库了（上面那次 addMessage），这是对的：他确实说过这句话，
    // 不该因为点了暂停就当没说过。但**回复必须丢掉** —— 否则暂停后过几秒又
    // 冒出一条回复，用户会以为暂停没生效。
    if (cancel?.cancelled ?? false) {
      debugPrint('[ask] 用户暂停，丢弃这次模型回复（问：「$q」）');
      return '';
    }

    if (!result.ok) {
      final reply = result.display;
      await addMessage('assistant', reply);
      return reply;
    }

    // 模型可能把用户的录入意图抽成了动作计划。这一步是「让模型理解人话」的
    // 落点：本地正则只覆盖常见写法，`还有两盒`「下个月过期」「剩3个」这类说法
    // 交给模型判断，App 只负责执行，不再靠关键词表去猜。
    //
    // 无论执行与否都要先摘掉 ```actions 代码块：那是给 App 看的，不是给用户看
    // 的。JSON 只坏一点点时若原样保留，用户会看到一屏裸 JSON —— 图表协议早就
    // 有「不露出裸 JSON」这条约束，动作协议同样要守。
    //
    // 传入 topic 是**必须的**：模型可能搞错模块（真机上出现过：在账本里说
    // 「加到账本里去」，模型却给了 med_add，结果往药箱写了一条护肝片）。
    // 模块归属由用户在界面上的选择决定，不由模型说了算，所以这里按主题过滤。
    final extracted = ActionPlan.extract(result.text, topic: topic);
    if (extracted.rejected) {
      debugPrint('[action] 模型给的动作类型与当前模块不符，已丢弃（问：「$q」）'
          '原文前 300 字：'
          '${result.text.length > 300 ? result.text.substring(0, 300) : result.text}');
    }
    if (extracted.actions.isNotEmpty &&
        actionMode != ActionInputMode.localOnly) {
      return _executePlanned(extracted.actions, topic, extracted.body);
    }

    // 走到这里说明：调用了模型，但从回复里**一个可执行动作都没有**。
    // 这是最难排查的失效 —— 用户看到的是「它答了但什么也没加」，而原因可能是
    // 模型没按协议输出、JSON 写坏了、把录入请求当成了提问（真机上出现过：说
    // 「今天买菜50，吃饭180」，模型回了一段本月支出统计），或者模块搞错了。
    // 单测里模型回复是我自己编的，永远撞不到这些情况，所以必须留下现场。
    if (!extracted.rejected) {
      debugPrint('[action] 无可执行动作（问：「$q」），原文前 300 字：'
          '${result.text.length > 300 ? result.text.substring(0, 300) : result.text}');
    }

    // 摘完代码块正文就空了，说明模型只给了动作没说话 —— 那多半是 JSON 坏了，
    // 退回原文比显示一条空消息好。
    //
    // 但**模块不匹配时绝不能退回原文**：原文里就是那段 ```actions JSON，
    // 退回去等于把一屏裸 JSON 甩给用户，而且里面还写着他没要求的药品名
    // （真机上正是这样：账本里回了一句「护肝片」的 JSON）。
    // 这种情况如实说明，不必假装成功。
    if (extracted.body.trim().isEmpty && extracted.rejected) {
      const reply = '这句话我没能对应到当前模块的录入。\n'
          '如果是要记一笔账，请说「今天买菜 50」这样的花销；'
          '如果是加药，请到「药箱」里说。';
      await addMessage('assistant', reply);
      return reply;
    }
    final reply = extracted.body.trim().isEmpty
        ? result.text
        : extracted.body;
    await addMessage('assistant', reply);
    return reply;
  }

  /// 执行模型给出的动作计划。
  ///
  /// [body] 是模型对本次录入的自然语言说明（已摘掉 ```actions 代码块）。有说明
  /// 就放在清单前面 —— 用户想知道「你理解成了什么」，光看清单看不出模型有没有
  /// 把「下个月」算错。模型只输出 JSON 没写正文时，用清单本身当回复。
  Future<String> _executePlanned(
    List<Map<String, dynamic>> planned,
    Topic topic,
    String body,
  ) async {
    final lines = <String>[];
    var added = 0;
    var merged = 0;

    for (final action in planned) {
      final row = (action['row'] as Map).cast<String, dynamic>();
      if (action['type'] == ActionPlan.medAdd) {
        // 同名药品不新建条目，而是把库存**加上去**。
        // 用户实测反馈过：「我药箱里以前记录了 2 盒护肝片，他又新加了一条，
        // 而不是把数量叠加」。同名两条记录会让「家里还有几盒」永远算错，
        // 而且用户得自己发现并手动清理。
        final existing = findMedByName(row['name']?.toString() ?? '');
        if (existing == null) {
          await med(row);
          added++;
          lines.add('· ${action['summary']}');
        } else {
          await med(row, existing: existing, addStock: true);
          merged++;
          lines.add(
            '· ${row['name']}：原有 ${_asInt(existing['stock'])} 盒 + '
            '新增 ${_asInt(row['stock'])} 盒 → 共 '
            '${_asInt(existing['stock']) + _asInt(row['stock'])} 盒',
          );
        }
      } else {
        await expense(row);
        added++;
        lines.add('· ${action['summary']}');
      }
    }

    final label = topic == Topic.health ? '药品已加入药箱' : '账目已加入账本';
    final total = added + merged;
    final mergeNote = merged > 0 ? '，其中 $merged 项与已有药品合并了库存' : '';
    final head = body.trim().isEmpty ? '' : '${body.trim()}\n\n';
    final reply = '$head$label（共 $total 项$mergeNote）：\n'
        '${lines.join('\n')}\n已同步显示在对应页面。';
    await addMessage('assistant', reply);
    return reply;
  }

  /// 紧急症状分流。命中时直接返回固定话术，不消耗 API 调用。
  /// 触发「立即就医」提示的关键词。
  ///
  /// 判据是 `question.contains(...)`，所以**关键词必须覆盖人们真实会打的说法**。
  /// 0.4B 补词时发现原列表只有 7 个书面词：说「胸痛」「呼吸困难」能命中，
  /// 但说**「胸口剧痛」「喘不上气」就完全不触发** —— 而后者才是着急时更可能
  /// 打出来的说法。这类漏检的代价是把急症当成普通科普问答，所以宁可多列。
  ///
  /// 取舍：只放「即使误判也无害」的词（多说一句「去医院」不会伤害用户），
  /// 不放「发烧」「咳嗽」这类常见轻症词，否则日常问药全被拦成紧急提示。
  static const urgentKeywords = [
    // 心血管 / 呼吸
    '胸痛',
    '胸口痛',
    '胸口疼',
    '胸闷',
    '心绞痛',
    '心梗',
    '呼吸困难',
    '喘不上气',
    '喘不过气',
    '窒息',
    // 神经
    '昏迷',
    '抽搐',
    '意识不清',
    '叫不醒',
    '中风',
    '偏瘫',
    '说话不清',
    // 过敏 / 中毒
    '严重过敏',
    '过敏休克',
    '喉咙肿',
    '误服',
    '吃错药',
    '过量',
    '中毒',
    // 出血 / 创伤
    '大出血',
    '止不住血',
    '吐血',
    '便血',
    // 其他危重
    '休克',
    '高热惊厥',
    '脱水',
  ];

  static String? urgentAdvice(String question) {
    if (!urgentKeywords.any(question.contains)) return null;
    return '这可能是紧急情况，请立即拨打 120 或前往急诊；'
        '不要等待 AI 回复，也不要自行加量或混用药物。';
  }

  // ------------------------------------------------------ 反向操作解析

  /// 一条消息里列多项时的分隔符。
  ///
  /// 逗号（中英文）、顿号、分号、竖线，以及换行。**不含空格** —— 空格在
  /// 「添加药品 布洛芬 库存 5」里是「名称与参数」的分隔符，把它也算作列表分隔符
  /// 会把「库存」「5」各当成一个药品名。
  static final _listSeparator = RegExp(r'[,，、;；|｜\n]');

  /// 药品名到「第一个空格」或「第一个分隔符」为止，其余作为可选参数。
  ///
  /// 分隔符优先：`添加药品布洛芬，库存 2` 里名称是「布洛芬」。若直接让
  /// `[^，,；;]+` 贪婪匹配，名称会把「库存 2」一起吞掉，参数就丢了。
  static final actionPattern = RegExp(
    r'^(?:添加药品|添加药瓶|加药)\s*'
    r'([^，,；;、\s]+)'
    r'(?:[，,；;、\s]+(.*))?$',
  );

  /// 账本动作的前缀。
  static final _expensePrefix = RegExp(r'^(?:添加账目|添加收支|记一笔|记账)\s*');

  /// 药品动作的前缀。
  static final _medPrefix = RegExp(r'^(?:添加药品|添加药瓶|加药)\s*');

  static String? _entryTypeOf(String text) {
    if (text.contains('收入') || text.contains('进账') || text.contains('赚')) {
      return 'income';
    }
    if (text.contains('支出') ||
        text.contains('花费') ||
        text.contains('花了') ||
        text.contains('消费')) {
      return 'expense';
    }
    return null;
  }

  static double? _inferAmountFrom(String rest) {
    final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(rest);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  /// 从自然语言里抓有效期，支持 `2027-05-01` / `2027/5/1` / `2027年5月1日`。
  ///
  /// 统一归一化成补零的 `YYYY-MM-DD`，避免把中文写法丢进数据库。
  static String? _parseExpiry(String text) {
    final m = RegExp(
      r'(\d{4})\s*[-/.年]\s*(\d{1,2})(?:\s*[-/.月]\s*(\d{1,2})\s*日?)?',
    ).firstMatch(text);
    if (m == null) return null;
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = m.group(3) == null ? 1 : int.parse(m.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final padded = month.toString().padLeft(2, '0');
    final paddedDay = day.toString().padLeft(2, '0');
    return '$year-$padded-$paddedDay';
  }

  /// 逗号也是「空格」：`添加药品 a 库存 2` 里两处都是分隔。
  static final _spaceOrSep = RegExp(r'[\s,，、;；|｜]+');

  /// 把列表主体切成「条目」。每条自带后续参数，直到下一个真正的分隔符。
  ///
  /// 先按分隔符切，再把「以参数词开头」的片段接回上一项，于是
  /// `a,b,c 库存 2 有效期 2027-05-01` 得到三条，而
  /// `布洛芬，库存 2，有效期 2027-05-01` 得到一条 —— 后者里的逗号是
  /// 「名称与参数」的分隔，不是列表分隔。这是本次解析最关键的一步区分。
  static List<String> _splitEntries(String body) {
    final chunks = _stripLeadingColon(body).split(_listSeparator);
    final entries = <String>[];
    for (final chunk in chunks) {
      final piece = chunk.trim();
      if (piece.isEmpty) continue;
      if (entries.isNotEmpty && _startsWithParam(piece)) {
        // 这一段是上一项的参数（如「库存 2」），接回去而不是当成新的一项
        entries[entries.length - 1] = '${entries.last} $piece';
      } else {
        entries.add(piece);
      }
    }
    return entries;
  }

  /// 去掉前缀后紧跟的冒号。
  ///
  /// `添加药品：a,b,c` 里的 `：` 既不是名称的一部分，也不是参数分隔符。漏掉它
  /// 会得到一个名叫「：a」的药品 —— 半对半错比全错更难发现。
  static String _stripLeadingColon(String body) =>
      body.replaceFirst(RegExp(r'^[:：]\s*'), '');

  /// 判断一个片段是否以参数词开头。
  ///
  /// 用来区分「参数」与「下一个名称」：`布洛芬，库存 2` 里第二段以「库存」开头，
  /// 是参数；`a,b,c` 里每段都是名字。注意**不能**反过来用「有没有片段以参数词
  /// 开头」来决定整体是不是列表 —— `a,b,c 库存 2` 的最后一段以「库存」开头，
  /// 但它同时是一个三项列表，判断必须按位置做，见 [_parseMedActions]。
  static bool _startsWithParam(String piece) =>
      RegExp(r'^(库存|数量|共|有效期|到期|失效|规格|储存|保存|备注|说明)').hasMatch(
        piece,
      );

  /// 账本那侧的对应判断：片段里有没有数字。
  ///
  /// - `记账 打车,18` —— 有数字，逗号是「名称/金额」分隔；
  /// - `记账 买菜,打车` —— 都没数字，是两笔待补金额的记录。
  static final _hasDigits = RegExp(r'\d');

  /// 把一条消息解析成动作列表。
  ///
  /// 支持一条消息里添加多项：`添加药品：a,b,c` → 三个药品。
  ///
  /// 早先只支持单项，于是 `添加药品：a,b,c` 会老老实实建出一个名叫「a,b,c」的
  /// 药品 —— 用户明确列了三样东西，得到的是一样叫这个名字的东西，既不报错也不
  /// 提示，属于「安静地做错事」。这里的关键是**区分列表与参数**：逗号既可能是
  /// 「多项之间的分隔」，也可能是「名称与参数之间的分隔」。判断必须按位置做，
  /// 见 [_parseMedActions] 里的说明。
  ///
  /// 返回空列表表示「不是反向操作」，交给 AI 正常回答。
  static List<ParsedAction> parseActions(String input, Topic topic) {
    final text = input.trim();
    if (topic == Topic.health) return _parseMedActions(text);
    return _parseExpenseActions(text);
  }

  static List<ParsedAction> _parseMedActions(String text) {
    final prefix = _medPrefix.firstMatch(text);
    if (prefix == null) return const [];
    final body = _stripLeadingColon(text.substring(prefix.end).trim());
    if (body.isEmpty) return const [];

    // 主切分：只按「显式分隔符」切，空格不算分隔符 ——
    // 这样 `布洛芬 库存 5` 才不会被拆成「布洛芬」和「库存 5」两个药品。
    final entries = _splitEntries(body);
    if (entries.isEmpty) return const [];

    // 全部片段都是参数 → 没有名称可加，不猜
    if (entries.every(_startsWithParam)) return const [];

    if (entries.length == 1) {
      // 单项：`布洛芬 库存 2` / `布洛芬，库存 2，有效期 2027-05-01`。
      // 用 actionPattern 走原有路径，保证既有行为一字不改。
      final m = actionPattern.firstMatch(text);
      if (m == null) return const [];
      final name = m.group(1)!.trim();
      if (name.isEmpty) return const [];
      return [_medAction(name, m.group(2) ?? '')];
    }

    // 多项：`a,b,c 库存 2 有效期 2027-05-01`。
    //
    // 这里**不能**用「有没有片段以参数词开头」来决定走单项还是多项 ——
    // `c 库存 2 有效期 2027-05-01` 也以参数词开头，那样会把一个真正的三项列表
    // 误判成单项（第一版就是这么错的：名字对了、参数全丢）。
    //
    // 要按位置判断：每段第一个词是名称；**参数可能挂在任意一段的尾巴上**——
    // 用户既会写 `a 库存 2,b,c`，也会写 `a,b,c 库存 2`。两种都要能解析，
    // 所以把所有段的尾巴都收集成共用参数。
    final names = <String>[];
    final shared = <String>[];
    for (final entry in entries) {
      final tokens = entry.split(_spaceOrSep);
      final head = tokens.first.trim();
      if (head.isEmpty) continue;
      final tail = tokens.length > 1 ? tokens.sublist(1).join(' ') : '';
      if (names.isEmpty && (_startsWithParam(head) || RegExp(r'^\d').hasMatch(head))) {
        // 还没收集到任何名称就遇到参数（如「库存 2」开头）：也是共用参数
        shared.add(entry);
        continue;
      }
      names.add(head);
      if (tail.isNotEmpty) shared.add(tail);
    }
    if (names.isEmpty) return const [];
    final rest = shared.join(' ');
    return [for (final name in names) _medAction(name, rest)];
  }

  static ParsedAction _medAction(String name, String rest) {
    final stockMatch = RegExp(r'(?:库存|数量|共)\s*(\d+)').firstMatch(rest);
    return ParsedAction(
      type: 'med',
      summary: name,
      row: {
        'name': name,
        'ingredient': '',
        'spec': '',
        'stock': stockMatch == null ? 1 : int.parse(stockMatch.group(1)!),
        'expiry': _parseExpiry(rest) ?? '',
        'storage': '',
        'note': '由 AI 快捷录入',
      },
    );
  }

  static List<ParsedAction> _parseExpenseActions(String text) {
    final prefix = _expensePrefix.firstMatch(text);
    if (prefix == null) return const [];
    final body = _stripLeadingColon(text.substring(prefix.end).trim());
    if (body.isEmpty) return const [];

    // 逗号两侧都有数字 → 「名称 金额」逐项配对：`买菜 32.5, 打车 18`
    final parts = body
        .split(_listSeparator)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length > 1 &&
        parts.every((p) => _hasDigits.hasMatch(p) && _leadingName(p).isNotEmpty)) {
      final actions = <ParsedAction>[];
      for (final part in parts) {
        final amount = _inferAmountFrom(part);
        final name = _leadingName(part);
        if (amount == null || amount < 0 || name.isEmpty) return const [];
        actions.add(_expenseAction(name, amount, text));
      }
      return actions;
    }

    // 其余情况按空格切「名称 金额 …」，于是 `买菜,打车 30` 得到两个名称 +
    // 一个共用金额（逗号在这里等同空格）。
    final head = body.split(_spaceOrSep);
    final names = <String>[];
    final amounts = <double>[];
    for (final token in head) {
      final amount = double.tryParse(token);
      if (amount != null) {
        amounts.add(amount);
        continue;
      }
      // 片段里带数字时可能是「买菜32」这种连写，拆成名称 + 金额
      final inline = RegExp(r'^(\D+?)(\d+(?:\.\d+)?)$').firstMatch(token);
      if (inline != null) {
        names.add(inline.group(1)!.trim());
        amounts.add(double.parse(inline.group(2)!));
      } else {
        names.add(token.trim());
      }
    }
    final cleanNames = names.where((n) => n.isNotEmpty).toList();
    if (cleanNames.isEmpty) return const [];

    // 一个金额：套用到所有名称（`记账 买菜,打车 30`）
    if (amounts.length == 1) {
      final amount = amounts.single;
      if (amount < 0) return const [];
      return [for (final name in cleanNames) _expenseAction(name, amount, text)];
    }
    // 名称与金额数量一致：逐个配对
    if (amounts.length == cleanNames.length) {
      final actions = <ParsedAction>[];
      for (var i = 0; i < cleanNames.length; i++) {
        if (amounts[i] < 0) return const [];
        actions.add(_expenseAction(cleanNames[i], amounts[i], text));
      }
      return actions;
    }
    // 形状对不上（比如 `记账 买菜` 缺金额）：不猜，交给 AI 正常回答
    return const [];
  }

  /// 取「名称 金额」片段里的名称部分。
  static String _leadingName(String part) =>
      RegExp(r'^(\D+?)\s*\d').firstMatch(part)?.group(1)?.trim() ?? '';

  static ParsedAction _expenseAction(
    String title,
    double amount,
    String context,
  ) => ParsedAction(
    type: 'expense',
    summary: '$title ${money(amount)}',
    row: {
      'title': title,
      'amount': amount,
      'category': 'AI 录入',
      'note': '由 AI 快捷录入',
      'entryType': _entryTypeOf(context) ?? 'expense',
    },
  );

  /// 单个动作的解析结果（[parseActions] 的第一个，或 null）。
  ///
  /// 保留这个签名是为了向后兼容：既有测试与调用点都按「一条消息一个动作」写。
  /// 新代码应当用 [parseActions]。
  static ParsedAction? parseAction(String input, Topic topic) {
    final actions = parseActions(input, topic);
    return actions.isEmpty ? null : actions.first;
  }

  /// 把落库结果写成一句回复。
  ///
  /// 多项时逐条列出，而不是只说「已加入」——用户是列了好几样东西，回复必须让他
  /// 一眼看出**每一样是不是都进去了**，否则「安静地少加一个」无从发现。
  ///
  /// [lines] 与 [merged] 由调用方传入，是为了让「与已有药品合并库存」这种
  /// **结果与输入不同**的情况能说清楚：只说「护肝片」的话，用户不知道系统是
  /// 新建了一条还是把数量加到了已有的那条上。
  static String _actionReply(
    List<ParsedAction> actions, {
    List<String>? lines,
    int merged = 0,
  }) {
    final isMed = actions.first.type == 'med';
    final label = isMed ? '药品已加入药箱' : '账目已加入账本';
    final mergeNote = merged > 0 ? '，其中 $merged 项与已有药品合并了库存' : '';
    if (actions.length == 1) {
      final detail = lines != null && lines.isNotEmpty
          ? lines.first
          : actions.first.summary;
      return '$label：$detail$mergeNote，并已同步显示在对应页面。';
    }
    final items = lines != null && lines.isNotEmpty
        ? lines.join('、')
        : actions.map((a) => a.summary).join('、');
    return '$label（共 ${actions.length} 项$mergeNote）：$items，'
        '并已同步显示在对应页面。';
  }

  /// 供测试直接校验回复文案（正常路径请用 [ask]）。
  @visibleForTesting
  static String actionReplyForTest(List<ParsedAction> actions) =>
      actions.isEmpty ? '' : _actionReply(actions);

  // ------------------------------------------------------- 密码生成器

  /// 记录一次密码生成结果。
  ///
  /// 有意不保存密码明文：本机数据库是明文 SQLite，写入明文等于把用户的账号
  /// 密码随手落到普通文件里。这里只留用途、长度与强度，用于回溯「我用过多强
  /// 的密码」，需要明文时由用户当场复制。
  Future<SavedPassword> savePasswordRecord({
    required String label,
    required String site,
    required int length,
    required int strength,
    required double entropy,
    String? id,
  }) async {
    final record = SavedPassword(
      id: id ?? _uuid.v4(),
      label: label.trim(),
      site: site.trim(),
      length: length,
      strength: strength,
      entropy: entropy,
      createdAt: DateTime.now(),
    );
    await db.put(T.passwords, record.toRow());
    savedPasswords = (await db.all(T.passwords))
        .map(SavedPassword.fromRow)
        .toList();
    notifyListeners();
    return record;
  }

  Future<void> removePasswordRecord(String id) async {
    await db.remove(T.passwords, id);
    savedPasswords = (await db.all(T.passwords))
        .map(SavedPassword.fromRow)
        .toList();
    notifyListeners();
  }

  Future<void> clearPasswordRecords() async {
    await db.clear(tables: const [T.passwords]);
    savedPasswords = const [];
    notifyListeners();
  }

  // ------------------------------------------------------------ 数据管理

  /// 清空指定的业务表，用于设置页「数据管理」。
  ///
  /// 对话被清空后会立即补一个空对话，保证 AI 页面始终有可用会话。
  Future<void> clearData({required List<String> tables}) async {
    await db.clear(tables: tables);
    await reloadLocal();
    if (tables.contains(T.conversations) ||
        tables.contains(T.chats)) {
      _activeConversationId = '';
      conversations = const [];
      messages = const [];
      await ensureConversations();
    }
    notifyListeners();
  }

  /// 已保存的本地数据规模，用于设置页展示与二次确认。
  Map<String, int> get dataCounts => {
    'expenses': expenses.length,
    'medicines': meds.length,
    'conversations': conversations.length,
    'passwords': savedPasswords.length,
  };

  // ---------------------------------------------------------------- 导出

  /// 导出用的全量消息。
  ///
  /// [messages] 只缓存当前对话，导出必须覆盖所有对话，否则备份会缺数据。
  List<ChatMessage> _allMessages = const [];

  /// 重新读取所有对话的消息，供导出使用。
  Future<void> refreshAllMessages() async {
    final rows = await db.all(T.chats);
    _allMessages = rows.map(ChatMessage.fromRow).toList();
  }

  /// 导出全部数据。
  ///
  /// 会先把所有对话的消息读全，再组装 JSON —— 只导出当前对话会丢掉其它
  /// 对话的历史，那对「换手机迁移」来说是致命的。
  ///
  /// **已知缺口：目前只有导出、没有导入。** 用户拿到这份 JSON 之后无法装回去，
  /// 所以「换机迁移」这条承诺实际上只做了一半。做成完整闭环需要写导入逻辑
  /// （含冲突合并与 schemaVersion 校验），属于未交付项，见 doc/需求缺口与优先级.md。
  Future<Map<String, dynamic>> exportData() async {
    await refreshAllMessages();
    return {
      'app': 'family_life_assistant',
      // 用真实库版本，不要写死数字：之前这里写的是 3，而 SqfliteDb.schemaVersion
      // 已经是 4，导出文件自称的版本与它实际来自的库结构不符 —— 将来真做导入时
      // 会按这个字段去套一套错误的解析规则。
      'schemaVersion': SqfliteDb.schemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'expenses': expenses,
      'medicines': meds,
      'conversations': conversations.map((c) => c.toRow()).toList(),
      'messages': _allMessages.map((m) {
        return {
          'role': m.role,
          'content': m.content,
          'topic': m.topic.code,
          'conversationId': m.conversationId,
          'createdAt': m.createdAt.toIso8601String(),
        };
      }).toList(),
      // 只导出参数与强度，不含任何密码明文。
      'passwordRecords': savedPasswords.map((p) => p.toRow()).toList(),
      'counts': dataCounts,
    };
  }

  Future<String> exportJson() async =>
      const JsonEncoder.withIndent('  ').convert(await exportData());
}

/// [Store.parseAction] 的返回值。
class ParsedAction {
  const ParsedAction({
    required this.type,
    required this.row,
    required this.summary,
  });

  /// 'med' 或 'expense'。
  final String type;
  final Map<String, dynamic> row;

  /// 用于回复文案的简短描述。
  final String summary;
}

