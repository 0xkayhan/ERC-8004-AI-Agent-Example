/**
 * ERC-8004 AI Agent Example — deployment script
 * =============================================
 *
 * Deploys the full ERC-8004 registry stack plus the demonstration contracts:
 *
 *   1. AgentIdentityRegistry    ERC-721 agent identity (no constructor args)
 *   2. AgentReputationRegistry  client feedback ledger   -> (identity)
 *   3. AgentValidationRegistry  validation hooks         -> (identity)
 *   4. ExampleValidator         demo validator oracle    -> (validation)
 *   5. KayhanAIAgent            end-to-end demo facade   -> (identity, reputation, validation)
 *
 * The deploy order matters: every dependent contract needs the address of the
 * registry it points at, and those references are immutable once deployed.
 *
 * Usage
 * -----
 *   npx hardhat run scripts/kayhan_ai_agent.ts                     # in-memory network
 *   npx hardhat run scripts/kayhan_ai_agent.ts --network localhost # `npx hardhat node`
 *   npx hardhat run scripts/kayhan_ai_agent.ts --network sepolia   # testnet
 *
 * Environment variables (see .env.example)
 * ----------------------------------------
 *   PRIVATE_KEY           Deployer key. Required on non-local networks.
 *   SEPOLIA_RPC_URL       RPC endpoint used by the `sepolia` network.
 *   REGISTER_DEMO_AGENT   Set to "true" to register a sample agent after deploy.
 *
 * Deployed addresses are written to `deployments/<network>.json`.
 */
import { network } from "hardhat";
import type { Contract } from "ethers";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const { ethers, networkName } = await network.getOrCreate();

const [deployer] = await ethers.getSigners();

if (deployer === undefined) {
  throw new Error(
    `No signer available on network "${networkName}". ` +
      `Add PRIVATE_KEY to your .env file, or deploy to a local network.`,
  );
}

/** Deploys a contract by name, waits for the tx to be mined, returns the instance. */
async function deploy(name: string, args: any[] = []): Promise<Contract> {
  process.stdout.write(`  • ${name}... `);
  const contract = await ethers.deployContract(name, args, deployer);
  await contract.waitForDeployment();
  console.log(await contract.getAddress());
  return contract;
}

async function main(): Promise<void> {
  const chain = await ethers.provider.getNetwork();
  const balance = await ethers.provider.getBalance(deployer.address);

  console.log("");
  console.log("ERC-8004 AI Agent Example — deployment");
  console.log("──────────────────────────────────────────────────────────────");
  console.log(`  network  : ${networkName} (chainId ${chain.chainId})`);
  console.log(`  deployer : ${deployer.address}`);
  console.log(`  balance  : ${ethers.formatEther(balance)} ETH`);
  console.log("──────────────────────────────────────────────────────────────");
  console.log("Deploying contracts:");
  console.log("");

  // 1. Identity registry — the root of the ERC-8004 identity model.
  const identity = await deploy("AgentIdentityRegistry");
  const identityAddress = await identity.getAddress();

  // 2 + 3. Reputation and Validation registries both reference the identity registry.
  const reputation = await deploy("AgentReputationRegistry", [identityAddress]);
  const validation = await deploy("AgentValidationRegistry", [identityAddress]);

  // 4. A minimal validator contract used by the demonstration flow.
  const validationAddress = await validation.getAddress();
  const validator = await deploy("ExampleValidator", [validationAddress]);

  // 5. The demo facade wiring all three registries together.
  const demo = await deploy("KayhanAIAgent", [
    identityAddress,
    await reputation.getAddress(),
    validationAddress,
  ]);

  // ── Sanity checks ─────────────────────────────────────────────────────────
  console.log("");
  console.log("Verifying wiring:");

  const reputationIdentity: string = await reputation.getIdentityRegistry();
  const validationIdentity: string = await validation.getIdentityRegistry();

  if (reputationIdentity.toLowerCase() !== identityAddress.toLowerCase()) {
    throw new Error("AgentReputationRegistry is not bound to AgentIdentityRegistry");
  }
  if (validationIdentity.toLowerCase() !== identityAddress.toLowerCase()) {
    throw new Error("AgentValidationRegistry is not bound to AgentIdentityRegistry");
  }
  console.log("  ✓ reputation & validation registries point at the identity registry");

  // ── Optional demo agent ───────────────────────────────────────────────────
  let agentId: string | null = null;

  if (process.env.REGISTER_DEMO_AGENT === "true") {
    console.log("");
    console.log("Registering demo agent:");

    const tx = await demo.registerAgent(
      "ipfs://QmDemoAgentRegistrationFile",
      "Kayhan Demo Agent",
      "gemini-2.5-pro",
    );
    const receipt = await tx.wait();

    const count: bigint = await demo.agentCount();
    agentId = count.toString();
    console.log(`  ✓ agent #${agentId} registered (tx ${receipt?.hash})`);
  }

  // ── Persist deployment record ─────────────────────────────────────────────
  const record = {
    network: networkName,
    chainId: Number(chain.chainId),
    deployer: deployer.address,
    contracts: {
      AgentIdentityRegistry: identityAddress,
      AgentReputationRegistry: await reputation.getAddress(),
      AgentValidationRegistry: validationAddress,
      ExampleValidator: await validator.getAddress(),
      KayhanAIAgent: await demo.getAddress(),
    },
    demoAgentId: agentId,
    deployedAt: new Date().toISOString(),
  };

  const outDir = join(process.cwd(), "deployments");
  mkdirSync(outDir, { recursive: true });
  const outFile = join(outDir, `${networkName}.json`);
  writeFileSync(outFile, `${JSON.stringify(record, null, 2)}\n`);

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log("");
  console.log("──────────────────────────────────────────────────────────────");
  console.log("Deployment complete — addresses:");
  for (const [name, address] of Object.entries(record.contracts)) {
    console.log(`  ${name.padEnd(24)} ${address}`);
  }
  console.log("──────────────────────────────────────────────────────────────");
  console.log(`Saved to ${outFile}`);
  console.log("");
}

await main();
