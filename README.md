# 家庭生活助手

0.1A 开发版。基于 Flutter 的本地优先家庭账本与家庭药箱，预留 Android、iOS 和 macOS 平台。

## 已实现

- 家庭账本：记录、删除和当月支出汇总。
- 家庭药箱：药名、成分、规格、库存、有效期、储存和说明书备注。
- 本地 SQLite 数据库与 JSON 数据导出。
- 90 天内药品到期提示。
- DeepSeek 默认配置，以及兼容 OpenAI Chat Completions 的自定义 API。
- 系统安全存储 API Key。
- 账本 AI 分析、健康科普聊天和紧急症状关键词分流。

健康模块仅用于药品管理和健康科普；不提供诊断、处方或个体化剂量建议。紧急情况请立即联系当地急救服务。

## 运行

```powershell
flutter pub get
flutter run -d <Android设备ID>
```

首次使用 AI 前，在应用“设置”中填写 API Base URL、模型名和 API Key。默认 DeepSeek 配置为 `https://api.deepseek.com` 和 `deepseek-flash`。
