// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";
import {ProofPolicy} from "../contracts/ProofPolicy.sol";
import {CriteriaEngine as CE} from "../contracts/CriteriaEngine.sol";

/// @notice Read-only verdict report for a job, rebuilt from chain state.
///
///         JOB_ID=<id> forge script script/Report.s.sol --rpc-url bsc_testnet
///
/// @dev Reconstructs the evidence from `LeafCommitted` logs rather than trusting
///      anything handed to it — the same path an independent auditor or the
///      Report Card front end takes. Nothing here is privileged; anyone can run
///      it against any job and get the same answer.
contract Report is Script {
    function run() external view {
        EvidenceRegistry registry = EvidenceRegistry(vm.envAddress("ADDR_REGISTRY"));
        ProofPolicy policy = ProofPolicy(vm.envAddress("ADDR_POLICY"));
        uint256 jobId = vm.envUint("JOB_ID");

        EvidenceRegistry.Record memory rec = registry.recordOf(jobId);
        (address provider, bytes32 criteriaHash, uint64 submittedAt, bool bound) = policy.termsOf(jobId);

        console.log("job          ", jobId);
        console.log("");
        console.log("-- terms --");
        console.log("  bound      ", bound);
        console.log("  provider   ", provider);
        console.log("  criteria   ", vm.toString(criteriaHash));
        console.log("  submittedAt", submittedAt);
        console.log("");
        console.log("-- evidence --");
        console.log("  agent      ", rec.agent);
        console.log("  leaves     ", rec.leafCount);
        console.log("  sealed     ", rec.isSealed);
        console.log("  chainHead  ", vm.toString(rec.chainHead));
        console.log("  first obs  ", rec.firstObservedAt);
        console.log("  last obs   ", rec.lastObservedAt);

        if (bound) {
            CE.Criterion[] memory cs = policy.criteriaOf(jobId);
            console.log("");
            console.log("-- criteria --");
            for (uint256 i; i < cs.length; ++i) {
                console.log("  metric     ", vm.toString(cs[i].metric));
                console.log("    threshold", vm.toString(cs[i].threshold));
                console.log("    minPct   ", cs[i].minSamplePct);
                console.log("    minSample", cs[i].minSamples);
                console.log("    maxGap   ", cs[i].maxGapSeconds);
            }
        }

        console.log("");
        console.log("-- verdict (state-derived, empty evidence) --");
        (uint8 v, bytes32 reason) = policy.check(jobId, "");
        console.log("  ", _verdict(v));
        console.log("   reason    ", vm.toString(reason));
        console.log("");
        console.log("A full APPROVE additionally requires the complete leaf set");
        console.log("as calldata. Replay it from LeafCommitted logs.");
    }

    function _verdict(uint8 v) private pure returns (string memory) {
        if (v == 1) return "APPROVE";
        if (v == 2) return "REJECT";
        return "PENDING";
    }
}
