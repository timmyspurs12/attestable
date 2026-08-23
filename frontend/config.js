// Attestable — deployment configuration.
//
// Fill this in after running script/Deploy.s.sol. Until then the UI runs on
// demonstration data and says so plainly on screen.
//
// Values come straight from config/deployed.97.json.

window.ATTESTABLE_CONFIG = {
  // BSC Testnet
  chainId: 97,
  rpcUrl: "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
  explorer: "https://testnet.bscscan.com",

  // Deployed contracts — leave blank to stay on demonstration data
  evidenceRegistry: "",
  proofPolicy: "",

  // Block to start scanning LeafCommitted logs from. Set this to the
  // deployment block; scanning from 0 on a public RPC will time out.
  fromBlock: 0,

  // Jobs to show. First entry is loaded on open.
  // Demo.s.sol prints these — paste them here.
  jobs: [
    // { id: "0x...", label: "Job B — breaching agent" },
  ],
};
