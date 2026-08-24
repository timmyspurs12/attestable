/* Attestable — chain layer.
 *
 * Reads verdicts, evidence and criteria straight from BSC and re-verifies
 * every claim in the browser. Nothing here is privileged: it is the same path
 * an auditor takes, which is the entire point of the product.
 *
 * Live mode (config.js filled):
 *   - every hardcoded demo number in index.html is overwritten with chain data
 *   - the verdict shown is the REAL verdict: check() is replayed via eth_call
 *     with the full evidence (leaves + reveal bundle), the same call settle()
 *     would make
 *   - the reveal bundle is independently re-hashed against the on-chain
 *     commitments — a doctored bundle fails to match and is flagged
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

  const LEAF_TUPLE =
    "tuple(bytes32 inputsHash, bytes32 attestationId, bytes32 policyVersion, bytes32 decisionHash, bytes32 actionTxHash, uint64 observedAt)";
  const REVEAL_TUPLE = "tuple(bytes32 metric, int256 value)";

  const REGISTRY_ABI = [
    "function recordOf(uint256) view returns (tuple(address agent, bytes32 chainHead, uint32 leafCount, uint64 firstObservedAt, uint64 lastObservedAt, uint64 sealedAt, bool isSealed))",
    "function verifyChain(uint256, " + LEAF_TUPLE + "[]) view returns (bool)",
    "event LeafCommitted(uint256 indexed jobId, uint32 indexed index, bytes32 chainHead, " + LEAF_TUPLE + " leaf)",
    "event RecordSealed(uint256 indexed jobId, bytes32 chainHead, uint32 leafCount, uint64 sealedAt, string blobURI)",
  ];

  const POLICY_ABI = [
    "function termsOf(uint256) view returns (address provider, bytes32 criteriaHash, uint64 submittedAt, bool bound)",
    "function criteriaOf(uint256) view returns (tuple(bytes32 metric, uint8 op, int256 threshold, uint16 minSamplePct, uint32 minSamples, uint32 maxGapSeconds)[])",
    "function check(uint256, bytes) view returns (uint8 verdict, bytes32 reason)",
    "function observationHash(bytes32, int256, uint64) pure returns (bytes32)",
    "function proofWindow() view returns (uint64)",
  ];

  const METRICS = {};
  ["health_factor", "collateral_ratio", "slippage_bps", "oracle_deviation_bps"].forEach((m) => {
    METRICS[E.keccak256(E.toUtf8Bytes(m))] = m;
  });

  const VERDICT = ["PENDING", "APPROVED", "REJECTED"];
  const OPS = ["≥", "≤", "="];

  const REASONS = {};
  [
    ["ATTESTABLE_APPROVED", "approved — criteria met"],
    ["ATTESTABLE_REJECTED_NO_EVIDENCE", "rejected — no evidence"],
    ["ATTESTABLE_REJECTED_TOO_FEW_SAMPLES", "rejected — too few samples"],
    ["ATTESTABLE_REJECTED_WRONG_AGENT", "rejected — wrong agent"],
    ["ATTESTABLE_REJECTED_CRITERIA", "rejected — criteria unmet"],
  ].forEach(([k, v]) => (REASONS[E.keccak256(E.toUtf8Bytes(k))] = v));

  // ---------------------------------------------------------------
  // State
  // ---------------------------------------------------------------

  const S = { provider: null, reg: null, pol: null, cache: {}, active: 0 };

  // ---------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------

  const configured = () =>
    !!(CFG.evidenceRegistry && CFG.proofPolicy && (CFG.jobs || []).length);

  const short = (h) => (h ? String(h).slice(0, 6) + "…" + String(h).slice(-4) : "—");
  const wad = (v) => Number(E.formatUnits(v, 18));

  function metricName(id) {
    return (METRICS[id] || "unknown").replace(/_/g, " ");
  }

  function provider() {
    if (!S.provider) {
      S.provider = new E.JsonRpcProvider(CFG.rpcUrl, CFG.chainId, {
        staticNetwork: true,
      });
      S.reg = new E.Contract(CFG.evidenceRegistry, REGISTRY_ABI, S.provider);
      S.pol = new E.Contract(CFG.proofPolicy, POLICY_ABI, S.provider);
    }
    return S.provider;
  }

  /* Public RPCs cap eth_getLogs block ranges (publicnode: 50k). Scan in
   * chunks just under the cap so it works everywhere, forever. */
  async function queryFilterChunked(contract, filter, fromBlock) {
    const MAX = 49000;
    const toBlock = await provider().getBlockNumber();
    if (toBlock - fromBlock <= MAX) {
      return contract.queryFilter(filter, fromBlock, toBlock);
    }
    const out = [];
    for (let s = fromBlock; s <= toBlock; s += MAX) {
      out.push(...(await contract.queryFilter(filter, s, Math.min(s + MAX - 1, toBlock))));
    }
    return out;
  }

  const critText = (c) =>
    c
      ? `${metricName(c.metric)} ${OPS[Number(c.op)]} ${wad(c.threshold)}, ` +
        `${Number(c.minSamplePct) / 100}%`
      : "—";

  // ---------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------

  async function loadJob(jobId) {
    provider();

    const [record, terms, criteria] = await Promise.all([
      S.reg.recordOf(jobId),
      S.pol.termsOf(jobId),
      S.pol.criteriaOf(jobId),
    ]);

    // Rebuild the decision log from events. Storage holds only the 32-byte
    // accumulator; the leaves live in logs, exactly as designed.
    const logs = await queryFilterChunked(
      S.reg,
      S.reg.filters.LeafCommitted(jobId),
      CFG.fromBlock || 0,
    );
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
      const sealed = await queryFilterChunked(
        S.reg,
        S.reg.filters.RecordSealed(jobId),
        CFG.fromBlock || 0,
      );
      if (sealed.length) blobURI = sealed[sealed.length - 1].args.blobURI;
    } catch (_) {}

    return { jobId, record, terms, criteria, leaves, blobURI, verdict: 0, reason: E.ZeroHash };
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

  /* Replay the settlement itself: check(jobId, full evidence) via eth_call.
   * This is exactly the call settle() would make — the verdict on screen is
   * the contract's verdict, not the frontend's opinion. */
  async function settleVerdict(job, bundle) {
    if (!bundle || !bundle.reveals || !job.leaves.length) return null;
    if (bundle.reveals.length !== job.leaves.length) return null;
    try {
      const leaves = job.leaves.map((l) => [
        l.inputsHash,
        l.attestationId,
        l.policyVersion,
        l.decisionHash,
        l.actionTxHash,
        l.observedAt,
      ]);
      const reveals = bundle.reveals.map((r) => {
        const n = normalize(r);
        return [n.metricId, n.raw];
      });
      const evidence = E.AbiCoder.defaultAbiCoder().encode(
        [LEAF_TUPLE + "[]", REVEAL_TUPLE + "[]"],
        [leaves, reveals],
      );
      const v = await S.pol.check(job.jobId, evidence);
      return { verdict: Number(v[0]), reason: v[1] };
    } catch (_) {
      return null;
    }
  }

  /* Share of revealed samples that met the criterion — computed in-browser,
   * shown next to the on-chain verdict. */
  function criteriaPct(job, bundle) {
    const c = job.criteria && job.criteria[0];
    if (!c || !bundle || !bundle.reveals || !job.leaves.length) return null;
    let met = 0;
    job.leaves.forEach((_, i) => {
      const r = normalize(bundle.reveals[i]);
      if (!r) return;
      const t = wad(c.threshold);
      const op = Number(c.op);
      if ((op === 0 && r.num >= t) || (op === 1 && r.num <= t) || (op === 2 && r.num === t)) met++;
    });
    return { met, total: job.leaves.length, pct: (100 * met) / job.leaves.length };
  }

  async function loadJobWithEvidence(idx) {
    if (S.cache[idx]) return S.cache[idx];
    const id = CFG.jobs[idx].id;
    const job = await loadJob(BigInt(id));
    let bundle = null,
      check = null,
      settled = null;
    try {
      const res = await fetch(`data/bundle-${id}.json`);
      if (res.ok) {
        bundle = await res.json();
        check = await reverify(job, bundle);
      }
    } catch (_) {}
    if (check && check.ok) settled = await settleVerdict(job, bundle);
    if (settled) {
      job.verdict = settled.verdict;
      job.reason = settled.reason;
    }
    const entry = { idx, job, bundle, check, pct: criteriaPct(job, bundle) };
    S.cache[idx] = entry;
    return entry;
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

  function injectStyles() {
    const css = document.createElement("style");
    css.textContent = `
      #jobBar{display:flex;gap:8px;flex-wrap:wrap;padding:10px 32px;border-bottom:1px solid var(--rule);align-items:center}
      #jobBar .jb-label{font-family:var(--font-mono);font-size:10px;letter-spacing:.12em;text-transform:uppercase;color:var(--ink-faint)}
      #jobBar button{font-family:var(--font-mono);font-size:10.5px;letter-spacing:.06em;text-transform:uppercase;
        background:none;border:1px solid var(--rule);color:var(--ink);padding:5px 10px;cursor:pointer}
      #jobBar button:hover{border-color:var(--ink)}
      #jobBar button.active{border-color:var(--accent);color:var(--accent)}
      #ledgerBody tr.live-row{cursor:pointer}
      #ledgerBody tr.live-row:hover td{background:rgba(0,0,0,.03)}
      body.dark #ledgerBody tr.live-row:hover td{background:rgba(255,255,255,.05)}
    `;
    document.head.appendChild(css);
  }

  function renderJobBar(active) {
    let bar = document.getElementById("jobBar");
    if (!bar) {
      bar = document.createElement("div");
      bar.id = "jobBar";
      document.getElementById("dataSource").after(bar);
    }
    bar.innerHTML =
      `<span class="jb-label">On-chain jobs —</span>` +
      CFG.jobs
        .map(
          (j, i) =>
            `<button data-idx="${i}" class="${i === active ? "active" : ""}">${
              j.label || "job " + (i + 1)
            }</button>`,
        )
        .join("");
    bar.querySelectorAll("button").forEach((b) =>
      b.addEventListener("click", () => selectJob(Number(b.dataset.idx))),
    );
  }

  function renderLedger(entries, active) {
    const body = document.getElementById("ledgerBody");
    if (!body) return;

    // Relabel the header for live data (no escrow values in this demo).
    const th = document.querySelectorAll("#screen-report .ledger thead th");
    if (th.length >= 6) {
      th[1].textContent = "Agent";
      th[4].textContent = "Met";
      th[5].textContent = "Sealed";
    }

    body.innerHTML = "";
    entries
      .slice()
      .sort((a, b) => Number(b.job.record.sealedAt || 0n) - Number(a.job.record.sealedAt || 0n))
      .forEach((e) => {
        const v = VERDICT[e.job.verdict].toLowerCase();
        const tr = document.createElement("tr");
        tr.className = "live-row" + (e.idx === active ? " active" : "");
        tr.title = "Load this job";
        tr.innerHTML =
          `<td class="num">${short(E.toBeHex(e.job.jobId, 32))}</td>` +
          `<td class="num">${short(e.job.record.agent)}</td>` +
          `<td>${critText(e.job.criteria[0])}</td>` +
          `<td><span class="stamp ${v}">${VERDICT[e.job.verdict]}</span></td>` +
          `<td class="num">${e.pct ? e.pct.met + "/" + e.pct.total : "—"}</td>` +
          `<td class="num">${
            e.job.record.sealedAt > 0n
              ? new Date(Number(e.job.record.sealedAt) * 1000).toISOString().slice(0, 10)
              : "—"
          }</td>`;
        tr.addEventListener("click", () => selectJob(e.idx));
        body.appendChild(tr);
      });
  }

  function renderReport(e) {
    const job = e.job;
    const hero = document.querySelector(".hero-number");
    if (hero) {
      if (e.pct) {
        const p = e.pct.pct.toFixed(1);
        hero.innerHTML = `${p.split(".")[0]}<sup>.${p.split(".")[1]}%</sup>`;
      } else {
        hero.innerHTML = `—`;
      }
    }
    const label = document.querySelector(".hero-metric .field-label");
    if (label) label.textContent = `Criteria-met rate — job ${short(E.toBeHex(job.jobId, 32))}`;

    const name = document.querySelector(".agent-name");
    if (name) name.textContent = "Agent " + short(job.record.agent);

    const chip = document.querySelector(".hash-chip .mono");
    if (chip) chip.textContent = short(job.record.agent);
    const copy = document.querySelector(".copy-btn");
    if (copy) copy.dataset.copy = job.record.agent;
    const seal = document.querySelector(".status-seal");
    if (seal) seal.textContent = "Live on BSC testnet";

    // Relabel the field strip, then fill it — labels must match live data.
    const fields = document.querySelectorAll("#screen-report .field-strip .field");
    const LIVE = [
      ["Leaves committed", String(job.record.leafCount)],
      ["Breach flags", String(e.pct ? e.pct.total - e.pct.met : "—")],
      ["Record state", job.record.isSealed ? "sealed" : "open"],
      ["Evidence shown", `${job.leaves.length} leaves`],
      ["chainHead", short(job.record.chainHead)],
    ];
    fields.forEach((f, i) => {
      if (LIVE[i]) {
        const l = f.querySelector(".field-label");
        const v = f.querySelector(".val");
        if (l) l.textContent = LIVE[i][0];
        if (v) v.textContent = LIVE[i][1];
      }
    });

    const note = document.querySelector(".footer-note");
    if (note) {
      note.innerHTML =
        `<span>chainHead <span class="mono">${short(job.record.chainHead)}</span></span>` +
        `<span>Verdict replayed live from BSC testnet · chainId ${CFG.chainId}</span>`;
    }
  }

  function renderVerdict(e) {
    const job = e.job;
    const rows = document.querySelectorAll("#screen-verdict .doc-row");
    const vals = document.querySelectorAll("#screen-verdict .doc-row .v");
    const reasonTxt =
      REASONS[job.reason] || (job.reason && job.reason !== E.ZeroHash ? short(job.reason) : "—");
    if (vals.length >= 6) {
      vals[0].textContent = short(job.record.agent);
      vals[1].textContent = short(job.terms.provider);
      vals[2].textContent = job.criteria[0]
        ? `${critText(job.criteria[0])}, ≥${job.criteria[0].minSamples} samples`
        : "unbound";
      vals[3].textContent = String(job.record.leafCount);
      vals[4].textContent = e.pct
        ? `${e.pct.met} of ${e.pct.total} (${e.pct.pct.toFixed(1)}%)`
        : "—";
      vals[5].textContent = reasonTxt;
    }
    // Relabel rows whose demo meaning doesn't apply to live data.
    const LIVE_LABELS = [
      "Agent",
      "Provider (hired)",
      "Acceptance criterion",
      "Committed leaves",
      "Samples within threshold",
      "Verdict reason",
    ];
    rows.forEach((r, i) => {
      const l = r.querySelector("span:first-child");
      if (l && LIVE_LABELS[i]) l.textContent = LIVE_LABELS[i];
    });

    const no = document.querySelector("#screen-verdict .doc-head .field-label");
    if (no) no.innerHTML = `No. <span class="mono">${short(E.toBeHex(job.jobId, 32))}</span>`;

    const stamp = document.getElementById("bigStamp");
    if (stamp) {
      stamp.textContent = VERDICT[job.verdict];
      stamp.classList.toggle("rejected", job.verdict !== 1);
      stamp.classList.remove("slam");
      void stamp.offsetWidth;
      stamp.classList.add("slam");
    }
  }

  function renderReplay(e) {
    const job = e.job;
    const strip = document.getElementById("ticksStrip");
    const graph = document.getElementById("thresholdGraph");
    if (!strip || !job.leaves.length) return;

    const c = job.criteria[0];
    const threshold = c ? wad(c.threshold) : null;
    const vals = e.bundle
      ? job.leaves.map((_, i) => {
          const r = normalize(e.bundle.reveals[i]);
          return r ? r.num : null;
        })
      : null;

    const tracked = document.querySelector(".recorder .field-label");
    if (tracked && c) {
      tracked.textContent = `Tracked metric — ${metricName(c.metric)} ${OPS[Number(c.op)]} ${wad(
        c.threshold,
      )}`;
    }

    strip.innerHTML = "";
    job.leaves.forEach((leaf, i) => {
      const t = document.createElement("div");
      const v = vals ? vals[i] : null;
      const bad =
        (e.check && e.check.mismatches.includes(i)) ||
        (v !== null && threshold !== null && v < threshold);
      t.className = "tick" + (bad ? " flag" : "");
      t.style.height =
        (v !== null ? 8 + Math.min(1, Math.max(0, (v - 1) / 1.2)) * 74 : 42) + "px";
      t.dataset.i = i;
      t.addEventListener("mouseenter", () => readout(job, i, v, threshold));
      t.addEventListener("click", () => specimen(job, i, v, threshold, e.check));
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

    // Real time axis instead of the demo's fixed 7-day labels.
    const axis = document.querySelector(".axis-row");
    if (axis && job.leaves.length) {
      const spans = axis.querySelectorAll("span");
      const f = new Date(job.leaves[0].observedAt * 1000);
      const l = new Date(job.leaves[job.leaves.length - 1].observedAt * 1000);
      const mid = new Date((f.getTime() + l.getTime()) / 2);
      const fmt = (d) =>
        d.toISOString().slice(5, 10).replace("-", "·") + " " + d.toISOString().slice(11, 16);
      if (spans.length >= 3) {
        spans[0].textContent = fmt(f);
        spans[1].textContent = fmt(mid);
        spans[2].textContent = fmt(l);
      }
    }

    const h2 = document.querySelector(".replay-meta h2");
    if (h2)
      h2.innerHTML = `Job <span class="mono">${short(
        E.toBeHex(job.jobId, 32),
      )}</span> — ${job.leaves.length} committed decisions`;

    const toggle = document.querySelector(".demo-toggle");
    if (toggle) toggle.style.display = "none";

    specimen(job, 0, vals ? vals[0] : null, threshold, e.check);
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

  function liveBanner(e) {
    const job = e.job;
    let msg = `Live · BSC testnet · ${job.leaves.length} leaves · verdict ${VERDICT[job.verdict]}`;
    if (REASONS[job.reason]) msg += ` · ${REASONS[job.reason].split(" — ")[1]}`;
    if (e.check) {
      msg += e.check.ok
        ? ` · ${e.check.matched}/${e.check.total} reveals verified in-browser`
        : ` · ${e.check.mismatches.length} reveal mismatch(es) detected`;
    }
    banner(msg, true);
  }

  function renderAll(e) {
    renderReport(e);
    renderVerdict(e);
    renderReplay(e);
    renderJobBar(e.idx);
    liveBanner(e);
    const known = Object.values(S.cache);
    if (known.length) renderLedger(known, e.idx);
  }

  async function selectJob(idx) {
    if (idx === S.active && S.cache[idx]) return;
    S.active = idx;
    renderJobBar(idx);
    banner(`Loading ${CFG.jobs[idx].label || "job"} from BSC testnet…`, false);
    try {
      const e = await loadJobWithEvidence(idx);
      if (S.active === idx) renderAll(e);
    } catch (err) {
      console.error(err);
      banner("Chain read failed — showing demonstration data. " + (err.shortMessage || err.message), false);
    }
  }

  // ---------------------------------------------------------------
  // Boot
  // ---------------------------------------------------------------

  async function boot() {
    if (!configured()) {
      banner("Demonstration data — no contracts configured in config.js", false);
      return;
    }
    injectStyles();
    banner("Connecting to BSC testnet…", false);
    try {
      const e = await loadJobWithEvidence(0);
      S.active = 0;
      renderAll(e);
      window.ATTESTABLE = {
        entry: e,
        cache: S.cache,
        loadJob,
        reverify,
        normalize,
        settleVerdict,
        selectJob,
      };

      // Fill the settlement ledger with every configured job in the
      // background, most recent first.
      for (let i = 1; i < CFG.jobs.length; i++) {
        loadJobWithEvidence(i)
          .then(() => renderLedger(Object.values(S.cache), S.active))
          .catch((err) => console.warn("job " + i + " failed:", err));
      }
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
