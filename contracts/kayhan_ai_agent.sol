// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title KayhanAIAgent
 * @notice ERC-8004 end-to-end demonstration contract.
 *
 *         This contract showcases how the three ERC-8004 registries work together
 *         to create a complete on-chain AI agent economy:
 *
 *           1. AgentIdentityRegistry  — mint/register agents as ERC-721 NFTs
 *           2. AgentReputationRegistry — submit, read, and aggregate feedback
 *           3. AgentValidationRegistry — request and record independent validation
 *
 *         It also implements a minimal example of a Validator contract that can
 *         respond to validation requests (simulating a zkML / TEE validator).
 *
 * Reference: https://eips.ethereum.org/EIPS/eip-8004
 *
 * ┌─────────────────────────────────────────────────────────────────┐
 * │  Deploy flow:                                                    │
 * │                                                                 │
 * │  1. Deploy AgentIdentityRegistry                                │
 * │  2. Deploy AgentReputationRegistry(identityRegistry)            │
 * │  3. Deploy AgentValidationRegistry(identityRegistry)            │
 * │  4. Deploy KayhanAIAgent(identity, reputation, validation)      │
 * │                                                                 │
 * │  The KayhanAIAgent owner can then:                              │
 * │    • registerAgent()     — mint a new agent NFT                 │
 * │    • updateAgentURI()    — update the agent's registration file │
 * │    • requestValidation() — request off-chain validation         │
 * │                                                                 │
 * │  Anyone can:                                                    │
 * │    • getAgentScore()     — query aggregated reputation score    │
 * │                                                                 │
 * │  Feedback is not proxied here (ERC-8004 binds the reviewer to   │
 * │  msg.sender): clients call the Reputation Registry directly.    │
 * └─────────────────────────────────────────────────────────────────┘
 */

// ─── Registry interfaces ──────────────────────────────────────────────────────

interface IAgentIdentityRegistry {
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    function register(
        string calldata agentURI,
        MetadataEntry[] calldata metadata
    ) external returns (uint256 agentId);

    function register(
        string calldata agentURI
    ) external returns (uint256 agentId);

    function setAgentURI(uint256 agentId, string calldata newURI) external;

    function getMetadata(
        uint256 agentId,
        string memory metadataKey
    ) external view returns (bytes memory);

    function setMetadata(
        uint256 agentId,
        string memory metadataKey,
        bytes memory metadataValue
    ) external;

    function getAgentWallet(uint256 agentId) external view returns (address);

    function ownerOf(uint256 agentId) external view returns (address);

    function tokenURI(uint256 agentId) external view returns (string memory);
}

/**
 * Read-only view of the reputation registry.
 *
 * The demo deliberately exposes no way to *write* feedback: ERC-8004 records
 * the reviewer as `msg.sender`, so a forwarding contract can never submit
 * feedback on behalf of a real client — the entry would be attributed to the
 * contract itself. Clients call the registry directly.
 */
interface IAgentReputationRegistry {
    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    )
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);

    function getClients(
        uint256 agentId
    ) external view returns (address[] memory);

    function getLastIndex(
        uint256 agentId,
        address clientAddress
    ) external view returns (uint64);
}

interface IAgentValidationRegistry {
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external;

    function getValidationStatus(
        bytes32 requestHash
    )
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );

    function getSummary(
        uint256 agentId,
        address[] calldata validatorAddresses,
        string calldata tag
    ) external view returns (uint64 count, uint8 averageResponse);
}

// ─── KayhanAIAgent ────────────────────────────────────────────────────────────

