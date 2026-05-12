#!/usr/bin/env node
/**
 * Hashish / pffthash PoW — 实时挖矿状态查询
 *
 * - 链上：当前难度、全局出块高度、challenge、你的 MinerStats、HASH 余额（Token-2022）
 * - 算力 MH/s：链上不存在「你的 GPU 实时算力」，需指向矿工标准输出日志文件（见 --miner-log）
 *
 * 用法：
 *   cd monitor && npm install
 *   export WALLET_PATH="$HOME/.config/solana/id.json"
 *   node mining-monitor.mjs --rpc https://api.mainnet-beta.solana.com
 *
 *   # 若矿工输出重定向到文件（示例）：
 *   # npx ts-node standard-miner/continuous-gpu-miner.ts 2>&1 | tee ~/hashish-miner.log
 *   # 默认会读 ~/.local/share/pffthash/hashish-miner.log（若存在，与一键脚本 --background 一致）
 *   node mining-monitor.mjs --rpc ... --wallet ...
 */

import fs from "fs";
import os from "os";
import path from "path";
import { Connection, Keypair, PublicKey } from "@solana/web3.js";
import {
  TOKEN_2022_PROGRAM_ID,
  getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import bs58 from "bs58";

const DEFAULT_PROGRAM = new PublicKey(
  "PoWQ79wY7LXrKaU8vZBoFb4JgSytENSdpAQAPJaZiSh",
);
const DEFAULT_MINT = new PublicKey(
  "HASHcf66ffcWdGvswuuu8ssLWSeXpto6QaeG32AktiSh",
);

function loadKeypair(filePath) {
  const abs = path.resolve(filePath);
  if (!fs.existsSync(abs)) {
    throw new Error(`钱包文件不存在: ${abs}`);
  }
  const raw = fs.readFileSync(abs, "utf-8").trim();
  if (!raw) {
    throw new Error(`钱包文件为空: ${abs}`);
  }
  let secret;
  if (raw.startsWith("[")) {
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) {
      throw new Error(`钱包 JSON 格式错误（应为数字数组）: ${abs}`);
    }
    secret = new Uint8Array(arr);
  } else {
    try {
      secret = bs58.decode(raw);
    } catch {
      throw new Error(
        `钱包无法解析（应为 Solana CLI 的 JSON 数组或单行 base58）: ${abs}`,
      );
    }
  }
  if (secret.length === 64) {
    try {
      return Keypair.fromSecretKey(secret);
    } catch (e) {
      throw new Error(`无法从文件创建 Keypair: ${abs} — ${e.message}`);
    }
  }
  if (secret.length === 32) {
    try {
      return Keypair.fromSeed(secret);
    } catch (e) {
      throw new Error(`无法从 seed 创建 Keypair: ${abs} — ${e.message}`);
    }
  }
  throw new Error(
    `密钥长度不对 (${secret.length} 字节)，应为 64（Solana CLI 导出的整段 keypair）或 32（仅 seed）。` +
      ` 常见误操作：把公钥当成了钱包、或编辑 id.json 时截断。文件: ${abs}`,
  );
}
function readU64LE(buf, off) {
  const view = new DataView(buf.buffer, buf.byteOffset + off, 8);
  return view.getBigUint64(0, true);
}

function readI64LE(buf, off) {
  const view = new DataView(buf.buffer, buf.byteOffset + off, 8);
  return view.getBigInt64(0, true);
}

function readU128LE(buf, off) {
  const lo = readU64LE(buf, off);
  const hi = readU64LE(buf, off + 8);
  return (hi << 64n) | lo;
}

/** 与 PoW-Miners readProtocolState 一致：跳过 8 字节 discriminator + authority(32) + mint(32) */
function parsePowConfig(data) {
  if (!data || data.length < 144) return null;
  const difficulty = readU128LE(data, 72);
  const blocksMined = readU64LE(data, 96);
  const challenge = Buffer.from(data.subarray(112, 144));
  return { difficulty, blocksMined, challenge };
}

/** MinerStats: 8 disc + miner(32) + blocks + tokens + fees + first_ts + last_ts + bump + pool_id */
function parseMinerStats(data) {
  if (!data || data.length < 82) return null;
  const minerPk = new PublicKey(data.subarray(8, 40));
  const blocksMined = readU64LE(data, 40);
  const totalTokensEarned = readU64LE(data, 48);
  const totalFeesPaid = readU64LE(data, 56);
  const firstBlockTs = readI64LE(data, 64);
  const lastBlockTs = readI64LE(data, 72);
  return {
    minerPk,
    blocksMined,
    totalTokensEarned,
    totalFeesPaid,
    firstBlockTs,
    lastBlockTs,
  };
}

