# 家庭生活助手

0.4H 开发版。基于 Flutter 的本地优先家庭账本、家庭药箱与密码生成器，预留 Android、iOS 和 macOS 平台。

> 版本号规则：**开发版用字母，正式版用数字**（`0.4A` → … → `0.4F` → `0.4G` → `0.4H`，
> 正式发布为 `0.4`，进入下一阶段为 `0.5A`）。每次更新要做三件事：
> 递增 `lib/pages/settings.dart` 的 `appVersion`、同步 `pubspec.yaml` 的
> `version:`（**并把 `+` 后面的 `versionCode` 加一**，否则 Android 拒绝覆盖安装）、
> 在 `Changelog.entries` 最前面加一条。
>
> Android 的 `versionName` 不接受字母，所以 pubspec 里写 `version: 0.4.0+12`，
> 与 App 内的 `0.4H` 是同一个版本（`<major>.<minor>` 必须一致）。
> 系统「应用信息」显示 `0.4.0`、App 内显示 `0.4H` 是**预期行为**。
> `test/version_consistency_test.dart` 会拦截漂移；历史上 versionCode 曾停在 2，
> 导致后续包装不上。

数据全部保存在本机：账目、药箱、对话都在本地 SQLite，API Key 存在系统安全存储。只有你主动提问时，才会把必要的摘要发送给模型服务商。

## 已实现

### 家庭账本（三级页面，顶部标签切换）

- 第一级 **今日**：记账按钮 + 当天明细列表 + 当天收 / 支 / 结余，可一键隐藏金额。
- 第二级 **汇总**：按 自然周 / 自然月 / 自然年 给出文字数据（支出、收入、结余、日均支出）
  与支出柱状图。
- **图表是带标题与合计的卡片**（0.4C）：柱子上浅下深渐变、有水平网格线与零线基线，
  最高的一根用主题色并标出金额，一眼能看出峰值在哪天 / 哪个月。
- 第三级 **分类**：同一个周期范围内的分类统计，按金额排序并显示占比，收入单独分组。
- 记录、修改、删除账目；支持支出 / 收入两种类型。
- 长按账目弹出「修改 / 删除」，修改沿用原 id，不会产生重复记录。
- 账目之间用分割线区分；已取消容易误操作的左滑删除。

### 家庭药箱（两级页面）

- 第一级 **药品**：药品列表 + 搜索 + 分类筛选，只放列表本身。
- 第二级 **统计**：药箱概览（全部 / 已过期 / 即将过期 / 常用药）、保质期完整性、分类分布。
- 药名、通用名 / 成分、规格、库存、有效期、储存条件与备注。
- **六个说明书级字段**（0.4D）：用法用量、治疗范围 / 适应症、药效 / 作用、不良反应、
  禁忌、注意事项。表单按「基本信息 / 用法与药效 / 安全信息」三组录入。
- **分类按给药途径自动判断**（0.4D）：先用一张常见药品词典按通用名定途径
  （`lib/core/med_dict.dart`），再用剂型关键词兜底，**外用优先于内服**
  （把外用药误判成内服的代价更大）。判不出来就归「其他」并在详情页提示可手动指定，
  表单里也能直接手选内服 / 外用，**手选优先于自动判断**。
- 搜索（名称 / 通用名 / 规格 / 备注）+ 分类筛选（常用 / 内服 / 外用 / 儿童 / 慢性病 / 其他）。
- 有效期用日期选择器录入，按「已过期 / 临期 / 正常」着色；列表按到期紧迫度排序。
- **药品详情页按用途分区**（0.4D）：状态卡（库存 / 有效期 / 分类 / 修改）
  → 基本信息 → 用法与药效 → 安全信息 → 资料出处 → 操作按钮。
  所有卡片左右边缘对齐（`CrossAxisAlignment.stretch`）。
- **联网查询资料**（0.4D 引入，0.4E 改名，**0.4F 才真正联网**）：向 AI 查询说明书级
  信息并回填上述字段，同时**记录来源与查询时间**并显示在「资料出处」里。
  查不到的字段写「未知」，**不编造内容**（`lib/ai/med_info.dart`）。