contract KayhanAIAgent {
    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted when a new agent is registered through this contract.
    event AgentRegistered(
        uint256 indexed agentId,
        string agentURI,
        address indexed owner
    );

    /// @notice Emitted when a validation request is created via this contract.
    event ValidationRequested(
        uint256 indexed agentId,
        address indexed validatorAddress,
        bytes32 requestHash
    );

    // ── State ─────────────────────────────────────────────────────────────────

    address public immutable owner;

    IAgentIdentityRegistry public immutable identityRegistry;
    IAgentReputationRegistry public immutable reputationRegistry;
    IAgentValidationRegistry public immutable validationRegistry;

    /// @notice Agents registered through this demonstration contract.
    uint256[] public registeredAgents;

    /// @notice Maps agentId => agent name (human-readable, stored on-chain for demo).
    mapping(uint256 => string) public agentNames;

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "KayhanAIAgent: not owner");
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param identityRegistry_   Deployed AgentIdentityRegistry address.
     * @param reputationRegistry_ Deployed AgentReputationRegistry address.
     * @param validationRegistry_ Deployed AgentValidationRegistry address.
     */
    constructor(
        address identityRegistry_,
        address reputationRegistry_,
        address validationRegistry_
    ) {
        require(
            identityRegistry_ != address(0),
            "KayhanAIAgent: zero identity address"
        );
        require(
            reputationRegistry_ != address(0),
            "KayhanAIAgent: zero reputation address"
        );
        require(
            validationRegistry_ != address(0),
            "KayhanAIAgent: zero validation address"
        );

        owner = msg.sender;
        identityRegistry = IAgentIdentityRegistry(identityRegistry_);
        reputationRegistry = IAgentReputationRegistry(reputationRegistry_);
        validationRegistry = IAgentValidationRegistry(validationRegistry_);
    }

    // ── Agent Registration ────────────────────────────────────────────────────

    /**
     * @notice Register a new AI agent in the Identity Registry.
     *
     *         The agentURI should resolve to an ERC-8004 registration file:
     *         https://eips.ethereum.org/EIPS/eip-8004#registration-v1
     *
     *         Supported URI schemes:
     *           • ipfs://QmCID             (recommended — content-addressed)
     *           • https://example.com/agent.json
     *           • data:application/json;base64,...  (fully on-chain)
     *
     * @param agentURI  URI pointing to the agent's registration JSON file.
     * @param agentName Human-readable name stored on-chain for demo purposes.
     * @param modelName AI model identifier (e.g., "gemini-2.5-pro") — stored as metadata.
     *
     * @dev    The agent NFT is minted to *this* contract, which is what lets it
     *         call `requestValidation()`. Because the contract owns the agent it
     *         must never review it — see the Reputation section below.
     *
     * @return agentId  The ERC-721 tokenId of the newly registered agent.
     */
    function registerAgent(
        string calldata agentURI,
        string calldata agentName,
        string calldata modelName
    ) external onlyOwner returns (uint256 agentId) {
        // Build metadata entries
        IAgentIdentityRegistry.MetadataEntry[]
            memory meta = new IAgentIdentityRegistry.MetadataEntry[](2);

        meta[0] = IAgentIdentityRegistry.MetadataEntry({
            metadataKey: "name",
            metadataValue: bytes(agentName)
        });
        meta[1] = IAgentIdentityRegistry.MetadataEntry({
            metadataKey: "model",
            metadataValue: bytes(modelName)
        });

        agentId = identityRegistry.register(agentURI, meta);

        registeredAgents.push(agentId);
        agentNames[agentId] = agentName;

        emit AgentRegistered(agentId, agentURI, msg.sender);
    }

    /**
     * @notice Update the registration file URI for an existing agent.
     * @dev    Use a base64-encoded data URI to store the registration file fully on-chain.
     */
    function updateAgentURI(
        uint256 agentId,
        string calldata newURI
    ) external onlyOwner {
        identityRegistry.setAgentURI(agentId, newURI);
    }

    /**
     * @notice Set arbitrary on-chain metadata for an agent.
     * @dev    Cannot set the reserved "agentWallet" key — use the registry directly.
     */
    function setAgentMetadata(
        uint256 agentId,
        string calldata key,
        bytes calldata value
    ) external onlyOwner {
        identityRegistry.setMetadata(agentId, key, value);
    }

    // ── Reputation (read-only) ────────────────────────────────────────────────

    // Feedback is intentionally NOT proxied by this contract.
    //
    // AgentReputationRegistry records the reviewer as `msg.sender`, and blocks
    // the agent's owner and its operators from self-reviewing. A forwarding
    // contract can therefore never submit feedback *on behalf of* a real client:
    // the entry would be attributed to the contract itself (and rejected outright
    // whenever the contract owns the agent). Clients must call
    // `AgentReputationRegistry.giveFeedback()` directly and self-identify as the
    // reviewer. This contract only aggregates the resulting scores for reading.

    /**
     * @notice Read the aggregated reputation score for an agent across all clients.
     * @dev    Requires a non-empty clientAddresses list to prevent Sybil attacks
     *         (per ERC-8004 spec). Use the Reputation Registry's getClients() to
     *         iteratively build trusted reviewer sets. The feedback entries
     *         themselves are submitted directly to the Reputation Registry.
     *
     * @param agentId         Target agent.
     * @param clientAddresses Trusted reviewer whitelist.
     * @param tag1            OPTIONAL tag filter.
     * @param tag2            OPTIONAL tag filter.
     *
     * @return count                 Number of matching non-revoked feedback entries.
     * @return summaryValue          Aggregate value normalised to 18 decimal places.
     * @return summaryValueDecimals  Always 18.
     */
    function getAgentScore(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    )
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals)
    {
        return
            reputationRegistry.getSummary(agentId, clientAddresses, tag1, tag2);
    }

    // ── Validation ────────────────────────────────────────────────────────────

    /**
     * @notice Request independent validation of an agent's output.
     *
     *         The requestHash is the canonical identifier for this validation job.
     *         It MUST be a keccak256 commitment to the payload at requestURI so
     *         the validator can verify integrity.
     *
     *         Example:
     *           bytes32 hash = keccak256(abi.encodePacked(agentId, taskOutput));
     *
     * @param agentId          Agent whose work is being validated.
     * @param validatorAddress Validator contract to route the request to.
     * @param requestURI       Off-chain data URI (IPFS recommended) containing
     *                         all inputs/outputs the validator needs.
     * @param requestHash      keccak256 commitment to the request payload.
     */
    function requestValidation(
        uint256 agentId,
        address validatorAddress,
        string calldata requestURI,
        bytes32 requestHash
    ) external onlyOwner {
        validationRegistry.validationRequest(
            validatorAddress,
            agentId,
            requestURI,
            requestHash
        );
        emit ValidationRequested(agentId, validatorAddress, requestHash);
    }

    /**
     * @notice Check the status of a previously submitted validation request.
     */
    function checkValidation(
        bytes32 requestHash
    )
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        )
    {
        return validationRegistry.getValidationStatus(requestHash);
    }

    /**
     * @notice Get aggregate validation stats for an agent across all its requests.
     * @param  agentId           Target agent.
     * @param  validatorAddresses OPTIONAL whitelist of trusted validators.
     * @param  tag               OPTIONAL tag filter (e.g., "hard-finality").
     *
     * @return count            Number of matching validated requests.
     * @return averageResponse  Average response score (0-100).
     */
    function getValidationScore(
        uint256 agentId,
        address[] calldata validatorAddresses,
        string calldata tag
    ) external view returns (uint64 count, uint8 averageResponse) {
        return validationRegistry.getSummary(agentId, validatorAddresses, tag);
    }

    // ── Enumeration ──────────────────────────────────────────────────────────

    /// @notice Returns the list of all agentIds registered through this contract.
    function getRegisteredAgents() external view returns (uint256[] memory) {
        return registeredAgents;
    }

    /// @notice Returns the number of agents registered through this contract.
    function agentCount() external view returns (uint256) {
        return registeredAgents.length;
    }

    /// @notice Returns the full on-chain info for an agent.
    function getAgentInfo(
        uint256 agentId
    )
        external
        view
        returns (
            address agentOwner,
            string memory agentURI,
            string memory agentName,
            address agentWallet,
            bytes memory modelName
        )
    {
        agentOwner = identityRegistry.ownerOf(agentId);
        agentURI = identityRegistry.tokenURI(agentId);
        agentName = agentNames[agentId];
        agentWallet = identityRegistry.getAgentWallet(agentId);
        modelName = identityRegistry.getMetadata(agentId, "model");
    }
}

