// 0.4F 前置验证：DeepSeek 的 Anthropic 兼容端点是否真的能用原生 web_search。
//
// 为什么要先写这个：0.4D 我凭「OpenAI 兼容格式常见写法」猜了一个
// `{"type":"web_search"}` 发到 chat/completions，结果**被静默忽略**，
// 白做一版。这次先拿真实凭据发一次真实请求，确认端点、请求形状、响应结构
// 三件事都对得上，再动 App 的代码。
//
// 凭据从 ~/.dsh/.credentials.yaml 读（不落命令行、不进进程列表、不打印）。
// 用法：node tools/probe-websearch.mjs [查询词]

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const BASE_URL = "https://api.deepseek.com/anthropic/v1";
const API_VERSION = "2023-06-01";
const MODEL = process.env.DS_SEARCH_MODEL || "deepseek-v4-flash";
const MAX_USES = 5;

/** 从 ~/.dsh/.credentials.yaml 里取一个键的值。只做扁平解析，够用即可。 */
function readCredential(name) {
  const file = path.join(os.homedir(), ".dsh", ".credentials.yaml");
  const text = fs.readFileSync(file, "utf8");
  for (const line of text.split(/\r?\n/)) {
    const m = /^\s*([A-Za-z0-9_-]+)\s*:\s*(.+?)\s*$/.exec(line);
    if (m && m[1] === name) return m[2];
  }
  return "";
}

const apiKey = process.env.DEEPSEEK_API_KEY || readCredential("DEEPSEEK_API_KEY");
if (!apiKey) {
  console.error("找不到 DEEPSEEK_API_KEY");
  process.exit(2);
}
console.log(`凭据: 已读取（长度 ${apiKey.length}，前缀 ${apiKey.slice(0, 5)}…）`);
console.log(`端点: ${BASE_URL}/messages`);
console.log(`模型: ${MODEL}\n`);

const query = process.argv.slice(2).join(" ") || "布洛芬缓释胶囊 说明书 用法用量 禁忌";

const body = {
  model: MODEL,
  max_tokens: 4096,
  messages: [
    {
      role: "user",
      content: [
        {
          type: "text",
          text: `Perform a web search for the query: ${query}`,
        },
      ],
    },
  ],
  tools: [
    {
      type: "web_search_20250305",
      name: "web_search",
      max_uses: MAX_USES,
    },
  ],
};

const started = Date.now();
let res;
try {
  res = await fetch(`${BASE_URL}/messages`, {
    method: "POST",
    redirect: "error",
    headers: {
      "x-api-key": apiKey,
      authorization: `Bearer ${apiKey}`,
      "anthropic-version": API_VERSION,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify(body),
  });
} catch (e) {
  console.error(`❌ 请求抛异常: ${e}`);
  process.exit(1);
}
const ms = Date.now() - started;

console.log(`HTTP ${res.status}  (${ms} ms)`);

const raw = await res.text();
if (!res.ok) {
  console.error("❌ 非 2xx，响应前 600 字符：");
  console.error(raw.slice(0, 600));
  process.exit(1);
}

let json;
try {
  json = JSON.parse(raw);
} catch (e) {
  console.error(`❌ 响应不是 JSON: ${e}`);
  console.error(raw.slice(0, 400));
  process.exit(1);
}

// ---- 结构确认 ----
const blocks = Array.isArray(json.content) ? json.content : [];
console.log(`\ncontent 块数: ${blocks.length}`);
const kinds = {};
for (const b of blocks) kinds[b.type] = (kinds[b.type] ?? 0) + 1;
console.log(`块类型分布: ${JSON.stringify(kinds)}`);

const resultBlocks = blocks.filter((b) => b.type === "web_search_tool_result");
if (resultBlocks.length === 0) {
  console.error(
    "\n❌ 没有 web_search_tool_result 块 —— 原生联网没被触发。",
  );
  console.log("各块类型明细:");
  for (const b of blocks) console.log(`  - ${b.type}`);
  process.exit(1);
}

const urls = [];
for (const b of resultBlocks) {
  for (const item of b.content ?? []) {
    if (item.type === "web_search_result" && item.url) urls.push(item.url);
  }
}
const uniq = [...new Set(urls)];

console.log(`\n✅ 有 web_search_tool_result 块：${resultBlocks.length} 个`);
console.log(`✅ 结果条目: ${urls.length} 条（去重后 ${uniq.length} 条）`);
console.log("\n来源 URL:");
for (const u of uniq.slice(0, 10)) console.log(`  ${u}`);

// 顺便确认 page_age / title 字段名是否如文档所述
const firstItem = (resultBlocks[0].content ?? []).find(
  (i) => i.type === "web_search_result",
);
if (firstItem) {
  console.log(`\n首条条目的字段: ${Object.keys(firstItem).join(", ")}`);
  console.log(`  title   = ${String(firstItem.title ?? "").slice(0, 70)}`);
  console.log(`  page_age= ${String(firstItem.page_age ?? "(无)")}`);
}

// 模型最终文本（联网后它应该据此作答）
const text = blocks
  .filter((b) => b.type === "text")
  .map((b) => b.text)
  .join("\n");
if (text) {
  console.log(`\n模型正文（前 300 字）:\n${text.slice(0, 300)}`);
}

console.log(`\nusage: ${JSON.stringify(json.usage ?? {})}`);
console.log("\n结论：端点与请求形状可用。");