- ⚠️ **「联网」这两个字在本项目里翻过三次车**，值得记住：
  ① **0.4D** 往 `chat/completions` 发 `{"type":"web_search"}` —— 该端点的 `tools`
  只接受 `function` 类型、「**内置工具类型会被忽略**」，于是**静默无效**：
  HTTP 200、正常返回、联网没发生。我还据此写了一条「降级并标注未真正联网核实」
  的分支，而那条分支**从未执行过** —— 等于给用户看了一句假话。
  ② **0.4E** 我据此宣布「DeepSeek API 不支持联网，要接第三方搜索」。**这句是错的**：
  我只验证了一条路就下了全局结论。
  ③ **0.4F** 查 DSH 自己的实现（`@deepseek-ai/dsh-web-search-deepseek`）才发现真相 ——
  **同一个服务商、同一个 Key，换个端点就能联网**：

  | | 聊天 | 联网搜索 |
  |---|---|---|
  | 路径 | `{base}/chat/completions` | `{base}/anthropic/v1/messages` |
  | 协议 | OpenAI 兼容 | **Anthropic 兼容** |
  | 联网 | 无 | `web_search_20250305` 服务端工具 |

  所以 `AiWebSearchClient` 是**独立于 `AiClient` 的第二个客户端**，不是给聊天
  加个参数。实现与实测记录见 `lib/ai/web_search.dart`。

- **来源按可信度分级**（0.4F）：官方（`gov.cn`）→ 机构/厂家（医院、药企）→ 其他网站，
  排序时官方置顶。理由是实测数据：查「布洛芬缓释胶囊」拿到 **16 条来源，
  其中 14 条是卖药电商与资讯站** ——「联网查到了」不等于「查到了权威来源」。
  点某条可复制网址，自己去核对（不直接跳转外部浏览器：本机装不了 `url_launcher`，
  且跳转会把用户带到一个我们无法核实的页面）。
