// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";
import {ProofPolicy} from "../contracts/ProofPolicy.sol";
import {CriteriaEngine as CE} from "../contracts/CriteriaEngine.sol";

/// @notice Drives two complete jobs on-chain and prints their verdicts.
///
///         forge script script/Demo.s.sol --rpc-url bsc_testnet --broadcast
///
///         Job A — an agent that did the work.        Expect APPROVE.
///         Job B — an agent that let the position     Expect REJECT.
///                 burn for six hours.
///
/// @dev This is the submission artifact. Job B is a client being refunded
///      automatically, with no dispute raised and nobody watching — the case
///      OptimisticPolicy would have silently paid out.
///
///      Requires ADDR_REGISTRY and ADDR_POLICY in .env (written by Deploy.s.sol).
contract Demo is Script {
    int256 constant WAD = 1e18;
    uint32 constant SAMPLES = 24; // hourly for a day
    uint64 constant STEP = 3600;

    EvidenceRegistry registry;
    ProofPolicy policy;
    uint64 t0;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address agent = vm.addr(pk);
        registry = EvidenceRegistry(vm.envAddress("ADDR_REGISTRY"));
        policy = ProofPolicy(vm.envAddress("ADDR_POLICY"));

        // Anchor observations in the past so every leaf satisfies the
        // registry's "never in the future" rule regardless of mining delay.
        t0 = uint64(block.timestamp) - (SAMPLES + 2) * STEP;

        uint256 jobA = uint256(keccak256(abi.encode("attestable-demo-A", block.timestamp)));
        uint256 jobB = uint256(keccak256(abi.encode("attestable-demo-B", block.timestamp)));

        console.log("agent     ", agent);
        console.log("job A     ", jobA);
        console.log("job B     ", jobB);
        console.log("");

        vm.startBroadcast(pk);
        _bind(jobA, agent);
        _bind(jobB, agent);
        (EvidenceRegistry.Leaf[] memory la, ProofPolicy.Reveal[] memory ra) = _run(jobA, false);
        (EvidenceRegistry.Leaf[] memory lb, ProofPolicy.Reveal[] memory rb) = _run(jobB, true);
        policy.onSubmitted(jobA, keccak256("A"), "");
        policy.onSubmitted(jobB, keccak256("B"), "");
        vm.stopBroadcast();

        _report("JOB A  honest agent", jobA, la, ra);
        _report("JOB B  breaching agent", jobB, lb, rb);

        _writeBundle(jobA, ra);
        _writeBundle(jobB, rb);

        console.log("");
        console.log("Note: verdicts harden after the proof window elapses.");
        console.log("Re-run script/Report.s.sol after that to see the final state.");
    }

    function _bind(uint256 jobId, address agent) private {
        CE.Criterion[] memory cs = new CE.Criterion[](1);
        cs[0] = CE.Criterion({
            metric: CE.HEALTH_FACTOR,
            op: CE.Op.GTE,
            threshold: 16 * WAD / 10, // 1.60
            minSamplePct: 9500, // 95% of samples
            minSamples: 20,
            maxGapSeconds: uint32(2 * STEP)
        });
        policy.bindTerms(jobId, agent, cs);
    }

    /// @param breach when true, health factor sits below 1.60 for six hours
    function _run(uint256 jobId, bool breach)
        private
        returns (EvidenceRegistry.Leaf[] memory leaves, ProofPolicy.Reveal[] memory reveals)
    {
        leaves = new EvidenceRegistry.Leaf[](SAMPLES);
        reveals = new ProofPolicy.Reveal[](SAMPLES);

        for (uint256 i; i < SAMPLES; ++i) {
            uint64 at = t0 + uint64(i) * STEP;
            int256 hf = (breach && i >= 10 && i < 16) ? 142 * WAD / 100 : 19 * WAD / 10;

            leaves[i] = EvidenceRegistry.Leaf({
                inputsHash: policy.observationHash(CE.HEALTH_FACTOR, hf, at),
                attestationId: keccak256(abi.encode("apro-feed", jobId, i)),
                policyVersion: keccak256("sentinel-v0.1"),
                decisionHash: keccak256(abi.encode(hf >= 16 * WAD / 10 ? "hold" : "deleverage", i)),
                actionTxHash: bytes32(0),
                observedAt: at
            });
            reveals[i] = ProofPolicy.Reveal({metric: CE.HEALTH_FACTOR, value: hf});
        }

        // One transaction instead of 24 — amortises the 21k base cost.
        registry.commitBatch(jobId, leaves);
        registry.seal(jobId, "greenfield://attestable/demo");
    }

    function _report(
        string memory label,
        uint256 jobId,
        EvidenceRegistry.Leaf[] memory l,
        ProofPolicy.Reveal[] memory r
    ) private view {
        (uint8 v, bytes32 reason) = policy.check(jobId, abi.encode(l, r));
        console.log("");
        console.log(label);
        console.log("  leaves   ", registry.recordOf(jobId).leafCount);
        console.log("  sealed   ", registry.recordOf(jobId).isSealed);
        console.log("  verdict  ", _verdict(v));
        console.log("  reason   ", vm.toString(reason));
    }

    /// @dev Revealed values live off-chain by design -- only their commitment is
    ///      on-chain. The Report Card fetches this bundle and re-derives every
    ///      hash in the visitor's browser, so publishing it proves nothing on
    ///      trust: a doctored bundle simply fails to match and is flagged.
    ///      In production this is the Greenfield blob named in RecordSealed.
    function _writeBundle(uint256 jobId, ProofPolicy.Reveal[] memory r) private {
        string memory body = "";
        for (uint256 i; i < r.length; ++i) {
            body = string.concat(
                body,
                i == 0 ? "" : ",",
                '\n    {"metric": "health_factor", "valueWad": "',
                vm.toString(r[i].value),
                '"}'
            );
        }
        string memory json = string.concat(
            '{\n  "jobId": "', vm.toString(jobId), '",\n  "reveals": [', body, "\n  ]\n}\n"
        );
        string memory path =
            string.concat("frontend/data/bundle-", vm.toString(jobId), ".json");
        vm.writeFile(path, json);
        console.log("  bundle   ", path);
    }

    function _verdict(uint8 v) private pure returns (string memory) {
        if (v == 1) return "APPROVE";
        if (v == 2) return "REJECT";
        return "PENDING (proof window still open)";
    }
}
