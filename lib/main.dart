import 'dart:convert';
import 'dart:io';
 
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final s = Store();
  await s.load();
  runApp(App(s));
}

class Store extends ChangeNotifier {
  final db = DB();
  final safe = const FlutterSecureStorage();
  final uuid = const Uuid();
  List<Map<String, dynamic>> expenses = [], meds = [], chats = [];
  String url = 'https://api.deepseek.com', model = 'deepseek-flash', key = '';
  Future<void> load() async {
    await db.open();
    expenses = await db.all('expenses', 'spentAt DESC');
    meds = await db.all('meds', 'expiry ASC');
    chats = await db.all('chats', 'createdAt ASC');
    url = await safe.read(key: 'url') ?? url;
    model = await safe.read(key: 'model') ?? model;
    key = await safe.read(key: 'key') ?? '';
  }

  Future<void> expense(Map<String, dynamic> x) async {
    x['id'] ??= uuid.v4();
    x['spentAt'] ??= DateTime.now().toIso8601String();
    x['entryType'] ??= 'expense';
    await db.put('expenses', x);
    expenses = await db.all('expenses', 'spentAt DESC');
    notifyListeners();
  }

  Future<void> med(Map<String, dynamic> x) async {
    x['id'] ??= uuid.v4();
    await db.put('meds', x);
    meds = await db.all('meds', 'expiry ASC');
    notifyListeners();
  }

  Future<void> remove(String t, String id) async {
    await db.remove(t, id);
    if (t == 'expenses')
      expenses = await db.all(t, 'spentAt DESC');
    else
      meds = await db.all(t, 'expiry ASC');
    notifyListeners();
  }

  Future<void> settings(String u, String m, String k) async {
    url = u;
    model = m;
    key = k;
    await safe.write(key: 'url', value: u);
    await safe.write(key: 'model', value: m);
    await safe.write(key: 'key', value: k);
    notifyListeners();
  }

  Future<String> ask(String q, bool health) async {
    final urgent =
        health &&
        ['胸痛', '呼吸困难', '昏迷', '抽搐', '严重过敏', '误服', '过量'].any(q.contains);
    if (urgent) return '这可能是紧急情况，请立即拨打 120 或前往急诊；不要等待 AI 回复，也不要自行加量或混用药物。';
    final action = _parseAction(q, health);
    if (action != null) {
      if (health)
        await med(action);
      else
        await expense(action);
      final label = health ? '药品已加入药箱' : '账目已加入账本';
      await _chat(
        'assistant',
        '$label：${action['name'] ?? action['title']}',
        health,
      );
      return '$label，并已同步显示在对应页面。';
    }
    await _chat('user', q, health);
    if (key.isEmpty) return '请先在“设置”中填写 API Key。数据仍只保留在本机。';
    try {
      final p = health
          ? '你是家庭健康与用药信息助手，不是医生。仅能基于药箱数据进行健康科普，不诊断、不处方、不提供个体剂量。孕哺、儿童、老人、多病用药、相互作用或症状加重时建议咨询药师或医生。药箱：${jsonEncode(meds)}'
          : '你是家庭账本分析助手。仅根据账目数据回答，不得编造。给出趋势、分类观察、预算建议和数据不足处。金额为人民币。账目：${jsonEncode(expenses)}';
      final r = await http
          .post(
            Uri.parse(
              '${url.replaceFirst(RegExp(r'/$'), '')}/chat/completions',
            ),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'model': model,
              'temperature': .3,
              'messages': [
                {'role': 'system', 'content': p},
                ...chats
                    .where((x) => x['topic'] == (health ? 'h' : 'f'))
                    .map((x) => {'role': x['role'], 'content': x['content']}),
              ],
            }),
          )
          .timeout(const Duration(seconds: 45));
      if (r.statusCode < 200 || r.statusCode > 299)
        throw Exception('${r.statusCode} ${r.body}');
      final a = jsonDecode(
        utf8.decode(r.bodyBytes),
      )['choices'][0]['message']['content'].toString().trim();
      await _chat('assistant', a, health);
      return a;
    } catch (e) {
      return 'AI 服务调用失败：$e';
    }
  }

  Map<String, dynamic>? _parseAction(String input, bool health) {
    if (health) {
      final m = RegExp(r'^(?:添加药品|添加药瓶)\s*([^，,；;]+)').firstMatch(input.trim());
      return m == null
          ? null
          : {
              'name': m.group(1)!.trim(),
              'ingredient': '',
              'spec': '',
              'stock': 1,
              'expiry': '',
              'storage': '',
              'note': '由 AI 快捷录入',
            };
    }
    final m = RegExp(r'^(?:添加账目|记账)\s*([^，,；;\d]+)[，,；;\s]+(\d+(?:\.\d+)?)')
        .firstMatch(input.trim());
    return m == null
        ? null
        : {
            'title': m.group(1)!.trim(),
            'amount': double.parse(m.group(2)!),
            'category': 'AI 录入',
            'note': '由 AI 快捷录入',
            'entryType': input.contains('收入') ? 'income' : 'expense',
          };
  }

  Future<void> _chat(String role, String content, bool h) async {
    await db.put('chats', {
      'id': uuid.v4(),
      'role': role,
      'content': content,
      'topic': h ? 'h' : 'f',
      'createdAt': DateTime.now().toIso8601String(),
    });
    chats = await db.all('chats', 'createdAt ASC');
    notifyListeners();
  }

  String export() => const JsonEncoder.withIndent('  ').convert({
    'exportedAt': DateTime.now().toIso8601String(),
    'expenses': expenses,
    'medicines': meds,
  });
}