- **「去药监局查询（权威来源）」**（0.4E）：一键复制药名并给出
  [国家药监局数据查询](https://www.nmpa.gov.cn/datasearch/home-index.html)入口。
  这是这条链路里唯一真正「可靠准确权威」的来源 —— 官方数据库、可自行核对。
  刻意**不按药名拼查询串**（官方地址不稳、拼错会把用户带到仿冒站点）。
- **主对话也能联网**（0.4F）：`web_search` 工具**始终挂着，搜不搜由模型判断**。
  问「今天买菜20」不会产生检索开销；问「布洛芬有什么副作用」它自己去搜。
  等回复时思考气泡按**真实事件**显示「正在思考 → 正在联网搜索 → 正在整理资料」——
  只有服务端真的回了 `server_tool_use`，界面才会说在联网。
- 药品详情页也可一键在健康主题下询问 AI。
- 支持 `2027-05-01`、`2027/5/1`、`2027年5月1日`、`2027年5月` 等写法。

### AI 助手（拆分为两个独立模块）

- 点开 AI 先看到两个入口：**账本分析** 与 **健康科普**，点进去是各自的模块介绍页。
- **介绍页上没有输入框**：先看助手能力与安全声明，点「创建对话」进入对话页。
- **不点发送不会创建对话**（0.4C）：点「创建对话」只是打开一页空白对话，
  只有真的发出第一条消息才落库。点进去看一眼又退出来，不会在列表里留下「新对话」。
- **历史对话收在右上角侧滑菜单里**（0.4B）：对话再多也不会把介绍页拉得很长，
  菜单里可点选、长按置顶 / 重命名 / 记忆范围 / 清空 / 删除。
- **对话可以置顶**（0.4C）：置顶区与普通区各带小标题，中间有一条明确的分界线，
  置顶的对话用实心图钉图标标出，取消置顶即回到普通区。
- **长按消息可以修改或复制**（0.4C）：自己发的消息可「修改」正文或「复制」，
  助手的回复可「复制」；两种消息都能「删除」。
- **修改后会自动重新发送**（0.4D）：改完那条**原地替换**（id 与时间戳都不变，
  时间轴上仍只有一条提问，不会出现「改前一份、改后一份」），
  它之后针对旧问题的助手回复会被删掉，然后按新内容重新提问一次。
  等待过程与首次发送完全一致，**同样可以暂停**。
  助手回复不允许编辑，因为它是「模型当时这么回答」的记录。
- **对话页只放消息与输入框**：没有介绍卡、建议问题、统计这类东西。
- **等待回复时发送按钮变成暂停按钮**（0.4B）：点一下即停止等待，回到可输入状态；
  提问会保留在记录里，那条回复不会补上来。紧急就医提示不受暂停影响。
- 两个模块从界面到机制完全独立：各自的对话列表、消息、记忆开关、文案与配色
  都各自一套，互不可见、互不串消息。
- 对话可以新建 / 重命名 / 置顶 / 清空 / 删除（在侧滑菜单里长按对话）；新建只会建到当前模块。
- 对话气泡与输入框的字号比正文小一档，长对话读起来更紧凑。
- 记忆三档：仅当前对话 / 存入全局记忆 / 不记忆（关闭时本地仍保留记录）。
- 图表输出：模型按约定格式返回数据，客户端渲染成真实的分类对比图与趋势图。
- 反向操作：说「添加药品 布洛芬 库存 5 有效期 2027-01-02」直接入药箱；记账语句直接入账本。
- **不会自动切换模块**：在账本分析里问药品问题也留在账本分析，想聊健康请回入口页进健康科普。
- 思考计时（正在分析你的账目数据… 12s）、日期分隔、左右气泡。
- 轻量 Markdown 渲染：不会把 `##`、`**` 这类标记原样显示给用户。

### 密码生成器（0.3A 新增）

- 随机密码：长度 4-64，大小写字母 / 数字 / 符号自由勾选，可排除易混淆字符（`0OoIl1|`）、可要求相邻不重复、可要求每类字符至少出现一次。使用 `Random.secure()`。
- 助记口令：3-8 个单词、分隔符可选、首字母大写、结尾附加 4 位数字。
- 密钥生成：最长 128 位，可按 4 / 8 / 16 分组，默认排除易混淆字符。
- 强度评估：按熵值给出 0-4 级强度、进度条与标签。
- 本地记录：只保存用途、长度与强度，**绝不保存密码明文**（本机数据库是明文 SQLite，写明文等于把密码落到普通文件里）。

### 设置

- 多级信息架构：账户与 AI / 数据与隐私 / 实用工具 / 关于。
- AI 服务：Base URL、模型名（点「获取可用模型」拉取服务商**真实**列表后点选，也可手工填写）、API Key（默认隐藏）、测试连接。
  模型名以服务商返回的列表为准，代码里**不写死任何模型名对照表**，也不会静默改写你选的名字。
- 反向录入：在对话里说「添加药品 a,b,c」「记账 买菜 32.5, 打车 18」即可批量落库。理解方式三档可选：
  **智能**（先本地即时识别，识别不了再交给 AI）、**仅 AI 理解**（支持「还有两盒」「下个月过期」等口语说法）、
  **仅本地识别**（不联网、不消耗额度，只认固定写法）。
- AI 对话设置：两个模块互相独立的说明与三档记忆，以及当前对话状态。
- 我的提示词：为两个主题补充个性化要求（安全约束不可被覆盖）。
- 数据管理：各表数据量、导出 JSON 到剪贴板、分表清空（危险操作带二次确认）。
- 全局记忆：跨对话共享的长期偏好。
- 检查更新：与更新源比对版本；未配置更新源时明确说明原因，并展示随包发布的更新日志。
- 使用说明：四步上手、常见问题与紧急就医提示。

### 通用

- 设计体系：8pt Grid 间距、固定字号层级、语义色 Token（品牌色 / 收支色 / 状态色 / 分类色板）。
- 视觉风格：浅灰蓝背景 + 白色内容卡 + 深青品牌色（`#145A72`）+ 20dp 圆角 + 极弱阴影。
- 紧急症状关键词分流，命中即给出就医提示且不消耗 API 调用。
  关键词覆盖**口语说法**（「胸口剧痛」「喘不上气」「叫不醒」「吃错药」等），
  不只认「胸痛」「呼吸困难」这类书面词 —— 着急时人打的是前者。
- 数据库 schema v4：内置结构升级，旧版本库会自动补齐缺失的表与列，历史账目、药品与聊天记录都不丢。
- 启动失败不会白屏：显示错误详情页并提供「重试」入口。

健康模块仅用于药品管理和健康科普；**不提供诊断、处方或个体化剂量建议**。紧急情况请立即拨打 120 或当地急救电话。

## 运行

```powershell
flutter pub get
flutter run -d <Android设备ID>
```

首次使用 AI 前，在「设置 → AI 服务」中填写 Base URL、模型名和 API Key，并点击「测试连接」确认可用。
默认 DeepSeek 配置为 `https://api.deepseek.com` 和 `deepseek-chat`。

如需启用「检查更新」的在线核对，用更新源地址构建：

```powershell
flutter build apk --release --dart-define=UPDATE_MANIFEST_URL=https://example.com/app-manifest.json
```

清单格式：

```json
{ "version": "0.5.0", "notes": "本版更新说明", "url": "https://example.com/app-0.5.0.apk" }
```

未指定时「检查更新」会明确提示「未配置更新源」，并展示内置的更新日志。
在线核对为后续计划：客户端逻辑已就绪，接入时只需提供清单 JSON 的托管地址。

## 验证

```powershell
flutter analyze                      # 静态分析（必须零问题）
flutter test                         # 单元测试 + Widget 测试（297 项，19 个文件）
flutter test test/tools/render_pages.dart --tags preview   # 窄屏预览 + 无溢出 + 出图稳定
flutter build apk --debug            # 构建校验
flutter build apk --release          # 发布构建
```

构建产物里可以核对版本号是否正确落进包（`versionCode` 不递增会导致装不上）：

```powershell
& "$env:LOCALAPPDATA\Android\Sdk\build-tools\37.0.0\aapt2.exe" dump badging `
  build\app\outputs\flutter-apk\app-release.apk | Select-String "package:"
# 期望：versionCode='4' versionName='0.4.0'
```

窄屏布局检查 / 出图预览（360×800 渲染主要页面，PNG 输出到 `test/tools/preview/`；
带 `preview` 标签，默认的 `flutter test` 会跳过）：

```powershell
flutter test test/tools/render_pages.dart --tags preview --update-goldens
```

## 代码结构

```
lib/
  main.dart              入口：加载本地数据后启动
  theme.dart             视觉规范：Gap（8pt Grid）、Tone（语义色）、Categories（分类色板）
  core/
    util.dart            日期/金额/库存解析，药品有效期语义（ExpiryInfo）
    stats.dart           纯函数统计口径（收入与支出严格分开）
    topic.dart           主题枚举 Topic 与记忆档位 MemoryScope
    chat_mode.dart       ChatMode：账本分析 / 健康科普两个独立模块的定义
    update.dart          版本号比较、更新清单解析、内置更新日志
  data/
    db.dart              LocalDb 接口 + SqfliteDb 实现（schema v6：表结构与迁移集中在此）
    models.dart          Conversation / SavedPassword / ChatMessage
    store.dart           全局状态与业务逻辑（ChangeNotifier）
  ai/
    client.dart          兼容 OpenAI Chat Completions 的客户端与错误翻译
                         （0.4D：complete(webSearch:) 可选带服务端 web_search 工具，
                          parseSources 解析引用来源）
    med_info.dart        药品资料整理：提示词 / 回复解析 / 来源描述 / 药监局入口（0.4E）
    prompt.dart          系统提示词构造：统计摘要 + 预算内明细 + 图表协议
    chart.dart           图表代码块解析（含括号配平兜底）
  core/
    med_classify.dart    药品分类（给药途径判定）+ 标签计算（0.4D）
    med_dict.dart        常见药品 → 给药途径词典（0.4D；新增条目务必同步加测试）
    ...
  security/
    password_engine.dart 密码 / 口令 / 密钥生成与强度评估
  widgets/
    ui.dart              0.4B 设计基元：R（小圆角）/ Hairline / SegmentedTabs /
                         PeriodNav / StatLine / ShareBar / SectionLabel /
                         ChartCard（带标题与合计的图表卡片，0.4C）/
                         SpendBars（柱状图，0.4C 重绘）/ CategoryStatRow / QuietEmpty
    common.dart          通用组件：PageTitle / HeroBanner / StatTile / FormField2 /
                         SelectField / CountStepper / SheetScaffold / SettingsGroup 等
    chart.dart           聊天内图表渲染（分类对比 / 时间趋势）
    chat_widgets.dart    聊天展示层：气泡（长按出修改/复制/删除菜单）/ 日期分隔 /
                         思考气泡 / 模块介绍卡 / 对话列表项（置顶图标）/
                         输入栏（发送↔暂停）/ RenameDialog（兼作消息编辑框）
    markdown.dart        轻量 Markdown 渲染，避免把标记原样显示给用户
  pages/
    home_shell.dart      五个 Tab 的容器
    boot_error.dart      启动失败页（避免白屏）
    home.dart            首页 Dashboard
    expenses.dart        账本（三级：今日 / 汇总 / 分类）
    expense_form.dart    记账 / 改账表单（编辑沿用原 id）
    meds.dart            药箱（两级：药品 / 统计）
    med_form.dart        添加 / 修改药品表单（三组分区 + 分类手选）
    med_detail.dart      药品详情（状态 / 基本信息 / 用法与药效 / 安全信息 /
                         资料出处 + 让 AI 补充 / 去药监局查询 / 询问 AI 三个入口）
    ai_hub.dart          AI 模块入口页（账本分析 / 健康科普两个按钮）
    module_home.dart     模块介绍页：能力清单 + 创建对话（草稿，不落库）+ 右上角
                         历史对话侧滑菜单（置顶区/普通区分组，无输入框）
    chat.dart            对话页：只有消息与输入框，发送键在等待时变暂停键，
                         长按消息可「修改并重新发送」（原地替换 + 自动重问）/复制/删除
    settings.dart        设置首页（四个分组）
    api_config.dart      AI 服务二级页
    chat_settings.dart   AI 对话设置二级页
    custom_prompt.dart   我的提示词二级页
    data_settings.dart   数据管理二级页
    memory.dart          全局记忆二级页
    password_tool.dart   密码生成器（0.3A）
    update.dart          检查更新二级页
    help.dart            使用说明二级页
test/
  util_test.dart / stats_test.dart / action_test.dart / prompt_test.dart
  ai_client_test.dart / markdown_test.dart / chart_test.dart
  password_engine_test.dart / conversation_test.dart / migration_test.dart
  update_test.dart / app_smoke_test.dart / feature_ui_test.dart
  support/fake_db.dart   内存版 LocalDb（含复刻坏结构的 LegacyChatsDb）
  tools/render_pages.dart 出图工具：渲染主要页面预览图，顺带做窄屏溢出检查
```

## 数据库结构

| 版本 | 变更 |
| --- | --- |
| v1 | `expenses` / `meds` / `chats` |
| v2 | `expenses` 增加 `entryType` |
| v3 | 新增 `conversations`、`passwords` |
| v4 | `chats` 补 `conversationId`（修复旧库启动白屏） |

迁移按「表 / 列是否存在」判断，重复执行安全；旧消息会自动认领到对应主题的对话。

## 文档

需求文档与设计示例图只在本机留存，不纳入版本库（已在 `.gitignore` 排除 `/doc/`）：

- `doc/0.2A更新.docx`、`doc/0.2B更新.docx`、`doc/0.2C更新.docx`、`doc/0.3A更新.docx`、`doc/0.4A更新.docx`：历次迭代需求与 UI 评审。
- `doc/0.2C-Ui优化示例图/`：0.2C 的 9 张界面示例图。
- **`doc/验收标准.md`**：可执行的自检清单。每条标准标注 `[自动]` / `[渲染]` / `[人工]` / `[阻断]`，`[阻断]` 意味着不达标就不该交付。
- **`doc/需求缺口与优先级.md`**：尚未交付的需求、已发现但未修的问题、以及需要产品负责人拍板的事项（分 P0–P3 与 D1–D6）。
- `doc/交付说明-0.4A.md`：本次交付（AI 模块拆分）的逐条对照、验证结果，含第七节（对抗性审查修复）与第八节（一次编码损坏事故的如实记录）。
- `doc/交付说明-0.3B.md`：0.2A/0.2B/0.2C/0.3A 的功能对照、0.3B 白屏修复与数据库升级说明。
- `doc/0.2C-修复说明.md`：0.2C 代码审计发现的问题与修复记录。
