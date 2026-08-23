// Attestable — preflight check.
// Verifies you can actually reach BSC testnet and that the live APEX (ERC-8183)
// stack is where the docs say it is, BEFORE you write a line of Solidity.
//
//   node scripts/preflight.mjs
//
// No dependencies. Uses built-in fetch (Node 18+).

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const cfg = JSON.parse(
  readFileSync(join(__dirname, "..", "config", "addresses.json"), "utf8"),
);

const NET = process.env.NETWORK === "mainnet" ? "bscMainnet" : "bscTestnet";
const net = cfg[NET];
const RPC = process.env.RPC_URL || net.rpcUrl;

let id = 0;
async function rpc(method, params = []) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const j = await res.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}

const ok = (m) => console.log(`  \x1b[32m✔\x1b[0m ${m}`);
const bad = (m) => console.log(`  \x1b[31m✘\x1b[0m ${m}`);
const info = (m) => console.log(`  \x1b[90m·\x1b[0m ${m}`);

let failures = 0;

console.log(`\n\x1b[1mAttestable preflight — ${NET}\x1b[0m`);
console.log(`RPC: ${RPC}\n`);

// 1. Chain reachable and correct
console.log("\x1b[1m1. Chain\x1b[0m");
try {
  const chainId = parseInt(await rpc("eth_chainId"), 16);
  if (chainId === net.chainId) ok(`connected, chainId ${chainId}`);
  else {
    bad(`chainId mismatch: got ${chainId}, expected ${net.chainId}`);
    failures++;
  }
  const block = parseInt(await rpc("eth_blockNumber"), 16);
  ok(`head block ${block.toLocaleString()}`);
} catch (e) {
  bad(`cannot reach RPC — ${e.message}`);
  bad(`try another endpoint via RPC_URL=... (see chainlist.org)`);
  failures++;
}

// 2. The live APEX stack really is deployed at those addresses
console.log("\n\x1b[1m2. Live ERC-8183 (APEX) stack\x1b[0m");
const targets = [
  ["AgenticCommerce", net.agenticCommerce],
  ["EvaluatorRouter ", net.evaluatorRouter],
  ["OptimisticPolicy", net.optimisticPolicy],
  ["Payment token   ", net.paymentToken],
];
for (const [name, addr] of targets) {
  try {
    const code = await rpc("eth_getCode", [addr, "latest"]);
    const bytes = (code.length - 2) / 2;
    if (bytes > 0) ok(`${name} ${addr}  (${bytes.toLocaleString()} bytes)`);
    else {
      bad(`${name} ${addr}  — NO CODE`);
      failures++;
    }
  } catch (e) {
    bad(`${name} — ${e.message}`);
    failures++;
  }
}

// 3. Your deployer wallet
console.log("\n\x1b[1m3. Deployer wallet\x1b[0m");
const addr = process.env.DEPLOYER_ADDRESS;
if (!addr) {
  info("DEPLOYER_ADDRESS not set — skipping (set it in .env once you have a key)");
} else {
  try {
    const wei = BigInt(await rpc("eth_getBalance", [addr, "latest"]));
    const bnb = Number(wei) / 1e18;
    if (bnb > 0.05) ok(`${addr} — ${bnb.toFixed(4)} tBNB`);
    else {
      bad(`${addr} — ${bnb.toFixed(4)} tBNB (low; top up at bnbchain.org/en/testnet-faucet)`);
      failures++;
    }
  } catch (e) {
    bad(`balance check failed — ${e.message}`);
    failures++;
  }
}

console.log(
  failures === 0
    ? "\n\x1b[32m\x1b[1mPreflight clean. You are cleared to build.\x1b[0m\n"
    : `\n\x1b[31m\x1b[1m${failures} check(s) failed — fix before writing code.\x1b[0m\n`,
);
process.exit(failures === 0 ? 0 : 1);
