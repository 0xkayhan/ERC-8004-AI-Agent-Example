// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AgentIdentityRegistry
 * @notice ERC-8004 Identity Registry — registers AI agents as ERC-721 NFTs.
 *         Each token (agentId) points to an agent registration file (agentURI)
 *         that describes the agent's capabilities, endpoints, and supported
 *         trust models (reputation, crypto-economic, TEE attestation).
 *
 * @dev    Implements ERC-721 with URI storage, on-chain metadata key/value store,
 *         and EIP-712 verified agent wallet management.
 *
 * Reference: https://eips.ethereum.org/EIPS/eip-8004
 */

// ─── Minimal ERC-721 interfaces ──────────────────────────────────────────────

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC721 is IERC165 {
    event Transfer(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId
    );
    event Approval(
        address indexed owner,
        address indexed approved,
        uint256 indexed tokenId
    );
    event ApprovalForAll(
        address indexed owner,
        address indexed operator,
        bool approved
    );

    function balanceOf(address owner) external view returns (uint256);

    function ownerOf(uint256 tokenId) external view returns (address);

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function transferFrom(address from, address to, uint256 tokenId) external;

    function approve(address to, uint256 tokenId) external;

    function setApprovalForAll(address operator, bool approved) external;

    function getApproved(uint256 tokenId) external view returns (address);

    function isApprovedForAll(
        address owner,
        address operator
    ) external view returns (bool);
}

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

interface IERC721Metadata is IERC721 {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function tokenURI(uint256 tokenId) external view returns (string memory);
}

// ─── ERC-1271 interface (smart-contract wallet signature validation) ──────────

interface IERC1271 {
    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    ) external view returns (bytes4);
}

// ─── AgentIdentityRegistry ────────────────────────────────────────────────────