class DB {
  Database? d;
  Future<void> open() async {
    if (d != null) return;
    final root = (Platform.isAndroid || Platform.isIOS)
        ? await getDatabasesPath()
        : (await getApplicationDocumentsDirectory()).path;
    d = await openDatabase(
      join(root, 'family_life.db'),
      version: 2,
      onCreate: (x, _) async {
        await x.execute(
          'CREATE TABLE expenses(id TEXT PRIMARY KEY,title TEXT,category TEXT,amount REAL,spentAt TEXT,note TEXT,entryType TEXT DEFAULT \'expense\')',
        );
        await x.execute(
          'CREATE TABLE meds(id TEXT PRIMARY KEY,name TEXT,ingredient TEXT,spec TEXT,stock INTEGER,expiry TEXT,storage TEXT,note TEXT)',
        );
        await x.execute(
          'CREATE TABLE chats(id TEXT PRIMARY KEY,role TEXT,content TEXT,topic TEXT,createdAt TEXT)',
        );
      },
      onUpgrade: (x, old, _) async {
        if (old < 2)
          await x.execute(
            "ALTER TABLE expenses ADD COLUMN entryType TEXT DEFAULT 'expense'",
          );
      },
    );
  }

  Future<List<Map<String, dynamic>>> all(String t, String o) =>
      d!.query(t, orderBy: o);
  Future<void> put(String t, Map<String, dynamic> x) async =>
      d!.insert(t, x, conflictAlgorithm: ConflictAlgorithm.replace);
  Future<void> remove(String t, String id) async =>
      d!.delete(t, where: 'id=?', whereArgs: [id]);
}

class App extends StatelessWidget {
  final Store s;
  const App(this.s, {super.key});
  @override
  Widget build(BuildContext c) => AnimatedBuilder(
    animation: s,
    builder: (_, __) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '家庭生活助手',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xff146b84),
      ),
      home: Home(s),
    ),
  );
}

