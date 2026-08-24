// Attestable — deployment configuration.
//
// LIVE on BSC Testnet (chain 97) since block 126849687.
// Every reveal bundle in data/ is re-verified in the visitor's browser against
// the on-chain commitments — a doctored bundle simply fails to match.

window.ATTESTABLE_CONFIG = {
  chainId: 97,
  // publicnode is CORS-friendly and does not throttle log scans
  // (the default data-seed RPC rate-limits eth_getLogs).
  rpcUrl: "https://bsc-testnet-rpc.publicnode.com",
  explorer: "https://testnet.bscscan.com",

  evidenceRegistry: "0x53fAEaF1ae895642F7FE4D359397C03D7b47365f",
  proofPolicy: "0x3e96442099A71643cfcd8d48Fa210736eB7fBb9C",

  // Block to start scanning LeafCommitted logs from (registry deploy block).
  fromBlock: 126849687,

  // First entry is loaded on open — the breach is the story.
  jobs: [
    { id: "59430671906202402067922224808275700359331806492423199610034053151807493666755", label: "Job B — breaching agent (latest run)" },
    { id: "82612149980820816226403819016928287009974769078110269763544694326257204078087", label: "Job A — honest agent (latest run)" },
    { id: "84884196985564603400985992270697390662143760095888777543147761349923548687324", label: "Job A — honest agent (hardened verdict)" },
    { id: "96348787739455618605335015514036932976552574567509832702297305168469743833968", label: "Job B — breaching agent (hardened verdict)" },
  ],
};
