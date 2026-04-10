# ERC-8004 AI Agent Example

A complete example implementation of **ERC-8004 "Trustless Agents"** — the Ethereum standard for discovering, trusting, and interacting with AI agents across organizational boundaries.

## Overview

This repository provides three production-ready smart contracts that together form the ERC-8004 protocol, plus a demonstration contract showing how they interoperate.

### Registries

| Contract | Description |
|---|---|
| `AgentIdentityRegistry.sol` | ERC-721-based identity. Each NFT token = one registered AI agent. |
| `AgentReputationRegistry.sol` | Structured client feedback ledger with filtering, revocation, and summary aggregation. |
| `AgentValidationRegistry.sol` | On-chain hooks for requesting and recording independent validation (zkML, TEE, stake re-execution). |
| `kayhan_ai_agent.sol` | End-to-end demonstration: registers an agent, gives feedback, and requests validation. |

### How Agent Identity Works

Each agent is globally identified by:
```
eip155:{chainId}:{identityRegistryAddress}
```
with an `agentId` (ERC-721 tokenId) identifying the specific agent within that registry.

The `agentURI` points to an off-chain (or fully on-chain via `data:` URI) **registration file** in JSON format that describes:
- Agent name, description, image
- Service endpoints (A2A, MCP, Web, ENS, DID, email, ...)
- Supported trust models (`reputation`, `crypto-economic`, `tee-attestation`)

### Trust Models

| Model | How |
|---|---|
| **Reputation** | Clients submit signed feedback values on-chain; aggregated by trusted reviewer lists to resist Sybil attacks |
| **Crypto-Economic** | Validators stake funds and re-execute agent tasks; slashing managed by validator protocol |
| **TEE Attestation** | Trusted Execution Environment oracles verify agent computations off-chain and post attestations on-chain |

## Quickstart

### 1. Deploy the registries

```solidity
// Deploy Identity Registry
AgentIdentityRegistry identity = new AgentIdentityRegistry();

// Deploy Reputation + Validation registries, linked to Identity
AgentReputationRegistry reputation = new AgentReputationRegistry(address(identity));
AgentValidationRegistry validation = new AgentValidationRegistry(address(identity));
```

### 2. Register an AI agent

```solidity
// Simple registration
uint256 agentId = identity.register("ipfs://QmYourAgentRegistrationFileCID");

// Registration with metadata
AgentIdentityRegistry.MetadataEntry[] memory meta = new AgentIdentityRegistry.MetadataEntry[](1);
meta[0] = AgentIdentityRegistry.MetadataEntry({
    metadataKey:   "model",
    metadataValue: bytes("gemini-2.5-pro")
});
uint256 agentId = identity.register("ipfs://QmYourCID", meta);
```

### 3. Give feedback

```solidity
// 4.5/5 stars (value=45, valueDecimals=1)
reputation.giveFeedback(
    agentId,
    45,         // value
    1,          // valueDecimals (45 / 10^1 = 4.5)
    "starred",  // tag1
    "",         // tag2
    "https://agent.example.com/chat",  // endpoint
    "",         // feedbackURI
    bytes32(0)  // feedbackHash
);
```

### 4. Request validation

```solidity
bytes32 requestHash = keccak256(abi.encodePacked(agentId, taskOutput, block.timestamp));
validation.validationRequest(
    validatorContractAddress,
    agentId,
    "ipfs://QmValidationPayloadCID",
    requestHash
);
```

## Agent Registration File Format

```json
{
  "type": "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
  "name": "MyAgent",
  "description": "An AI agent that does X",
  "image": "https://example.com/agent.png",
  "services": [
    { "name": "A2A",   "endpoint": "https://agent.example/.well-known/agent-card.json", "version": "0.3.0" },
    { "name": "MCP",   "endpoint": "https://mcp.agent.example/", "version": "2025-06-18" },
    { "name": "web",   "endpoint": "https://agent.example/" }
  ],
  "x402Support": false,
  "active": true,
  "registrations": [
    { "agentId": 1, "agentRegistry": "eip155:1:0xYourIdentityRegistryAddress" }
  ],
  "supportedTrust": ["reputation", "crypto-economic", "tee-attestation"]
}
```

## Reference

- [ERC-8004 Specification](https://eips.ethereum.org/EIPS/eip-8004)
- [Model Context Protocol (MCP)](https://modelcontextprotocol.io/)
- [Agent2Agent Protocol (A2A)](https://google.github.io/A2A/)
- [EIP-712 Structured Signatures](https://eips.ethereum.org/EIPS/eip-712)
- [ERC-1271 Smart Contract Signatures](https://eips.ethereum.org/EIPS/eip-1271)

## License

MIT
