import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 版本号比较与更新检查。
///
/// 0.2A 文档在设置里写了「检查更新」，这里把它实现成一个可用的功能：
///  - 有更新源时：拉取一份 JSON 清单，比较版本号并给出下载地址；
///  - 没有更新源 / 网络不可用：明确告知「已是最新版本」，并展示随包发布的
///    更新日志，而不是假装检查成功或长时间转圈。
class UpdateChecker {
  const UpdateChecker({this.client});

  /// 更新清单地址。为空表示未配置更新源。
  ///
  /// 之所以允许为空：本应用不附带任何服务器，硬编码一个不存在的地址只会
  /// 让「检查更新」永远失败。留空时按「无法联网核对」处理，界面会说明原因。
  static const manifestUrl = String.fromEnvironment('UPDATE_MANIFEST_URL');

  final http.Client? client;

  /// 检查更新。[now] 便于测试注入固定版本。
  Future<UpdateResult> check({
    required String currentVersion,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final source = manifestUrl.trim();
    if (source.isEmpty) {
      return UpdateResult(
        status: UpdateStatus.notConfigured,
        currentVersion: currentVersion,
        message: '未配置更新源，无法联网核对新版本。当前已是最新开发版。',
      );
    }

    final uri = Uri.tryParse(source);
    if (uri == null || !uri.hasScheme) {
      return UpdateResult(
        status: UpdateStatus.failed,
        currentVersion: currentVersion,
        message: '更新源地址无效：$source',
      );
    }

    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient.get(uri).timeout(timeout);
      if (response.statusCode != 200) {
        return UpdateResult(
          status: UpdateStatus.failed,
          currentVersion: currentVersion,
          message: '更新源返回 HTTP ${response.statusCode}',
        );
      }
      return parseManifest(
        utf8.decode(response.bodyBytes),
        currentVersion: currentVersion,
      );
    } on TimeoutException {
      return UpdateResult(
        status: UpdateStatus.failed,
        currentVersion: currentVersion,
        message: '连接超时，请检查网络后重试。',
      );
    } on SocketException catch (error) {
      return UpdateResult(
        status: UpdateStatus.failed,
        currentVersion: currentVersion,
        message: '网络不可用：${error.message}',
      );
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// 解析更新清单正文。抽成独立方法便于在测试里直接覆盖各种畸形输入。
  static UpdateResult parseManifest(
    String body, {
    required String currentVersion,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return UpdateResult(
        status: UpdateStatus.failed,
        currentVersion: currentVersion,
        message: '更新清单不是合法的 JSON。',
      );
    }
    if (decoded is! Map) {
      return UpdateResult(
        status: UpdateStatus.failed,
        currentVersion: currentVersion,
        message: '更新清单格式不正确（期望一个 JSON 对象）',
      );
    }
    final latest = decoded['version']?.toString().trim() ?? '';
    if (latest.isEmpty) {
      return UpdateResult(
        status: UpdateStatus.failed,
        currentVersion: currentVersion,
        message: '更新清单缺少 version 字段',
      );
    }
    final notes = decoded['notes']?.toString().trim() ?? '';
    final url = decoded['url']?.toString().trim() ?? '';
    final hasNewer = compareVersions(latest, currentVersion) > 0;

    return UpdateResult(
      status: hasNewer ? UpdateStatus.available : UpdateStatus.upToDate,
      currentVersion: currentVersion,
      latestVersion: latest,
      notes: notes,
      downloadUrl: url,
      message: hasNewer
          ? '发现新版本 $latest，当前是 $currentVersion。'
          : '已是最新版本（$currentVersion）。',
    );
  }

  /// 比较版本号。
  ///
  /// 返回 >0 表示 [a] 比 [b] 新。支持 `0.3.0`、`0.3.0+2`、`0.3A`、`v1.2.3`
  /// 这类写法：
  ///  - 数字段按数值比较，段数不同时缺失位按 0 处理（`1.0` == `1.0.0`）；
  ///  - 缺失位对上非数字段时，说明对方是预发布串（`1.0.0` > `1.0.0-beta`）；
  ///  - 非数字后缀（如 `0.3A` 的 `A`）按字母序比较，保证 `0.3A` 与 `0.2C`
  ///    也能正确排序。
  static int compareVersions(String a, String b) {
    final left = _segments(a);
    final right = _segments(b);
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final x = i < left.length ? left[i] : null;
      final y = i < right.length ? right[i] : null;
      final result = _compareSegment(x, y);
      if (result != 0) return result;
    }
    return 0;
  }

  static List<String> _segments(String version) => version
      .trim()
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split(RegExp(r'[.\-+]'))
      .where((segment) => segment.isNotEmpty)
      .toList();

  /// 比较单个版本段。
  ///
  /// [a] / [b] 为 null 表示该版本没有这一段。规则：
  ///  - 两边都缺 → 相等；
  ///  - 对方是数字段 → 缺失位按 0 处理（`1.0` == `1.0.0`）；
  ///  - 对方是非数字段 → 对方是预发布标记，缺失位代表正式版，缺失方更新
  ///    （`1.0.0` > `1.0.0-beta`）。
  static int _compareSegment(String? a, String? b) {
    if (a == null && b == null) return 0;
    if (a == null) return _isNumeric(b!) ? -int.parse(b) : 1;
    if (b == null) return _isNumeric(a) ? int.parse(a) : -1;

    final aNumber = int.tryParse(a);
    final bNumber = int.tryParse(b);
    if (aNumber != null && bNumber != null) return aNumber.compareTo(bNumber);
    // 数字段优先于非数字段：1.0.0 > 1.0.0-beta
    if (aNumber != null) return 1;
    if (bNumber != null) return -1;
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  static bool _isNumeric(String segment) => int.tryParse(segment) != null;
}

enum UpdateStatus {
  /// 有可用新版本。
  available,

  /// 已是最新。
  upToDate,

  /// 未配置更新源。
  notConfigured,

  /// 网络或数据问题导致检查失败。
  failed,
}

class UpdateResult {
  const UpdateResult({
    required this.status,
    required this.currentVersion,
    this.latestVersion = '',
    this.notes = '',
    this.downloadUrl = '',
    this.message = '',
  });

  final UpdateStatus status;
  final String currentVersion;
  final String latestVersion;
  final String notes;
  final String downloadUrl;
  final String message;

  bool get hasUpdate => status == UpdateStatus.available;

  /// 是否应该显示「已是最新」这类正面文案。
  ///
  /// **只有真的核对过才配说「已是最新」。** 这里曾经把 [UpdateStatus.notConfigured]
  /// 也算进来，于是默认构建（没传 `--dart-define=UPDATE_MANIFEST_URL`）下：
  /// 代码在任何网络调用之前就返回 notConfigured，页面却显示绿勾
  /// 「已是最新版本」+「未配置更新源…」。用户拿到的是**错误的安全感** ——「没检查」
  /// 和「检查了、没有新版」是两件事，不能共用一句肯定语气的话术。
  bool get isReassuring => status == UpdateStatus.upToDate;
}

/// 随包发布的更新日志。
///
/// 「检查更新」在没有更新源时也要能给出有用的信息，所以把各版本的
/// 主要变更写在包里 —— 这既是更新说明，也是交付的对照表。
class Changelog {
  const Changelog._();

  static const entries = <ChangelogEntry>[
    ChangelogEntry(
      version: '0.5.4',
      title: '一键把老对话的记忆改成「全局记忆」',
      highlights: [
        '新增入口：**设置 → 全局记忆 → 把全部对话改成「全局记忆」**，'
            '一次把之前建的老对话全部改过来',
        '为什么需要它：0.5.3 把**新建**对话的默认档位改成了「全局记忆」，'
            '但升级前就存在的对话保留自己原来的档位（不覆盖你自己设过的选择），'
            '所以老对话看起来「没变化」—— 现在有了批量入口，不用再一条条点胶囊',
        '点之前会告诉你会改**几个**对话；如果其中有原本设为「不记忆」的，'
            '会单独提醒你：改完之后那些对话的历史会开始随提问发送给模型',
        '已经是「全局记忆」的对话会被跳过，不会白改一遍顺序',
      ],
    ),
    ChangelogEntry(
      version: '0.5.3',
      title: 'AI 对话记忆默认改为「全局记忆」',
      highlights: [
        '**新建的 AI 对话默认使用「全局记忆」**（原为「仅当前对话」）。'
            '这意味着新开的对话之间可以互相引用上下文，不用每次重新交代背景',
        '**已经存在的对话不受影响**：它们保留你自己设过的记忆档位，'
            '不会被这次升级悄悄改掉',
        '每个对话仍可单独调整，入口在对话页顶部的记忆胶囊：'
            '「全局记忆」共享上下文 /「仅当前对话」只在本对话内 /「不记忆」完全不发送历史',
        '「全局记忆」的具体内容在「设置 → 全局记忆」里查看与编辑，'
            '也可以随时清空',
      ],
    ),
    ChangelogEntry(
      version: '0.5.2',
      title: '桌面组件：在桌面直接记账、记药',
      highlights: [
        '**新增桌面组件**，一共四种：**记账**、**AI 记账**、**记药**、**AI 记药**。'
            '在「设置 → 桌面组件」里可以一键添加到桌面，也可以手动添加',
        '**「记账 / 记药」点开就是一张小卡片**，直接在桌面上填完保存，'
            '不用等 App 打开。字段与 App 内**完全一致**：'
            '记账可选支出/收入、金额、分类、名称、日期、备注；'
            '记药填名称、规格、数量、有效期、储存条件',
        '**「AI 记账 / AI 记药」点开进 App，说一句话就行**：'
            '「今天买菜 20」「布洛芬两盒」，由 AI 解析成结构化记录后自动入库。'
            '这两版之所以要进 App，是因为桌面组件本身放不了输入框（系统限制）',
        '组件上会显示**实时汇总**：记账组件显示今日支出与笔数，'
            '记药组件显示药箱总数与需要关注的药品数（过期、临期、没库存）',
        '**桌面记完不会丢**：记录先安全落在本机，回到 App 自动写入账本/药箱，'
            '按记录编号去重，重复同步也不会记成两条',
        '「设置 → 桌面组件」里每一种都写清了点开之后会发生什么，'
            '并解释为什么 AI 版需要打开 App —— 免得选错了以为功能坏了',
      ],
    ),
    ChangelogEntry(
      version: '0.5.1',
      title: '首个发行版：账本 + 药箱 + 联网 AI 助手 + 密码生成器',
      highlights: [
        '这是**第一个发行版**（前面 0.1A～0.4I 都是开发版）。'
            '从这一版起，版本号用三段式数字，不再带开发代号',
        '**真正能联网的 AI 助手**。聊天和药品资料查询都会联网检索，'
            '思考气泡会显示「正在联网搜索」；检索到的网页按可信度分级'
            '（官方 → 机构/厂家 → 其他网站），官方来源排在最前，'
            '并明确提示网页质量参差、不要只看一条',
        '**家庭账本**：记收支、分类统计、按月份翻看，支持备注与类型区分',
        '**家庭药箱**：记录药品名称/成分/规格/存量/有效期/存放位置，'
            '可联网补充说明书信息（用法用量、适应症、禁忌、不良反应等），'
            '并把检索到的来源网址一并存下来、点一下可复制',
        '**密码生成器**：本地生成、强度与熵值评估，不上传任何数据',
        '**数据全部留在本机**。账本、药箱、对话、密码记录都只存在手机本地数据库，'
            'API Key 存在系统安全存储里，App 不往任何服务器同步',
        '安全边界：不诊断、不开处方、不给个人化剂量；'
            '遇到紧急情况的关键词会直接提示拨打 120',
        '本次还修掉一个启动崩溃：清除应用数据后 App 起不来'
            '（全新安装的建表语句漏了一列）。已补上并加了断言防止再犯',
      ],
    ),
    ChangelogEntry(
      version: '0.4I',
      title: '修复：清除应用数据后 App 起不来（全新安装缺一列）',
      highlights: [
        '**你报的那个崩溃修好了**。在系统设置里「清除数据」之后打开 App 直接停在'
            '「应用启动失败」，错误是 `table conversations has no column named pinnedAt`',
        '**根因**：`conversations` 表的「置顶」那一列（`pinnedAt`）是**升级时补的**，'
            '而**全新安装的建表语句里从来没补过它**。全新安装走 `onCreate`、'
            '升级走 `onUpgrade`，两条路互不相干 —— 于是**升级上来的用户正常，'
            '新装或清过数据的用户一写对话就崩**。这是典型的「开发者自己永远踩不到」的坑：'
            '我自己的库是一路升级上来的，所以一切正常',
        '**修法两层**：① 基础建表补齐这一列；② 全新安装也**再跑一遍迁移**，'
            '让两条路必然收敛到同一套结构 —— 以后新增列不会再出现这种偏差',
        '**为什么 480 项测试没抓住它**：那些测试都是**纯 SQL 字符串断言**，'
            '没有一项比较过「全新安装」和「升级安装」产出的列集合是否相等。'
            '现在新增 `test/schema_consistency_test.dart` 专门做这个比较，'
            '并且把「基础建表必须包含所有迁移补的列」变成断言',
      ],
    ),
    ChangelogEntry(
      version: '0.4H',
      title: '模型收敛到 Flash：默认改 deepseek-flash，Pro 不再出现在可选项里',
      highlights: [
        '**默认模型改成 `deepseek-flash`**。它和界面上显示的「v4.1 flash」'
            '是**同一个模型，只是叫法不同** —— 而 `deepseek-flash` 是接口'
            '`/models` 真实返回的名字，所以用接口的真名，避免服务商不认',
        '**「获取可用模型」不再列出 Pro**（你说「不支持 pro，这点货不需要更贵的」）。'
            '原来那份列表会把全部模型做成可点胶囊，Pro 就在里面 —— '
            '**误点一下，之后每次请求都按 Pro 计费，界面毫无提示**。'
            '现在从源头上不让它出现，比事后提醒可靠',
        '判据用「名字里含 pro」而不是写死 `deepseek-v4-pro`：'
            '将来服务商出 `v5-pro` 这条规则照样拦得住，而写死的名字会'
            '**悄悄失效**，胶囊又冒出来',
        '**顺带修一个我自己引入的错**：第一版过滤写成「不在列表里或不是默认值就改写」，'
            '于是你手选的 `deepseek-chat` 一拉列表就被悄悄改成 flash。'
            '现在的判据是「**已经不支持、且服务商也确实不再返回它**」才改写 —— '
            '你选的东西不该被「拉列表」这个动作改掉',
      ],
    ),
    ChangelogEntry(
      version: '0.4G',
      title: '聊天输入框：回车改成换行，不再一按就发出去',
      highlights: [
        '**回车 = 换行**（你报的问题）。原来输入框明明是**多行**框'
            '（能长到 4 行），却把回车键配成了「发送」—— 想分两段写一句'
            '稍长的问题（比如先列药名再问禁忌）根本没机会，按一下就发出去了。'
            '现在回车老老实实插入换行，长问题可以慢慢写',
        '**发送改为点右边那个圆形按钮**。这是上面的必然代价，说清楚：'
            '多行输入必须有换行键，而换行键和发送键不能是同一个。'
            '很多人习惯的「回车发送」在这个输入框里会和「换行」冲突，'
            '既然你明确要换行，那发送就交给按钮',
        '顺带确认：**多行内容发出去时换行不会被吃掉** —— '
            '你写的两段会原样带进问题里，不会挤成一行',
      ],
    ),
    ChangelogEntry(
      version: '0.4F',
      title: '真正联网了：药品资料与主对话都能联网检索，思考气泡显示「正在联网搜索」',
      highlights: [
        '**联网搜索真的做出来了**。0.4D 我往聊天端点发内置 `web_search` 工具，'
            '被服务端**静默忽略**；0.4E 我又据此下结论说「API 不支持联网、要接第三方」——'
            '**这句是错的**。真相是 DeepSeek 有**另一个端点**原生支持联网：'
            'Anthropic 兼容的 `/anthropic/v1/messages` + `web_search_20250305` 服务器工具。'
            '同一个 Key、同一个服务商，**换个端点就能联网**',
        '**药品资料改成真正的联网检索**：按钮改回「联网查询资料」'
            '（能力有了，名字就不该再含糊）；来源里写**真实检索到的网址**，'
            '不再是「模型已有知识」',
        '**来源按可信度分级并排序**：官方（药监局等 gov.cn）→ 机构/厂家（医院、药企）→ 其他网站。'
            '实测查「布洛芬缓释胶囊」拿到 16 条来源，其中 14 条是卖药电商与资讯站 ——'
            '**「联网查到了」不等于「查到了权威来源」**，所以每条都标出等级，'
            '点一下可复制网址自己去核对',
        '**主对话也能联网搜索**：账本与健康两个模块都会联网。'
            '联网工具**始终挂着，搜不搜由模型判断** —— '
            '问「今天买菜20」不会产生任何检索开销，问「布洛芬有什么副作用」它自己会去搜。'
            '这样做还有个好处：界面状态永远是真实的（见下一条）',
        '**思考气泡显示「正在联网搜索」**：等回复时按真实进度显示'
            '「正在思考 → 正在联网搜索（配小图标）→ 正在整理资料」，'
            '能搜到多少条来源也会实时显示。'
            '**这句提示不是定时器演的**：只有服务端真的回了 `server_tool_use` 事件，'
            '界面才会说在联网 —— 没搜就一直显示「正在思考」',
        '修好一个会让「联网」整个失效的字符串处理错误：SSE 事件的 `data` 是'
            '**JSON 字符串**，早先被直接当 map 取字段，于是每个事件都解析成 null，'
            '表现是「服务端没有返回内容」。**事件名是对的、只有内容全空**，极难从现象反推',
      ],
    ),
    ChangelogEntry(
      version: '0.4E',
      title: '更正「联网查询」说法：改为「让 AI 补充资料」+ 新增药监局官方查询入口',
      highlights: [
        '**更正 0.4D 的一处错误说法**。0.4D 写的是「可联网查询药品资料、'
            '服务商不支持时标注未真正联网核实」。查证 DeepSeek 开放平台文档后确认：'
            'API 的工具列表**只接受 function 类型，内置工具类型会被忽略** ——'
            '那个「联网查询」**从来没有真正联网过**，而「未真正联网核实」这句话，'
            '是在描述一件从没发生过的事',
        '按钮改名：「联网查询资料」→「让 AI 补充资料」，不再承诺一个做不到的能力',
        '资料出处如实写成「模型已有知识，自述依据…；未经核实，仅供参考」，'
            '**不再出现「联网」「检索」任何字样**（连否定句也不写 ——'
            '「未经联网核实」同样会让人以为本来能联网、只是这次没成）',
        '**新增「去药监局查询（权威来源）」**：一键复制药名，并给出'
            '国家药监局官方数据查询入口。这是这条链路里唯一真正'
            '「可靠准确权威」的来源，也是唯一能负责任地指向的地方',
        '修好「补充资料失败却说不清原因」：以前请求失败会静默返回空，'
            '界面只显示「资料出处：暂无」，用户分不清是没配 API Key、网络问题，'
            '还是模型没按格式回答。现在这三种情况分别给出提示',
        '修复更新日志把 Markdown 星号原样显示（「按**给药途径**判断」）——'
            '这一页漏接了 SimpleMarkdown，现已接上并有测试守住',
      ],
    ),
    ChangelogEntry(
      version: '0.4D',
      title: '药品资料补全与准确分类、消息改完自动重发、药品详情版面重做',
      highlights: [
        '药品分类改为按**给药途径**判断：新增常见药品词典，'
            '「布洛芬」「阿莫西林」「碘伏」这类只有通用名、不带剂型的药不再掉进「其他」；'
            '同时支持在药品表单里**手动指定**内服/外用，手选优先于自动判断',
        '药品详情页新增六个说明书级字段：用法用量、治疗范围/适应症、药效/作用、'
            '不良反应、禁忌、注意事项',
        // ⚠️ 这一条描述的是 0.4D 当时的**意图**，但它没有成立（见 0.4E 第一条）。
        // 故意保留原文不改写历史：读更新日志的人需要看到「当时说了什么」，
        // 再由 0.4E 那一条去更正。悄悄改掉旧条目等于抹掉自己的错误。
        '药品详情页新增「联网查询资料」（**此说法在 0.4E 已被更正，'
            '实际从未真正联网**）：向 AI 查询后自动回填上述字段，'
            '并记录来源与查询时间；查不到就写「未知」而不是编造内容',
        '药品详情页版面重做：修复卡片宽度不一致（宽窄两张卡左右对不齐）的尺寸问题；'
            '按「状态 → 基本信息 → 用法与药效 → 安全信息 → 资料出处」分区，'
            '字段再多也能找到「禁忌在哪」',
        '修改已发出的消息后**自动重新发送**：改的那条原地替换（不新增重复消息）、'
            '旧回答删掉、再让 AI 按新内容重答一遍，等待过程与首次发送完全一致、可暂停',
        '修复「修改后重发会留下旧回答」的问题（新旧两个答案并存的根因是'
            '按时间戳比大小，而写入用户消息与回复可能落在同一微秒）',
      ],
    ),
    ChangelogEntry(
      version: '0.4C',
      title: '图表重绘、对话可用性：置顶 / 修改消息 / 不点发送不建对话',
      highlights: [
        '账本统计图表重绘：柱子改为上浅下深的渐变、加水平网格线、加零线基线，'
            '最高的一根用主题色并标出金额',
        '图表升级为带标题与合计的卡片，「各月支出 / 每天支出」和「合计 ¥xxx」'
            '直接写在图上方，不再是一排没有说明的柱子',
        '长按自己发的消息可以「修改」正文（只改记录，不会重新提问）或「复制」',
        '长按助手回复可以「复制」，也可以删除任意一条消息',
        '历史对话支持「置顶」：置顶区与普通区分别带小标题，中间有明确分界线，'
            '置顶的对话用实心图钉图标标出',
        '点「创建对话」不再立刻产生一条空对话；只有真的发出第一条消息才创建，'
            '点进去看一眼又退出来不会在列表里留下「新对话」',
        '修复对话操作菜单在 360×800 屏幕上溢出 37 像素的问题（菜单项变多会撑破布局）',
      ],
    ),
    ChangelogEntry(
      version: '0.4B',
      title: '界面重排：账本与药箱拆成多级页面，整体去掉「AI 味」',
      highlights: [
        '账本拆成三级，用顶部标签切换：「今日」（记账按钮 + 当天明细 + 当天收支）、'
            '「汇总」（周/月/年的文字数据与支出柱状图）、「分类」（周/月/年的分类占比）',
        '账本首页不再堆着「本月收支」卡与「本月分类统计」，也不用再滚很长才能看到当天明细',
        '药箱拆成「药品」「统计」两级，去掉「全部/已过期/即将过期/常用药」四张统计卡',
        '去掉账本与药箱顶部的大标题和副标题，页面直接从内容开始',
        'AI 模块介绍页的历史对话收进右上角侧滑菜单，对话再多也不再把页面拉长',
        '对话页等待回复时，发送按钮变成暂停按钮，点一下即可停止等待（提问会保留）',
        '整体视觉改为紧凑克制的记账工具风格：小圆角、去掉卡片投影、细线单色图标',
        '紧急就医关键词补充口语说法：「胸口剧痛」「喘不上气」「叫不醒」等也能识别',
      ],
    ),
    ChangelogEntry(
      version: '0.4A',
      title: 'AI 反向录入修复：不再漏记、错记与重复记',
      highlights: [
        '修复「当前提问没有发给模型」：请求里漏掉了你刚说的那句话，'
            'AI 只能照着上一轮回答（表现是「我说买菜20，它却记了上一句的250」）',
        '修复在账本里说话却往药箱写数据：动作类型现在由模块决定，不再由模型决定',
        '同名药品不再新增一条，改为叠加库存并说明「原有 2 盒 + 新增 3 盒 → 共 5 盒」',
        '陈述句（「我有两盒护肝片」）直接录入，不再反问保质期等信息',
        '明确指令（「帮我把布洛芬加到药箱里去」）不再被回成自我介绍',
        '模型把上一轮内容当指令时不会重复记账：历史已裁剪并注明省略',
        '版本号改为开发版规则（0.4A / 0.4B / 0.4C，正式版 0.4）',
      ],
    ),
    ChangelogEntry(
      version: '0.3C',
      title: 'AI 模块拆分为账本分析与健康科普',
      highlights: [
        '点开 AI 先看到两个模块入口，进入后是模块介绍页，两个模块完全独立',
        '模块介绍页上没有输入框：必须先「创建对话」才进入对话页',
        '对话页只留消息与输入框，不再放介绍卡、建议问题与统计',
        '账本分析与健康科普各有自己的对话列表，互不可见、互不串消息',
        '发消息不再按内容自动切换主题：在账本模块问药品问题也不会跳走',
        '对话气泡与输入框的字号缩小一档，长对话更紧凑',
        '修复首页「问问 AI」直接落进对话页、绕过模块选择的问题',
      ],
    ),
    ChangelogEntry(
      version: '0.3B',
      title: '启动崩溃与旧数据升级修复',
      highlights: [
        '修复升级到 0.3A 后启动白屏：schema v4 会给旧库的 chats 表补上 conversationId 列',
        '旧版本的聊天记录自动认领到对应主题的对话，历史消息不丢',
        '启动失败不再白屏：改为显示错误详情页，并提供「重试」入口',
        '安全存储损坏时退回默认设置继续启动，只需重新填写一次 API Key',
        '修复窄屏（360×800）下「添加药品」抽屉按钮被顶出屏幕、账本日期行溢出的问题',
        '修复弹窗与抽屉里 controller 过早释放导致的断言异常',
      ],
    ),
    ChangelogEntry(
      version: '0.3A',
      title: '密码生成器模块',
      highlights: [
        '随机密码：长度 4-64、大小写 / 数字 / 符号自由勾选、排除易混淆字符、相邻不重复',
        '助记口令：3-8 个单词、可选分隔符、首字母大写与结尾数字',
        '密钥生成：最长 128 位、可分组复制，默认排除易混淆字符',
        '强度评估：按熵值给出 0-4 级强度与进度条',
        '本地记录：只保存用途、长度与强度，绝不保存密码明文',
      ],
    ),
    ChangelogEntry(
      version: '0.2C',
      title: '按示例图重做全部界面',
      highlights: [
        '建立设计体系：8pt Grid 间距、字号层级、语义色 Token',
        '首页重做为产品中心：头图、本月概览、快捷功能四宫格、隐私提示、最近记录',
        '账本页：月份切换、本月收支三栏卡（可隐藏金额）、分类筛选、日期导航、分类统计',
        '药箱页：四项统计、搜索、分类筛选、药品卡片与到期标记',
        '表单改为底部抽屉：字段名在输入框上方、库存步进器、日期选择、字数计数',
        'AI 页：主题卡、欢迎卡片、日期分隔、左右气泡、快捷问题胶囊、思考计时',
      ],
    ),
    ChangelogEntry(
      version: '0.2B',
      title: '设置信息架构与 AI 页重构',
      highlights: [
        '设置改为多级结构：账户与 AI / 数据与隐私 / 实用工具 / 关于',
        '新增二级页：AI 服务、AI 对话设置、我的提示词、数据管理、全局记忆、使用说明',
        '统一视觉规范：浅灰蓝背景 + 白色内容卡 + 深青品牌色 + 20dp 圆角 + 极弱阴影',
        '弹窗表单重做，去掉「工程 Demo 感」',
      ],
    ),
    ChangelogEntry(
      version: '0.2A',
      title: '功能补全',
      highlights: [
        '多对话管理：新建 / 重命名 / 清空 / 删除，消息按对话隔离',
        '记忆机制：仅当前对话 / 存入全局记忆 / 不记忆 三档可选',
        'AI 反向操作：说「添加药品 布洛芬 库存 5」可自动入药箱，记账语句自动入账本',
        'AI 图表输出：模型按约定格式给出数据，客户端渲染成分类对比与趋势图',
        '账本：年 / 月 / 日切换、收入支出统计、长按修改删除',
        '药箱：详情页可查看完整信息并一键询问 AI',
        '设置新增检查更新入口',
      ],
    ),
  ];

  static String get latest => entries.first.version;
}

class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    required this.title,
    required this.highlights,
  });

  final String version;
  final String title;
  final List<String> highlights;
}
