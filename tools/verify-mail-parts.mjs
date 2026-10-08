// 从收件箱把 0.4A 的 9 个分片下载回来、按序合并、与原始 APK 比对哈希。
//
// 目的：证明「邮件通道真的可用」，而不是只看 SMTP 返回 200。
// 这是本机配好邮箱后第一次真正走「下载 → 合并 → 校验」这条用户会走的路径。
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  listMessages,
  fetchStructure,
  classifyParts,
  fetchAttachmentToFile,
} from "./tools/read-email.mjs";

const ORIGINAL = "D:\\0.computer\\2.Android\\ai-assistant\\build\\app\\outputs\\flutter-apk\\app-release.apk";
const OUT = path.join(os.tmpdir(), "apk-verify");

const sha256 = (file) =>
  createHash("sha256").update(fs.readFileSync(file)).digest("hex");

/** 找出该邮件里的附件段号。 */
async function attachmentSection(uid, log) {
  // 注意：返回字段是 attParts（不是 attachments）；fetchStructure 返回
  // { parts, totalSize }，要取 .parts 再喂进来。
  const { parts } = await fetchStructure(uid, { log });
  const { attParts } = classifyParts(parts);
  if (!attParts.length) return null;
  return attParts[0].section;
}

const log = () => {}; // 静默：只看结论

fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });

// 9 封分片的 uid：第一封标题是「测试：…第1/9 份」，其余是「…（第 n/9 份）」
console.log("=== 在收件箱里找出 9 个分片 ===");
const recent = await listMessages({ limit: 40, log });
const parts = recent
  .filter((m) => /0\.4A 安装包/.test(m.subject ?? ""))
  .map((m) => ({
    uid: m.uid,
    subject: m.subject,
    // 从标题里取份号；第 1 封是「测试：…第1/9 份」，其余是「…（第 2/9 份）」。
    // 注意「第」和数字之间可能有空格，漏了 \s* 会只匹配到第 1 封（踩过）。
    n: Number((/第\s*(\d+)\s*\/\s*9/.exec(m.subject) ?? [])[1] ?? 0),
  }))
  .filter((p) => p.n > 0)
  .sort((a, b) => a.n - b.n);

console.log(`找到 ${parts.length} 封：${parts.map((p) => p.n).join(", ")}`);
if (parts.length !== 9) {
  console.error(`!! 期望 9 封，实际 ${parts.length} 封 —— 可能还没全部到达`);
  process.exit(1);
}

const downloaded = [];
for (const p of parts) {
  const section = await attachmentSection(p.uid, log);
  if (!section) {
    console.error(`!! 第 ${p.n} 份（uid=${p.uid}）没有附件`);
    process.exit(1);
  }
  const dest = path.join(OUT, `part${String(p.n).padStart(2, "0")}`);
  await fetchAttachmentToFile(p.uid, section, dest, { log, timeoutMs: 60000 });
  const size = fs.statSync(dest).size;
  downloaded.push({ n: p.n, dest, size });
  console.log(`  第 ${p.n} 份  uid=${p.uid}  段=${section}  ${(size / 1024 / 1024).toFixed(2)} MB`);
}

// 合并
const merged = path.join(OUT, "app-release.apk");
const out = fs.openSync(merged, "w");
for (const d of downloaded) {
  fs.writeSync(out, fs.readFileSync(d.dest));
}
fs.closeSync(out);

const gotSize = fs.statSync(merged).size;
const gotHash = sha256(merged);
const wantSize = fs.statSync(ORIGINAL).size;
const wantHash = sha256(ORIGINAL);

console.log("\n=== 校验 ===");
console.log(`原始   : ${wantSize} 字节  sha256=${wantHash}`);
console.log(`合并后 : ${gotSize} 字节  sha256=${gotHash}`);
console.log(`合并文件: ${merged}`);

if (gotSize === wantSize && gotHash === wantHash) {
  console.log("\n✅ 完全一致：邮件通道传输的分片可以还原出与原始文件逐字节相同的 APK");
  process.exit(0);
}
console.error("\n❌ 不一致：邮件通道有损坏或丢失");
process.exit(1);