/**
 * 解析 GPU 矿工 stdout 中的 Progress 行（与 continuous-gpu-miner 正则一致）
 * Progress: 12345 hashes | Live: 12.34 MH/s | Avg: 56.78 MH/s
 */
function parseLastHashrateFromLog(filePath) {
  try {
    const st = fs.statSync(filePath);
    const tail = 256 * 1024;
    const start = st.size > tail ? st.size - tail : 0;
    const fd = fs.openSync(filePath, "r");
    const buf = Buffer.alloc(st.size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    const text = buf.toString("utf-8");
    const lines = text.split(/\r?\n/);
    const re =
      /Progress:\s+(\d+)\s+hashes\s+\|\s+Live:\s+([\d.]+)\s+MH\/s\s+\|\s+Avg:\s+([\d.]+)\s+MH\/s/;
    for (let i = lines.length - 1; i >= 0; i--) {
      const m = lines[i].match(re);
      if (m) {
        return {
          hashesChecked: m[1],
          liveMhs: parseFloat(m[2]),
          avgMhs: parseFloat(m[3]),
        };
      }
    }
  } catch {
    return null;
  }
  return null;
}

function formatTs(ts) {
  if (ts === 0n) return "—";
  const ms = Number(ts) * 1000;
  if (!Number.isFinite(ms)) return String(ts);
  return new Date(ms).toISOString();
}

function formatBig(n) {
  return n.toLocaleString("zh-CN");
}

function parseArgs(argv) {
  const out = {
    rpc: process.env.RPC_URL || "https://api.mainnet-beta.solana.com",
    walletPath: process.env.WALLET_PATH || "",
    intervalMs: Number(process.env.POLL_MS || 2000),
    minerLog: "",
    poolId: Number(process.env.POOL_ID || 0),
    programId: process.env.PROGRAM_ID || DEFAULT_PROGRAM.toBase58(),
    mint: process.env.MINT || DEFAULT_MINT.toBase58(),
    json: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--rpc" && argv[i + 1]) out.rpc = argv[++i];
    else if (a === "--wallet" && argv[i + 1]) out.walletPath = argv[++i];
    else if (a === "--interval" && argv[i + 1])
      out.intervalMs = Math.max(500, parseInt(argv[++i], 10) || 2000);
    else if (a === "--miner-log" && argv[i + 1]) out.minerLog = argv[++i];
    else if (a === "--pool" && argv[i + 1]) {
      const p = parseInt(argv[++i], 10);
      out.poolId = Number.isFinite(p) ? p : 0;
    }
    else if (a === "--program" && argv[i + 1]) out.programId = argv[++i];
    else if (a === "--mint" && argv[i + 1]) out.mint = argv[++i];
    else if (a === "--json") out.json = true;
    else if (a === "-h" || a === "--help") out.help = true;
  }
  return out;
}

function resolveMinerLogPath(opts) {
  let p = (opts.minerLog || "").trim();
  if (p) return path.resolve(p);
  p = process.env.MINER_LOG || process.env.HASHISH_MINER_LOG || "";
  if (p) return path.resolve(p);
  const def = path.join(os.homedir(), ".local/share/pffthash/hashish-miner.log");
  if (fs.existsSync(def)) return def;
  return "";
}

function pdaPowConfig(programId, poolId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("pow_config"), Buffer.from([poolId & 0xff])],
    programId,
  )[0];
}

