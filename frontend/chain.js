/* Attestable — chain layer.
 *
 * Reads verdicts, evidence and criteria straight from BSC and re-verifies
 * every claim in the browser. Nothing here is privileged: it is the same path
 * an auditor takes, which is the entire point of the product.
 *
 * Falls back to demonstration data when config.js has no addresses, and says
 * so on screen. A demo that silently shows fake numbers as if they were real
 * is worse than no demo.
 */
(function () {
  "use strict";

  const CFG = window.ATTESTABLE_CONFIG || {};
  const E = window.ethers;

  // ---------------------------------------------------------------
  // ABI — only what we call
  // ---------------------------------------------------------------

  const REGISTRY_ABI = [
    "function recordOf(uint256) view returns (tuple(address agent, bytes32 chainHead, uint32 leafCount, uint64 firstObservedAt, uint64 lastObservedAt, uint64 sealedAt, bool isSealed))",
    "function verifyChain(uint256, tuple(bytes32 inputsHash, bytes32 attestationId, bytes32 policyVersion, bytes32 decisionHash, bytes32 actionTxHash, uint64 observedAt)[]) view returns (bool)",
    "event LeafCommitted(uint256 indexed jobId, uint32 indexed index, bytes32 chainHead, tuple(bytes32 inputsHash, bytes32 attestationId, bytes32 policyVersion, bytes32 decisionHash, bytes32 actionTxHash, uint64 observedAt) leaf)",
    "event RecordSealed(uint256 indexed jobId, bytes32 chainHead, uint32 leafCount, uint64 sealedAt, string blobURI)",
  ];

  const POLICY_ABI = [
    "function termsOf(uint256) view returns (address provider, bytes32 criteriaHash, uint64 submittedAt, bool bound)",
    "function criteriaOf(uint256) view returns (tuple(bytes32 metric, uint8 op, int256 threshold, uint16 minSamplePct, uint32 minSamples, uint32 maxGapSeconds)[])",
    "function check(uint256, bytes) view returns (uint8 verdict, bytes32 reason)",
    "function observationHash(bytes32 metric, int256 value, uint64 observedAt) pure returns (bytes32)",
    "function proofWindow() view returns (uint64)",
  ];

  const METRICS = {};
  ["health_factor", "collateral_ratio", "slippage_bps", "oracle_deviation_bps"].forEach((m) => {
    METRICS[E.keccak256(E.toUtf8Bytes(m))] = m;
  });

  const VERDICT = ["PENDING", "APPROVED", "REJECTED"];
  const OPS = ["≥", "≤", "="];

  // ---------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------

  const configured = () =>
    !!(CFG.evidenceRegistry && CFG.proofPolicy && (CFG.jobs || []).length);

  const short = (h) => (h ? h.slice(0, 6) + "…" + h.slice(-4) : "—");
  const wad = (v) => Number(E.formatUnits(v, 18));

  function metricName(id) {
    return (METRICS[id] || "unknown").replace(/_/g, " ");
  }

  // ---------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------

  async function loadJob(jobId) {
    const provider = new E.JsonRpcProvider(CFG.rpcUrl, CFG.chainId, {
      staticNetwork: true,
    });
    const reg = new E.Contract(CFG.evidenceRegistry, REGISTRY_ABI, provider);
    const pol = new E.Contract(CFG.proofPolicy, POLICY_ABI, provider);

    const [record, terms, criteria] = await Promise.all([
      reg.recordOf(jobId),
      pol.termsOf(jobId),
      pol.criteriaOf(jobId),
    ]);

    // Rebuild the decision log from events. Storage holds only the 32-byte
    // accumulator; the leaves live in logs, exactly as designed.
    const filter = reg.filters.LeafCommitted(jobId);
    const logs = await reg.queryFilter(filter, CFG.fromBlock || 0, "latest");
    const leaves = logs
      .map((l) => ({
        index: Number(l.args.index),
        chainHead: l.args.chainHead,
        inputsHash: l.args.leaf.inputsHash,
        attestationId: l.args.leaf.attestationId,
        policyVersion: l.args.leaf.policyVersion,
        decisionHash: l.args.leaf.decisionHash,
        actionTxHash: l.args.leaf.actionTxHash,
        observedAt: Number(l.args.leaf.observedAt),
        txHash: l.transactionHash,
        block: l.blockNumber,
      }))
      .sort((a, b) => a.index - b.index);

    let blobURI = null;
    try {
      const sealed = await reg.queryFilter(
        reg.filters.RecordSealed(jobId),
        CFG.fromBlock || 0,
        "latest",
      );
      if (sealed.length) blobURI = sealed[sealed.length - 1].args.blobURI;
    } catch (_) {}

    // State-derived verdict. A full APPROVE additionally needs the complete
    // leaf set as calldata — see reverify() below.
    let verdict = 0,
      reason = E.ZeroHash;
    try {
      const v = await pol.check(jobId, "0x");
      verdict = Number(v[0]);
      reason = v[1];
    } catch (_) {}

    return { jobId, record, terms, criteria, leaves, blobURI, verdict, reason, reg, pol };
  }

  /* Independently verify a reveal bundle against the on-chain commitments.
   *
   * This is the claim the whole project rests on, checked in the visitor's own
   * browser: each revealed (metric, value) must rehash to the inputsHash the
   * agent committed BEFORE the outcome was known. Any mismatch is a lie, and
   * it is pointed at precisely. */
  function normalize(r) {
    if (!r) return null;
    const metricId = r.metric.startsWith("0x") ? r.metric : E.keccak256(E.toUtf8Bytes(r.metric));
    const raw = r.valueWad !== undefined ? BigInt(r.valueWad) : E.parseUnits(String(r.value), 18);
    return { metricId, raw, num: Number(E.formatUnits(raw, 18)) };
  }

  async function reverify(job, bundle) {
    if (!bundle || !bundle.reveals) return null;
    const out = { total: job.leaves.length, matched: 0, mismatches: [] };

    for (let i = 0; i < job.leaves.length; i++) {
      const r = normalize(bundle.reveals[i]);
      if (!r) {
        out.mismatches.push(i);
        continue;
      }
      const expected = E.keccak256(
        E.AbiCoder.defaultAbiCoder().encode(
          ["bytes32", "bytes32", "int256", "uint64"],
          [
            E.keccak256(E.toUtf8Bytes("ATTESTABLE_OBS_V1")),
            r.metricId,
            r.raw,
            job.leaves[i].observedAt,
          ],
        ),
      );
      if (expected.toLowerCase() === job.leaves[i].inputsHash.toLowerCase()) out.matched++;
      else out.mismatches.push(i);
    }
    out.ok = out.mismatches.length === 0 && out.total > 0;
    return out;
  }

  // ---------------------------------------------------------------
  // Rendering — reuses the ids already in index.html
  // ---------------------------------------------------------------

  function banner(text, live) {
    let el = document.getElementById("dataSource");
    if (!el) {
      el = document.createElement("div");
      el.id = "dataSource";
      el.style.cssText =
        "font-family:var(--font-mono);font-size:10.5px;letter-spacing:.12em;" +
        "text-transform:uppercase;padding:7px 32px;border-bottom:1px solid var(--rule);";
      document.querySelector(".topbar").after(el);
    }
    el.style.color = live ? "var(--green)" : "var(--ink-faint)";
    el.textContent = text;
  }

  function renderLedger(job) {
    const body = document.getElementById("ledgerBody");
    if (!body) return;
    const v = VERDICT[job.verdict].toLowerCase();
    const c = job.criteria[0];
    const crit = c
      ? `${metricName(c.metric)} ${OPS[Number(c.op)]} ${wad(c.threshold)}, ` +
        `${Number(c.minSamplePct) / 100}%`
      : "—";

    body.innerHTML = "";
    const tr = document.createElement("tr");
    tr.innerHTML =
      `<td class="num">${short(E.toBeHex(job.jobId, 32))}</td>` +
      `<td class="num">${short(job.terms.provider)}</td>` +
      `<td>${crit}</td>` +
      `<td><span class="stamp ${v}">${VERDICT[job.verdict]}</span></td>` +
      `<td class="num">${job.record.leafCount} leaves</td>` +
      `<td class="num">${
        job.record.sealedAt > 0n
          ? new Date(Number(job.record.sealedAt) * 1000).toISOString().slice(0, 10)
          : "—"
      }</td>`;
    body.appendChild(tr);

    const hero = document.querySelector(".hero-number");
    if (hero) {
      const pct = job.verdict === 1 ? "100" : job.verdict === 2 ? "0" : "—";
      hero.innerHTML = `${pct}<sup>${pct === "—" ? "" : ".0%"}</sup>`;
    }
    const label = document.querySelector(".hero-metric .field-label");
    if (label) label.textContent = `Criteria-met rate — job ${short(E.toBeHex(job.jobId, 32))}`;

    const name = document.querySelector(".agent-name");
    if (name) name.textContent = "Agent " + short(job.record.agent);

    const chip = document.querySelector(".hash-chip .mono");
    if (chip) chip.textContent = short(job.record.agent);

    const fields = document.querySelectorAll(".field .val");
    if (fields.length >= 5) {
      fields[0].textContent = String(job.record.leafCount);
      fields[1].textContent = job.verdict === 2 ? "1" : "0";
      fields[2].textContent = job.record.isSealed ? "sealed" : "open";
      fields[3].textContent = `${job.leaves.length} leaves`;
      fields[4].textContent = short(job.record.chainHead);
    }

    const note = document.querySelector(".footer-note");
    if (note) {
      note.innerHTML =
        `<span>chainHead <span class="mono">${short(job.record.chainHead)}</span></span>` +
        `<span>Read live from BSC testnet · chainId ${CFG.chainId}</span>`;
    }
  }

  function renderVerdict(job) {
    const stamp = document.getElementById("bigStamp");
    if (stamp) {
      stamp.textContent = VERDICT[job.verdict];
      stamp.classList.toggle("rejected", job.verdict !== 1);
      stamp.classList.remove("slam");
      void stamp.offsetWidth;
      stamp.classList.add("slam");
    }
    const rows = document.querySelectorAll("#screen-verdict .doc-row .v");
    if (rows.length >= 6) {
      rows[0].textContent = short(job.record.agent);
      rows[1].textContent = short(job.terms.provider);
      const c = job.criteria[0];
      rows[2].textContent = c
        ? `${metricName(c.metric)} ${OPS[Number(c.op)]} ${wad(c.threshold)}, ` +
          `${Number(c.minSamplePct) / 100}%, ≥${c.minSamples} samples`
        : "unbound";
      rows[3].textContent = String(job.record.leafCount);
      rows[4].textContent = job.record.isSealed ? "sealed" : "not sealed";
      rows[5].textContent = short(job.reason);
    }
  }

  function renderReplay(job, bundle, check) {
    const strip = document.getElementById("ticksStrip");
    const graph = document.getElementById("thresholdGraph");
    if (!strip || !job.leaves.length) return;

    const c = job.criteria[0];
    const threshold = c ? wad(c.threshold) : null;
    const vals = bundle
      ? job.leaves.map((_, i) => {
          const r = normalize(bundle.reveals[i]);
          return r ? r.num : null;
        })
      : null;

    strip.innerHTML = "";
    job.leaves.forEach((leaf, i) => {
      const t = document.createElement("div");
      const v = vals ? vals[i] : null;
      const bad =
        (check && check.mismatches.includes(i)) ||
        (v !== null && threshold !== null && v < threshold);
      t.className = "tick" + (bad ? " flag" : "");
      t.style.height =
        (v !== null ? 8 + Math.min(1, Math.max(0, (v - 1) / 1.2)) * 74 : 42) + "px";
      t.dataset.i = i;
      t.addEventListener("mouseenter", () => readout(job, i, v, threshold));
      t.addEventListener("click", () => specimen(job, i, v, threshold, check));
      strip.appendChild(t);
    });

    if (graph && vals && threshold !== null) {
      const min = 1.05,
        max = 2.1;
      const y = (x) => 118 - ((x - min) / (max - min)) * 104;
      const pts = vals
        .map((v, i) => `${(i / (vals.length - 1)) * 1000},${y(v ?? min)}`)
        .join(" ");
      graph.innerHTML =
        `<line x1="0" y1="${y(threshold)}" x2="1000" y2="${y(threshold)}" ` +
        `stroke="var(--red)" stroke-width="1.4" stroke-dasharray="5 5" opacity=".85"/>` +
        `<polyline points="${pts}" fill="none" stroke="var(--ink)" stroke-width="1.6"/>`;
    } else if (graph) {
      graph.innerHTML = "";
    }

    const h2 = document.querySelector(".replay-meta h2");
    if (h2)
      h2.innerHTML = `Job <span class="mono">${short(
        E.toBeHex(job.jobId, 32),
      )}</span> — ${job.leaves.length} committed decisions`;

    const toggle = document.querySelector(".demo-toggle");
    if (toggle) toggle.style.display = "none";

    specimen(job, 0, vals ? vals[0] : null, threshold, check);
  }

  function readout(job, i, v, threshold) {
    const leaf = job.leaves[i];
    const set = (id, txt, warn) => {
      const el = document.getElementById(id);
      if (!el) return;
      el.textContent = txt;
      el.classList.toggle("warn", !!warn);
    };
    const below = v !== null && threshold !== null && v < threshold;
    set("roBlock", String(leaf.block));
    set("roTime", new Date(leaf.observedAt * 1000).toISOString().replace("T", " ").slice(0, 16));
    set("roHF", v !== null ? v.toFixed(3) : "committed", below);
    set("roState", below ? "Below threshold" : v === null ? "value in bundle" : "Within threshold", below);
  }

  function specimen(job, i, v, threshold, check) {
    const leaf = job.leaves[i];
    const chain = document.getElementById("chain");
    if (!chain) return;

    const mismatch = check && check.mismatches.includes(i);
    const below = v !== null && threshold !== null && v < threshold;

    const title = document.getElementById("specimenTitle");
    if (title) title.textContent = `Decision ${i} · block ${leaf.block}`;
    const time = document.getElementById("specimenTime");
    if (time) time.textContent = new Date(leaf.observedAt * 1000).toUTCString();

    const stages = [
      {
        label: "Inputs",
        sub: "committed",
        fail: mismatch,
        facts: [
          ["commitment", short(leaf.inputsHash)],
          ["attestation", short(leaf.attestationId)],
          ["revealed", v !== null ? v.toFixed(3) : "—"],
        ],
      },
      {
        label: "Decision",
        sub: "pre-outcome",
        fail: false,
        facts: [
          ["hash", short(leaf.decisionHash)],
          ["model", short(leaf.policyVersion)],
          ["chainHead", short(leaf.chainHead)],
        ],
      },
      {
        label: "Action",
        sub: "on-chain",
        fail: false,
        facts: [
          ["commit tx", short(leaf.txHash)],
          ["action", leaf.actionTxHash === E.ZeroHash ? "no-op (deliberate)" : short(leaf.actionTxHash)],
          ["block", String(leaf.block)],
        ],
      },
      {
        label: "Outcome",
        sub: "measured",
        fail: below,
        facts: [
          ["value", v !== null ? v.toFixed(3) : "—"],
          ["threshold", threshold !== null ? String(threshold) : "—"],
          ["met", below ? "No" : v === null ? "—" : "Yes"],
        ],
      },
    ];

    chain.innerHTML = "";
    stages.forEach((s, idx) => {
      const d = document.createElement("div");
      d.className = "stage" + (s.fail ? " stage-fail" : "");
      d.innerHTML =
        `<span class="field-label">${s.label} — ${s.sub}</span>` +
        s.facts.map((f) => `<div class="fact"><span class="k">${f[0]}: </span>${f[1]}</div>`).join("");
      chain.appendChild(d);
      if (idx < 3) {
        const l = document.createElement("div");
        const broken = mismatch && idx === 0;
        l.className = "link" + (broken ? " broken" : "");
        l.innerHTML = broken
          ? `<div class="link-label">Break</div><svg viewBox="0 0 36 26"><ellipse cx="12" cy="13" rx="7" ry="9" fill="none" stroke="var(--red)" stroke-width="2"/><path d="M17 6 L22 20" stroke="var(--red)" stroke-width="2"/><path d="M31 6 L26 20" stroke="var(--red)" stroke-width="2"/></svg>`
          : `<svg viewBox="0 0 36 26"><ellipse cx="12" cy="13" rx="7" ry="9" fill="none" stroke="var(--ink-faint)" stroke-width="2"/><ellipse cx="24" cy="13" rx="7" ry="9" fill="none" stroke="var(--ink-faint)" stroke-width="2"/></svg>`;
        chain.appendChild(l);
      }
    });
  }

  // ---------------------------------------------------------------
  // Boot
  // ---------------------------------------------------------------

  async function boot() {
    if (!configured()) {
      banner("Demonstration data — no contracts configured in config.js", false);
      return;
    }
    banner("Connecting to BSC testnet…", false);
    try {
      const jobId = BigInt(CFG.jobs[0].id);
      const job = await loadJob(jobId);

      let bundle = null,
        check = null;
      try {
        const res = await fetch(`data/bundle-${CFG.jobs[0].id}.json`);
        if (res.ok) {
          bundle = await res.json();
          check = await reverify(job, bundle);
        }
      } catch (_) {}

      renderLedger(job);
      renderVerdict(job);
      renderReplay(job, bundle, check);

      let msg = `Live · BSC testnet · ${job.leaves.length} leaves · verdict ${VERDICT[job.verdict]}`;
      if (check) {
        msg += check.ok
          ? ` · ${check.matched}/${check.total} reveals verified in-browser`
          : ` · ${check.mismatches.length} reveal mismatch(es) detected`;
      }
      banner(msg, true);
      window.ATTESTABLE = { job, bundle, check, loadJob, reverify, normalize };
    } catch (err) {
      console.error(err);
      banner("Chain read failed — showing demonstration data. " + (err.shortMessage || err.message), false);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