// ─── ExampleValidator ─────────────────────────────────────────────────────────

/**
 * @title ExampleValidator
 * @notice A minimal validator contract for demonstration purposes.
 *
 *         In production, validators would implement one of:
 *           • Stake-secured re-execution (others run the same task and compare)
 *           • zkML proof verification (zero-knowledge ML proofs)
 *           • TEE oracle (Trusted Execution Environment attestation)
 *           • Trusted human judges with EIP-712 signed verdicts
 *
 *         This example simulates a simple "trusted oracle" validator where
 *         the contract owner submits pass/fail results.
 */
interface IValidationRegistry {
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external;
}

contract ExampleValidator {
    address public immutable owner;
    IValidationRegistry public immutable validationRegistry;

    event ValidationCompleted(
        bytes32 indexed requestHash,
        uint8 response,
        string tag
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "ExampleValidator: not owner");
        _;
    }

    constructor(address validationRegistry_) {
        require(
            validationRegistry_ != address(0),
            "ExampleValidator: zero address"
        );
        owner = msg.sender;
        validationRegistry = IValidationRegistry(validationRegistry_);
    }

    /**
     * @notice Submit a validation response.
     *
     * @param requestHash  The hash identifying the validation request.
     * @param response     Score 0-100 (0=fail, 100=pass, intermediate=partial).
     * @param responseURI  OPTIONAL — URI to off-chain evidence (IPFS recommended).
     * @param responseHash OPTIONAL — keccak256 of responseURI content.
     * @param tag          OPTIONAL — finality marker, e.g. "soft-finality" / "hard-finality".
     */
    function submitValidation(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external onlyOwner {
        require(response <= 100, "ExampleValidator: response > 100");
        validationRegistry.validationResponse(
            requestHash,
            response,
            responseURI,
            responseHash,
            tag
        );
        emit ValidationCompleted(requestHash, response, tag);
    }

    function f(uint8 _in) public pure returns (uint8 out) {
        out = _in;
    }

    function f(uint256 _in) public pure returns (uint256 out) {
        out = _in;
    }

    /**
     * @notice Convenience: submit a binary pass/fail with an optional IPFS evidence link.
     * @param requestHash  The request to validate.
     * @param passed       true = 100 (pass), false = 0 (fail).
     * @param evidenceURI  OPTIONAL IPFS URI with validation evidence.
     */
    function submitBinaryResult(
        bytes32 requestHash,
        bool passed,
        string calldata evidenceURI
    ) external onlyOwner {
        uint8 response = passed ? 100 : 0;
        validationRegistry.validationResponse(
            requestHash,
            response,
            evidenceURI,
            bytes32(0), // IPFS — no hash needed
            passed ? "pass" : "fail"
        );
        emit ValidationCompleted(
            requestHash,
            response,
            passed ? "pass" : "fail"
        );
    }
}
