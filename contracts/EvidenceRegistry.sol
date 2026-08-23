// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  EvidenceRegistry — tamper-evident decision log for autonomous agents
/// @notice An agent working an ERC-8183 job commits one `Leaf` per decision,
///         BEFORE the outcome of that decision is known. Each leaf is folded
///         into a running hash chain, so the completed record proves:
///
///           ORDER        — leaf N is bound to leaf N-1 by construction
///           COMPLETENESS — no leaf can be removed or inserted after the fact
///           PRE-COMMITMENT — `observedAt` is bounded by `block.timestamp`,
///                            so an agent cannot backdate a decision it only
///                            made once it saw how things turned out
///
///         That last property is the whole point. Anyone can claim they made
///         the right call. This makes the claim falsifiable.
///
/// @dev    DESIGN: this registry is deliberately DUMB and PERMISSIONLESS.
///
///         It does not know what a "job" is, who is entitled to work one, or
///         what "done" means. The first address to commit against a jobId
///         claims it and is locked in as that record's `agent`; nobody else
///         can ever write to it.
///
///         Authorisation lives in ProofPolicy, which is the only contract with
///         the kernel context to answer "is this the provider the client
///         actually hired?" — it asserts `recordOf(jobId).agent == job.provider`
///         at settlement. A front-runner who claims a jobId first has only
///         succeeded in writing a record under their own address that no
///         policy will ever honour, at their own gas expense.
///
///         Keeping authorisation out of here means the registry has no
///         privileged roles, no admin, no upgrade path, and nothing to
///         compromise.
contract EvidenceRegistry {
    // ---------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------

    /// @param inputsHash     keccak256 of the observation bundle the decision was made from.
    /// @param attestationId  Oracle attestation covering those inputs (APRO). Zero if unattested.
    /// @param policyVersion  Model id + prompt hash + agent code commit. Pins WHAT decided.
    /// @param decisionHash   keccak256 of the structured decision, committed before the outcome.
    /// @param actionTxHash   Resulting BSC transaction. Zero is legitimate — see NO_OP.
    /// @param observedAt     Agent's observation time. Must be monotonic and never in the future.
    struct Leaf {
        bytes32 inputsHash;
        bytes32 attestationId;
        bytes32 policyVersion;
        bytes32 decisionHash;
        bytes32 actionTxHash;
        uint64 observedAt;
    }

    struct Record {
        address agent;
        bytes32 chainHead;
        uint32 leafCount;
        uint64 firstObservedAt;
        uint64 lastObservedAt;
        uint64 sealedAt;
        bool isSealed;
    }

    /// @notice `actionTxHash == NO_OP` means "I looked, and correctly chose to do nothing."
    /// @dev    An agent that decides not to act must still be able to prove it was awake.
    ///         Without an explicit no-op commitment, diligent inaction is indistinguishable
    ///         from absence — and inaction is frequently the correct call.
    bytes32 public constant NO_OP = bytes32(0);

    /// @notice Domain separator folded into the genesis link so chains from a
    ///         different deployment or chainid can never be replayed here.
    bytes32 public immutable GENESIS;

    mapping(uint256 => Record) private _records;

    // ---------------------------------------------------------------
    // Events — the full leaf is emitted, never stored. Storage keeps only
    // the 32-byte accumulator; reconstruction happens from logs off-chain.
    // ---------------------------------------------------------------

    event RecordOpened(uint256 indexed jobId, address indexed agent);
    event LeafCommitted(uint256 indexed jobId, uint32 indexed index, bytes32 chainHead, Leaf leaf);
    event RecordSealed(
        uint256 indexed jobId, bytes32 chainHead, uint32 leafCount, uint64 sealedAt, string blobURI
    );

    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error NotRecordAgent(uint256 jobId, address agent, address caller);
    error RecordIsSealed(uint256 jobId);
    error RecordNotFound(uint256 jobId);
    error NonMonotonicObservation(uint64 last, uint64 given);
    error FutureObservation(uint64 given, uint64 blockTime);
    error EmptyBatch();
    error EmptyRecord(uint256 jobId);

    constructor() {
        GENESIS = keccak256(abi.encode("ATTESTABLE_EVIDENCE_V1", block.chainid, address(this)));
    }

    // ---------------------------------------------------------------
    // Write path
    // ---------------------------------------------------------------

    /// @notice Commit one decision. First caller for a `jobId` claims the record.
    function commit(uint256 jobId, Leaf calldata leaf) external {
        _commit(jobId, leaf);
    }

    /// @notice Commit several decisions in one transaction.
    /// @dev    Amortises the 21k base cost for high-cadence agents. Ordering within
    ///         the batch is preserved and the same monotonicity rules apply, so a
    ///         batch is indistinguishable from N separate commits in the final chain.
    function commitBatch(uint256 jobId, Leaf[] calldata leaves) external {
        uint256 n = leaves.length;
        if (n == 0) revert EmptyBatch();
        for (uint256 i; i < n;) {
            _commit(jobId, leaves[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _commit(uint256 jobId, Leaf calldata leaf) private {
        Record storage r = _records[jobId];

        if (r.agent == address(0)) {
            r.agent = msg.sender;
            r.chainHead = GENESIS;
            r.firstObservedAt = leaf.observedAt;
            emit RecordOpened(jobId, msg.sender);
        } else if (r.agent != msg.sender) {
            revert NotRecordAgent(jobId, r.agent, msg.sender);
        }

        if (r.isSealed) revert RecordIsSealed(jobId);

        // Never in the future: bounds how far ahead an agent can pre-write.
        if (leaf.observedAt > block.timestamp) {
            revert FutureObservation(leaf.observedAt, uint64(block.timestamp));
        }
        // Never backwards: an agent cannot slot a decision in behind one it
        // already committed, which is how it would otherwise rewrite history
        // once the outcome became known.
        if (r.leafCount != 0 && leaf.observedAt < r.lastObservedAt) {
            revert NonMonotonicObservation(r.lastObservedAt, leaf.observedAt);
        }

        bytes32 head = _fold(r.chainHead, leaf);
        uint32 index = r.leafCount;

        r.chainHead = head;
        r.leafCount = index + 1;
        r.lastObservedAt = leaf.observedAt;

        emit LeafCommitted(jobId, index, head, leaf);
    }

    /// @notice Freeze the record. No further leaves may be committed.
    /// @param  blobURI Pointer to the full evidence bundle (Greenfield / IPFS / Unibase).
    ///                 Advisory only — the chain head above is authoritative.
    /// @dev    Note what is NOT a parameter: the root. The agent does not get to
    ///         supply the value it is judged against. `chainHead` is accumulated by
    ///         this contract from leaves it accepted one at a time.
    function seal(uint256 jobId, string calldata blobURI) external {
        Record storage r = _records[jobId];
        if (r.agent == address(0)) revert RecordNotFound(jobId);
        if (r.agent != msg.sender) revert NotRecordAgent(jobId, r.agent, msg.sender);
        if (r.isSealed) revert RecordIsSealed(jobId);
        if (r.leafCount == 0) revert EmptyRecord(jobId);

        r.isSealed = true;
        r.sealedAt = uint64(block.timestamp);

        emit RecordSealed(jobId, r.chainHead, r.leafCount, r.sealedAt, blobURI);
    }

    // ---------------------------------------------------------------
    // Read / verification path — all view, all free off-chain via eth_call
    // ---------------------------------------------------------------

    function recordOf(uint256 jobId) external view returns (Record memory) {
        return _records[jobId];
    }

    function chainHeadOf(uint256 jobId) external view returns (bytes32) {
        return _records[jobId].chainHead;
    }

    /// @notice Fold one leaf into a running head. Pure — anyone can replay a
    ///         chain locally from event logs and reach the same value.
    function fold(bytes32 prevHead, Leaf calldata leaf) external pure returns (bytes32) {
        return _fold(prevHead, leaf);
    }

    function _fold(bytes32 prevHead, Leaf calldata leaf) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                prevHead,
                leaf.inputsHash,
                leaf.attestationId,
                leaf.policyVersion,
                leaf.decisionHash,
                leaf.actionTxHash,
                leaf.observedAt
            )
        );
    }

    /// @notice Replay a full set of leaves and confirm it reproduces the stored head.
    /// @dev    This is the primitive `ProofPolicy` gate 1 calls. Supplying leaves as
    ///         calldata rather than reading them from storage is what makes the whole
    ///         design cheap: storage holds 32 bytes per job, and the party who wants
    ///         settlement pays to present the evidence.
    ///
    ///         Cost is linear in leaf count. A 7-day job at hourly cadence is ~170
    ///         leaves ≈ well within a BSC block. Jobs needing tens of thousands of
    ///         leaves should move to a Merkle commitment with sampled inclusion
    ///         proofs; the fold function stays the same, only the accumulator changes.
    function verifyChain(uint256 jobId, Leaf[] calldata leaves) external view returns (bool) {
        Record storage r = _records[jobId];
        if (r.leafCount != leaves.length) return false;

        bytes32 head = GENESIS;
        for (uint256 i; i < leaves.length;) {
            head = _fold(head, leaves[i]);
            unchecked {
                ++i;
            }
        }
        return head == r.chainHead;
    }

    /// @notice Largest gap, in seconds, between consecutive observations.
    /// @dev    An agent cannot fake attentiveness by committing a burst of leaves at
    ///         the end: `observedAt` is monotonic and bounded by block time, so a
    ///         period of absence leaves a hole that shows up here. Cadence criteria
    ///         in `ProofPolicy` are enforced against this value.
    ///
    ///         Returns 0 for fewer than two leaves. Callers MUST treat a leaf count
    ///         below the expected sample size as a failure in its own right, not as
    ///         a perfect cadence score.
    function maxGap(Leaf[] calldata leaves) external pure returns (uint64 gap) {
        if (leaves.length < 2) return 0;
        for (uint256 i = 1; i < leaves.length;) {
            uint64 d = leaves[i].observedAt - leaves[i - 1].observedAt;
            if (d > gap) gap = d;
            unchecked {
                ++i;
            }
        }
    }
}
