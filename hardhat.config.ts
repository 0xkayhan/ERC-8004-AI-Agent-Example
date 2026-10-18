import { defineConfig } from "hardhat/config";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatNetworkHelpers from "@nomicfoundation/hardhat-network-helpers";
import hardhatNodeTestRunner from "@nomicfoundation/hardhat-node-test-runner";
import "dotenv/config";

export default defineConfig({
  plugins: [hardhatEthers, hardhatNetworkHelpers, hardhatNodeTestRunner],
  solidity: {
    version: "0.8.28",
    settings: {
      // AgentReputationRegistry.sol hits "Stack too deep" without the IR
      // pipeline, so the optimizer + viaIR are required to compile the project.
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  networks: {
    // Persistent local chain: start it with `npx hardhat node`, then deploy with
    // `npx hardhat run scripts/kayhan_ai_agent.ts --network localhost`.
    localhost: {
      type: "http",
      chainType: "l1",
      url: process.env.LOCALHOST_RPC_URL ?? "http://127.0.0.1:8545",
    },

    // Ethereum Sepolia testnet. Requires SEPOLIA_RPC_URL and PRIVATE_KEY in .env.
    sepolia: {
      type: "http",
      chainType: "l1",
      url: process.env.SEPOLIA_RPC_URL ?? "https://ethereum-sepolia-rpc.publicnode.com",
      ...(process.env.PRIVATE_KEY !== undefined
        ? { accounts: [process.env.PRIVATE_KEY] }
        : {}),
    },
  },
});
