// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPolicy} from "./IPolicy.sol";
import {EvidenceRegistry} from "./EvidenceRegistry.sol";
import {CriteriaEngine as CE} from "./CriteriaEngine.sol";

/// @title  ProofPolicy — evidence-based settlement for ERC-8183 agent jobs
/// @notice A drop-in alternative to BNB Chain's reference `OptimisticPolicy`.
///
///         OptimisticPolicy pays a provider when nobody complains in time.
///         That is structurally broken for autonomous agents, whose entire
///         premise is that nobody is watching.
///
///         ProofPolicy pays only when the agent can prove it did the job, and
///         refunds the client automatically when it cannot — with no dispute
///         raised, no vote taken, and nobody paying attention.
///
/// @dev    Interface and invariants per
///         github.com/bnb-chain/apex-contracts/blob/main/docs/custom-policy.md
contract ProofPolicy is IPolicy {
    // ---------------------------------------------------------------
    // Verdict codes — from the spec. Do not invent new ones.
    // ---------------------------------------------------------------
    uint8 internal constant PENDING = 0;
    uint8 internal constant APPROVE = 1;
    uint8 internal constant REJECT = 2;

    bytes32 public constant REASON_APPROVED = keccak256("ATTESTABLE_APPROVED");
    bytes32 public constant REASON_NO_EVIDENCE = keccak256("ATTESTABLE_REJECTED_NO_EVIDENCE");
    bytes32 public constant REASON_TOO_FEW = keccak256("ATTESTABLE_REJECTED_TOO_FEW_SAMPLES");
    bytes32 public constant REASON_WRONG_AGENT = keccak256("ATTESTABLE_REJECTED_WRONG_AGENT");
    bytes32 public constant REASON_CRITERIA = keccak256("ATTESTABLE_REJECTED_CRITERIA");

    /// @notice Domain tag for the observation commitment. An agent commits
    ///         `inputsHash = observationHash(metric, value, observedAt)` at
    ///         decision time and reveals `(metric, value)` at settlement.
    ///         The value it is judged on is therefore fixed before the outcome
    ///         is known — which is the entire point of the system.
    bytes32 public constant OBS_DOMAIN = keccak256("ATTESTABLE_OBS_V1");

    address public immutable router;
    EvidenceRegistry public immutable registry;

    /// @notice Grace period after submission before absent or incomplete
    ///         evidence hardens into a REJECT. Gives an honest agent time to
    ///         seal and a settler time to assemble calldata.
    uint64 public immutable proofWindow;

    struct Terms {
        address provider; // the agent the client actually hired
        bytes32 criteriaHash;
        uint64 submittedAt;
        bool bound;
    }

    /// @param metric One of the CriteriaEngine metric ids.
    /// @param value  WAD-scaled observation revealed at settlement.
    struct Reveal {
        bytes32 metric;
        int256 value;
    }

    mapping(uint256 => Terms) public termsOf;
    mapping(uint256 => CE.Criterion[]) private _criteria;

    error NotRouter();
    error AlreadySubmitted();
    error TermsAlreadyBound();
    error TermsNotBound();
    error NoCriteria();
    error BadCriterion(uint256 index, CE.Fail reason);

    event TermsBound(uint256 indexed jobId, address indexed provider, bytes32 criteriaHash, uint256 count);
    event JobSubmitted(uint256 indexed jobId, bytes32 deliverable, bytes32 optParamsHash);

    constructor(address router_, EvidenceRegistry registry_, uint64 proofWindow_) {
        router = router_;
        registry = registry_;
        proofWindow = proofWindow_;
    }

    // ---------------------------------------------------------------
    // Commissioning
    // ---------------------------------------------------------------

    /// @notice Bind the acceptance criteria and the hired provider for a job.
    ///
    /// @dev    TRUST FLOW. This is permissionless and first-caller-wins, for the
    ///         same reason `EvidenceRegistry` is: this contract cannot see the
    ///         kernel's `job.client` and will not pretend otherwise.
    ///
    ///         Safety comes from ordering rather than access control. The client
    ///         binds terms, reads them back on-chain, and only then funds the
    ///         escrow. Funding is the client's act of consent. A stranger who
    ///         front-runs the binding has only published terms the client will
    ///         read, reject, and refuse to fund.
    ///
    ///         Terms are immutable once bound and cannot be changed after
    ///         submission, so neither side can move the goalposts mid-job.
    ///
    ///         ROADMAP: once the kernel's Job struct is read directly, this
    ///         becomes `require(msg.sender == job.client)` and the ordering
    ///         requirement disappears.
    function bindTerms(uint256 jobId, address provider, CE.Criterion[] calldata criteria) external {
        Terms storage t = termsOf[jobId];
        if (t.bound) revert TermsAlreadyBound();
        if (criteria.length == 0) revert NoCriteria();

        for (uint256 i; i < criteria.length;) {
            (bool ok, CE.Fail reason) = CE.validate(criteria[i]);
            if (!ok) revert BadCriterion(i, reason);
            _criteria[jobId].push(criteria[i]);
            unchecked {
                ++i;
            }
        }

        bytes32 h = CE.hashAll(_criteria[jobId]);
        t.provider = provider;
        t.criteriaHash = h;
        t.bound = true;

        emit TermsBound(jobId, provider, h, criteria.length);
    }

    function criteriaOf(uint256 jobId) external view returns (CE.Criterion[] memory) {
        return _criteria[jobId];
    }

    // ---------------------------------------------------------------
    // IPolicy — onSubmitted
    // ---------------------------------------------------------------

    /// @dev Invariants 2, 3 and 5: router-gated, one-shot, storage writes only.
    function onSubmitted(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external {
        if (msg.sender != router) revert NotRouter();
        Terms storage t = termsOf[jobId];
        if (t.submittedAt != 0) revert AlreadySubmitted();

        // Deliberately NOT reverting when terms are unbound. Reverting here
        // would block the kernel's submit for an unrelated bookkeeping failure.
        // An unbound job simply never reaches APPROVE, and the client's
        // expiry refund is the escape. Absent terms fail closed.
        t.submittedAt = uint64(block.timestamp);

        emit JobSubmitted(jobId, deliverable, keccak256(optParams));
    }

    // ---------------------------------------------------------------
    // IPolicy — check
    // ---------------------------------------------------------------

    /// @notice The verdict.
    /// @param evidence `abi.encode(EvidenceRegistry.Leaf[] leaves, Reveal[] reveals)`
    ///
    /// @dev WHY A BAD CALLER CANNOT GRIEF THE PROVIDER.
    ///
    ///      `settle` is permissionless and `evidence` is caller-supplied, so a
    ///      naive design lets any stranger submit garbage, fail the criteria and
    ///      rob an honest agent of its fee.
    ///
    ///      That is closed by the order of the gates. REJECT is only ever
    ///      reachable from facts that are unique or on-chain:
    ///
    ///        * Gate 1 requires the supplied leaves to replay to the registry's
    ///          stored `chainHead` in full. Exactly one leaf set can do that, so
    ///          once gate 1 passes the evidence is not "the caller's version" —
    ///          it is the record. Wrong or partial evidence fails gate 1 and
    ///          returns PENDING, never REJECT.
    ///
    ///        * The state-derived rejections (no sealed record, wrong agent)
    ///          read the registry directly and ignore calldata entirely.
    ///
    ///      So a griefer's only power is to leave the job PENDING, which any
    ///      honest party undoes by calling settle with the real evidence.
    ///
    ///      Invariant 4 (monotonic verdicts) follows: the passing evidence is
    ///      unique and the record is sealed, so a job that can APPROVE can never
    ///      subsequently REJECT.
    ///
    ///      Invariant 6: returns PENDING, never reverts, on anything unexpected.
    function check(uint256 jobId, bytes calldata evidence)
        external
        view
        returns (uint8 verdict, bytes32 reason)
    {
        Terms memory t = termsOf[jobId];
        if (t.submittedAt == 0 || !t.bound) return (PENDING, bytes32(0));

        bool hardened = block.timestamp >= t.submittedAt + proofWindow;

        EvidenceRegistry.Record memory rec = registry.recordOf(jobId);

        // --- state-derived rejections: independent of calldata ---

        // The agent that wrote the evidence is not the one the client hired.
        // This is what closes the registry's permissionless claim: a front-runner
        // who grabbed the jobId produced a record no policy will honour.
        if (rec.agent != t.provider) {
            return hardened ? (REJECT, REASON_WRONG_AGENT) : (PENDING, bytes32(0));
        }

        // Never sealed. The agent did not finish, or never started.
        if (!rec.isSealed) {
            return hardened ? (REJECT, REASON_NO_EVIDENCE) : (PENDING, bytes32(0));
        }

        // Evidence thinner than the thinnest criterion allows. Checked from the
        // registry's own leafCount so a caller cannot mask sparse work by
        // submitting fewer leaves than exist.
        uint32 floor = _minSampleFloor(jobId);
        if (rec.leafCount < floor) {
            return hardened ? (REJECT, REASON_TOO_FEW) : (PENDING, bytes32(0));
        }

        // --- gate 1: the evidence is the record, or it is nothing ---

        (bool decoded, EvidenceRegistry.Leaf[] memory leaves, Reveal[] memory reveals) = _decode(evidence);
        if (!decoded || leaves.length != reveals.length) return (PENDING, bytes32(0));
        if (!registry.verifyChain(jobId, leaves)) return (PENDING, bytes32(0));

        // --- gate 2: each revealed value is the one committed at the time ---

        for (uint256 i; i < leaves.length;) {
            bytes32 expected = observationHash(reveals[i].metric, reveals[i].value, leaves[i].observedAt);
            if (leaves[i].inputsHash != expected) return (PENDING, bytes32(0));
            unchecked {
                ++i;
            }
        }

        // --- gate 3: oracle attestation ---
        //
        // Presence only, for now. Signature verification against APRO's signer
        // set lands with AttestationVerifier; until then this proves an
        // attestation was referenced at decision time, not that it is valid.
        // Stated plainly rather than claimed as more than it is.
        for (uint256 i; i < leaves.length;) {
            if (leaves[i].attestationId == bytes32(0)) return (PENDING, bytes32(0));
            unchecked {
                ++i;
            }
        }

        // --- gate 4: the criteria themselves ---

        CE.Criterion[] memory cs = _criteria[jobId];
        for (uint256 i; i < cs.length;) {
            CE.Sample[] memory samples = _samplesFor(cs[i].metric, leaves, reveals);
            (bool ok,,) = CE.evaluate(cs[i], samples);
            if (!ok) return (REJECT, REASON_CRITERIA);
            unchecked {
                ++i;
            }
        }

        return (APPROVE, REASON_APPROVED);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @notice The commitment an agent writes into `Leaf.inputsHash`.
    function observationHash(bytes32 metric, int256 value, uint64 observedAt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(OBS_DOMAIN, metric, value, observedAt));
    }

    /// @dev Smallest `minSamples` across all criteria — the floor below which no
    ///      criterion could pass, so sparse evidence is rejected from state alone.
    function _minSampleFloor(uint256 jobId) private view returns (uint32 floor) {
        CE.Criterion[] memory cs = _criteria[jobId];
        for (uint256 i; i < cs.length;) {
            if (floor == 0 || cs[i].minSamples < floor) floor = cs[i].minSamples;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Project the leaves down to one metric's series, preserving order.
    function _samplesFor(bytes32 metric, EvidenceRegistry.Leaf[] memory leaves, Reveal[] memory reveals)
        private
        pure
        returns (CE.Sample[] memory out)
    {
        uint256 n;
        for (uint256 i; i < reveals.length;) {
            if (reveals[i].metric == metric) ++n;
            unchecked {
                ++i;
            }
        }
        out = new CE.Sample[](n);
        uint256 k;
        for (uint256 i; i < reveals.length;) {
            if (reveals[i].metric == metric) {
                out[k] = CE.Sample({value: reveals[i].value, observedAt: leaves[i].observedAt});
                unchecked {
                    ++k;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Malformed calldata must yield PENDING, not a revert (invariant 6).
    function _decode(bytes calldata evidence)
        private
        view
        returns (bool ok, EvidenceRegistry.Leaf[] memory leaves, Reveal[] memory reveals)
    {
        if (evidence.length == 0) return (false, leaves, reveals);
        try this.decodeEvidence(evidence) returns (
            EvidenceRegistry.Leaf[] memory l, Reveal[] memory r
        ) {
            return (true, l, r);
        } catch {
            return (false, leaves, reveals);
        }
    }

    /// @dev External only so `_decode` can catch a malformed-abi revert.
    function decodeEvidence(bytes calldata evidence)
        external
        pure
        returns (EvidenceRegistry.Leaf[] memory, Reveal[] memory)
    {
        return abi.decode(evidence, (EvidenceRegistry.Leaf[], Reveal[]));
    }
}
