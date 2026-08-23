# Attestable

**Agents don't get paid for showing up. They get paid for proof.**

An evidence-based settlement policy for AI agents on BNB Chain.

---

## The problem

BNB Chain ships a real agentic commerce stack on BSC mainnet and testnet — ERC-8004 identity, ERC-8183 job escrow, and an `EvaluatorRouter` that binds each job to a pluggable settlement policy.

The policy that ships with it, `OptimisticPolicy`, is UMA-style: **silence past the dispute window is implicit approval.**

That is a reasonable bootstrap for human-supervised work. It is structurally broken for autonomous agents, because the entire premise of an autonomous agent is that *nobody is watching*. At any real scale, "silence approves" means an agent that does nothing gets paid by default, and the client's only defence is to be personally vigilant — the exact thing they hired an agent to stop doing.

## The approach

`EvaluatorRouter` binds a *pluggable* policy per job, and `OptimisticPolicy` is explicitly the **reference** implementation. BNB Chain's own [custom-policy guide](https://github.com/bnb-chain/apex-contracts/blob/main/docs/custom-policy.md) says to write a new one when the verdict function itself needs to change — naming *"require an oracle price range at submission"* and *"route to a third-party attestation service"* as examples.

Attestable is that second policy. An agent gets paid only if it can prove it did the job.

```
Client hires with machine-checkable criteria
        ↓
Agent commits a hash-chained decision log — inputs, model version,
decision, resulting tx — each leaf BEFORE the outcome is known
        ↓
settle() → ProofPolicy verifies evidence against criteria
        ↓
APPROVED → escrow releases      REJECTED → client auto-refunded
        ↓
Verdict feeds a public track record keyed to ERC-8004 identity
```

Reputation becomes a **byproduct of getting paid**, not a self-report. It cannot be farmed without escrowing real value and satisfying verifiable criteria.

## What this proves — and what it doesn't

| Proves | Does not prove |
|---|---|
| Inputs were real — oracle-signed, not invented | That the model's reasoning was sound |
| Decision was committed **before** the outcome was known | That the agent is *good* |
| On-chain action matches the committed decision | That the exact claimed weights ran (needs TEE/zkML) |
| Outcome satisfies the criteria, recomputable by anyone | Anything about off-chain side effects |

Attestable makes agent claims **falsifiable**. Today an agent says "I made 40%" and there is no way to check. Full execution integrity (Phala TEE, zkML) is roadmap, not claim.

## Status

| Component | State |
|---|---|
| `EvidenceRegistry.sol` | ✅ Implemented — 25 tests, 512 fuzz runs passing |
| `ProofPolicy.sol` | 🔨 Skeleton — interface + invariants pinned, gates TODO |
| `CriteriaEngine.sol` | ⬜ Next |
| `AttestationVerifier.sol` | ⬜ Pending APRO feed integration |
| `ReputationIndex.sol` | ⬜ Planned |
| Frontend (4 screens) | ✅ Built, running |
| Sentinel reference agent | ⬜ Planned |

## Quick start

```bash
# contracts
forge test -vv
forge test --gas-report

# chain + deployed-stack liveness
node scripts/preflight.mjs

# frontend
python3 -m http.server 3000 --bind 0.0.0.0 --directory frontend
```

## Measured gas (optimizer on, 200 runs)

| Operation | Gas |
|---|---|
| Deploy `EvidenceRegistry` | 762,828 |
| `commit` — first leaf (cold) | 98,745 |
| `commit` — steady state (warm) | 28,380 |
| `commitBatch` — per leaf amortised | ~27,500 |
| `seal` | ~30,200 |
| `verifyChain` — 12 leaves | ~31,800 |
| `maxGap` — 5 leaves | 3,564 |

**Economics, stated honestly.** A 7-day job at hourly cadence is ~170 leaves ≈ **4.9M gas** of commit cost, borne by the agent. On BSC at 1 gwei that is ~0.005 BNB. Evidence is not free, and cadence is therefore a real economic parameter, not a free dial — a criterion demanding minute-level sampling over 30 days would cost more than most jobs are worth.

This is a feature of the design rather than a flaw in it: proof costs something, so criteria have to be chosen deliberately. `commitBatch` exists to amortise the 21k base cost for high-cadence agents.

## Design notes

**The registry is deliberately permissionless.** It does not know what a job is or who is entitled to work one. First committer for a `jobId` claims the record and is locked in. Authorisation lives in `ProofPolicy`, the only contract with the kernel context to answer *"is this the provider the client actually hired?"* A front-runner who claims a `jobId` has only written a record under their own address that no policy will honour, at their own gas expense. The registry has no admin, no roles, no upgrade path, nothing to compromise.

**No agent-supplied root.** `seal()` takes a blob URI, not a root. The agent never supplies the value it is judged against — `chainHead` is accumulated by the contract from leaves it accepted one at a time.

**Storage is 32 bytes per job.** Leaves are emitted as events, never stored. Whoever wants settlement pays calldata to present the evidence. Cost is linear in leaf count; jobs needing tens of thousands of leaves should move to a Merkle commitment with sampled inclusion proofs — the fold function stays identical, only the accumulator changes.

**`NO_OP` is explicit.** An agent that looks and correctly decides to do nothing must be able to prove it was awake. Without a no-op commitment, diligent inaction is indistinguishable from absence — and inaction is frequently the correct call.

**`ProofPolicy` has a REJECT path** where the upstream `ZkProofPolicy` template deliberately does not. That template notes *"'I can prove it' is asymmetric with 'I can prove it is wrong'."* Attestable's criteria are decidable in **both** directions — "health factor stayed ≥ 1.6 across 95% of sampled blocks" has a negation independently recomputable from chain state. That symmetry is what earns a real REJECT, which is the point: the client is refunded at settlement without having to notice.

## Deployed dependencies — BSC Testnet (97)

| Contract | Address |
|---|---|
| `AgenticCommerce` | `0xa206c0517B6371C6638CD9e4a42Cc9f02A33B0DE` |
| `EvaluatorRouter` | `0xd7d36d66d2f1b608a0f943f722d27e3744f66f25` |
| `OptimisticPolicy` | `0x4f4678d4439fec812ac7674bb3efb4c8f5fb78a6` |
| Payment token (USDC) | `0xc70B8741B8B07A6d61E54fd4B20f22Fa648E5565` |

Mainnet addresses in `config/addresses.json`. Source of truth: [apex-contracts#deployments](https://github.com/bnb-chain/apex-contracts#deployments).

## Known blocker

`EvaluatorRouter` **whitelists policies**, so jobs on BNB Chain's official Router cannot bind `ProofPolicy` until an admin adds it. Mitigation is twofold: deploy an independent APEX stack (open source, permissionless) so the demo is never blocked, and separately request whitelisting on the official testnet Router.

## Licence

MIT.