contract AgentIdentityRegistry is IERC721Metadata {
    // ── ERC-8004 Events ───────────────────────────────────────────────────────

    /// @notice Emitted when a new agent is registered (minted).
    event Registered(
        uint256 indexed agentId,
        string agentURI,
        address indexed owner
    );

    /// @notice Emitted when an agent's URI is updated.
    event URIUpdated(
        uint256 indexed agentId,
        string newURI,
        address indexed updatedBy
    );

    /// @notice Emitted when on-chain metadata is set for an agent.
    event MetadataSet(
        uint256 indexed agentId,
        string indexed indexedMetadataKey,
        string metadataKey,
        bytes metadataValue
    );

    // ── ERC-721 Events (already declared in IERC721) ──────────────────────────

    // ── Storage ───────────────────────────────────────────────────────────────

    string private constant _NAME = "ERC-8004 AI Agent Registry";
    string private constant _SYMBOL = "AGENT";

    // Reserved metadata key for payment wallet
    string private constant KEY_AGENT_WALLET = "agentWallet";

    // EIP-712 type hash for setAgentWallet
    bytes32 private constant SET_WALLET_TYPEHASH =
        keccak256(
            "SetAgentWallet(uint256 agentId,address newWallet,uint256 deadline,uint256 nonce)"
        );

    // EIP-712 domain separator (set at construction)
    bytes32 private immutable _DOMAIN_SEPARATOR;

    // Auto-incrementing token counter (starts at 1)
    uint256 private _nextId = 1;

    // ERC-721 core mappings
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // agentId => agentURI (registration file pointer)
    mapping(uint256 => string) private _agentURIs;

    // agentId => key => value  (generic on-chain metadata)
    mapping(uint256 => mapping(string => bytes)) private _metadata;

    // agentId => payment wallet   (separate from NFT owner)
    mapping(uint256 => address) private _agentWallets;

    // agentId => nonce  (replay-protection for setAgentWallet)
    mapping(uint256 => uint256) private _walletNonces;

    // ── Structs ───────────────────────────────────────────────────────────────

    /// @notice Key-value metadata entry used during registration.
    struct MetadataEntry {
        string metadataKey;
        bytes metadataValue;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor() {
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(_NAME)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    // ── ERC-165 ───────────────────────────────────────────────────────────────

    function supportsInterface(
        bytes4 interfaceId
    ) external pure override returns (bool) {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    // ── ERC-721 Metadata ──────────────────────────────────────────────────────

    function name() external pure override returns (string memory) {
        return _NAME;
    }

    function symbol() external pure override returns (string memory) {
        return _SYMBOL;
    }

    /// @notice Returns the agentURI for a given agentId (ERC-721 tokenURI).
    function tokenURI(
        uint256 agentId
    ) external view override returns (string memory) {
        require(
            _owners[agentId] != address(0),
            "AgentIdentityRegistry: nonexistent agent"
        );
        return _agentURIs[agentId];
    }

    // ── ERC-721 Core ──────────────────────────────────────────────────────────

    function balanceOf(address owner) external view override returns (uint256) {
        require(owner != address(0), "AgentIdentityRegistry: zero address");
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) external view override returns (address) {
        address owner = _owners[tokenId];
        require(
            owner != address(0),
            "AgentIdentityRegistry: nonexistent token"
        );
        return owner;
    }

    function approve(address to, uint256 tokenId) external override {
        address owner = _owners[tokenId];
        require(
            msg.sender == owner || _operatorApprovals[owner][msg.sender],
            "AgentIdentityRegistry: not owner or operator"
        );
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function getApproved(
        uint256 tokenId
    ) external view override returns (address) {
        require(
            _owners[tokenId] != address(0),
            "AgentIdentityRegistry: nonexistent token"
        );
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(
        address operator,
        bool approved
    ) external override {
        require(operator != msg.sender, "AgentIdentityRegistry: self approval");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(
        address owner,
        address operator
    ) external view override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external override {
        require(
            _isApprovedOrOwner(msg.sender, tokenId),
            "AgentIdentityRegistry: not approved"
        );
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external override {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public override {
        require(
            _isApprovedOrOwner(msg.sender, tokenId),
            "AgentIdentityRegistry: not approved"
        );
        _transfer(from, to, tokenId);
        if (to.code.length > 0) {
            bytes4 retval = IERC721Receiver(to).onERC721Received(
                msg.sender,
                from,
                tokenId,
                data
            );
            require(
                retval == IERC721Receiver.onERC721Received.selector,
                "AgentIdentityRegistry: unsafe recipient"
            );
        }
    }

    // ── ERC-8004 Registration ─────────────────────────────────────────────────

    /**
     * @notice Register a new AI agent with a URI and optional metadata entries.
     * @param  agentURI  URI pointing to the ERC-8004 registration file.
     * @param  metadata  Array of key/value metadata pairs stored on-chain.
     * @return agentId   The assigned ERC-721 tokenId for the new agent.
     */
    function register(
        string calldata agentURI,
        MetadataEntry[] calldata metadata
    ) external returns (uint256 agentId) {
        agentId = _mint(msg.sender, agentURI);
        for (uint256 i = 0; i < metadata.length; i++) {
            _setMetadata(
                agentId,
                metadata[i].metadataKey,
                metadata[i].metadataValue
            );
        }
    }

    /**
     * @notice Register a new AI agent with only a URI (no extra metadata).
     */
    function register(
        string calldata agentURI
    ) external returns (uint256 agentId) {
        agentId = _mint(msg.sender, agentURI);
    }

    /**
     * @notice Register a new AI agent shell — URI can be added later via setAgentURI.
     */
    function register() external returns (uint256 agentId) {
        agentId = _mint(msg.sender, "");
    }

    // ── ERC-8004 URI Management ───────────────────────────────────────────────

    /**
     * @notice Update the registration file URI for an agent.
     * @dev    Caller must be owner or approved operator.
     */
    function setAgentURI(uint256 agentId, string calldata newURI) external {
        require(
            _isOwnerOrOperator(msg.sender, agentId),
            "AgentIdentityRegistry: not owner or operator"
        );
        _agentURIs[agentId] = newURI;
        emit URIUpdated(agentId, newURI, msg.sender);
    }

    // ── ERC-8004 On-chain Metadata ────────────────────────────────────────────

    /**
     * @notice Read a metadata value for a given agent and key.
     */
    function getMetadata(
        uint256 agentId,
        string memory metadataKey
    ) external view returns (bytes memory) {
        return _metadata[agentId][metadataKey];
    }

    /**
     * @notice Set a metadata key/value for a given agent.
     * @dev    The key "agentWallet" is reserved; use setAgentWallet() instead.
     *         Caller must be owner or approved operator.
     */
    function setMetadata(
        uint256 agentId,
        string memory metadataKey,
        bytes memory metadataValue
    ) external {
        require(
            _isOwnerOrOperator(msg.sender, agentId),
            "AgentIdentityRegistry: not owner or operator"
        );
        require(
            keccak256(bytes(metadataKey)) != keccak256(bytes(KEY_AGENT_WALLET)),
            "AgentIdentityRegistry: agentWallet is reserved, use setAgentWallet()"
        );
        _setMetadata(agentId, metadataKey, metadataValue);
    }

    // ── ERC-8004 Agent Wallet Management ─────────────────────────────────────

    /**
     * @notice Returns the agent's designated payment wallet address.
     *         Falls back to the NFT owner if no wallet has been set.
     */
    function getAgentWallet(uint256 agentId) external view returns (address) {
        address wallet = _agentWallets[agentId];
        return wallet != address(0) ? wallet : _owners[agentId];
    }

    /**
     * @notice Clear the agent wallet override (reverts to NFT owner as receiver).
     * @dev    Caller must be owner or approved operator.
     */
    function unsetAgentWallet(uint256 agentId) external {
        require(
            _isOwnerOrOperator(msg.sender, agentId),
            "AgentIdentityRegistry: not owner or operator"
        );
        _clearAgentWallet(agentId);
    }

    /**
     * @notice Set a new payment wallet for an agent, verified by EIP-712 signature
     *         (EOA) or ERC-1271 (smart contract wallet).
     * @dev    The NEW wallet must sign the structured data proving control.
     *         Caller must be owner or approved operator of the agent.
     * @param  agentId    The agent to update.
     * @param  newWallet  The new payment wallet address.
     * @param  deadline   Unix timestamp after which the signature is invalid.
     * @param  signature  EIP-712 or ERC-1271 signature from newWallet.
     */
    function setAgentWallet(
        uint256 agentId,
        address newWallet,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(
            _isOwnerOrOperator(msg.sender, agentId),
            "AgentIdentityRegistry: not owner or operator"
        );
        require(
            block.timestamp <= deadline,
            "AgentIdentityRegistry: signature expired"
        );
        require(newWallet != address(0), "AgentIdentityRegistry: zero wallet");

        uint256 nonce = _walletNonces[agentId];
        bytes32 structHash = keccak256(
            abi.encode(SET_WALLET_TYPEHASH, agentId, newWallet, deadline, nonce)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash)
        );

        // Accept ERC-1271 (smart contract) or ECDSA (EOA) signatures
        if (newWallet.code.length > 0) {
            bytes4 result = IERC1271(newWallet).isValidSignature(
                digest,
                signature
            );
            require(
                result == IERC1271.isValidSignature.selector,
                "AgentIdentityRegistry: invalid ERC-1271 signature"
            );
        } else {
            address recovered = _recoverSigner(digest, signature);
            require(
                recovered == newWallet,
                "AgentIdentityRegistry: invalid ECDSA signature"
            );
        }

        _walletNonces[agentId] = nonce + 1;
        _agentWallets[agentId] = newWallet;

        // Store in the reserved metadata slot as well for composability
        emit MetadataSet(
            agentId,
            KEY_AGENT_WALLET,
            KEY_AGENT_WALLET,
            abi.encodePacked(newWallet)
        );
    }

    /**
     * @notice Returns the current EIP-712 nonce for wallet signature replay protection.
     */
    function walletNonce(uint256 agentId) external view returns (uint256) {
        return _walletNonces[agentId];
    }

    /**
     * @notice Returns the EIP-712 domain separator for this registry.
     */
    function domainSeparator() external view returns (bytes32) {
        return _DOMAIN_SEPARATOR;
    }

    // ── Internal Helpers ──────────────────────────────────────────────────────

    function _mint(
        address to,
        string memory uri
    ) internal returns (uint256 agentId) {
        agentId = _nextId++;
        _owners[agentId] = to;
        _balances[to] += 1;
        _agentURIs[agentId] = uri;

        emit Transfer(address(0), to, agentId);
        emit Registered(agentId, uri, to);

        // Emit MetadataSet for the initial agentWallet (= owner at mint time)
        emit MetadataSet(
            agentId,
            KEY_AGENT_WALLET,
            KEY_AGENT_WALLET,
            abi.encodePacked(to)
        );
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        require(_owners[tokenId] == from, "AgentIdentityRegistry: wrong owner");
        require(to != address(0), "AgentIdentityRegistry: zero recipient");

        // Clear approval
        delete _tokenApprovals[tokenId];

        // Clear agentWallet — new owner must re-verify
        _clearAgentWallet(tokenId);

        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    function _setMetadata(
        uint256 agentId,
        string memory key,
        bytes memory value
    ) internal {
        _metadata[agentId][key] = value;
        emit MetadataSet(agentId, key, key, value);
    }

    function _clearAgentWallet(uint256 agentId) internal {
        if (_agentWallets[agentId] != address(0)) {
            delete _agentWallets[agentId];
            emit MetadataSet(
                agentId,
                KEY_AGENT_WALLET,
                KEY_AGENT_WALLET,
                bytes("")
            );
        }
    }

    function _isApprovedOrOwner(
        address spender,
        uint256 tokenId
    ) internal view returns (bool) {
        address owner = _owners[tokenId];
        return (spender == owner ||
            _tokenApprovals[tokenId] == spender ||
            _operatorApprovals[owner][spender]);
    }

    function _isOwnerOrOperator(
        address spender,
        uint256 agentId
    ) internal view returns (bool) {
        require(
            _owners[agentId] != address(0),
            "AgentIdentityRegistry: nonexistent agent"
        );
        return _isApprovedOrOwner(spender, agentId);
    }

    /// @dev Recovers signer from an ECDSA signature over `digest`.
    function _recoverSigner(
        bytes32 digest,
        bytes calldata sig
    ) internal pure returns (address) {
        require(sig.length == 65, "AgentIdentityRegistry: invalid sig length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        return ecrecover(digest, v, r, s);
    }
}
