// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AgentValidationRegistry
 * @notice ERC-8004 Validation Registry — enables agents to request independent
 *         verification of their work from validator contracts, and validators to
 *         post their responses on-chain.
 *
 *         Validators could implement:
 *           • Stake-secured inference re-execution
 *           • Zero-knowledge machine learning (zkML) verifiers
 *           • Trusted Execution Environment (TEE) oracles
 *           • Trusted human judges
 *
 *         Incentives and slashing are managed by the specific validation protocol
 *         and are intentionally out of scope for this registry.
 *
 * Reference: https://eips.ethereum.org/EIPS/eip-8004
 */

interface IAgentIdentityRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function getApproved(uint256 tokenId) external view returns (address);
}

contract AgentValidationRegistry {

    // ── Events ────────────────────────────────────────────────────────────────

    /**
     * @notice Emitted when an agent requests validation.
     * @dev    requestHash is the keccak256 commitment to the request payload
     *         and is used as the canonical request identifier.
     */
    event ValidationRequest(
        address indexed validatorAddress,
        uint256 indexed agentId,
        string          requestURI,
        bytes32 indexed requestHash
    );

    /**
     * @notice Emitted when a validator posts a response.
     * @dev    validationResponse() may be called multiple times for the same
     *         requestHash (e.g., soft-finality then hard-finality).
     */
    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8           response,
        string          responseURI,
        bytes32         responseHash,
        string          tag
    );

    // ── Storage ───────────────────────────────────────────────────────────────

    /// @dev On-chain state of a validation request after a response is recorded.
    struct ValidationRecord {
        address validatorAddress;
        uint256 agentId;
        uint8   response;     // 0–100: 0=fail, 100=pass, intermediate = partial
        bytes32 responseHash; // keccak256 of responseURI content (optional for IPFS)
        string  tag;          // Custom categorisation or finality marker
        uint256 lastUpdate;   // block.timestamp of most recent response
    }

    /// @dev Lightweight request info stored when a request is first submitted.
    struct RequestRecord {
        address validatorAddress;
        uint256 agentId;
        bool    exists;
    }

    // requestHash => full validation record (populated when validator responds)
    mapping(bytes32 => ValidationRecord) private _validations;

    // requestHash => lightweight request info
    mapping(bytes32 => RequestRecord) private _requests;

    // agentId => list of requestHashes
    mapping(uint256 => bytes32[]) private _agentValidations;

    // validatorAddress => list of requestHashes
    mapping(address => bytes32[]) private _validatorRequests;

    // Identity registry reference
    IAgentIdentityRegistry private immutable _identityRegistry;

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param identityRegistry_ Address of the deployed AgentIdentityRegistry.
     */
    constructor(address identityRegistry_) {
        require(identityRegistry_ != address(0), "ValidationRegistry: zero address");
        _identityRegistry = IAgentIdentityRegistry(identityRegistry_);
    }

    // ── Read: registry reference ──────────────────────────────────────────────

    /// @notice Returns the associated identity registry address.
    function getIdentityRegistry() external view returns (address) {
        return address(_identityRegistry);
    }

    // ── Write: validation lifecycle ───────────────────────────────────────────

    /**
     * @notice Request validation from a specific validator contract.
     *
     * @param validatorAddress  Address of the validator smart contract to invoke.
     * @param agentId           The agent requesting validation (must be owned/approved by caller).
     * @param requestURI        URI to off-chain data containing inputs/outputs for verification.
     * @param requestHash       keccak256 commitment to the request payload (canonical identifier).
     *
     * @dev   All parameters are mandatory. Caller must be owner or approved operator of agentId.
     *        requestHash uniquely identifies the request; re-using one overwrites prior data.
     */
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string  calldata requestURI,
        bytes32 requestHash
    ) external {
        require(validatorAddress != address(0), "ValidationRegistry: zero validator");
        require(requestHash != bytes32(0),      "ValidationRegistry: empty requestHash");

        // Auth: only agent owner or approved operator may request validation
        address agentOwner = _identityRegistry.ownerOf(agentId); // reverts if nonexistent
        require(
            msg.sender == agentOwner ||
            _identityRegistry.isApprovedForAll(agentOwner, msg.sender) ||
            _identityRegistry.getApproved(agentId) == msg.sender,
            "ValidationRegistry: not owner or operator"
        );

        bool isNew = !_requests[requestHash].exists;
        _requests[requestHash] = RequestRecord({
            validatorAddress: validatorAddress,
            agentId:          agentId,
            exists:           true
        });

        if (isNew) {
            _agentValidations[agentId].push(requestHash);
            _validatorRequests[validatorAddress].push(requestHash);
        }

        emit ValidationRequest(validatorAddress, agentId, requestURI, requestHash);
    }

    /**
     * @notice Record a validation response for an existing request.
     *
     * @param requestHash   The canonical identifier of the request being responded to.
     * @param response      Validation result 0–100 (0 = fail, 100 = pass).
     * @param responseURI   OPTIONAL — URI to off-chain evidence / audit.
     * @param responseHash  OPTIONAL — keccak256 of responseURI content (non-IPFS only).
     * @param tag           OPTIONAL — custom tag (e.g., "soft-finality", "hard-finality").
     *
     * @dev   Only the validatorAddress specified in the original request may call this.
     *        May be called multiple times per requestHash (progressive validation states).
     *        response MUST be between 0 and 100 inclusive.
     */
    function validationResponse(
        bytes32 requestHash,
        uint8   response,
        string  calldata responseURI,
        bytes32 responseHash,
        string  calldata tag
    ) external {
        require(_requests[requestHash].exists,   "ValidationRegistry: unknown request");
        require(response <= 100,                 "ValidationRegistry: response > 100");
        RequestRecord storage req = _requests[requestHash];
        require(msg.sender == req.validatorAddress,
            "ValidationRegistry: caller is not the designated validator");

        _validations[requestHash] = ValidationRecord({
            validatorAddress: msg.sender,
            agentId:          req.agentId,
            response:         response,
            responseHash:     responseHash,
            tag:              tag,
            lastUpdate:       block.timestamp
        });

        emit ValidationResponse(
            msg.sender,
            req.agentId,
            requestHash,
            response,
            responseURI,
            responseHash,
            tag
        );
    }

    // ── Read: individual validation status ────────────────────────────────────

    /**
     * @notice Returns the full on-chain state for a validation request.
     * @dev    If the validator has not responded yet, response will be 0 and
     *         lastUpdate will be 0.
     */
    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8   response,
            bytes32 responseHashOut,
            string memory tag,
            uint256 lastUpdate
        )
    {
        require(_requests[requestHash].exists, "ValidationRegistry: unknown request");
        ValidationRecord storage v = _validations[requestHash];
        RequestRecord    storage r = _requests[requestHash];
        validatorAddress = r.validatorAddress;
        agentId          = r.agentId;
        response         = v.response;
        responseHashOut  = v.responseHash;
        tag              = v.tag;
        lastUpdate       = v.lastUpdate;
    }

    // ── Read: aggregate validation statistics ─────────────────────────────────

    /**
     * @notice Returns aggregate validation statistics for an agent.
     *
     * @param agentId           The agent to query.
     * @param validatorAddresses OPTIONAL whitelist of validators (empty = all).
     * @param tag               OPTIONAL tag filter (empty = all).
     *
     * @return count            Number of matching validation records.
     * @return averageResponse  Average response value across matching records (0-100).
     */
    function getSummary(
        uint256 agentId,
        address[] calldata validatorAddresses,
        string  calldata tag
    )
        external
        view
        returns (uint64 count, uint8 averageResponse)
    {
        bytes32[] storage hashes = _agentValidations[agentId];
        bool filterValidator = validatorAddresses.length > 0;
        bool filterTag       = bytes(tag).length > 0;

        uint256 total = 0;

        for (uint256 i = 0; i < hashes.length; i++) {
            bytes32 h = hashes[i];
            ValidationRecord storage v = _validations[h];
            if (v.lastUpdate == 0) continue; // no response yet

            if (filterValidator && !_inArray(v.validatorAddress, validatorAddresses)) continue;
            if (filterTag && keccak256(bytes(v.tag)) != keccak256(bytes(tag))) continue;

            total += v.response;
            count++;
        }

        if (count > 0) {
            averageResponse = uint8(total / count);
        }
    }

    /**
     * @notice Returns all requestHashes associated with a given agent.
     */
    function getAgentValidations(uint256 agentId)
        external
        view
        returns (bytes32[] memory)
    {
        return _agentValidations[agentId];
    }

    /**
     * @notice Returns all requestHashes associated with a given validator.
     */
    function getValidatorRequests(address validatorAddress)
        external
        view
        returns (bytes32[] memory)
    {
        return _validatorRequests[validatorAddress];
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _inArray(address target, address[] calldata arr) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == target) return true;
        }
        return false;
    }
}
