// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";

contract EvidenceRegistryTest is Test {
    EvidenceRegistry reg;

    address agent = address(0xA1);
    address impostor = address(0xB2);

    uint256 constant JOB = 11842;
    uint64 constant T0 = 1_700_000_000;

    function setUp() public {
        reg = new EvidenceRegistry();
        vm.warp(T0 + 1_000_000);
    }

    // ---------------- helpers ----------------

    function _leaf(uint64 at, uint256 salt) internal pure returns (EvidenceRegistry.Leaf memory) {
        return EvidenceRegistry.Leaf({
            inputsHash: keccak256(abi.encode("inputs", salt)),
            attestationId: keccak256(abi.encode("apro", salt)),
            policyVersion: keccak256("model-v1"),
            decisionHash: keccak256(abi.encode("decision", salt)),
            actionTxHash: keccak256(abi.encode("tx", salt)),
            observedAt: at
        });
    }

    function _commitSeries(uint256 n, uint64 step) internal returns (EvidenceRegistry.Leaf[] memory ls) {
        ls = new EvidenceRegistry.Leaf[](n);
        vm.startPrank(agent);
        for (uint256 i; i < n; ++i) {
            ls[i] = _leaf(T0 + uint64(i) * step, i);
            reg.commit(JOB, ls[i]);
        }
        vm.stopPrank();
    }

    // ---------------- claim / authorisation ----------------

    function test_FirstCommitterClaimsRecord() public {
        vm.prank(agent);
        reg.commit(JOB, _leaf(T0, 0));

        EvidenceRegistry.Record memory r = reg.recordOf(JOB);
        assertEq(r.agent, agent);
        assertEq(r.leafCount, 1);
        assertEq(r.firstObservedAt, T0);
        assertEq(r.lastObservedAt, T0);
        assertFalse(r.isSealed);
    }

    function test_RevertWhen_ImpostorCommitsToClaimedRecord() public {
        vm.prank(agent);
        reg.commit(JOB, _leaf(T0, 0));

        vm.prank(impostor);
        vm.expectRevert(
            abi.encodeWithSelector(EvidenceRegistry.NotRecordAgent.selector, JOB, agent, impostor)
        );
        reg.commit(JOB, _leaf(T0 + 1, 1));
    }

    function test_DistinctJobsAreIndependent() public {
        vm.prank(agent);
        reg.commit(JOB, _leaf(T0, 0));
        vm.prank(impostor);
        reg.commit(JOB + 1, _leaf(T0, 0));

        assertEq(reg.recordOf(JOB).agent, agent);
        assertEq(reg.recordOf(JOB + 1).agent, impostor);
        // Same leaf, different job, same head — jobId is not folded in, the
        // record is keyed by it. Documented, not accidental.
        assertEq(reg.chainHeadOf(JOB), reg.chainHeadOf(JOB + 1));
    }

    // ---------------- pre-commitment guarantees ----------------

    function test_RevertWhen_ObservationIsInFuture() public {
        uint64 future = uint64(block.timestamp) + 1;
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                EvidenceRegistry.FutureObservation.selector, future, uint64(block.timestamp)
            )
        );
        reg.commit(JOB, _leaf(future, 0));
    }

    function test_RevertWhen_ObservationGoesBackwards() public {
        vm.startPrank(agent);
        reg.commit(JOB, _leaf(T0 + 100, 0));
        vm.expectRevert(
            abi.encodeWithSelector(EvidenceRegistry.NonMonotonicObservation.selector, T0 + 100, T0 + 99)
        );
        reg.commit(JOB, _leaf(T0 + 99, 1));
        vm.stopPrank();
    }

    function test_EqualTimestampsAllowed() public {
        vm.startPrank(agent);
        reg.commit(JOB, _leaf(T0, 0));
        reg.commit(JOB, _leaf(T0, 1)); // same second, two decisions — legal
        vm.stopPrank();
        assertEq(reg.recordOf(JOB).leafCount, 2);
    }

    // ---------------- chain integrity ----------------

    function test_VerifyChainAcceptsExactReplay() public {
        EvidenceRegistry.Leaf[] memory ls = _commitSeries(12, 3600);
        assertTrue(reg.verifyChain(JOB, ls));
    }

    function test_VerifyChainRejectsMutatedLeaf() public {
        EvidenceRegistry.Leaf[] memory ls = _commitSeries(12, 3600);
        ls[5].decisionHash = keccak256("i actually said something else");
        assertFalse(reg.verifyChain(JOB, ls));
    }

    function test_VerifyChainRejectsReordering() public {
        EvidenceRegistry.Leaf[] memory ls = _commitSeries(6, 3600);
        (ls[2], ls[3]) = (ls[3], ls[2]);
        assertFalse(reg.verifyChain(JOB, ls));
    }

    function test_VerifyChainRejectsDroppedLeaf() public {
        EvidenceRegistry.Leaf[] memory ls = _commitSeries(6, 3600);
        EvidenceRegistry.Leaf[] memory short = new EvidenceRegistry.Leaf[](5);
        for (uint256 i; i < 5; ++i) short[i] = ls[i];
        assertFalse(reg.verifyChain(JOB, short));
    }

    function test_VerifyChainRejectsInsertedLeaf() public {
        EvidenceRegistry.Leaf[] memory ls = _commitSeries(4, 3600);
        EvidenceRegistry.Leaf[] memory padded = new EvidenceRegistry.Leaf[](5);
        for (uint256 i; i < 4; ++i) padded[i] = ls[i];
        padded[4] = _leaf(T0 + 4 * 3600, 99);
        assertFalse(reg.verifyChain(JOB, padded));
    }

    function test_BatchAndSingleProduceIdenticalChain() public {
        EvidenceRegistry.Leaf[] memory ls = new EvidenceRegistry.Leaf[](5);
        for (uint256 i; i < 5; ++i) ls[i] = _leaf(T0 + uint64(i) * 60, i);

        vm.startPrank(agent);
        for (uint256 i; i < 5; ++i) reg.commit(JOB, ls[i]);
        reg.commitBatch(JOB + 1, ls);
        vm.stopPrank();

        assertEq(reg.chainHeadOf(JOB), reg.chainHeadOf(JOB + 1));
        assertEq(reg.recordOf(JOB).leafCount, reg.recordOf(JOB + 1).leafCount);
    }

    function test_RevertWhen_BatchIsEmpty() public {
        vm.prank(agent);
        vm.expectRevert(EvidenceRegistry.EmptyBatch.selector);
        reg.commitBatch(JOB, new EvidenceRegistry.Leaf[](0));
    }

    // ---------------- no-op semantics ----------------

    function test_NoOpDecisionIsRecordable() public {
        EvidenceRegistry.Leaf memory l = _leaf(T0, 0);
        l.actionTxHash = reg.NO_OP();

        vm.prank(agent);
        reg.commit(JOB, l);

        // Deliberate inaction is provable — an agent that looked and correctly
        // did nothing must not be indistinguishable from one that was absent.
        assertEq(reg.recordOf(JOB).leafCount, 1);
    }

    // ---------------- sealing ----------------

    function test_SealFreezesRecord() public {
        _commitSeries(3, 60);

        vm.prank(agent);
        reg.seal(JOB, "greenfield://bucket/job-11842.json");

        EvidenceRegistry.Record memory r = reg.recordOf(JOB);
        assertTrue(r.isSealed);
        assertEq(r.sealedAt, uint64(block.timestamp));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.RecordIsSealed.selector, JOB));
        reg.commit(JOB, _leaf(T0 + 999, 42));
    }

    function test_RevertWhen_SealingTwice() public {
        _commitSeries(2, 60);
        vm.startPrank(agent);
        reg.seal(JOB, "uri");
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.RecordIsSealed.selector, JOB));
        reg.seal(JOB, "uri");
        vm.stopPrank();
    }

    function test_RevertWhen_SealingUnknownRecord() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.RecordNotFound.selector, JOB));
        reg.seal(JOB, "uri");
    }

    function test_RevertWhen_ImpostorSeals() public {
        _commitSeries(2, 60);
        vm.prank(impostor);
        vm.expectRevert(
            abi.encodeWithSelector(EvidenceRegistry.NotRecordAgent.selector, JOB, agent, impostor)
        );
        reg.seal(JOB, "uri");
    }

    function test_ChainHeadSurvivesSeal() public {
        EvidenceRegistry.Leaf[] memory ls = _commitSeries(7, 900);
        bytes32 before = reg.chainHeadOf(JOB);
        vm.prank(agent);
        reg.seal(JOB, "uri");
        assertEq(reg.chainHeadOf(JOB), before);
        assertTrue(reg.verifyChain(JOB, ls));
    }

    // ---------------- cadence ----------------

    function test_MaxGapDetectsAbsence() public view {
        EvidenceRegistry.Leaf[] memory ls = new EvidenceRegistry.Leaf[](5);
        ls[0] = _leaf(T0, 0);
        ls[1] = _leaf(T0 + 3600, 1);
        ls[2] = _leaf(T0 + 7200, 2);
        ls[3] = _leaf(T0 + 90000, 3); // agent asleep for ~23 hours
        ls[4] = _leaf(T0 + 93600, 4);

        assertEq(reg.maxGap(ls), 82800);
    }

    function test_MaxGapZeroForTrivialInput() public view {
        assertEq(reg.maxGap(new EvidenceRegistry.Leaf[](0)), 0);
        assertEq(reg.maxGap(new EvidenceRegistry.Leaf[](1)), 0);
    }

    // ---------------- events ----------------

    function test_EmitsRecordOpenedOnce() public {
        vm.startPrank(agent);
        vm.expectEmit(true, true, false, true);
        emit EvidenceRegistry.RecordOpened(JOB, agent);
        reg.commit(JOB, _leaf(T0, 0));
        reg.commit(JOB, _leaf(T0 + 1, 1)); // must not re-open
        vm.stopPrank();
        assertEq(reg.recordOf(JOB).leafCount, 2);
    }

    function test_EmitsLeafCommittedWithRunningHead() public {
        EvidenceRegistry.Leaf memory l = _leaf(T0, 0);
        bytes32 expected = reg.fold(reg.GENESIS(), l);

        vm.prank(agent);
        vm.expectEmit(true, true, false, true);
        emit EvidenceRegistry.LeafCommitted(JOB, 0, expected, l);
        reg.commit(JOB, l);

        assertEq(reg.chainHeadOf(JOB), expected);
    }

    // ---------------- fuzz ----------------

    function testFuzz_ChainAlwaysReplays(uint8 nRaw, uint16 stepRaw) public {
        uint256 n = uint256(nRaw) % 40 + 1;
        uint64 step = uint64(stepRaw) % 3600 + 1;

        EvidenceRegistry.Leaf[] memory ls = new EvidenceRegistry.Leaf[](n);
        vm.startPrank(agent);
        for (uint256 i; i < n; ++i) {
            ls[i] = _leaf(T0 + uint64(i) * step, i);
            reg.commit(JOB, ls[i]);
        }
        vm.stopPrank();

        assertTrue(reg.verifyChain(JOB, ls));
        assertEq(reg.recordOf(JOB).leafCount, uint32(n));
    }

    function testFuzz_AnyMutationBreaksChain(uint8 nRaw, uint8 idxRaw, bytes32 tamper) public {
        uint256 n = uint256(nRaw) % 20 + 2;
        uint256 idx = uint256(idxRaw) % n;

        EvidenceRegistry.Leaf[] memory ls = _commitSeriesN(n);
        vm.assume(tamper != ls[idx].decisionHash);
        ls[idx].decisionHash = tamper;

        assertFalse(reg.verifyChain(JOB, ls));
    }

    function _commitSeriesN(uint256 n) internal returns (EvidenceRegistry.Leaf[] memory ls) {
        ls = new EvidenceRegistry.Leaf[](n);
        vm.startPrank(agent);
        for (uint256 i; i < n; ++i) {
            ls[i] = _leaf(T0 + uint64(i) * 60, i);
            reg.commit(JOB, ls[i]);
        }
        vm.stopPrank();
    }
}