class Home extends StatefulWidget {
  final Store s;
  const Home(this.s, {super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int i = 0;
  @override
  Widget build(BuildContext c) {
    final p = [
      Dash(widget.s),
      Expenses(widget.s),
      Meds(widget.s),
      Chat(widget.s),
      Settings(widget.s),
    ];
    return Scaffold(
      body: SafeArea(child: p[i]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => i = v),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(icon: Icon(Icons.receipt_long), label: '账本'),
          NavigationDestination(icon: Icon(Icons.medication), label: '药箱'),
          NavigationDestination(icon: Icon(Icons.auto_awesome), label: 'AI'),
          NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

class Title extends StatelessWidget {
  final String a, b;
  const Title(this.a, {super.key, this.b = ''});
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(a, style: Theme.of(c).textTheme.headlineMedium),
        if (b.isNotEmpty) Text(b),
      ],
    ),
  );
}

class Dash extends StatelessWidget {
  final Store s;
  const Dash(this.s, {super.key});
  @override
  Widget build(BuildContext c) {
    final now = DateFormat('yyyy-MM').format(DateTime.now());
    final total = s.expenses
        .where((e) => (e['spentAt'] as String).startsWith(now))
        .fold<double>(0, (v, e) => v + (e['amount'] as num).toDouble());
    final alert = s.meds.where((m) {
      final d = DateTime.tryParse(m['expiry'] ?? '');
      return d != null &&
          d.isBefore(DateTime.now().add(const Duration(days: 90)));
    }).length;
    return ListView(
      children: [
        const Title('家庭生活助手', b: '本地优先 · API Key 安全保存'),
        card(
          c,
          Icons.account_balance_wallet,
          '本月支出',
          '¥${total.toStringAsFixed(2)}',
        ),
        card(c, Icons.medication, '90 天内到期', '$alert 项', alert > 0),
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text('健康模块仅提供药箱管理与健康科普，不做诊断、处方或个体化用药剂量。紧急症状请直接拨打 120。'),
        ),
      ],
    );
  }
}

Widget card(
  BuildContext c,
  IconData i,
  String a,
  String b, [
  bool warn = false,
]) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  child: Card(
    color: warn ? Colors.orange.shade50 : null,
    child: ListTile(
      leading: Icon(i, color: warn ? Colors.orange : null),
      title: Text(a),
      trailing: Text(b, style: Theme.of(c).textTheme.titleLarge),
    ),
  ),
);

class Expenses extends StatefulWidget {
  final Store s;
  const Expenses(this.s, {super.key});
  @override
  State<Expenses> createState() => _ExpensesState();
}

