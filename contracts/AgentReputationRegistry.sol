// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AgentReputationRegistry
 * @notice ERC-8004 Reputation Registry — on-chain feedback ledger for AI agents.
 *
 *         Any address can submit a structured feedback signal against a registered
 *         agent. Feedback consists of a signed fixed-point value, optional taxonomy
 *         tags, an endpoint URI, and a pointer to an off-chain JSON file with
 *         richer context (IPFS recommended). All stored fields are queryable by
 *         smart contracts, enabling on-chain composability.
 *
 *         Security note: clientAddresses MUST be filtered by the caller when using
 *         getSummary/readAllFeedback to mitigate Sybil attacks — unfiltered results
 *         are intentionally not supported per the ERC-8004 spec.
 *
 * Reference: https://eips.ethereum.org/EIPS/eip-8004
 */

interface IAgentIdentityRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function getApproved(uint256 tokenId) external view returns (address);
}

contract AgentReputationRegistry {

    // ── Events ────────────────────────────────────────────────────────────────

    /**
     * @notice Emitted when new feedback is submitted.
     * @dev    endpoint, feedbackURI, and feedbackHash are emitted but NOT stored
     *         on-chain (use event logs / subgraph indexers to retrieve them).
     */
    event NewFeedback(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64          feedbackIndex,
        int128          value,
        uint8           valueDecimals,
        string indexed  indexedTag1,
        string          tag1,
        string          tag2,
        string          endpoint,
        string          feedbackURI,
        bytes32         feedbackHash
    );

    /// @notice Emitted when a feedback entry is revoked by the original submitter.
    event FeedbackRevoked(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64  indexed feedbackIndex
    );

    /// @notice Emitted when a response is appended to an existing feedback entry.
    event ResponseAppended(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64          feedbackIndex,
        address indexed responder,
        string          responseURI,
        bytes32         responseHash
    );

    // ── Storage ───────────────────────────────────────────────────────────────

    /// @dev On-chain stored portion of a feedback entry.
    struct FeedbackRecord {
        int128  value;
        uint8   valueDecimals;
        string  tag1;
        string  tag2;
        bool    isRevoked;
    }

    /// @dev Response count per (agentId, clientAddress, feedbackIndex, responder).
    ///      Stored as a nested mapping of response counts per responder.
    struct ResponseInfo {
        uint64 totalResponses;
        mapping(address => uint64) byResponder;
    }

    // agentId => clientAddress => feedbackIndex (1-based) => record
    mapping(uint256 => mapping(address => mapping(uint64 => FeedbackRecord))) private _feedback;

    // agentId => clientAddress => last feedback index submitted (0 = none yet)
    mapping(uint256 => mapping(address => uint64)) private _lastIndex;

    // agentId => list of all clients who gave feedback
    mapping(uint256 => address[]) private _clients;
    mapping(uint256 => mapping(address => bool)) private _isClient;

    // agentId => clientAddress => feedbackIndex => ResponseInfo
    mapping(uint256 =>
        mapping(address =>
            mapping(uint64 => ResponseInfo))) private _responses;

    // Identity registry reference (set once at deploy)
    IAgentIdentityRegistry private immutable _identityRegistry;

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param identityRegistry_ Address of the deployed AgentIdentityRegistry.
     */
    constructor(address identityRegistry_) {
        require(identityRegistry_ != address(0), "ReputationRegistry: zero address");
        _identityRegistry = IAgentIdentityRegistry(identityRegistry_);
    }

    // ── Read: registry reference ──────────────────────────────────────────────

    /// @notice Returns the associated identity registry address.
    function getIdentityRegistry() external view returns (address) {
        return address(_identityRegistry);
    }

    // ── Write: feedback lifecycle ─────────────────────────────────────────────

    /**
     * @notice Submit feedback for a registered agent.
     *
     * @param agentId       The target agent's ERC-721 tokenId.
     * @param value         Signed fixed-point feedback value.
     * @param valueDecimals Decimal places for value (0-18).
     * @param tag1          OPTIONAL — first taxonomy tag (e.g. "starred", "successRate").
     * @param tag2          OPTIONAL — second taxonomy tag (e.g. time period like "week").
     * @param endpoint      OPTIONAL — the specific agent endpoint this feedback relates to.
     * @param feedbackURI   OPTIONAL — off-chain feedback detail file URI (IPFS recommended).
     * @param feedbackHash  OPTIONAL — keccak256 of feedbackURI content for non-IPFS URIs.
     *
     * @dev   Caller MUST NOT be the agent owner or an approved operator of the agent.
     *        valueDecimals MUST be between 0 and 18.
     */
    function giveFeedback(
        uint256 agentId,
        int128  value,
        uint8   valueDecimals,
        string  calldata tag1,
        string  calldata tag2,
        string  calldata endpoint,
        string  calldata feedbackURI,
        bytes32 feedbackHash
    ) external {
        require(valueDecimals <= 18, "ReputationRegistry: valueDecimals > 18");

        // Guard: agent owner and its operators cannot self-review
        address agentOwner = _identityRegistry.ownerOf(agentId); // reverts if nonexistent
        require(msg.sender != agentOwner, "ReputationRegistry: owner cannot self-review");
        require(
            !_identityRegistry.isApprovedForAll(agentOwner, msg.sender),
            "ReputationRegistry: operator cannot self-review"
        );
        require(
            _identityRegistry.getApproved(agentId) != msg.sender,
            "ReputationRegistry: approved operator cannot self-review"
        );

        uint64 feedbackIndex = _lastIndex[agentId][msg.sender] + 1;
        _lastIndex[agentId][msg.sender] = feedbackIndex;

        _feedback[agentId][msg.sender][feedbackIndex] = FeedbackRecord({
            value:         value,
            valueDecimals: valueDecimals,
            tag1:          tag1,
            tag2:          tag2,
            isRevoked:     false
        });

        // Register client if first time
        if (!_isClient[agentId][msg.sender]) {
            _isClient[agentId][msg.sender] = true;
            _clients[agentId].push(msg.sender);
        }

        emit NewFeedback(
            agentId,
            msg.sender,
            feedbackIndex,
            value,
            valueDecimals,
            tag1,
            tag1,
            tag2,
            endpoint,
            feedbackURI,
            feedbackHash
        );
    }

    /**
     * @notice Revoke a previously submitted feedback entry.
     * @dev    Only the original submitter can revoke their own feedback.
     */
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external {
        FeedbackRecord storage rec = _feedback[agentId][msg.sender][feedbackIndex];
        require(rec.valueDecimals <= 18 && feedbackIndex > 0 &&
                feedbackIndex <= _lastIndex[agentId][msg.sender],
            "ReputationRegistry: nonexistent feedback");
        require(!rec.isRevoked, "ReputationRegistry: already revoked");

        rec.isRevoked = true;
        emit FeedbackRevoked(agentId, msg.sender, feedbackIndex);
    }

    /**
     * @notice Append a response to an existing feedback entry.
     *         Anyone can respond — e.g., the agent refuting a negative review,
     *         or an intelligence aggregator tagging it as spam.
     *
     * @param agentId        The agent the feedback was given to.
     * @param clientAddress  The original feedback submitter.
     * @param feedbackIndex  The 1-based index of the feedback.
     * @param responseURI    OPTIONAL — URI pointing to response detail (IPFS recommended).
     * @param responseHash   OPTIONAL — keccak256 of responseURI content (non-IPFS only).
     */
    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64  feedbackIndex,
        string  calldata responseURI,
        bytes32 responseHash
    ) external {
        require(
            feedbackIndex > 0 && feedbackIndex <= _lastIndex[agentId][clientAddress],
            "ReputationRegistry: nonexistent feedback"
        );

        ResponseInfo storage ri = _responses[agentId][clientAddress][feedbackIndex];
        ri.totalResponses += 1;
        ri.byResponder[msg.sender] += 1;

        emit ResponseAppended(agentId, clientAddress, feedbackIndex,
            msg.sender, responseURI, responseHash);
    }

    // ── Read: individual feedback ─────────────────────────────────────────────

    /**
     * @notice Read a single feedback entry.
     */
    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (
            int128  value,
            uint8   valueDecimals,
            string memory tag1,
            string memory tag2,
            bool    isRevoked
        )
    {
        require(
            feedbackIndex > 0 && feedbackIndex <= _lastIndex[agentId][clientAddress],
            "ReputationRegistry: nonexistent feedback"
        );
        FeedbackRecord storage rec = _feedback[agentId][clientAddress][feedbackIndex];
        return (rec.value, rec.valueDecimals, rec.tag1, rec.tag2, rec.isRevoked);
    }

    // ── Read: aggregate and bulk queries ─────────────────────────────────────

    /**
     * @notice Aggregate feedback summary across a whitelist of trusted clients.
     *         clientAddresses MUST be non-empty (Sybil protection per spec).
     *
     * @param agentId         Agent to query.
     * @param clientAddresses Trusted reviewer whitelist.
     * @param tag1            OPTIONAL — filter by tag1 (empty = no filter).
     * @param tag2            OPTIONAL — filter by tag2 (empty = no filter).
     *
     * @return count                 Number of matching non-revoked entries.
     * @return summaryValue          Sum of all matching values (scaled to summaryValueDecimals).
     * @return summaryValueDecimals  Decimal precision of summaryValue (fixed at 18).
     */
    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    )
        external
        view
        returns (
            uint64  count,
            int128  summaryValue,
            uint8   summaryValueDecimals
        )
    {
        require(clientAddresses.length > 0, "ReputationRegistry: empty clientAddresses");

        bool filterTag1 = bytes(tag1).length > 0;
        bool filterTag2 = bytes(tag2).length > 0;

        summaryValueDecimals = 18; // normalise everything to 18 decimals internally
        int256 acc = 0;

        for (uint256 i = 0; i < clientAddresses.length; i++) {
            address client = clientAddresses[i];
            uint64 last = _lastIndex[agentId][client];
            for (uint64 j = 1; j <= last; j++) {
                FeedbackRecord storage rec = _feedback[agentId][client][j];
                if (rec.isRevoked) continue;
                if (filterTag1 && keccak256(bytes(rec.tag1)) != keccak256(bytes(tag1))) continue;
                if (filterTag2 && keccak256(bytes(rec.tag2)) != keccak256(bytes(tag2))) continue;

                // Normalise to 18 decimal places
                int256 normalised = int256(rec.value);
                if (rec.valueDecimals < 18) {
                    normalised *= int256(10 ** uint256(18 - rec.valueDecimals));
                }
                acc += normalised;
                count++;
            }
        }
        summaryValue = int128(acc);
    }

    /**
     * @notice Bulk-read all feedback across a set of client addresses.
     *         Revoked entries are excluded by default unless includeRevoked is true.
     */
    function readAllFeedback(
        uint256 agentId,
        address[] calldata clientAddresses,
        string  calldata tag1,
        string  calldata tag2,
        bool    includeRevoked
    )
        external
        view
        returns (
            address[] memory clients,
            uint64[]  memory feedbackIndexes,
            int128[]  memory values,
            uint8[]   memory valueDecimals,
            string[]  memory tag1s,
            string[]  memory tag2s,
            bool[]    memory revokedStatuses
        )
    {
        // First pass: count matching entries
        uint256 total = _countMatching(agentId, clientAddresses, tag1, tag2, includeRevoked);

        clients         = new address[](total);
        feedbackIndexes = new uint64[](total);
        values          = new int128[](total);
        valueDecimals   = new uint8[](total);
        tag1s           = new string[](total);
        tag2s           = new string[](total);
        revokedStatuses = new bool[](total);

        bool filterTag1 = bytes(tag1).length > 0;
        bool filterTag2 = bytes(tag2).length > 0;
        uint256 idx = 0;

        for (uint256 i = 0; i < clientAddresses.length; i++) {
            address client = clientAddresses[i];
            uint64 last = _lastIndex[agentId][client];
            for (uint64 j = 1; j <= last; j++) {
                FeedbackRecord storage rec = _feedback[agentId][client][j];
                if (!includeRevoked && rec.isRevoked) continue;
                if (filterTag1 && keccak256(bytes(rec.tag1)) != keccak256(bytes(tag1))) continue;
                if (filterTag2 && keccak256(bytes(rec.tag2)) != keccak256(bytes(tag2))) continue;

                clients[idx]         = client;
                feedbackIndexes[idx] = j;
                values[idx]          = rec.value;
                valueDecimals[idx]   = rec.valueDecimals;
                tag1s[idx]           = rec.tag1;
                tag2s[idx]           = rec.tag2;
                revokedStatuses[idx] = rec.isRevoked;
                idx++;
            }
        }
    }

    /**
     * @notice Returns the number of responses appended to a feedback entry,
     *         optionally filtered by responder whitelist.
     */
    function getResponseCount(
        uint256 agentId,
        address clientAddress,
        uint64  feedbackIndex,
        address[] calldata responders
    ) external view returns (uint64 count) {
        ResponseInfo storage ri = _responses[agentId][clientAddress][feedbackIndex];
        if (responders.length == 0) {
            return ri.totalResponses;
        }
        for (uint256 i = 0; i < responders.length; i++) {
            count += ri.byResponder[responders[i]];
        }
    }

    /**
     * @notice Returns all client addresses that have ever given feedback to an agent.
     */
    function getClients(uint256 agentId) external view returns (address[] memory) {
        return _clients[agentId];
    }

    /**
     * @notice Returns the most recent feedback index for a given (agentId, clientAddress) pair.
     *         Returns 0 if no feedback has been submitted.
     */
    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64) {
        return _lastIndex[agentId][clientAddress];
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _countMatching(
        uint256 agentId,
        address[] calldata clientAddresses,
        string  calldata tag1,
        string  calldata tag2,
        bool    includeRevoked
    ) internal view returns (uint256 total) {
        bool filterTag1 = bytes(tag1).length > 0;
        bool filterTag2 = bytes(tag2).length > 0;
        for (uint256 i = 0; i < clientAddresses.length; i++) {
            address client = clientAddresses[i];
            uint64 last = _lastIndex[agentId][client];
            for (uint64 j = 1; j <= last; j++) {
                FeedbackRecord storage rec = _feedback[agentId][client][j];
                if (!includeRevoked && rec.isRevoked) continue;
                if (filterTag1 && keccak256(bytes(rec.tag1)) != keccak256(bytes(tag1))) continue;
                if (filterTag2 && keccak256(bytes(rec.tag2)) != keccak256(bytes(tag2))) continue;
                total++;
            }
        }
    }
}
