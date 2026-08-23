# Attestable — frontend

Single-file static UI. No build step, no dependencies. Open `index.html` or serve the folder:

```bash
python3 -m http.server 3000 --bind 0.0.0.0 --directory frontend
```

Verified: HTTP 200, 4 screens wired, 23/23 `getElementById` targets resolve, no undeclared CSS custom properties, no tab/screen mismatch.

## Screens

| Tab | Purpose |
|---|---|
| **Report** | Agent Report Card — hero criteria-met rate + settlement ledger |
| **Replay** | Decision Replay — flight-recorder timeline + evidence chain specimen |
| **Verdict** | Certificate of Settlement — stamp + four verification gates |
| **Commission** | Requisition form — machine-checkable criteria builder |

## Deliberate behaviours (do not "fix" these)

- **Replay opens in Breach mode.** `setMode('flag')` runs on load, so the first thing a visitor sees is a *caught failure* — broken chain link, metric crossing below the dashed threshold, red ticks. This is the correct default: proving the system catches a bad agent is a far stronger claim than showing it approve a good one. Same reason the Verdict screen ships showing `REJECTED`.
- **Stamp fires on load** (`slamStamp` at +150ms) and re-fires via *Re-run certification*. Useful for retakes when recording the demo video.
- **Google Fonts load from CDN.** Renders correctly in a real browser and in the live preview. The in-app *file* preview sandbox blocks network requests, so fonts fall back there — that's expected, not a bug. Self-host into `frontend/fonts/` before the demo recording if you want zero dependency on network conditions.

## Data seams — where real chain data will plug in

All mock data is isolated to these points in the `<script>` block. Nothing else needs to change when we go live.

| Seam | Currently | Will become |
|---|---|---|
| `ledgerData` array | 6 hardcoded rows | `EvidenceRegistry` / kernel settlement events via `eth_getLogs` |
| `buildSeries(mode)` | seeded PRNG | committed evidence leaves for a real `jobId` |
| `updateReadout(i)` | `41200950 + i*23` | `observedAt` + block from the leaf |
| `selectTick(i)` → `stages[]` | literal strings | leaf fields: `inputsHash`, `attestationId`, `policyVersion`, `decisionHash`, `actionTxHash` |
| Verdict gates (static HTML) | 4 hardcoded rows | the four `ProofPolicy.check()` gates |
| `addClauseBtn` handler | appends a text row | ABI-encodes a `Criterion` struct for `createJob` |

The `broken` flag in `selectTick()` is the visual contract for gate 2 (unbroken hash chain) — when wired, it becomes a real verification result rather than an index comparison.

## Next

1. Read-only wiring: point `ledgerData` at real testnet events once `EvidenceRegistry` is deployed.
2. Wallet connect on Commission only (everything else stays public and read-only — that's the point of a verification instrument).
3. Self-host fonts before recording.
