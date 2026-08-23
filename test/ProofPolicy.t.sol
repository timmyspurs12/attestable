// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProofPolicy} from "../contracts/ProofPolicy.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";
import {CriteriaEngine as CE} from "../contracts/CriteriaEngine.sol";

contract ProofPolicyTest is Test {
    EvidenceRegistry reg;
    ProofPolicy pol;

    address router = makeAddr("router");
    address agent = address(0xA1);
    address impostor = address(0xB2);

    uint256 constant JOB = 11842;
    uint64 constant T0 = 1_700_000_000;
    uint64 constant WINDOW = 1 hours;
    int256 constant WAD = 1e18;

    uint8 constant PENDING = 0;
    uint8 constant APPROVE = 1;
    uint8 constant REJECT = 2;

    function setUp() public {
        reg = new EvidenceRegistry();
        pol = new ProofPolicy(router, reg, WINDOW);
        vm.warp(T0 + 1_000_000);
    }

    // ---------------- helpers ----------------

    function _hfCriterion(uint32 minSamples, uint32 maxGap)
        internal
        pure
        returns (CE.Criterion[] memory cs)
    {
        cs = new CE.Criterion[](1);
        cs[0] = CE.Criterion({
            metric: CE.HEALTH_FACTOR,
            op: CE.Op.GTE,
            threshold: 16 * WAD / 10,
            minSamplePct: 9500,
            minSamples: minSamples,
            maxGapSeconds: maxGap
        });
    }

    /// Agent commits `n` observations of `value`, then seals.
    function _work(uint256 n, int256 value, uint64 step, bool doSeal)
        internal
        returns (EvidenceRegistry.Leaf[] memory leaves, ProofPolicy.Reveal[] memory reveals)
    {
        leaves = new EvidenceRegistry.Leaf[](n);
        reveals = new ProofPolicy.Reveal[](n);

        vm.startPrank(agent);
        for (uint256 i; i < n; ++i) {
            uint64 at = T0 + uint64(i) * step;
            leaves[i] = EvidenceRegistry.Leaf({
                inputsHash: pol.observationHash(CE.HEALTH_FACTOR, value, at),
                attestationId: keccak256(abi.encode("apro", i)),
                policyVersion: keccak256("model-v1"),
                decisionHash: keccak256(abi.encode("hold", i)),
                actionTxHash: keccak256(abi.encode("tx", i)),
                observedAt: at
            });
            reveals[i] = ProofPolicy.Reveal({metric: CE.HEALTH_FACTOR, value: value});
            reg.commit(JOB, leaves[i]);
        }
        if (doSeal) reg.seal(JOB, "greenfield://job");
        vm.stopPrank();
    }

    function _submit() internal {
        vm.prank(router);
        pol.onSubmitted(JOB, keccak256("deliverable"), "");
    }

    function _harden() internal {
        vm.warp(block.timestamp + WINDOW + 1);
    }

    function _ev(EvidenceRegistry.Leaf[] memory l, ProofPolicy.Reveal[] memory r)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(l, r);
    }

    // =========================================================
    // THE TWO HEADLINE CASES
    // =========================================================

    function test_HonestAgentIsApproved() public {
        pol.bindTerms(JOB, agent, _hfCriterion(100, 3600));
        (EvidenceRegistry.Leaf[] memory l, ProofPolicy.Reveal[] memory r) =
            _work(168, 19 * WAD / 10, 3600, true);
        _submit();

        (uint8 v, bytes32 reason) = pol.check(JOB, _ev(l, r));
        assertEq(v, APPROVE);
        assertEq(reason, pol.REASON_APPROVED());
    }

    function test_BreachingAgentIsRejectedAndClientRefunded() public {
        // THE artifact. Health factor drops below 1.6 for 12 of 168 hours,
        // taking the met rate to 92.8% against a 95% requirement. No dispute
        // is raised, nobody complains, nobody is watching. It rejects anyway.
        pol.bindTerms(JOB, agent, _hfCriterion(100, 3600));

        uint256 n = 168;
        EvidenceRegistry.Leaf[] memory l = new EvidenceRegistry.Leaf[](n);
        ProofPolicy.Reveal[] memory r = new ProofPolicy.Reveal[](n);

        vm.startPrank(agent);
        for (uint256 i; i < n; ++i) {
            uint64 at = T0 + uint64(i) * 3600;
            int256 hf = (i >= 60 && i < 72) ? 142 * WAD / 100 : 19 * WAD / 10;
            l[i] = EvidenceRegistry.Leaf({
                inputsHash: pol.observationHash(CE.HEALTH_FACTOR, hf, at),
                attestationId: keccak256(abi.encode("apro", i)),
                policyVersion: keccak256("model-v1"),
                decisionHash: keccak256(abi.encode("d", i)),
                actionTxHash: bytes32(0), // agent did nothing while it burned
                observedAt: at
            });
            r[i] = ProofPolicy.Reveal({metric: CE.HEALTH_FACTOR, value: hf});
            reg.commit(JOB, l[i]);
        }
        reg.seal(JOB, "greenfield://job");
        vm.stopPrank();

        _submit();

        (uint8 v, bytes32 reason) = pol.check(JOB, _ev(l, r));
        assertEq(v, REJECT);
        assertEq(reason, pol.REASON_CRITERIA());
    }

    // =========================================================
    // GRIEFING — the attack the gate ordering exists to stop
    // =========================================================

    function test_GarbageEvidenceCannotRejectAnHonestAgent() public {
        pol.bindTerms(JOB, agent, _hfCriterion(100, 3600));
        (EvidenceRegistry.Leaf[] memory l, ProofPolicy.Reveal[] memory r) =
            _work(168, 19 * WAD / 10, 3600, true);
        _submit();
        _harden();

        // A stranger tries to rob the agent by settling with fabricated evidence.
        EvidenceRegistry.Leaf[] memory fake = new EvidenceRegistry.Leaf[](168);
        ProofPolicy.Reveal[] memory fakeR = new ProofPolicy.Reveal[](168);
        for (uint256 i; i < 168; ++i) {
            uint64 at = T0 + uint64(i) * 3600;
            int256 bad = WAD; // 1.0, far below threshold
            fake[i] = EvidenceRegistry.Leaf({
                inputsHash: pol.observationHash(CE.HEALTH_FACTOR, bad, at),
                attestationId: keccak256("x"),
                policyVersion: keccak256("x"),
                decisionHash: keccak256("x"),
                actionTxHash: bytes32(0),
                observedAt: at
            });
            fakeR[i] = ProofPolicy.Reveal({metric: CE.HEALTH_FACTOR, value: bad});
        }

        vm.prank(impostor);
        (uint8 v,) = pol.check(JOB, _ev(fake, fakeR));
        assertEq(v, PENDING); // gate 1 fails -> pending, NOT reject

        // The real evidence still approves. The griefer only delayed things.
        (uint8 v2,) = pol.check(JOB, _ev(l, r));
        assertEq(v2, APPROVE);
    }

    function test_TruncatedEvidenceCannotForceReject() public {
        pol.bindTerms(JOB, agent, _hfCriterion(10, 0));
        (EvidenceRegistry.Leaf[] memory l, ProofPolicy.Reveal[] memory r) =
            _work(50, 19 * WAD / 10, 3600, true);
        _submit();
        _harden();

        // Hide the good samples: supply only the first 12 leaves.
        EvidenceRegistry.Leaf[] memory cut = new EvidenceRegistry.Leaf[](12);
        ProofPolicy.Reveal[] memory cutR = new ProofPolicy.Reveal[](12);
        for (uint256 i; i < 12; ++i) {
            cut[i] = l[i];
            cutR[i] = r[i];
        }

        (uint8 v,) = pol.check(JOB, _ev(cut, cutR));
        assertEq(v, PENDING);

        (uint8 v2,) = pol.check(JOB, _ev(l, r));
        assertEq(v2, APPROVE);
    }

    function test_MalformedCalldataReturnsPendingNotRevert() public {
        pol.bindTerms(JOB, agent, _hfCriterion(10, 0));
        _work(20, 2 * WAD, 3600, true);
        _submit();
        _harden();

        (uint8 v,) = pol.check(JOB, hex"deadbeef");
        assertEq(v, PENDING);

        (uint8 v2,) = pol.check(JOB, "");
        assertEq(v2, PENDING);
    }

    // =========================================================
    // LYING ABOUT VALUES
    // =========================================================

    function test_AgentCannotRevealDifferentValueThanCommitted() public {
        pol.bindTerms(JOB, agent, _hfCriterion(10, 0));
        // Commits a failing 1.42 ...
        (EvidenceRegistry.Leaf[] memory l,) = _work(20, 142 * WAD / 100, 3600, true);
        _submit();
        _harden();

        // ... then tries to reveal a passing 1.9 at settlement.
        ProofPolicy.Reveal[] memory lie = new ProofPolicy.Reveal[](20);
        for (uint256 i; i < 20; ++i) {
            lie[i] = ProofPolicy.Reveal({metric: CE.HEALTH_FACTOR, value: 19 * WAD / 10});
        }

        (uint8 v,) = pol.check(JOB, _ev(l, lie));
        assertEq(v, PENDING); // gate 2: reveal does not rehash to the commitment
    }

    function test_AgentCannotSwapMetricLabel() public {
        pol.bindTerms(JOB, agent, _hfCriterion(10, 0));
        (EvidenceRegistry.Leaf[] memory l, ProofPolicy.Reveal[] memory r) =
            _work(20, 19 * WAD / 10, 3600, true);
        _submit();
        _harden();

        r[5].metric = CE.SLIPPAGE_BPS; // relabel one sample
        (uint8 v,) = pol.check(JOB, _ev(l, r));
        assertEq(v, PENDING);
    }

    // =========================================================
    // STATE-DERIVED REJECTIONS
    // =========================================================

    function test_UnsealedEvidenceRejectsAfterWindow() public {
        pol.bindTerms(JOB, agent, _hfCriterion(10, 0));
        (EvidenceRegistry.Leaf[] memory l, ProofPolicy.Reveal[] memory r) =
            _work(20, 2 * WAD, 3600, false); // never sealed
        _submit();

        (uint8 before,) = pol.check(JOB, _ev(l, r));
        assertEq(before, PENDING); // grace period

        _harden();
        (uint8 v, bytes32 reason) = pol.check(JOB, _ev(l, r));
        assertEq(v, REJECT);
        assertEq(reason, pol.REASON_NO_EVIDENCE());
    }

    function test_SilentAgentRejects() public {
        // The headline failure OptimisticPolicy pays for: an agent that did
        // absolutely nothing. No leaves, no seal, no complaint from anyone.
        pol.bindTerms(JOB, agent, _hfCriterion(10, 0));
        _submit();
        _harden();

        (uint8 v, bytes32 reason) = pol.check(JOB, "");
        assertEq(v, REJECT);
        assertEq(reason, pol.REASON_WRONG_AGENT()); // no record at all
    }

    function test_WrongAgentRejects() public {
        pol.bindTerms(JOB, agent, _hfCriterion(10, 0));

        // Front-runner claims the jobId in the registry.
        vm.startPrank(impostor);
        EvidenceRegistry.Leaf memory leaf = EvidenceRegistry.Leaf({
            inputsHash: pol.observationHash(CE.HEALTH_FACTOR, 2 * WAD, T0),
            attestationId: keccak256("a"),
            policyVersion: keccak256("m"),
            decisionHash: keccak256("d"),
            actionTxHash: bytes32(0),
            observedAt: T0
        });
        reg.commit(JOB, leaf);
        reg.seal(JOB, "uri");
        vm.stopPrank();

        _submit();
        _harden();

        (uint8 v, bytes32 reason) = pol.check(JOB, "");
        assertEq(v, REJECT);
        assertEq(reason, pol.REASON_WRONG_AGENT());
    }

    function test_SparseEvidenceRejectsFromStateAlone() public {
        pol.bindTerms(JOB, agent, _hfCriterion(100, 0));
        (EvidenceRegistry.Leaf[] memory l, ProofPolicy.Reveal[] memory r) =
            _work(3, 2 * WAD, 3600, true); // 3 leaves, needs 100
        _submit();
        _harden();

        (uint8 v, bytes32 reason) = pol.check(JOB, _ev(l, r));
        assertEq(v, REJECT);
        assertEq(reason, pol.REASON_TOO_FEW());
    }

    function test_CadenceBreachRejects() public {
        pol.bindTerms(JOB, agent, _hfCriterion(5, 3600));

        uint256 n = 6;
        EvidenceRegistry.Leaf[] memory l = new EvidenceRegistry.Leaf[](n);
        ProofPolicy.Reveal[] memory r = new ProofPolicy.Reveal[](n);
        uint64[6] memory times =
            [T0, T0 + 3600, T0 + 7200, T0 + 90_000, T0 + 93_600, T0 + 97_200];

        vm.startPrank(agent);
        for (uint256 i; i < n; ++i) {
            int256 hf = 2 * WAD; // every value is fine
            l[i] = EvidenceRegistry.Leaf({
                inputsHash: pol.observationHash(CE.HEALTH_FACTOR, hf, times[i]),
                attestationId: keccak256("a"),
                policyVersion: keccak256("m"),
                decisionHash: keccak256(abi.encode(i)),
                actionTxHash: bytes32(0),
                observedAt: times[i]
            });
            r[i] = ProofPolicy.Reveal({metric: CE.HEALTH_FACTOR, value: hf});
            reg.commit(JOB, l[i]);
        }
        reg.seal(JOB, "uri");
        vm.stopPrank();

        _submit();
        _harden();

        // Every observation cleared the threshold, but it went dark for 23h.
        (uint8 v, bytes32 reason) = pol.check(JOB, _ev(l, r));
        assertEq(v, REJECT);
        assertEq(reason, pol.REASON_CRITERIA());
    }

    // =========================================================
    // IPOLICY INVARIANTS
    // =========================================================

    function test_OnSubmittedIsRouterOnly() public {
        vm.prank(impostor);
        vm.expectRevert(ProofPolicy.NotRouter.selector);
        pol.onSubmitted(JOB, bytes32(0), "");
    }

    function test_OnSubmittedIsOneShot() public {
        _submit();
        vm.prank(router);
        vm.expectRevert(ProofPolicy.AlreadySubmitted.selector);
        pol.onSubmitted(JOB, bytes32(0), "");
    }

    function test_UnknownJobIsPendingNotRevert() public view {
        (uint8 v, bytes32 reason) = pol.check(9999, "");
        assertEq(v, PENDING);
        assertEq(reason, bytes32(0));
    }

    function test_UnboundTermsNeverApprove() public {
        // Job submitted with no criteria bound at all. Must fail closed:
        // never approve, and let the kernel's expiry refund release the client.
        (EvidenceRegistry.Leaf[] memory l, ProofPolicy.Reveal[] memory r) =
            _work(20, 2 * WAD, 3600, true);
        _submit();
        _harden();

        (uint8 v,) = pol.check(JOB, _ev(l, r));
        assertEq(v, PENDING);
    }

    function test_VerdictIsMonotonic() public {
        pol.bindTerms(JOB, agent, _hfCriterion(100, 3600));
        (EvidenceRegistry.Leaf[] memory l, ProofPolicy.Reveal[] memory r) =
            _work(168, 19 * WAD / 10, 3600, true);
        _submit();

        (uint8 a,) = pol.check(JOB, _ev(l, r));
        _harden();
        (uint8 b,) = pol.check(JOB, _ev(l, r));
        vm.warp(block.timestamp + 365 days);
        (uint8 c,) = pol.check(JOB, _ev(l, r));

        assertEq(a, APPROVE);
        assertEq(b, APPROVE);
        assertEq(c, APPROVE); // never flips
    }

    // =========================================================
    // TERMS BINDING
    // =========================================================

    function test_TermsAreImmutableOnceBound() public {
        pol.bindTerms(JOB, agent, _hfCriterion(10, 0));
        vm.expectRevert(ProofPolicy.TermsAlreadyBound.selector);
        pol.bindTerms(JOB, impostor, _hfCriterion(1, 0));
    }

    function test_InvalidCriterionRejectedAtBinding() public {
        CE.Criterion[] memory bad = _hfCriterion(0, 0); // minSamples = 0
        vm.expectRevert(
            abi.encodeWithSelector(ProofPolicy.BadCriterion.selector, 0, CE.Fail.InvalidCriterion)
        );
        pol.bindTerms(JOB, agent, bad);
    }

    function test_UnknownMetricRejectedAtBinding() public {
        CE.Criterion[] memory bad = _hfCriterion(10, 0);
        bad[0].metric = keccak256("vibes");
        vm.expectRevert(
            abi.encodeWithSelector(ProofPolicy.BadCriterion.selector, 0, CE.Fail.UnknownMetric)
        );
        pol.bindTerms(JOB, agent, bad);
    }

    function test_EmptyCriteriaRejected() public {
        vm.expectRevert(ProofPolicy.NoCriteria.selector);
        pol.bindTerms(JOB, agent, new CE.Criterion[](0));
    }

    function test_CriteriaHashIsReadableBeforeFunding() public {
        // The trust flow: client binds, reads back, and only then funds.
        CE.Criterion[] memory cs = _hfCriterion(100, 3600);
        pol.bindTerms(JOB, agent, cs);

        (address provider, bytes32 h,, bool bound) = pol.termsOf(JOB);
        assertEq(provider, agent);
        assertTrue(bound);
        assertEq(h, CE.hashAll(cs));
        assertEq(pol.criteriaOf(JOB).length, 1);
    }
}
