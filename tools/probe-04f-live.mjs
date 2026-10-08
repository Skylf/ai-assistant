// 0.4F 联网搜索：真机之外的最高保真验证。
//
// 这个脚本**照抄 Dart 侧 `AiWebSearchClient.search` 的解析逻辑**，用真实 Key
// 打真实端点，验证三件事：
//   ① 端点/工具类型确实被服务端接受（不是静默忽略）；
//   ② `server_tool_use` 出现在 `web_search_tool_result` **之前** ——
//      界面「正在联网搜索」的阶段顺序才有依据；
//   ③ 结构化来源真的取得回来（而不是靠从正文正则抓 URL）。
//
// ⚠️ 这个脚本**只从 ~/.dsh/.credentials.yaml 读 Key，绝不打印 Key**。
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const credPath = join(homedir(), ".dsh", ".credentials.yaml");
const creds = readFileSync(credPath, "utf8");
const m = creds.match(/DEEPSEEK_API_KEY:\s*(\S+)/);
if (!m) {
  console.error("没在凭证文件里找到 DEEPSEEK_API_KEY");
  process.exit(1);
}
const apiKey = m[1].trim();

const query = process.argv[2] || "布洛芬缓释胶囊的用法用量和禁忌是什么？";

// 与 Dart 的 buildBody 完全一致
const body = {
  model: "deepseek-v4-flash",
  max_tokens: 4096,
  messages: [{ role: "user", content: [{ type: "text", text: query }] }],
  tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 5 }],
  stream: true,
};

const started = Date.now();
const resp = await fetch("https://api.deepseek.com/anthropic/v1/messages", {
  method: "POST",
  headers: {
    "x-api-key": apiKey,
    authorization: `Bearer ${apiKey}`,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
    accept: "text/event-stream",
  },
  body: JSON.stringify(body),
});

console.log(`HTTP ${resp.status}  (${Date.now() - started} ms)`);
if (!resp.ok) {
  console.log("响应体：", (await resp.text()).slice(0, 600));
  process.exit(1);
}

// ── 照抄 Dart 的 SSE 解析 ──
const decoder = new TextDecoder("utf-8");
let buf = "";
const events = [];
for await (const chunk of resp.body) {
  buf += decoder.decode(chunk, { stream: true });
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).replace(/\r$/, "");
    buf = buf.slice(nl + 1);
    if (line === "") continue;
    if (line.startsWith("event: ")) events.push({ name: line.slice(7), data: "" });
    else if (line.startsWith("data: ") && events.length) {
      const last = events[events.length - 1];
      last.data += (last.data ? "\n" : "") + line.slice(6);
    }
  }
}

// ── 复刻 Dart 的「阶段只报一次」与来源收集 ──
const phases = [];
const sources = [];
const seen = new Set();
let text = "";
let searched = false;
let usage = null;

for (const ev of events) {
  let payload = null;
  try {
    payload = ev.data.trim() ? JSON.parse(ev.data) : null;
  } catch {
    continue; // 心跳等非 JSON：当没有 payload（不能中断整条流）
  }
  if (!payload) continue;

  // usage 在 message_start / message_delta 里，服务端用它报告**真实检索次数**
  if (payload.usage) usage = payload.usage;
  if (payload.message?.usage) usage = payload.message.usage;

  if (ev.name === "content_block_start") {
    const b = payload.content_block || {};
    if (b.type === "server_tool_use" && !phases.includes("searching")) {
      phases.push("searching");
    } else if (b.type === "web_search_tool_result") {
      searched = true;
      for (const item of b.content || []) {
        if (item.type !== "web_search_result") continue;
        if (seen.has(item.url)) continue;
        seen.add(item.url);
        sources.push({ url: item.url, title: item.title });
      }
    } else if (b.type === "text" && !phases.includes("composing")) {
      phases.push("composing");
    }
  } else if (ev.name === "content_block_delta") {
    const d = payload.delta || {};
    if (d.type === "text_delta") {
      if (!phases.includes("composing")) phases.push("composing");
      text += d.text || "";
    }
  } else if (ev.name === "error") {
    console.log("服务端 error 事件：", JSON.stringify(payload.error));
  }
}

// ── 关键判断：阶段顺序 ──
const iSearch = events.findIndex(
  (e) => e.name === "content_block_start" && e.data.includes("server_tool_use"),
);
const iResult = events.findIndex(
  (e) => e.name === "content_block_start" && e.data.includes("web_search_tool_result"),
);

console.log(`\n事件总数：${events.length}`);
console.log(`事件类型：${[...new Set(events.map((e) => e.name))].join(", ")}`);
console.log(`阶段回调：["thinking", ${phases.map((p) => `"${p}"`).join(", ")}]`);
console.log(`searched = ${searched}`);
console.log(
  `服务端自报检索次数 = ${usage?.server_tool_use?.web_search_requests ?? "(未上报)"}`,
);
console.log(`结构化来源 ${sources.length} 条`);
if (searched) {
  console.log(
    iSearch >= 0 && iResult >= 0 && iSearch < iResult
      ? `✅ server_tool_use(第${iSearch}个事件) 在 web_search_tool_result(第${iResult}个事件) 之前 —— 阶段顺序有依据`
      : `⚠️ 阶段顺序不符合预期：server_tool_use@${iSearch}, web_search_tool_result@${iResult}`,
  );
} else {
  console.log(
    "ℹ️ 这一问**不需要联网**，模型没调用检索工具 —— " +
      "对记账类问题正是期望行为（省一次检索，且界面会一直显示「正在思考」）",
  );
}
console.log(`\n正文前 200 字：\n${text.trim().slice(0, 200)}`);
console.log(`\n来源（按服务端顺序，前 8 条）：`);
for (const s of sources.slice(0, 8)) console.log(`  · ${s.url}`);

if (!searched && (usage?.server_tool_use?.web_search_requests ?? 0) > 0) {
  console.error(
    "\n❌ 服务端说检索了，但我们一个 web_search_tool_result 都没收到 —— 解析漏了",
  );
  process.exit(1);
}