class _ExpensesState extends State<Expenses> {
  DateTime selected = DateTime.now();
  @override
  Widget build(BuildContext c) {
    final s = widget.s;
    final rows = s.expenses.where((e) {
      final d = DateTime.tryParse(e['spentAt'] ?? '');
      return d != null &&
          d.year == selected.year &&
          d.month == selected.month &&
          d.day == selected.day;
    }).toList();
    final income = rows
        .where((e) => e['entryType'] == 'income')
        .fold<double>(0, (v, e) => v + (e['amount'] as num).toDouble());
    final out = rows
        .where((e) => e['entryType'] != 'income')
        .fold<double>(0, (v, e) => v + (e['amount'] as num).toDouble());
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => expenseDialog(c, s),
        label: const Text('记一笔'),
        icon: const Icon(Icons.add),
      ),
      body: ListView(
        children: [
          const Title('家庭账本', b: '长按账目可修改或删除'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => setState(
                    () => selected = selected.subtract(const Duration(days: 1)),
                  ),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: c,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                        initialDate: selected,
                      );
                      if (d != null) setState(() => selected = d);
                    },
                    icon: const Icon(Icons.calendar_month),
                    label: Text(
                      DateFormat('yyyy 年 MM 月 dd 日').format(selected),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(
                    () => selected = selected.add(const Duration(days: 1)),
                  ),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: card(
                    c,
                    Icons.south_west,
                    '收入',
                    '¥${income.toStringAsFixed(2)}',
                  ),
                ),
                Expanded(
                  child: card(
                    c,
                    Icons.north_east,
                    '支出',
                    '¥${out.toStringAsFixed(2)}',
                  ),
                ),
              ],
            ),
          ),
          if (rows.isEmpty) const Empty('当天还没有账目。'),
          ...rows.map(
            (e) => Column(
              children: [
                ListTile(
                  onLongPress: () => entryMenu(c, s, e, false),
                  leading: CircleAvatar(
                    child: Icon(
                      e['entryType'] == 'income' ? Icons.add : Icons.remove,
                    ),
                  ),
                  title: Text(e['title']),
                  subtitle: Text('${e['category']} · ${date(e['spentAt'])}'),
                  trailing: Text(
                    '${e['entryType'] == 'income' ? '+' : '-'}¥${(e['amount'] as num).toStringAsFixed(2)}',
                  ),
                ),
                const Divider(height: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class Meds extends StatelessWidget {
  final Store s;
  const Meds(this.s, {super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => medDialog(c, s),
      label: const Text('添加药品'),
      icon: const Icon(Icons.add),
    ),
    body: ListView(
      children: [
        const Title('家庭药箱', b: '点击查看详情；长按可修改或删除'),
        if (s.meds.isEmpty) const Empty('还没有药品。'),
        ...s.meds.map((m) {
          final d = DateTime.tryParse(m['expiry'] ?? '');
          final bad = d != null && d.isBefore(DateTime.now());
          return Column(
            children: [
              ListTile(
                onTap: () => Navigator.push(
                  c,
                  MaterialPageRoute(builder: (_) => MedicineDetail(s, m)),
                ),
                onLongPress: () => entryMenu(c, s, m, true),
                isThreeLine: true,
                leading: CircleAvatar(
                  backgroundColor: bad ? Colors.red.shade100 : null,
                  child: const Icon(Icons.medication),
                ),
                title: Text(m['name']),
                subtitle: Text(
                  '${m['ingredient'].toString().isEmpty ? '成分未填' : m['ingredient']} · 库存 ${m['stock']}\n有效期：${m['expiry'].toString().isEmpty ? '未填' : m['expiry']}',
                ),
                trailing: bad
                    ? const Icon(Icons.warning_amber, color: Colors.red)
                    : null,
              ),
              const Divider(height: 1),
            ],
          );
        }),
      ],
    ),
  );
}

class Empty extends StatelessWidget {
  final String x;
  const Empty(this.x, {super.key});
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.all(40),
    child: Center(child: Text(x)),
  );
}

class Chat extends StatefulWidget {
  final Store s;
  const Chat(this.s, {super.key});
  @override
  State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> {
  bool h = false, busy = false;
  final q = TextEditingController();
  Future<void> send() async {
    final x = q.text.trim();
    if (x.isEmpty || busy) return;
    setState(() => busy = true);
    q.clear();
    final r = await widget.s.ask(x, h);
    if (mounted) {
      if (!widget.s.chats.any((m) => m['content'] == r))
        await widget.s._chat('assistant', r, h);
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final rows = widget.s.chats
        .where((m) => m['topic'] == (h ? 'h' : 'f'))
        .toList();
    return Column(
      children: [
        const Title('AI 助手'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('账本分析'),
                icon: Icon(Icons.insights),
              ),
              ButtonSegment(
                value: true,
                label: Text('健康科普'),
                icon: Icon(Icons.health_and_safety),
              ),
            ],
            selected: {h},
            onSelectionChanged: (v) => setState(() => h = v.first),
          ),
        ),
        if (h)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '健康科普不替代医生诊断或处方。紧急情况请立即拨打 120。',
              style: TextStyle(color: Colors.deepOrange),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final x = rows[i], user = x['role'] == 'user';
              return Align(
                alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 520),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: user
                        ? Theme.of(c).colorScheme.primaryContainer
                        : Theme.of(c).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(x['content']),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            children: [
              ActionChip(
                label: const Text('分析我的账本'),
                onPressed: () {
                  setState(() => h = false);
                  q.text = '分析我的账本';
                  send();
                },
              ),
              ActionChip(
                label: const Text('分析我的药瓶库'),
                onPressed: () {
                  setState(() => h = true);
                  q.text = '分析我的药瓶库';
                  send();
                },
              ),
            ],
          ),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('正在思考…', style: TextStyle(color: Colors.grey)),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: q,
                  onSubmitted: (_) => send(),
                  decoration: InputDecoration(
                    hintText: h ? '例如：哪些药即将到期？' : '例如：分析本月开销',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: busy ? null : send,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class Settings extends StatefulWidget {
  final Store s;
  const Settings(this.s, {super.key});
  @override
  State<Settings> createState() => _SettingsState();
}

class _SettingsState extends State<Settings> {
  late TextEditingController u, m, k;
  @override
  void initState() {
    super.initState();
    u = TextEditingController(text: widget.s.url);
    m = TextEditingController(text: widget.s.model);
    k = TextEditingController(text: widget.s.key);
  }

  @override
  void dispose() {
    u.dispose();
    m.dispose();
    k.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => ListView(
    children: [
      const Title('设置', b: 'API Key 使用系统安全存储保存'),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        child: Text('账户与 AI', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      ListTile(
        leading: const Icon(Icons.person_outline),
        title: const Text('账户'),
        subtitle: const Text('本地优先，暂未启用云端账号'),
        onTap: () => infoDialog(c, '账户', '当前版本不要求注册账号。后续同步功能会以明确授权方式提供。'),
      ),
      ListTile(
        leading: const Icon(Icons.model_training_outlined),
        title: const Text('模型'),
        subtitle: const Text('管理 API 地址、模型与密钥'),
        onTap: () => infoDialog(
          c,
          '模型',
          '在下方填写兼容 OpenAI Chat Completions 的服务配置；默认模板为 DeepSeek。',
        ),
      ),
      ListTile(
        leading: const Icon(Icons.add_circle_outline),
        title: const Text('新增模型'),
        subtitle: const Text('通过 Base URL 和模型名添加'),
        onTap: () => infoDialog(c, '新增模型', '直接修改下方 API Base URL 与模型名，然后保存即可。'),
      ),
      ListTile(
        leading: const Icon(Icons.memory_outlined),
        title: const Text('记忆'),
        subtitle: const Text('健康与账本数据默认仅用于当前对话'),
        onTap: () => infoDialog(c, '记忆', '当前版本默认不保存为跨会话全局记忆；后续会为每个对话提供独立开关。'),
      ),
      ListTile(
        leading: const Icon(Icons.notes_outlined),
        title: const Text('我的提示词'),
        subtitle: const Text('预留个性化提示词入口'),
        onTap: () =>
            infoDialog(c, '我的提示词', '0.2A 已预留入口。个性化提示词将在后续版本加入安全审查与作用域选择。'),
      ),
      ListTile(
        leading: const Icon(Icons.system_update_outlined),
        title: const Text('检查更新'),
        subtitle: const Text('当前版本 0.2A 开发版'),
        onTap: () =>
            infoDialog(c, '检查更新', '当前为 0.2A 开发版；请通过 GitHub 标签获取后续固定版本。'),
      ),
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            input(u, 'API Base URL'),
            input(m, '模型名'),
            input(k, 'API Key', secret: true),
            FilledButton(
              onPressed: () async {
                await widget.s.settings(
                  u.text.trim(),
                  m.text.trim(),
                  k.text.trim(),
                );
                if (mounted)
                  ScaffoldMessenger.of(c)
                      .showSnackBar(const SnackBar(content: Text('设置已保存')));
              },
              child: const Text('保存 AI 设置'),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => showDialog(
                context: c,
                builder: (_) => AlertDialog(
                  title: const Text('本地数据导出'),
                  content: SingleChildScrollView(
                    child: SelectableText(widget.s.export()),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
              icon: const Icon(Icons.download),
              label: const Text('查看 JSON 导出'),
            ),
            const SizedBox(height: 20),
            const Text(
              '默认：DeepSeek\nhttps://api.deepseek.com · deepseek-flash\n可接入兼容 OpenAI Chat Completions 的服务。',
            ),
          ],
        ),
      ),
    ],
  );
}

Widget input(TextEditingController c, String l, {bool secret = false}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: secret,
        decoration: InputDecoration(
          labelText: l,
          border: const OutlineInputBorder(),
        ),
      ),
    );
void infoDialog(BuildContext c, String title, String content) => showDialog(
  context: c,
  builder: (_) => AlertDialog(
    title: Text(title),
    content: Text(content),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('知道了')),
    ],
  ),
);
Future<void> expenseDialog(BuildContext c, Store s) async {
  final a = TextEditingController(),
      b = TextEditingController(),
      d = TextEditingController(text: '日常'),
      n = TextEditingController();
  var income = false;
  var when = DateTime.now();
  await showDialog(
    context: c,
    builder: (x) => StatefulBuilder(
      builder: (x, setLocal) => AlertDialog(
        title: const Text('新增账目'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('支出')),
                  ButtonSegment(value: true, label: Text('收入')),
                ],
                selected: {income},
                onSelectionChanged: (v) => setLocal(() => income = v.first),
              ),
              input(a, '名称'),
              TextField(
                controller: b,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: '金额',
                  border: OutlineInputBorder(),
                ),
              ),
              input(d, '分类'),
              TextButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: x,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                    initialDate: when,
                  );
                  if (picked != null) setLocal(() => when = picked);
                },
                icon: const Icon(Icons.calendar_month),
                label: Text('记录日期：${date(when.toIso8601String())}'),
              ),
              input(n, '备注（可选）'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(x),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final v = double.tryParse(b.text);
              if (a.text.trim().isEmpty || v == null) return;
              await s.expense({
                'title': a.text.trim(),
                'amount': v,
                'category': d.text.trim(),
                'note': n.text.trim(),
                'entryType': income ? 'income' : 'expense',
                'spentAt': when.toIso8601String(),
              });
              if (x.mounted) Navigator.pop(x);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}

Future<void> medDialog(BuildContext c, Store s) async {
  final a = TextEditingController(),
      b = TextEditingController(),
      sp = TextEditingController(),
      st = TextEditingController(text: '1'),
      ex = TextEditingController(),
      so = TextEditingController(),
      n = TextEditingController();
  await showDialog(
    context: c,
    builder: (x) => AlertDialog(
      title: const Text('添加药品'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            input(a, '药品名称'),
            input(b, '通用名 / 成分'),
            input(sp, '规格'),
            input(st, '库存'),
            input(ex, '有效期（YYYY-MM-DD）'),
            input(so, '储存条件'),
            input(n, '说明书要点 / 备注'),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(x), child: const Text('取消')),
        FilledButton(
          onPressed: () async {
            if (a.text.trim().isEmpty) return;
            await s.med({
              'name': a.text.trim(),
              'ingredient': b.text.trim(),
              'spec': sp.text.trim(),
              'stock': int.tryParse(st.text) ?? 0,
              'expiry': ex.text.trim(),
              'storage': so.text.trim(),
              'note': n.text.trim(),
            });
            if (x.mounted) Navigator.pop(x);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

Future<void> entryMenu(
  BuildContext c,
  Store s,
  Map<String, dynamic> row,
  bool medicine,
) async {
  final result = await showModalBottomSheet<String>(
    context: c,
    builder: (_) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('修改'),
            onTap: () => Navigator.pop(c, 'edit'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('删除'),
            onTap: () => Navigator.pop(c, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (result == 'delete')
    await s.remove(medicine ? 'meds' : 'expenses', row['id']);
  if (result == 'edit') {
    if (medicine)
      await medDialog(c, s);
    else
      await expenseDialog(c, s);
  }
}

class MedicineDetail extends StatelessWidget {
  final Store s;
  final Map<String, dynamic> m;
  const MedicineDetail(this.s, this.m, {super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(m['name'])),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        detail('通用名 / 成分', m['ingredient']),
        detail('规格', m['spec']),
        detail('库存', m['stock']),
        detail('有效期', m['expiry']),
        detail('储存条件', m['storage']),
        detail('说明书要点 / 备注', m['note']),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () async {
            final r = await s.ask(
              '请仅根据我的药箱资料介绍 ${m['name']} 的信息、储存和需要咨询药师的情况。',
              true,
            );
            if (c.mounted)
              showDialog(
                context: c,
                builder: (_) => AlertDialog(
                  title: const Text('健康科普'),
                  content: SingleChildScrollView(child: Text(r)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              );
          },
          icon: const Icon(Icons.auto_awesome),
          label: const Text('询问 AI'),
        ),
      ],
    ),
  );
}

Widget detail(String k, dynamic v) => Padding(
  padding: const EdgeInsets.only(bottom: 16),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(k, style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(v?.toString().isEmpty ?? true ? '未填写' : v.toString()),
    ],
  ),
);

String date(dynamic x) {
  final d = DateTime.tryParse(x?.toString() ?? '');
  return d == null ? '日期未知' : DateFormat('yyyy-MM-dd').format(d);
}
