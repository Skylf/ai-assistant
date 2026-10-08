// 分批把安装包发到用户邮箱。
//
// 为什么写 Node 而不是 PowerShell 脚本：
// 阿里云 DirectMail 对单封邮件 DATA 有 8~24MB 上限，52MB 的 APK 整封发不出去
// （实测被拒：557 The length of DATA content is achieved the maximum threshold），
// 所以切成多份、每份 6MB 单独发（6MB 已实测可发）。
//
// 为什么不用 .ps1：PS 5.1 读没有 BOM 的 UTF-8 会按 GBK 解码，脚本里的中文
// 会变成乱码并导致**语法错误**（实测 `Missing closing '}'`）。Node 没有这个问题。
//
// 用法：node tools/send-parts.mjs <版本号> <parts目录> <总份数> [起始份号]
//   例：node tools/send-parts.mjs 0.4C build/mail-parts-04C 10
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const BRIDGE = "D:\\0.DSH系统工作区\\5.dsh微信桥接";

const [version, partsDir, totalArg, fromArg] = process.argv.slice(2);
if (!version || !partsDir || !totalArg) {
  console.error("用法: node tools/send-parts.mjs <版本号> <parts目录> <总份数> [起始份号]");
  process.exit(2);
}
const TOTAL = Number(totalArg);
const FROM = fromArg ? Number(fromArg) : 1;

/** 跑 send-email.mjs，返回是否成功。 */
function send({ subject, text, file }) {
  return new Promise((resolve) => {
    const args = ["tools\\send-email.mjs", "--subject", subject, "--text", text];
    if (file) args.push("--file", file);
    const child = spawn(process.execPath, args, {
      cwd: BRIDGE,
      // 不要用 pipe 抓输出：本机沙箱禁止子进程管道（EPERM）。
      // 让子进程直接继承 stdio，成功与否用退出码判断。
      stdio: "inherit",
      shell: false,
    });
    child.on("error", (e) => {
      console.error(`spawn 失败: ${e.message}`);
      resolve(false);
    });
    child.on("close", (code) => resolve(code === 0));
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let ok = 0;
const failed = [];

for (let n = FROM; n <= TOTAL; n++) {
  const name = `app-release.apk.part${String(n).padStart(2, "0")}`;
  const file = path.join(partsDir, name);
  if (!fs.existsSync(file)) {
    console.warn(`缺少 ${name}，跳过`);
    failed.push(name);
    continue;
  }
  console.log(`\n=== 发送 ${name}（第 ${n}/${TOTAL} 份）===`);
  const done = await send({
    subject: `家庭生活助手 ${version} 安装包（第 ${n}/${TOTAL} 份）`,
    text:
      `这是 ${version} 安装包的第 ${n} 份，共 ${TOTAL} 份。\n` +
      `请把 ${TOTAL} 个 part 文件放在同一个文件夹里，收齐后再合并。\n` +
      `合并方法与校验值见另一封「合并方法与本轮改动说明」的邮件。\n` +
      `注意：是 ${version} 版本，不要和之前的旧 part 混在一起。`,
    file,
  });
  if (done) {
    ok++;
    console.log(`  ✓ ${name}`);
  } else {
    failed.push(name);
    console.warn(`  ✗ ${name}`);
  }
  await sleep(3000);
}

console.log(`\n完成：成功 ${ok} 份，失败 ${failed.length} 份`);
if (failed.length) console.log(`失败清单：${failed.join(", ")}`);
