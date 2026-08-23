// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  CriteriaEngine — machine-checkable acceptance criteria
/// @notice Turns "keep my position safe" into something a contract can decide.
///
///         A client commits criteria at job creation. At settlement, ProofPolicy
///         replays the agent's evidence through this engine and gets a verdict
///         nobody has to agree to — it either holds or it doesn't.
///
/// @dev    LIBRARY, NOT A CONTRACT. All functions are `internal pure`, so they
///         inline into ProofPolicy at compile time. No external call, no
///         delegatecall, no separate deployment to trust or upgrade, and the
///         verdict path has no address it could be pointed away from.
///
///         SCALING: every value and threshold is a signed WAD (1e18).
///         Health factor 1.6 is 1.6e18. Basis-point metrics are also WAD-scaled
///         (25 bps is 25e18) so one comparison path serves all four metrics.
///         Signed, because deviation and drawdown are naturally negative.
library CriteriaEngine {
    // ---------------------------------------------------------------
    // Metrics — a closed set, deliberately
    // ---------------------------------------------------------------
    //
    // Four metrics that work beat twelve that half-work. "Unrealised functions"
    // is a listed scoring penalty, and an unknown metric is worse than a missing
    // one: a criterion the engine cannot evaluate would otherwise pass silently,
    // which is exactly the failure mode Attestable exists to remove.
    //
    // These mirror the four in the commissioning UI. Adding a fifth means adding
    // it here AND teaching the agent to sample it — the pair is the unit of work.

    bytes32 internal constant HEALTH_FACTOR = keccak256("health_factor");
    bytes32 internal constant COLLATERAL_RATIO = keccak256("collateral_ratio");
    bytes32 internal constant SLIPPAGE_BPS = keccak256("slippage_bps");
    bytes32 internal constant ORACLE_DEVIATION_BPS = keccak256("oracle_deviation_bps");

    uint16 internal constant BPS = 10_000;

    enum Op {
        GTE, // value >= threshold  — health factor, collateral ratio
        LTE, // value <= threshold  — slippage, deviation
        EQ // value == threshold  — discrete states

    }

    /// @notice Why a criterion failed. Returned instead of a bare bool so the
    ///         UI and the settlement receipt can say something specific — a
    ///         client refunded by an automated system deserves to know which
    ///         gate the agent missed.
    enum Fail {
        None,
        UnknownMetric, // engine cannot evaluate this — never silently pass
        InvalidCriterion, // malformed at commissioning time
        TooFewSamples, // evidence too sparse to mean anything
        Unordered, // samples not monotonic; evidence is malformed
        CadenceBreach, // agent went dark for longer than allowed
        ThresholdBreach // the actual metric failed

    }

    /// @param metric        One of the four constants above.
    /// @param op            Comparison direction.
    /// @param threshold     WAD-scaled bound.
    /// @param minSamplePct  Share of samples that must satisfy it, in bps.
    /// @param minSamples    Absolute floor on sample count. Without this, one
    ///                      passing sample would score 100% — an agent could
    ///                      sleep all week, wake once at a good moment, and
    ///                      claim perfection.
    /// @param maxGapSeconds Longest permitted silence between samples.
    ///                      Zero means unconstrained.
    struct Criterion {
        bytes32 metric;
        Op op;
        int256 threshold;
        uint16 minSamplePct;
        uint32 minSamples;
        uint32 maxGapSeconds;
    }

    /// @param value      WAD-scaled observation.
    /// @param observedAt Timestamp from the evidence leaf.
    struct Sample {
        int256 value;
        uint64 observedAt;
    }

    // ---------------------------------------------------------------
    // Validation — run at commissioning, before anyone escrows money
    // ---------------------------------------------------------------

    function isKnownMetric(bytes32 metric) internal pure returns (bool) {
        return metric == HEALTH_FACTOR || metric == COLLATERAL_RATIO || metric == SLIPPAGE_BPS
            || metric == ORACLE_DEVIATION_BPS;
    }

    /// @notice Reject nonsense before it becomes an escrowed dispute.
    function validate(Criterion memory c) internal pure returns (bool ok, Fail reason) {
        if (!isKnownMetric(c.metric)) return (false, Fail.UnknownMetric);
        if (c.minSamplePct == 0 || c.minSamplePct > BPS) return (false, Fail.InvalidCriterion);
        if (c.minSamples == 0) return (false, Fail.InvalidCriterion);
        return (true, Fail.None);
    }

    // ---------------------------------------------------------------
    // Evaluation
    // ---------------------------------------------------------------

    function satisfies(Op op, int256 value, int256 threshold) internal pure returns (bool) {
        if (op == Op.GTE) return value >= threshold;
        if (op == Op.LTE) return value <= threshold;
        return value == threshold;
    }

    /// @notice Evaluate one criterion against one metric's samples.
    /// @return ok      True only if every gate below passes.
    /// @return reason  First gate that failed.
    /// @return metBps  Share of samples that satisfied the threshold, in bps.
    ///
    /// @dev Gate order is deliberate — structural failures are reported before
    ///      threshold failures, because "the agent barely showed up" is a more
    ///      useful finding than "the number was wrong", and an agent with three
    ///      cherry-picked samples should not be able to report 100%.
    ///
    ///      metBps floors on division. 9,499 of 10,000 samples yields 9499, not
    ///      9500, so a 95% requirement correctly fails. Rounding always favours
    ///      the client, which is the right default when the agent is the party
    ///      that chose when to sample.
    function evaluate(Criterion memory c, Sample[] memory samples)
        internal
        pure
        returns (bool ok, Fail reason, uint16 metBps)
    {
        (bool valid, Fail vr) = validate(c);
        if (!valid) return (false, vr, 0);

        uint256 n = samples.length;
        if (n < c.minSamples) return (false, Fail.TooFewSamples, 0);

        uint256 met;
        for (uint256 i; i < n;) {
            if (i != 0) {
                uint64 prev = samples[i - 1].observedAt;
                uint64 cur = samples[i].observedAt;
                // Evidence from the registry is monotonic by construction. If it
                // is not monotonic here, the caller assembled it wrongly or is
                // lying — either way it is not evidence.
                if (cur < prev) return (false, Fail.Unordered, 0);
                if (c.maxGapSeconds != 0 && cur - prev > c.maxGapSeconds) {
                    return (false, Fail.CadenceBreach, 0);
                }
            }
            if (satisfies(c.op, samples[i].value, c.threshold)) {
                unchecked {
                    ++met;
                }
            }
            unchecked {
                ++i;
            }
        }

        metBps = uint16((met * BPS) / n);
        if (metBps < c.minSamplePct) return (false, Fail.ThresholdBreach, metBps);
        return (true, Fail.None, metBps);
    }

    /// @notice Evaluate a full requisition. Every criterion must pass.
    /// @return ok        True only if all pass.
    /// @return failedAt  Index of the first failing criterion (0 when ok).
    /// @return reason    Why it failed.
    /// @dev    Short-circuits. A requisition is a conjunction — partial credit
    ///         would mean paying an agent for a job it did not finish.
    function evaluateAll(Criterion[] memory cs, Sample[][] memory samples)
        internal
        pure
        returns (bool ok, uint256 failedAt, Fail reason)
    {
        if (cs.length != samples.length) return (false, 0, Fail.InvalidCriterion);
        if (cs.length == 0) return (false, 0, Fail.InvalidCriterion);

        for (uint256 i; i < cs.length;) {
            (bool pass, Fail r,) = evaluate(cs[i], samples[i]);
            if (!pass) return (false, i, r);
            unchecked {
                ++i;
            }
        }
        return (true, 0, Fail.None);
    }

    // ---------------------------------------------------------------
    // Commitment
    // ---------------------------------------------------------------

    /// @dev abi.encode, never encodePacked — packed encoding of a struct with
    ///      dynamic-width neighbours invites collisions, and this hash is what
    ///      the client is held to.
    function hash(Criterion memory c) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(c.metric, c.op, c.threshold, c.minSamplePct, c.minSamples, c.maxGapSeconds)
        );
    }

    /// @notice Commitment over a whole requisition, bound at job creation and
    ///         re-derived at settlement. Neither party can move the goalposts:
    ///         the client cannot tighten criteria after seeing the agent
    ///         struggle, and the agent cannot loosen them after failing.
    function hashAll(Criterion[] memory cs) internal pure returns (bytes32) {
        bytes32[] memory hs = new bytes32[](cs.length);
        for (uint256 i; i < cs.length;) {
            hs[i] = hash(cs[i]);
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encode("ATTESTABLE_CRITERIA_V1", hs));
    }
}
