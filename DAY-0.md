# DAY 0 — What you need before you write code

You're right that starting early is the advantage. Submissions are judged in **bi-weekly batches**, so shipping early means a smaller field *and* time to iterate an Honourable Mention up into a prize. This is the readiness checklist.

**Good news first: I already validated the hard part.** The thesis holds up against BNB Chain's own source code, and the live contracts are confirmed on-chain (run `node scripts/preflight.mjs` — it passes right now).

---

## 1. What I verified for you

### The extension point is officially sanctioned — in writing

`apex-contracts/docs/custom-policy.md` is BNB Chain's own guide to authoring a policy. It says write a new one when:

> *"the **verdict function itself** needs to change — e.g. 'require N-of-M off-chain signatures', **'require an oracle price range at submission'**, **'route to a third-party attestation service'**."*

That is a description of Attestable, published by the people judging you. There's even a worked `ZkProofPolicy` template to pattern-match against. **You are not fighting the architecture; you're filling a slot they documented and left open.**

### The interface is tiny

```solidity
interface IPolicy {
    function onSubmitted(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;
    function check(uint256 jobId, bytes calldata evidence) external view returns (uint8 verdict, bytes32 reason);
}
```

Two functions. Verdicts: `0` Pending, `1` Approve (provider paid), `2` Reject (client refunded). That's the entire surface you must implement. Vendored at `contracts/IPolicy.sol`; skeleton at `contracts/ProofPolicy.sol`.

### `optParams` is a perfect, unplanned fit

`submit()` carries an opaque `bytes optParams` that ERC-8183 **forbids the kernel from interpreting**, and the Router relays it to your policy unchanged. The docs say policies may use it to bind *"URI, manifest hash, ZK public inputs"*.

That's your evidence-root transport, already built, no upgrade required. This is the single luckiest thing about the design — the plumbing Attestable needs already exists.

### The stack is live (verified on-chain just now)

| Contract | BSC Testnet (97) |
|---|---|
| `AgenticCommerce` | `0xa206c0517B6371C6638CD9e4a42Cc9f02A33B0DE` |
| `EvaluatorRouter` | `0xd7d36d66d2f1b608a0f943f722d27e3744f66f25` |
| `OptimisticPolicy` | `0x4f4678d4439fec812ac7674bb3efb4c8f5fb78a6` |
| Payment token (USDC) | `0xc70B8741B8B07A6d61E54fd4B20f22Fa648E5565` |

Mainnet addresses are in `config/addresses.json`. All confirmed to have bytecode.

---

## 2. ⚠️ The one real blocker — deal with it on day 1, not day 12

**`EvaluatorRouter` maintains a policy whitelist.** From the repo README:

> *"EvaluatorRouterUpgradeable — acts as both `job.evaluator` and `job.hook`. **Whitelists policies**, binds each registered job to a policy..."*

So you **cannot** point a job on BNB Chain's official Router at your `ProofPolicy` until an admin whitelists it. Discovering this in week 2 would wreck your timeline. Two moves, and you should do **both**:

**A. Deploy your own APEX stack (your safety net — do this first).**
The repo is open source with a one-shot `bun run deploy:testnet`. Deploy your own Commerce + Router + `ProofPolicy`, whitelist yourself, done. Fully permissionless, works today, nothing to wait for. Your demo is never blocked.

**B. Ask BNB Chain to whitelist `ProofPolicy` on the official testnet Router.**
Post in the hackathon Discord support group in week 1 with your deployed address and a two-line explanation.

Move B is worth far more than the integration itself. It puts your project **in front of the core team, in their own channel, framed as a contribution to their stack** — weeks before judging. Even a "not yet" is a conversation with the people who decide prizes. And their own custom-policy doc invites exactly this. If they say yes, "our policy is whitelisted on BNB Chain's production Router" is a line no other submission will have.

---

## 3. Accounts and keys to set up (~45 min, do it today)

