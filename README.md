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
| `kayhan_ai_agent.sol` | End-to-end demonstration: registers an agent, aggregates client feedback, and requests validation. |

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

## Deployment (Hardhat)

The Quickstart above shows the protocol flow in Solidity. For a runnable
deployment, this repository ships `scripts/kayhan_ai_agent.ts`, which deploys the
whole stack in dependency order, verifies the wiring, and writes the resulting
addresses to `deployments/<network>.json`.

### 1. Install dependencies

```bash
npm install
```

### 2. Configure the environment

```bash
cp .env.example .env
```

| Variable | Required | Description |
|---|---|---|
| `PRIVATE_KEY` | Non-local networks | Deployer private key. Never commit one that holds real funds. |
| `SEPOLIA_RPC_URL` | Sepolia | RPC endpoint, e.g. Alchemy, Infura or a public node. |
| `LOCALHOST_RPC_URL` | Optional | Defaults to `http://127.0.0.1:8545`. |
| `REGISTER_DEMO_AGENT` | Optional | Set to `true` to register a sample agent after deploying. |

### 3. Deploy

```bash
# In-memory network — fastest, state is discarded when the command exits.
npx hardhat run scripts/kayhan_ai_agent.ts

# Local node — persistent chain, handy for wallet and frontend testing.
npx hardhat node
npx hardhat run scripts/kayhan_ai_agent.ts --network localhost

# Sepolia testnet — requires PRIVATE_KEY and SEPOLIA_RPC_URL.
npx hardhat run scripts/kayhan_ai_agent.ts --network sepolia
```

### 4. What gets deployed

| # | Contract | Constructor arguments |
|---|---|---|
| 1 | `AgentIdentityRegistry` | — |
| 2 | `AgentReputationRegistry` | identity registry address |
| 3 | `AgentValidationRegistry` | identity registry address |
| 4 | `ExampleValidator` | validation registry address |
| 5 | `KayhanAIAgent` | identity, reputation and validation registry addresses |

The script then calls `getIdentityRegistry()` on both registries to confirm they
point at the identity registry, and — when `REGISTER_DEMO_AGENT=true` — registers
one demo agent through `KayhanAIAgent`.

### 5. Deployment record

Each run writes a JSON record containing the chain id, the deployer and every
contract address:

```json
{
  "network": "localhost",
  "chainId": 31337,
  "deployer": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "contracts": {
    "AgentIdentityRegistry": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    "AgentReputationRegistry": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
    "AgentValidationRegistry": "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
    "ExampleValidator": "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
    "KayhanAIAgent": "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9"
  },
  "demoAgentId": null,
  "deployedAt": "2026-10-17T14:57:44.559Z"
}
```

> **Note:** `AgentReputationRegistry.sol` exceeds the EVM stack limit, so the
> Hardhat configuration enables the optimizer together with the IR pipeline
> (`viaIR: true`). Run `npx hardhat compile` first if you want to inspect the
> build artifacts before deploying.

## Tests

The suite lives in `test/AgentTests.ts` and runs on Hardhat 3's built-in
`node:test` runner. Every test starts from a clean stack thanks to
`@nomicfoundation/hardhat-network-helpers`' `loadFixture`, which snapshots the
chain after the first deployment.

```bash
npx hardhat test                        # run everything
npx hardhat test --grep "Reputation"    # only matching tests
npx hardhat test test/AgentTests.ts     # a single file
```

| Suite | Covers |
|---|---|
| `AgentIdentityRegistry` | ERC-721 minting, registration metadata, agent URI, EIP-712 `setAgentWallet`, transfers |
| `AgentReputationRegistry` | feedback lifecycle, 18-decimal normalisation, tags, revocation, responses |
| `AgentValidationRegistry` | request/response lifecycle, authorization, aggregation |
| `KayhanAIAgent` (end-to-end) | agent registration, reputation aggregation, full validation flow |

> **Note:** `KayhanAIAgent` exposes no feedback function on purpose. ERC-8004
> records the reviewer as `msg.sender` and blocks the agent's owner and its
> operators from self-reviewing, so a forwarding contract can never submit
> feedback *on behalf of* a client — the entry would be attributed to the
> contract itself. Feedback always goes straight to `AgentReputationRegistry`;
> `KayhanAIAgent` only aggregates the resulting scores for reading.

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
