// 真机验证：DeepSeek 流式联网搜索能否支撑「正在联网搜索」的阶段提示。
//
// 这不是单元测试，是一次**端到端探针** —— 单测只能证明「我发的形状符合我的预期」，
// 证明不了「服务端认这个形状、并按我预期的方式流式返回」。0.4D 就栽在后者上。
//
// 要验三件事：
//  ① 端点与请求形状可用（HTTP 2xx、有 web_search_tool_result）
//  ② `content_block_start` 里能观测到 `server_tool_use` → 界面可以据此显示「正在联网搜索」
//  ③ 来源是**结构化**的（web_search_result.url），不是从正文正则抓的
//
// 凭据从 ~/.dsh/.credentials.yaml 读，不落命令行。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function cred(name) {
  const file = path.join(os.homedir(), ".dsh", ".credentials.yaml");
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Za-z0-9_-]+)\s*:\s*(.+?)\s*$/.exec(line);
    if (m && m[1] === name) return m[2];
  }
  return "";
}

const apiKey = cred("DEEPSEEK_API_KEY");
if (!apiKey) {
  console.error("找不到 DEEPSEEK_API_KEY");
  process.exit(2);
}

// 与 lib/ai/web_search.dart 的 buildBody 保持一致
const body = {
  model: "deepseek-v4-flash",
  max_tokens: 4096,
  messages: [
    {
      role: "user",
      content: [
        {
          type: "text",
          text:
            "请联网查询「布洛芬缓释胶囊」的说明书要点，然后按下面格式回答：\n" +
            "usage: 用法用量\nindications: 适应症\nefficacy: 药效\n" +
            "adverse: 不良反应\ncontraindications: 禁忌\nprecautions: 注意事项\n" +
            "source: 来源名称",
        },
      ],
    },
  ],
  tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 5 }],
  stream: true,
};

console.log("POST https://api.deepseek.com/anthropic/v1/messages  (stream=true)\n");
const res = await fetch("https://api.deepseek.com/anthropic/v1/messages", {
  method: "POST",
  redirect: "error",
  headers: {
    "x-api-key": apiKey,
    authorization: `Bearer ${apiKey}`,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    accept: "text/event-stream",
  },
  body: JSON.stringify(body),
});
console.log(`HTTP ${res.status}`);
if (!res.ok) {
  console.error((await res.text()).slice(0, 600));
  process.exit(1);
}

// ---- 复刻 Dart 侧 SSE 解析，验证阶段事件确实可观测 ----
const decoder = new TextDecoder();
let buf = "";
const eventNames = [];
const blockTypes = [];
const sources = [];
const seenUrls = new Set();
let text = "";
let searched = false;
let sawServerToolUse = false;

function handleEvent(name, dataRaw) {
  eventNames.push(name);
  if (!dataRaw) return;
  let data;
  try {
    data = JSON.parse(dataRaw);
  } catch {
    return;
  }
  if (name === "content_block_start") {
    const block = data.content_block ?? {};
    blockTypes.push(block.type);
    if (block.type === "server_tool_use") sawServerToolUse = true;
    if (block.type === "web_search_tool_result") {
      searched = true;
      collect(block.content);
    }
  } else if (name === "content_block_delta") {
    const d = data.delta ?? {};
    if (d.type === "text_delta") text += d.text ?? "";
  } else if (name === "message_delta") {
    const blocks = data.delta?.content;
    if (Array.isArray(blocks)) {
      for (const b of blocks) if (b.type === "web_search_tool_result") {
        searched = true;
        collect(b.content);
      }
    }
  } else if (name === "error") {
    console.error(`\n❌ 服务端返回 error 事件: ${JSON.stringify(data).slice(0, 300)}`);
  }
}

function collect(content) {
  if (!Array.isArray(content)) return;
  for (const item of content) {
    if (item?.type !== "web_search_result") continue;
    const url = (item.url ?? "").trim();
    if (!url || seenUrls.has(url)) continue;
    seenUrls.add(url);
    sources.push({ url, title: (item.title ?? "").trim() });
  }
}

let curEvent = "";
let curData = [];
function flush() {
  if (curEvent || curData.length) handleEvent(curEvent, curData.join("\n"));
  curEvent = "";
  curData = [];
}

for await (const chunk of res.body) {
  buf += decoder.decode(chunk, { stream: true });
  let idx;
  while ((idx = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, idx).replace(/\r$/, "");
    buf = buf.slice(idx + 1);
    if (line === "") {
      flush();
    } else if (line.startsWith("event:")) {
      curEvent = line.slice(6).trim();
    } else if (line.startsWith("data:")) {
      curData.push(line.slice(5).trimStart());
    }
  }
}
flush();

console.log(`\n事件类型: ${JSON.stringify([...new Set(eventNames)])}`);
console.log(`事件总数: ${eventNames.length}`);
console.log(`content_block 类型: ${JSON.stringify(blockTypes)}`);

console.log("\n---- 判定 ----");
console.log(
  sawServerToolUse
    ? "✅ ②观测到 server_tool_use → 界面可以显示「正在联网搜索」"
    : "❌ ②没观测到 server_tool_use，阶段提示无法实现",
);
console.log(
  searched
    ? `✅ ①真的联网了（web_search_tool_result），结构化来源 ${sources.length} 条`
    : "❌ ①没有 web_search_tool_result —— 联网没发生",
);
console.log(
  sources.length > 0
    ? "✅ ③来源是结构化的（url/title 字段），不是从正文抓的"
    : "❌ ③没有结构化来源",
);

if (sources.length) {
  console.log("\n来源（前 8 条）:");
  for (const s of sources.slice(0, 8)) console.log(`  ${s.url}\n     ${s.title.slice(0, 60)}`);
}

console.log(`\n模型正文（前 400 字）:\n${text.slice(0, 400)}`);