| # | What | Where | Note |
|---|---|---|---|
| 1 | **Throwaway wallet** | MetaMask / `cast wallet new` | Fresh key. Never one that's held real funds. Hackathon keys leak. |
| 2 | **Testnet tBNB** | [bnbchain.org/en/testnet-faucet](https://www.bnbchain.org/en/testnet-faucet) | Get 3 funded wallets — owner, client, provider — the e2e suite needs all three |
| 3 | **BscScan API key** | [bscscan.com/myapikey](https://bscscan.com/myapikey) | Free. **Required** for contract verification, which is explicitly scored |
| 4 | **Public GitHub repo** | — | Public from commit #1. Commit history is scored and can't be faked retroactively |
| 5 | **X account** | — | Tweet day 1 tagging `@BNBChain` `#BNBAIHack`. A tweet is a hard submission requirement |
| 6 | **Hackathon Discord** | [mee6.xyz/i/f00NIOmDWP](https://mee6.xyz/i/f00NIOmDWP) | Where you make the whitelist ask |
| 7 | **APRO** | [docs.apro.com](https://docs.apro.com) | Feed addresses + signature format for `AttestationVerifier` |
| 8 | **NetMind / Unibase** | sponsor sites | Can wait until week 2 |

---

## 4. Toolchain

Your workspace already has Node 20, Python 3.13, npm, git. You'll also want:

```bash
# Bun — apex-contracts is Bun + Hardhat; you need it to run their tests/deploys
curl -fsSL https://bun.sh/install | bash

# Foundry — for YOUR contracts (forge test is much nicer for fuzzing criteria)
curl -L https://foundry.paradigm.xyz | bash && foundryup

# The agent SDK (Python 3.10+)
pip install "bnbagent[server,ipfs]"
```

Mixing Foundry for your contracts with Bun/Hardhat for the vendored APEX stack is fine and normal.

---

## 5. Your actual first day (before any Solidity)

The highest-value thing you can do today is **not** write `ProofPolicy`. It's to run one job end-to-end through the *existing* stack so the interfaces are in your hands.

```bash
git clone https://github.com/bnb-chain/apex-contracts && cd apex-contracts
bun install && bun run compile
bun test                 # 62 unit tests, ~1.5s — read OptimisticPolicy.test.ts closely
bun run node             # terminal 1: local chain
bun run deploy:local     # terminal 2: your own full stack
bun run e2e:local        # all 5 ERC-8183 flows, ~15s
```

Then read `test/e2e/flows/happy.ts` and `dispute-reject.ts`. **When you can explain why `dispute-reject` refunds the client, you're ready to write `ProofPolicy`** — because your job is to make that refund happen automatically, from evidence, with no human dispute.

Budget one day. It will save you three.

---

## 6. Ordered task list for week 1

1. ✅ Preflight passes (`node scripts/preflight.mjs`) — **already done**
2. Wallets funded, BscScan key, repo public, day-1 tweet
3. `bun run e2e:local` green on your machine
4. Deploy your own APEX stack to BSC testnet (unblocks everything)
5. Post the whitelist ask in Discord
6. `EvidenceRegistry.sol` + tests → deploy → **verify on BscScan**
7. `CriteriaEngine.sol`, four metrics only
8. `ProofPolicy.check()` gates 1 and 4 (skip APRO for now — prove the loop first)
9. **Milestone that matters: a real job on testnet that settles REJECTED because criteria weren't met.** Save that tx hash. It is the single most valuable artifact in your submission.
10. `AttestationVerifier` (gate 2) once the loop is green

Note the ordering: **get `settle()` returning REJECT on a real failing job before you touch APRO, NetMind, or any UI.** That one transaction is the proof your thesis works. Everything else is elaboration, and if you run out of time, you still have a submission.

---

## 7. Files in this scaffold

```
attestable/
├── DAY-0.md                      ← you are here
├── .env.example                  ← copy to .env; live addresses pre-filled
├── config/addresses.json         ← testnet + mainnet APEX addresses
├── contracts/
│   ├── IPolicy.sol               ← vendored from bnb-chain/apex-contracts
│   └── ProofPolicy.sol           ← skeleton: correct interface, 6 invariants,
│                                   TODO gates, and the REJECT design note
└── scripts/preflight.mjs         ← chain + contract liveness check (passing)
```

Read the design note at the bottom of `ProofPolicy.check()` — it explains why Attestable has a REJECT path when BNB Chain's own ZK template deliberately doesn't. That argument is a deck slide, and it's the thing that will separate you from a team that just copied the template.

---

## 8. Reference

- Custom policy guide — `github.com/bnb-chain/apex-contracts/blob/main/docs/custom-policy.md`
- Design + threat model — `docs/design.md` §5.5, §6
- Agent SDK — `github.com/bnb-chain/bnbagent-sdk`
- SDK docs — `docs.bnbchain.org/developer-kit/bnbagent-sdk/`
- MPP SDK (HTTP 402 payments) — `docs.bnbchain.org/developer-kit/mpp-sdk/`
- APRO — `docs.apro.com/ai-oracle/`
- Faucet — `bnbchain.org/en/testnet-faucet`