function pdaMinerStats(programId, poolId, minerPubkey) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("miner_stats"), Buffer.from([poolId & 0xff]), minerPubkey.toBuffer()],
    programId,
  )[0];
}

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help) {
    console.log(`
用法: node mining-monitor.mjs [选项]

选项:
  --rpc <url>           Solana RPC（默认 RPC_URL 或 mainnet-beta）
  --wallet <path>       钱包 JSON（默认 WALLET_PATH）
  --interval <ms>       刷新间隔，默认 2000
  --miner-log <path>    矿工日志（解析 Progress 行得到 MH/s）。不设则试 \$HOME/.local/share/pffthash/hashish-miner.log

环境变量: RPC_URL, WALLET_PATH, POLL_MS, MINER_LOG, HASHISH_MINER_LOG, POOL_ID, PROGRAM_ID, MINT
`);
    process.exit(0);
  }

  if (!opts.walletPath) {
    console.error("请设置 --wallet 或环境变量 WALLET_PATH");
    process.exit(1);
  }

  const wallet = loadKeypair(path.resolve(opts.walletPath));
  const programId = new PublicKey(opts.programId);
  const mint = new PublicKey(opts.mint);
  const poolId = Number.isFinite(opts.poolId) ? opts.poolId : 0;

  const minerLogPath = resolveMinerLogPath(opts);

  const connection = new Connection(opts.rpc, "confirmed");
  const powConfig = pdaPowConfig(programId, poolId);
  const minerStatsPk = pdaMinerStats(programId, poolId, wallet.publicKey);
  const ata = getAssociatedTokenAddressSync(
    mint,
    wallet.publicKey,
    false,
    TOKEN_2022_PROGRAM_ID,
  );

  const render = async () => {
    const [powInfo, statsInfo, bal] = await Promise.all([
      connection.getAccountInfo(powConfig),
      connection.getAccountInfo(minerStatsPk),
      connection.getTokenAccountBalance(ata).catch(() => null),
    ]);

    const proto = powInfo?.data ? parsePowConfig(powInfo.data) : null;
    const miner = statsInfo?.data ? parseMinerStats(statsInfo.data) : null;
    const hr = minerLogPath ? parseLastHashrateFromLog(minerLogPath) : null;

    const row = {
      time: new Date().toISOString(),
      wallet: wallet.publicKey.toBase58(),
      poolId,
      rpc: opts.rpc,
      globalBlocksMined: proto ? proto.blocksMined.toString() : null,
      difficulty: proto ? proto.difficulty.toString() : null,
      challengeHex: proto ? proto.challenge.toString("hex") : null,
      yourBlocksMined: miner ? miner.blocksMined.toString() : "0",
      yourTotalTokensEarnedRaw: miner ? miner.totalTokensEarned.toString() : "0",
      yourTotalFeesPaidLamports: miner ? miner.totalFeesPaid.toString() : "0",
      yourLastBlockAt: miner ? formatTs(miner.lastBlockTs) : "—",
      hashBalanceUi: bal?.value?.uiAmountString ?? null,
      liveHashrateMhs: hr?.liveMhs ?? null,
      avgHashrateMhs: hr?.avgMhs ?? null,
      hashesCheckedFromLog: hr?.hashesChecked ?? null,
      minerLogPath: minerLogPath || null,
    };

    if (opts.json) {
      console.log(JSON.stringify(row));
      return;
    }

    const lines = [
      "════════ Hashish PoW 实时监控 ════════",
      `时间: ${row.time}`,
      `钱包: ${row.wallet}`,
      `RPC:  ${row.rpc}`,
      `矿池: ${row.poolId}  |  PowConfig: ${powConfig.toBase58()}`,
      "",
      "【全链协议】",
      `  已挖出区块数: ${proto ? formatBig(proto.blocksMined) : "—"}`,
      `  当前难度:     ${proto ? formatBig(proto.difficulty) : "—"}`,
      `  Challenge:    ${
        proto
          ? `${proto.challenge.toString("hex").slice(0, 24)}…`
          : "—"
      }`,
      "",
      "【你的链上统计 MinerStats】",
      `  你挖中的区块数:     ${miner ? formatBig(miner.blocksMined) : "0（账户可能尚未创建）"}`,
      `  累计获得代币(raw): ${miner ? formatBig(miner.totalTokensEarned) : "0"}`,
      `  累计支付 SOL 费:   ${miner ? formatBig(miner.totalFeesPaid) + " lamports" : "0"}`,
      `  上次出块时间:     ${row.yourLastBlockAt}`,
      "",
      "【HASH 余额 (ATA)】",
      `  ${row.hashBalanceUi ?? "—（无 ATA 或 RPC 错误）"}`,
      "",
      "【算力 MH/s】",
      minerLogPath ? `  日志文件: ${minerLogPath}` : "  （未指定日志路径）",
      hr
        ? `  Live: ${hr.liveMhs.toFixed(2)} MH/s  |  Avg: ${hr.avgMhs.toFixed(2)} MH/s  |  已试哈希(日志): ${hr.hashesChecked}`
        : minerLogPath
          ? `  日志中暂无 Progress 行: ${minerLogPath}\n  （GPU 进入 Mining 后才会刷 Live/Avg MH/s）`
          : `  未配置日志路径，无法显示 MH/s。\n  使用后台矿工: pffthash/scripts/ubuntu-oneclick-fast.sh --mine-only --background\n  或手动: node mining-monitor.mjs --miner-log ~/.local/share/pffthash/hashish-miner.log`,
      "══════════════════════════════════════",
    ];

    if (process.stdout.isTTY) {
      process.stdout.write("\x1b[2J\x1b[H");
    }
    process.stdout.write(lines.join("\n") + "\n");
  };

  await render();
  setInterval(() => {
    render().catch((e) => console.error(e));
  }, opts.intervalMs);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
