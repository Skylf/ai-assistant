// 把 APK 切成若干份，便于通过邮件附件发送（阿里云 DirectMail 单封 DATA 有 8~24MB 上限）。
//
// 用法：node tools/split-file.mjs <源文件> <输出目录> [每份字节数]
// 产出：<名字>.part01 ... .partNN、<名字>.sha256（整文件校验值）、
//       以及一段可直接照抄的合并命令。
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [src, outDir, sizeArg] = process.argv.slice(2);
if (!src || !outDir) {
  console.error("用法: node tools/split-file.mjs <源文件> <输出目录> [每份字节数]");
  process.exit(2);
}
// 6 MB 一份：base64 后约 8 MB，留出邮件头与编码余量，避开 8~24MB 的下限
const partSize = sizeArg ? Number(sizeArg) : 6 * 1024 * 1024;

const buf = fs.readFileSync(src);
fs.mkdirSync(outDir, { recursive: true });
const base = path.basename(src);
const total = Math.ceil(buf.length / partSize);
const parts = [];

for (let i = 0; i < total; i++) {
  const chunk = buf.subarray(i * partSize, (i + 1) * partSize);
  const name = `${base}.part${String(i + 1).padStart(2, "0")}`;
  const dest = path.join(outDir, name);
  fs.writeFileSync(dest, chunk);
  parts.push({ name, bytes: chunk.length });
}

const sha = createHash("sha256").update(buf).digest("hex");
fs.writeFileSync(path.join(outDir, `${base}.sha256`), `${sha}  ${base}\n`);

console.log(`源文件 : ${src}`);
console.log(`大小   : ${buf.length} 字节 (${(buf.length / 1024 / 1024).toFixed(1)} MB)`);
console.log(`切分   : ${total} 份，每份上限 ${(partSize / 1024 / 1024).toFixed(1)} MB`);
for (const p of parts) {
  console.log(`  ${p.name}  ${(p.bytes / 1024 / 1024).toFixed(2)} MB`);
}
console.log(`SHA256 : ${sha}`);
console.log("");
console.log("合并命令（在放好所有 part 的目录里执行）：");
console.log(`  cmd: copy /b ${base}.part01+${base}.part02+... ${base}`);
console.log(`  pwsh: Get-Content ${base}.part* -Encoding Byte -ReadCount 0 | Set-Content ${base} -Encoding Byte`);
console.log(`  校验: certutil -hashfile ${base} SHA256   # 应与上面 SHA256 一致`);
