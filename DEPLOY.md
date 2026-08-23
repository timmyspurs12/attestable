# Deploying to BSC Testnet

Verified working against a local chain: **10 transactions, all successful, both verdicts correct.** These are the exact commands for testnet.

## 1. Fill `.env`

```
PRIVATE_KEY=0x...            # throwaway wallet, never one that held real funds
DEPLOYER_ADDRESS=0x...
ETHERSCAN_API_KEY=...        # bscscan.com/myapikey — required for verification
```

Fund the wallet: https://www.bnbchain.org/en/testnet-faucet

```bash
node scripts/preflight.mjs   # confirms chain + balance before you spend anything
```

## 2. Deploy + verify

```bash
source .env
forge script script/Deploy.s.sol \
  --rpc-url bsc_testnet --broadcast --verify -vvv
```

Writes `config/deployed.97.json`. If verification is skipped or fails, run it manually — **verified contracts are an explicit scoring criterion**:

```bash
forge verify-contract <ADDRESS> contracts/EvidenceRegistry.sol:EvidenceRegistry \
  --chain 97 --etherscan-api-key $ETHERSCAN_API_KEY --watch

forge verify-contract <ADDRESS> contracts/ProofPolicy.sol:ProofPolicy \
  --chain 97 --etherscan-api-key $ETHERSCAN_API_KEY --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,uint64)" \
      <ROUTER> <REGISTRY> 3600)
```

## 3. Run the demo — this is the submission artifact

```bash
export ADDR_REGISTRY=$(jq -r .evidenceRegistry config/deployed.97.json)
export ADDR_POLICY=$(jq -r .proofPolicy config/deployed.97.json)

forge script script/Demo.s.sol --rpc-url bsc_testnet --broadcast -vvv
```

Two jobs, 8 transactions:

| | |
|---|---|
| **Job A** | agent did the work → **APPROVE** |
| **Job B** | position left below threshold for 6h → **REJECT** |

Job B is the one that matters. A client refunded automatically, with no dispute raised and nobody watching — the case `OptimisticPolicy` would have paid out.

**Save both job ids and every tx hash.** They go in the README, the deck and the demo video. The hackathon requires at least 2 successful transactions inside the contest window; this produces 10.

## 4. Verdicts harden after the proof window

`PROOF_WINDOW` defaults to 1 hour. Before it elapses, incomplete evidence reads PENDING rather than REJECT, so an honest agent is not punished for a slow settler. After it passes:

```bash
JOB_ID=<job B id> forge script script/Report.s.sol --rpc-url bsc_testnet
```

Set `PROOF_WINDOW=60` at deploy time if you want a faster loop while filming.

## Note on the router

`ProofPolicy` gates `onSubmitted` on an immutable router. In production that is BNB Chain's `EvaluatorRouter`, but jobs cannot bind to our policy there until it is whitelisted, so `ROUTER` defaults to the deployer and the full lifecycle runs today. Pointing it at the real router is one env var and a redeploy:

```bash
ROUTER=0xd7d36d66d2f1b608a0f943f722d27e3744f66f25 forge script script/Deploy.s.sol ...
```

## What ran locally

```
Deploy.s.sol   CREATE EvidenceRegistry     ✓
               CREATE ProofPolicy          ✓

Demo.s.sol     bindTerms   (job A)         ✓
               bindTerms   (job B)         ✓
               commitBatch (24 leaves)     ✓
               seal                        ✓
               commitBatch (24 leaves)     ✓
               seal                        ✓
               onSubmitted (job A)         ✓
               onSubmitted (job B)         ✓

JOB A  honest agent      leaves 24  sealed true  verdict APPROVE
JOB B  breaching agent   leaves 24  sealed true  verdict REJECT
```
