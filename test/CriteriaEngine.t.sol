// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CriteriaEngine as CE} from "../contracts/CriteriaEngine.sol";

contract CriteriaEngineTest is Test {
    int256 constant WAD = 1e18;
    uint64 constant T0 = 1_700_000_000;

    // ---------------- helpers ----------------

    function _hf(int256 threshold, uint16 pct, uint32 minSamples, uint32 maxGap)
        internal
        pure
        returns (CE.Criterion memory)
    {
        return CE.Criterion({
            metric: CE.HEALTH_FACTOR,
            op: CE.Op.GTE,
            threshold: threshold,
            minSamplePct: pct,
            minSamples: minSamples,
            maxGapSeconds: maxGap
        });
    }

    /// Samples at a fixed cadence, all at `value`.
    function _flat(uint256 n, int256 value, uint64 step) internal pure returns (CE.Sample[] memory s) {
        s = new CE.Sample[](n);
        for (uint256 i; i < n; ++i) {
            s[i] = CE.Sample({value: value, observedAt: T0 + uint64(i) * step});
        }
    }

    // ---------------- metric allow-list ----------------

    function test_KnownMetrics() public pure {
        assertTrue(CE.isKnownMetric(CE.HEALTH_FACTOR));
        assertTrue(CE.isKnownMetric(CE.COLLATERAL_RATIO));
        assertTrue(CE.isKnownMetric(CE.SLIPPAGE_BPS));
        assertTrue(CE.isKnownMetric(CE.ORACLE_DEVIATION_BPS));
    }

    function test_UnknownMetricNeverSilentlyPasses() public pure {
        CE.Criterion memory c = _hf(16 * WAD / 10, 9500, 1, 0);
        c.metric = keccak256("vibes");

        (bool ok, CE.Fail r,) = CE.evaluate(c, _flat(100, 2 * WAD, 60));
        // Every sample would clear the threshold. It must still fail.
        assertFalse(ok);
        assertEq(uint256(r), uint256(CE.Fail.UnknownMetric));
    }

    // ---------------- validation ----------------

    function test_RejectsZeroMinSamples() public pure {
        (bool ok, CE.Fail r) = CE.validate(_hf(16 * WAD / 10, 9500, 0, 0));
        assertFalse(ok);
        assertEq(uint256(r), uint256(CE.Fail.InvalidCriterion));
    }

    function test_RejectsOutOfRangePct() public pure {
        (bool a,) = CE.validate(_hf(WAD, 0, 1, 0));
        (bool b,) = CE.validate(_hf(WAD, 10_001, 1, 0));
        assertFalse(a);
        assertFalse(b);
        (bool c,) = CE.validate(_hf(WAD, 10_000, 1, 0));
        assertTrue(c);
    }

    // ---------------- the headline case ----------------

    function test_NominalRunPasses() public pure {
        CE.Criterion memory c = _hf(16 * WAD / 10, 9500, 100, 3600);
        (bool ok, CE.Fail r, uint16 met) = CE.evaluate(c, _flat(168, 19 * WAD / 10, 3600));
        assertTrue(ok);
        assertEq(uint256(r), uint256(CE.Fail.None));
        assertEq(met, 10_000);
    }

    function test_BreachBelowThresholdFails() public pure {
        CE.Criterion memory c = _hf(16 * WAD / 10, 9500, 10, 0);
        CE.Sample[] memory s = _flat(100, 19 * WAD / 10, 3600);
        // 6 hours below 1.6 out of 100 -> 94% met, needs 95%
        for (uint256 i = 48; i < 54; ++i) s[i].value = 142 * WAD / 100;

        (bool ok, CE.Fail r, uint16 met) = CE.evaluate(c, s);
        assertFalse(ok);
        assertEq(uint256(r), uint256(CE.Fail.ThresholdBreach));
        assertEq(met, 9400);
    }

    function test_ToleranceAllowsBriefBreach() public pure {
        CE.Criterion memory c = _hf(16 * WAD / 10, 9500, 10, 0);
        CE.Sample[] memory s = _flat(100, 19 * WAD / 10, 3600);
        for (uint256 i = 48; i < 53; ++i) s[i].value = 142 * WAD / 100; // exactly 95%

        (bool ok,, uint16 met) = CE.evaluate(c, s);
        assertTrue(ok);
        assertEq(met, 9500);
    }

    // ---------------- the cherry-pick attack ----------------

    function test_SparseEvidenceCannotScorePerfect() public pure {
        // The attack: sleep all week, wake once at a favourable moment, and
        // report 100% of samples met. minSamples is the defence.
        CE.Criterion memory c = _hf(16 * WAD / 10, 10_000, 100, 0);
        (bool ok, CE.Fail r, uint16 met) = CE.evaluate(c, _flat(3, 2 * WAD, 3600));
        assertFalse(ok);
        assertEq(uint256(r), uint256(CE.Fail.TooFewSamples));
        assertEq(met, 0); // no percentage is reported for evidence this thin
    }

    function test_CadenceBreachCaughtEvenWhenEveryValueIsGood() public pure {
        // Every observation clears the threshold, but the agent went dark for
        // 23 hours in the middle. Being right when you look does not help if
        // you were not looking.
        CE.Criterion memory c = _hf(16 * WAD / 10, 9500, 5, 3600);
        CE.Sample[] memory s = new CE.Sample[](5);
        s[0] = CE.Sample(2 * WAD, T0);
        s[1] = CE.Sample(2 * WAD, T0 + 3600);
        s[2] = CE.Sample(2 * WAD, T0 + 7200);
        s[3] = CE.Sample(2 * WAD, T0 + 90_000); // gone for ~23h
        s[4] = CE.Sample(2 * WAD, T0 + 93_600);

        (bool ok, CE.Fail r,) = CE.evaluate(c, s);
        assertFalse(ok);
        assertEq(uint256(r), uint256(CE.Fail.CadenceBreach));
    }

    function test_ZeroMaxGapMeansUnconstrained() public pure {
        CE.Criterion memory c = _hf(16 * WAD / 10, 9500, 2, 0);
        CE.Sample[] memory s = new CE.Sample[](2);
        s[0] = CE.Sample(2 * WAD, T0);
        s[1] = CE.Sample(2 * WAD, T0 + 999_999);
        (bool ok,,) = CE.evaluate(c, s);
        assertTrue(ok);
    }

    function test_UnorderedSamplesRejected() public pure {
        CE.Criterion memory c = _hf(16 * WAD / 10, 9500, 2, 0);
        CE.Sample[] memory s = new CE.Sample[](3);
        s[0] = CE.Sample(2 * WAD, T0);
        s[1] = CE.Sample(2 * WAD, T0 + 100);
        s[2] = CE.Sample(2 * WAD, T0 + 50); // backwards
        (bool ok, CE.Fail r,) = CE.evaluate(c, s);
        assertFalse(ok);
        assertEq(uint256(r), uint256(CE.Fail.Unordered));
    }

    // ---------------- rounding ----------------

    function test_RoundingFavoursTheClient() public pure {
        // 9,499 of 10,000 is 94.99%. It must not round up into a 95% pass.
        CE.Criterion memory c = _hf(16 * WAD / 10, 9500, 10, 0);
        CE.Sample[] memory s = _flat(10_000, 2 * WAD, 60);
        for (uint256 i; i < 501; ++i) s[i].value = WAD;

        (bool ok,, uint16 met) = CE.evaluate(c, s);
        assertEq(met, 9499);
        assertFalse(ok);
    }

    function test_BoundaryValueCounts() public pure {
        // GTE is inclusive: exactly at the threshold passes.
        CE.Criterion memory c = _hf(16 * WAD / 10, 10_000, 1, 0);
        (bool ok,, uint16 met) = CE.evaluate(c, _flat(10, 16 * WAD / 10, 60));
        assertTrue(ok);
        assertEq(met, 10_000);
    }

    // ---------------- operators / other metrics ----------------

    function test_LteMetricSlippage() public pure {
        CE.Criterion memory c = CE.Criterion({
            metric: CE.SLIPPAGE_BPS,
            op: CE.Op.LTE,
            threshold: 50 * WAD, // 50 bps
            minSamplePct: 9900,
            minSamples: 10,
            maxGapSeconds: 0
        });
        (bool ok,,) = CE.evaluate(c, _flat(100, 12 * WAD, 60));
        assertTrue(ok);

        (bool bad,, uint16 met) = CE.evaluate(c, _flat(100, 80 * WAD, 60));
        assertFalse(bad);
        assertEq(met, 0);
    }

    function test_NegativeDeviationHandled() public pure {
        // Deviation is signed; -30 bps must not read as "less than 25" by accident
        // of unsigned wraparound. This is why the engine uses int256 throughout.
        CE.Criterion memory c = CE.Criterion({
            metric: CE.ORACLE_DEVIATION_BPS,
            op: CE.Op.GTE,
            threshold: -25 * WAD,
            minSamplePct: 10_000,
            minSamples: 1,
            maxGapSeconds: 0
        });
        (bool ok,,) = CE.evaluate(c, _flat(5, -10 * WAD, 60));
        assertTrue(ok);

        (bool bad,,) = CE.evaluate(c, _flat(5, -30 * WAD, 60));
        assertFalse(bad);
    }

    function test_EqOperator() public pure {
        CE.Criterion memory c = CE.Criterion({
            metric: CE.COLLATERAL_RATIO,
            op: CE.Op.EQ,
            threshold: 150 * WAD,
            minSamplePct: 10_000,
            minSamples: 1,
            maxGapSeconds: 0
        });
        (bool ok,,) = CE.evaluate(c, _flat(3, 150 * WAD, 60));
        assertTrue(ok);
    }

    // ---------------- requisitions ----------------

    function test_EvaluateAllRequiresEveryCriterion() public pure {
        CE.Criterion[] memory cs = new CE.Criterion[](2);
        cs[0] = _hf(16 * WAD / 10, 9500, 5, 0);
        cs[1] = CE.Criterion(CE.SLIPPAGE_BPS, CE.Op.LTE, 50 * WAD, 9900, 5, 0);

        CE.Sample[][] memory ss = new CE.Sample[][](2);
        ss[0] = _flat(50, 2 * WAD, 60); // fine
        ss[1] = _flat(50, 90 * WAD, 60); // blows slippage

        (bool ok, uint256 at, CE.Fail r) = CE.evaluateAll(cs, ss);
        assertFalse(ok);
        assertEq(at, 1);
        assertEq(uint256(r), uint256(CE.Fail.ThresholdBreach));
    }

    function test_EvaluateAllPassesWhenAllPass() public pure {
        CE.Criterion[] memory cs = new CE.Criterion[](2);
        cs[0] = _hf(16 * WAD / 10, 9500, 5, 0);
        cs[1] = CE.Criterion(CE.SLIPPAGE_BPS, CE.Op.LTE, 50 * WAD, 9900, 5, 0);

        CE.Sample[][] memory ss = new CE.Sample[][](2);
        ss[0] = _flat(50, 2 * WAD, 60);
        ss[1] = _flat(50, 10 * WAD, 60);

        (bool ok,, CE.Fail r) = CE.evaluateAll(cs, ss);
        assertTrue(ok);
        assertEq(uint256(r), uint256(CE.Fail.None));
    }

    function test_EmptyRequisitionRejected() public pure {
        (bool ok,, CE.Fail r) = CE.evaluateAll(new CE.Criterion[](0), new CE.Sample[][](0));
        assertFalse(ok);
        assertEq(uint256(r), uint256(CE.Fail.InvalidCriterion));
    }

    function test_MismatchedLengthsRejected() public pure {
        (bool ok,,) = CE.evaluateAll(new CE.Criterion[](2), new CE.Sample[][](1));
        assertFalse(ok);
    }

    // ---------------- commitment ----------------

    function test_HashIsStable() public pure {
        CE.Criterion memory a = _hf(16 * WAD / 10, 9500, 100, 3600);
        CE.Criterion memory b = _hf(16 * WAD / 10, 9500, 100, 3600);
        assertEq(CE.hash(a), CE.hash(b));
    }

    function test_HashChangesWithEveryField() public pure {
        CE.Criterion memory base = _hf(16 * WAD / 10, 9500, 100, 3600);
        bytes32 h = CE.hash(base);

        CE.Criterion memory m = base;
        m.threshold = 15 * WAD / 10;
        assertTrue(CE.hash(m) != h);

        m = base;
        m.minSamplePct = 9000;
        assertTrue(CE.hash(m) != h);

        m = base;
        m.minSamples = 99;
        assertTrue(CE.hash(m) != h);

        m = base;
        m.maxGapSeconds = 1800;
        assertTrue(CE.hash(m) != h);

        m = base;
        m.op = CE.Op.LTE;
        assertTrue(CE.hash(m) != h);
    }

    function test_RequisitionHashIsOrderSensitive() public pure {
        CE.Criterion[] memory a = new CE.Criterion[](2);
        a[0] = _hf(16 * WAD / 10, 9500, 10, 0);
        a[1] = CE.Criterion(CE.SLIPPAGE_BPS, CE.Op.LTE, 50 * WAD, 9900, 10, 0);

        CE.Criterion[] memory b = new CE.Criterion[](2);
        b[0] = a[1];
        b[1] = a[0];

        // Reordering changes the commitment. Neither party can quietly reshuffle
        // a requisition after it is bound on-chain.
        assertTrue(CE.hashAll(a) != CE.hashAll(b));
    }

    // ---------------- fuzz ----------------

    function testFuzz_MetBpsNeverExceedsFull(uint8 nRaw, int64 valRaw, int64 thRaw) public pure {
        uint256 n = uint256(nRaw) % 60 + 1;
        CE.Criterion memory c = _hf(int256(thRaw), 1, uint32(n), 0);

        CE.Sample[] memory s = new CE.Sample[](n);
        for (uint256 i; i < n; ++i) {
            s[i] = CE.Sample({value: int256(valRaw), observedAt: T0 + uint64(i)});
        }

        (,, uint16 met) = CE.evaluate(c, s);
        assertLe(met, 10_000);
    }

    function testFuzz_AllPassOrNonePass(uint8 nRaw, int64 valRaw, int64 thRaw) public pure {
        // With a flat series every sample compares identically, so the met rate
        // can only ever be 0% or 100%. Anything else means the counter is wrong.
        uint256 n = uint256(nRaw) % 40 + 1;
        CE.Criterion memory c = _hf(int256(thRaw), 1, 1, 0);

        CE.Sample[] memory s = new CE.Sample[](n);
        for (uint256 i; i < n; ++i) {
            s[i] = CE.Sample({value: int256(valRaw), observedAt: T0 + uint64(i)});
        }

        (,, uint16 met) = CE.evaluate(c, s);
        assertTrue(met == 0 || met == 10_000);
        assertEq(met == 10_000, int256(valRaw) >= int256(thRaw));
    }
}
