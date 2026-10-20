/**
 * ERC-8004 AI Agent Example — test suite
 * ======================================
 *
 * Uses Hardhat 3's built-in `node:test` runner together with:
 *   • `@nomicfoundation/hardhat-ethers`        -> contracts, signers, EIP-712 signing
 *   • `@nomicfoundation/hardhat-network-helpers` -> `loadFixture` for fast isolation
 *
 * Run with:
 *   npx hardhat test
 *   npx hardhat test --grep "Reputation"
 *   npx hardhat test test/AgentTests.ts
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { HDNodeWallet } from "ethers";
import { network } from "hardhat";

describe("ERC-8004 AI Agent Example", async function () {
  const { ethers, networkHelpers } = await network.getOrCreate();
  const { loadFixture } = networkHelpers;

  /**
   * Deploys a contract and waits until it is mined.
   *
   * Contracts are returned as `any` on purpose: this project does not generate
   * ethers contract types (`hardhat-ethers@4.0.11` ships no type generator), so
   * the static `BaseContract` type would reject every ABI method call.
   */
  async function deploy(name: string, args: any[] = []): Promise<any> {
    const contract = await ethers.deployContract(name, args);
    await contract.waitForDeployment();
    return contract;
  }

  /**
   * Deploys the complete stack from a clean chain state and returns every
   * contract plus a handful of funded signers. `loadFixture` snapshots the
   * chain after the first run, so subsequent calls are instant and isolated.
   */
  async function deployStack() {
    const [deployer, alice, bob, carol] = await ethers.getSigners();

    const identity = await deploy("AgentIdentityRegistry");
    const reputation = await deploy("AgentReputationRegistry", [await identity.getAddress()]);
    const validation = await deploy("AgentValidationRegistry", [await identity.getAddress()]);
    const validator = await deploy("ExampleValidator", [await validation.getAddress()]);
    const demo = await deploy("KayhanAIAgent", [
      await identity.getAddress(),
      await reputation.getAddress(),
      await validation.getAddress(),
    ]);

    return { identity, reputation, validation, validator, demo, deployer, alice, bob, carol };
  }

  /** Asserts that `action` reverts with a reason containing `reason`. */
  async function expectRevert(action: () => Promise<unknown>, reason: string): Promise<void> {
    let caught: unknown;
    try {
      await action();
    } catch (error) {
      caught = error;
    }

    assert.ok(caught !== undefined, `expected a revert containing "${reason}", but the call succeeded`);

    const error = caught as { message?: string; shortMessage?: string; reason?: string };
    const text = [error.message, error.shortMessage, error.reason]
      .filter((value): value is string => typeof value === "string")
      .join(" | ");

    assert.ok(text.includes(reason), `expected revert reason "${reason}", got: ${text}`);
  }

  /** A timestamp comfortably in the future, used as an EIP-712 signature deadline. */
  async function futureDeadline(seconds = 3_600): Promise<bigint> {
    const block = await ethers.provider.getBlock("latest");
    return BigInt(block!.timestamp) + BigInt(seconds);
  }

  /** Signs the registry's `SetAgentWallet` EIP-712 struct with `wallet`. */
  async function signSetWallet(
    wallet: HDNodeWallet,
    verifyingContract: string,
    agentId: bigint,
    newWallet: string,
    deadline: bigint,
    nonce: bigint,
  ): Promise<string> {
    const chainId = (await ethers.provider.getNetwork()).chainId;

    return wallet.signTypedData(
      { name: "ERC-8004 AI Agent Registry", version: "1", chainId, verifyingContract },
      {
        SetAgentWallet: [
          { name: "agentId", type: "uint256" },
          { name: "newWallet", type: "address" },
          { name: "deadline", type: "uint256" },
          { name: "nonce", type: "uint256" },
        ],
      },
      { agentId, newWallet, deadline, nonce },
    );
  }

  // ─── AgentIdentityRegistry ──────────────────────────────────────────────────

  describe("AgentIdentityRegistry", async function () {
    it("mints an ERC-721 token bound to the agent URI", async function () {
      const { identity, deployer } = await loadFixture(deployStack);

      const agentId = await identity["register(string)"].staticCall("ipfs://QmAgent1");
      await (await identity["register(string)"]("ipfs://QmAgent1")).wait();

      assert.equal(agentId, 1n);
      assert.equal(await identity.ownerOf(agentId), deployer.address);
      assert.equal(await identity.balanceOf(deployer.address), 1n);
      assert.equal(await identity.tokenURI(agentId), "ipfs://QmAgent1");
      assert.equal(await identity.name(), "ERC-8004 AI Agent Registry");
      assert.equal(await identity.symbol(), "AGENT");
    });

    it("declares the ERC-721 and ERC-165 interfaces", async function () {
      const { identity } = await loadFixture(deployStack);

      assert.equal(await identity.supportsInterface("0x80ac58cd"), true); // ERC-721
      assert.equal(await identity.supportsInterface("0x01ffc9a7"), true); // ERC-165
      assert.equal(await identity.supportsInterface("0xffffffff"), false);
    });

    it("stores registration metadata and supports empty registrations", async function () {
      const { identity } = await loadFixture(deployStack);

      const metadata = [
        { metadataKey: "name", metadataValue: ethers.toUtf8Bytes("Aurora") },
        { metadataKey: "model", metadataValue: ethers.toUtf8Bytes("gemini-2.5-pro") },
      ];

      const agentId = await identity["register(string,(string,bytes)[])"].staticCall("ipfs://QmMeta", metadata);
      await (await identity["register(string,(string,bytes)[])"]("ipfs://QmMeta", metadata)).wait();

      assert.equal(ethers.toUtf8String(await identity.getMetadata(agentId, "name")), "Aurora");
      assert.equal(ethers.toUtf8String(await identity.getMetadata(agentId, "model")), "gemini-2.5-pro");

      const emptyId = await identity["register()"].staticCall();
      await (await identity["register()"]()).wait();
      assert.equal(await identity.tokenURI(emptyId), "");
    });

    it("reverts when reading a nonexistent agent", async function () {
      const { identity } = await loadFixture(deployStack);

      await expectRevert(() => identity.tokenURI(999n), "nonexistent agent");
      await expectRevert(() => identity.ownerOf(999n), "");
    });

    it("lets the owner and approved operators update the agent URI", async function () {
      const { identity, alice } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmOld")).wait();

      await expectRevert(
        () => identity.connect(alice).setAgentURI(1n, "ipfs://QmNew"),
        "not owner or operator",
      );

      await (await identity.setAgentURI(1n, "ipfs://QmNew")).wait();
      assert.equal(await identity.tokenURI(1n), "ipfs://QmNew");

      await (await identity.approve(alice.address, 1n)).wait();
      await (await identity.connect(alice).setAgentURI(1n, "ipfs://QmThird")).wait();

      assert.equal(await identity.getApproved(1n), alice.address);
      assert.equal(await identity.tokenURI(1n), "ipfs://QmThird");
    });

    it("stores generic metadata but rejects the reserved agentWallet key", async function () {
      const { identity } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmMeta")).wait();

      await (await identity.setMetadata(1n, "capability", ethers.toUtf8Bytes("summarise"))).wait();

      assert.equal(
        ethers.toUtf8String(await identity.getMetadata(1n, "capability")),
        "summarise",
      );

      await expectRevert(
        () => identity.setMetadata(1n, "agentWallet", ethers.toUtf8Bytes("x")),
        "reserved",
      );
    });

    it("falls back to the NFT owner as the agent wallet", async function () {
      const { identity, deployer } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmWallet")).wait();

      assert.equal(await identity.getAgentWallet(1n), deployer.address);
    });

    it("sets the agent wallet with an EIP-712 signature and bumps the nonce", async function () {
      const { identity, deployer } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmWallet")).wait();

      const newWallet = ethers.Wallet.createRandom();
      const deadline = await futureDeadline();
      const nonce = await identity.walletNonce(1n);

      assert.equal(nonce, 0n);

      const signature = await signSetWallet(
        newWallet,
        await identity.getAddress(),
        1n,
        newWallet.address,
        deadline,
        nonce,
      );
      await (await identity.setAgentWallet(1n, newWallet.address, deadline, signature)).wait();

      assert.equal(await identity.getAgentWallet(1n), newWallet.address);
      assert.equal(await identity.walletNonce(1n), 1n);

      await (await identity.unsetAgentWallet(1n)).wait();
      assert.equal(await identity.getAgentWallet(1n), deployer.address);
    });

    it("rejects an agent wallet signature produced by the wrong key", async function () {
      const { identity } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmWallet")).wait();

      const intended = ethers.Wallet.createRandom();
      const impostor = ethers.Wallet.createRandom();
      const deadline = await futureDeadline();

      const signature = await signSetWallet(
        impostor,
        await identity.getAddress(),
        1n,
        intended.address,
        deadline,
        0n,
      );

      await expectRevert(
        () => identity.setAgentWallet(1n, intended.address, deadline, signature),
        "invalid ECDSA signature",
      );
    });

    it("transfers ownership and clears the agent wallet override", async function () {
      const { identity, deployer, bob } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmTransfer")).wait();

      const newWallet = ethers.Wallet.createRandom();
      const deadline = await futureDeadline();
      const signature = await signSetWallet(
        newWallet,
        await identity.getAddress(),
        1n,
        newWallet.address,
        deadline,
        0n,
      );
      await (await identity.setAgentWallet(1n, newWallet.address, deadline, signature)).wait();
      assert.equal(await identity.getAgentWallet(1n), newWallet.address);

      await (await identity.transferFrom(deployer.address, bob.address, 1n)).wait();

      assert.equal(await identity.ownerOf(1n), bob.address);
      assert.equal(await identity.balanceOf(deployer.address), 0n);
      assert.equal(await identity.balanceOf(bob.address), 1n);
      // The override was cleared on transfer, so it falls back to the new owner.
      assert.equal(await identity.getAgentWallet(1n), bob.address);
    });
  });

  // ─── AgentReputationRegistry ────────────────────────────────────────────────

  describe("AgentReputationRegistry", async function () {
    it("blocks the agent owner from reviewing its own agent", async function () {
      const { identity, reputation } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      await expectRevert(
        () => reputation.giveFeedback(1n, 5n, 0, "starred", "", "", "", ethers.ZeroHash),
        "owner cannot self-review",
      );
    });

    it("records client feedback and exposes it through the read API", async function () {
      const { identity, reputation, alice } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      await (
        await reputation
          .connect(alice)
          .giveFeedback(1n, 45n, 1, "starred", "week", "https://agent.example/chat", "ipfs://QmFeedback", ethers.ZeroHash)
      ).wait();

      const feedback = await reputation.readFeedback(1n, alice.address, 1n);
      assert.equal(feedback.value, 45n);
      assert.equal(feedback.valueDecimals, 1n);
      assert.equal(feedback.tag1, "starred");
      assert.equal(feedback.tag2, "week");
      assert.equal(feedback.isRevoked, false);

      assert.equal(await reputation.getLastIndex(1n, alice.address), 1n);
      assert.deepEqual([...(await reputation.getClients(1n))], [alice.address]);
    });

    it("rejects an out-of-range decimal scale", async function () {
      const { identity, reputation, alice } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      await expectRevert(
        () => reputation.connect(alice).giveFeedback(1n, 1n, 19, "", "", "", "", ethers.ZeroHash),
        "valueDecimals > 18",
      );
    });

    it("aggregates a trusted reviewer list, normalised to 18 decimals", async function () {
      const { identity, reputation, alice, bob } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      // 45 / 10^1 = 4.5
      await (await reputation.connect(alice).giveFeedback(1n, 45n, 1, "starred", "", "", "", ethers.ZeroHash)).wait();
      // 5 / 10^0 = 5
      await (await reputation.connect(bob).giveFeedback(1n, 5n, 0, "starred", "", "", "", ethers.ZeroHash)).wait();

      const summary = await reputation.getSummary(1n, [alice.address, bob.address], "", "");
      assert.equal(summary.count, 2n);
      assert.equal(summary.summaryValue, 9_500_000_000_000_000_000n); // 9.5
      assert.equal(summary.summaryValueDecimals, 18n);
    });

    it("requires a non-empty trusted reviewer list", async function () {
      const { identity, reputation } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      await expectRevert(() => reputation.getSummary(1n, [], "", ""), "empty clientAddresses");
    });

    it("excludes revoked feedback and honours tag filters", async function () {
      const { identity, reputation, alice } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      await (await reputation.connect(alice).giveFeedback(1n, 4n, 0, "starred", "", "", "", ethers.ZeroHash)).wait(); // index 1
      await (await reputation.connect(alice).giveFeedback(1n, 99n, 0, "uptime", "", "", "", ethers.ZeroHash)).wait(); // index 2

      const starred = await reputation.getSummary(1n, [alice.address], "starred", "");
      assert.equal(starred.count, 1n);
      assert.equal(starred.summaryValue, 4_000_000_000_000_000_000n);

      await (await reputation.connect(alice).revokeFeedback(1n, 1n)).wait();

      const afterRevoke = await reputation.getSummary(1n, [alice.address], "", "");
      assert.equal(afterRevoke.count, 1n);
      assert.equal(afterRevoke.summaryValue, 99_000_000_000_000_000_000n);
    });

    it("appends responses to feedback and counts them per responder", async function () {
      const { identity, reputation, alice, bob, carol } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      await (await reputation.connect(alice).giveFeedback(1n, 2n, 0, "starred", "", "", "", ethers.ZeroHash)).wait();

      await (
        await reputation.connect(carol).appendResponse(1n, alice.address, 1n, "ipfs://QmResponse", ethers.ZeroHash)
      ).wait();

      assert.equal(await reputation.getResponseCount(1n, alice.address, 1n, []), 1n);
      assert.equal(await reputation.getResponseCount(1n, alice.address, 1n, [carol.address]), 1n);
      assert.equal(await reputation.getResponseCount(1n, alice.address, 1n, [bob.address]), 0n);
    });
  });

  // ─── AgentValidationRegistry ────────────────────────────────────────────────

  describe("AgentValidationRegistry", async function () {
    it("only lets the agent owner or operator request validation", async function () {
      const { identity, validation, validator, alice } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      const validatorAddress = await validator.getAddress();
      const requestHash = ethers.keccak256(ethers.toUtf8Bytes("task-1"));

      await expectRevert(
        async () => validation.connect(alice).validationRequest(validatorAddress, 1n, "ipfs://QmRequest", requestHash),
        "not owner or operator",
      );
    });

    it("records a validation request and exposes it through the enumerations", async function () {
      const { identity, validation, validator } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      const validatorAddress = await validator.getAddress();
      const requestHash = ethers.keccak256(ethers.toUtf8Bytes("task-1"));

      await (await validation.validationRequest(validatorAddress, 1n, "ipfs://QmRequest", requestHash)).wait();

      const status = await validation.getValidationStatus(requestHash);
      assert.equal(status.validatorAddress, validatorAddress);
      assert.equal(status.agentId, 1n);
      assert.equal(status.response, 0n);
      assert.equal(status.lastUpdate, 0n, "no response has been recorded yet");

      assert.deepEqual([...(await validation.getAgentValidations(1n))], [requestHash]);
      assert.deepEqual([...(await validation.getValidatorRequests(validatorAddress))], [requestHash]);
    });

    it("rejects malformed validation requests", async function () {
      const { identity, validation, validator } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      const validatorAddress = await validator.getAddress();
      const requestHash = ethers.keccak256(ethers.toUtf8Bytes("task-1"));

      await expectRevert(
        () => validation.validationRequest(ethers.ZeroAddress, 1n, "ipfs://QmRequest", requestHash),
        "zero validator",
      );
      await expectRevert(
        () => validation.validationRequest(validatorAddress, 1n, "ipfs://QmRequest", ethers.ZeroHash),
        "empty requestHash",
      );
    });

    it("only lets the designated validator respond", async function () {
      const { identity, validation, validator, alice } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      const validatorAddress = await validator.getAddress();
      const requestHash = ethers.keccak256(ethers.toUtf8Bytes("task-1"));
      await (await validation.validationRequest(validatorAddress, 1n, "ipfs://QmRequest", requestHash)).wait();

      await expectRevert(
        () => validation.connect(alice).validationResponse(requestHash, 100, "", ethers.ZeroHash, "pass"),
        "caller is not the designated validator",
      );
    });

    it("records a validator response and aggregates it", async function () {
      const { identity, validation, validator } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      const validatorAddress = await validator.getAddress();
      const requestHash = ethers.keccak256(ethers.toUtf8Bytes("task-1"));
      await (await validation.validationRequest(validatorAddress, 1n, "ipfs://QmRequest", requestHash)).wait();

      await (await validator.submitBinaryResult(requestHash, true, "ipfs://QmEvidence")).wait();

      const status = await validation.getValidationStatus(requestHash);
      assert.equal(status.response, 100n);
      assert.equal(status.tag, "pass");
      assert.notEqual(status.lastUpdate, 0n);

      const summary = await validation.getSummary(1n, [], "");
      assert.equal(summary.count, 1n);
      assert.equal(summary.averageResponse, 100n);
    });

    it("rejects out-of-range validator responses", async function () {
      const { identity, validation, validator } = await loadFixture(deployStack);
      await (await identity["register(string)"]("ipfs://QmAgent")).wait();

      const validatorAddress = await validator.getAddress();
      const requestHash = ethers.keccak256(ethers.toUtf8Bytes("task-1"));
      await (await validation.validationRequest(validatorAddress, 1n, "ipfs://QmRequest", requestHash)).wait();

      await expectRevert(
        () => validator.submitValidation(requestHash, 101, "", ethers.ZeroHash, "partial"),
        "response > 100",
      );
    });
  });

  // ─── KayhanAIAgent (end-to-end demo) ────────────────────────────────────────

  describe("KayhanAIAgent (end-to-end demo)", async function () {
    it("registers an agent owned by the demo contract and exposes its info", async function () {
      const { identity, demo } = await loadFixture(deployStack);
      const demoAddress = await demo.getAddress();

      const agentId = await demo.registerAgent.staticCall("ipfs://QmDemo", "Kayhan Demo Agent", "gemini-2.5-pro");
      await (await demo.registerAgent("ipfs://QmDemo", "Kayhan Demo Agent", "gemini-2.5-pro")).wait();

      assert.equal(agentId, 1n);
      assert.equal(await demo.agentCount(), 1n);
      assert.deepEqual([...(await demo.getRegisteredAgents())], [1n]);
      assert.equal(await identity.ownerOf(agentId), demoAddress);

      const info = await demo.getAgentInfo(agentId);
      assert.equal(info.agentOwner, demoAddress);
      assert.equal(info.agentURI, "ipfs://QmDemo");
      assert.equal(info.agentName, "Kayhan Demo Agent");
      assert.equal(info.agentWallet, demoAddress);
      assert.equal(ethers.toUtf8String(info.modelName), "gemini-2.5-pro");
    });

    it("restricts agent registration to the contract owner", async function () {
      const { demo, alice } = await loadFixture(deployStack);

      await expectRevert(
        () => demo.connect(alice).registerAgent("ipfs://QmDemo", "Nope", "model"),
        "not owner",
      );
    });

    it("updates the registration file and metadata through the demo (owner only)", async function () {
      const { identity, demo, alice } = await loadFixture(deployStack);

      const agentId = await demo.registerAgent.staticCall("ipfs://QmDemo", "Demo", "gemini-2.5-pro");
      await (await demo.registerAgent("ipfs://QmDemo", "Demo", "gemini-2.5-pro")).wait();

      // Both wrappers are owner-only passthroughs to the identity registry.
      await expectRevert(() => demo.connect(alice).updateAgentURI(agentId, "ipfs://QmHijacked"), "not owner");
      await expectRevert(
        () => demo.connect(alice).setAgentMetadata(agentId, "capability", ethers.toUtf8Bytes("hijacked")),
        "not owner",
      );

      await (await demo.updateAgentURI(agentId, "ipfs://QmUpdated")).wait();
      await (await demo.setAgentMetadata(agentId, "capability", ethers.toUtf8Bytes("summarise"))).wait();

      assert.equal(await identity.tokenURI(agentId), "ipfs://QmUpdated");
      assert.equal(ethers.toUtf8String(await identity.getMetadata(agentId, "capability")), "summarise");

      // The demo's own view reads through to the updated registration file.
      const info = await demo.getAgentInfo(agentId);
      assert.equal(info.agentURI, "ipfs://QmUpdated");
      assert.equal(ethers.toUtf8String(info.modelName), "gemini-2.5-pro"); // untouched by the update
    });

    it("does not expose a feedback entry point", async function () {
      const { demo } = await loadFixture(deployStack);

      // ERC-8004 records the reviewer as `msg.sender` and blocks the agent owner
      // and its operators from self-reviewing, so a forwarding contract can never
      // submit feedback on a client's behalf. The demo therefore proxies nothing
      // for feedback and only aggregates the resulting scores for reading.
      assert.equal(demo.giveFeedback, undefined);
      assert.equal(demo.rateAgent, undefined);
    });

    it("aggregates client feedback submitted directly to the reputation registry", async function () {
      const { reputation, demo, bob } = await loadFixture(deployStack);

      // The demo owns this agent (which is what lets it request validation)...
      const agentId = await demo.registerAgent.staticCall("ipfs://QmDemo", "Demo", "gemini-2.5-pro");
      await (await demo.registerAgent("ipfs://QmDemo", "Demo", "gemini-2.5-pro")).wait();

      // ...and Bob, an independent client, reviews it straight on the registry.
      await (
        await reputation
          .connect(bob)
          .giveFeedback(agentId, 45n, 1, "starred", "week", "https://agent.example/chat", "", ethers.ZeroHash)
      ).wait();

      const score = await demo.getAgentScore(agentId, [bob.address], "", "");
      assert.equal(score.count, 1n);
      assert.equal(score.summaryValue, 4_500_000_000_000_000_000n); // 4.5, normalised to 18 decimals
      assert.equal(score.summaryValueDecimals, 18n);
    });

    it("runs the full validation flow: request -> validate -> read score", async function () {
      const { demo, validator } = await loadFixture(deployStack);
      const validatorAddress = await validator.getAddress();

      const agentId = await demo.registerAgent.staticCall("ipfs://QmDemo", "Demo", "gemini-2.5-pro");
      await (await demo.registerAgent("ipfs://QmDemo", "Demo", "gemini-2.5-pro")).wait();

      const requestHash = ethers.keccak256(ethers.toUtf8Bytes("demo-task-output"));
      await (await demo.requestValidation(agentId, validatorAddress, "ipfs://QmRequest", requestHash)).wait();

      const pending = await demo.checkValidation(requestHash);
      assert.equal(pending.response, 0n);
      assert.equal(pending.lastUpdate, 0n);

      await (await validator.submitBinaryResult(requestHash, true, "ipfs://QmEvidence")).wait();

      const resolved = await demo.checkValidation(requestHash);
      assert.equal(resolved.validatorAddress, validatorAddress);
      assert.equal(resolved.agentId, agentId);
      assert.equal(resolved.response, 100n);
      assert.equal(resolved.tag, "pass");

      const score = await demo.getValidationScore(agentId, [], "");
      assert.equal(score.count, 1n);
      assert.equal(score.averageResponse, 100n);
    });

    it("restricts validation requests to the contract owner", async function () {
      const { demo, validator, alice } = await loadFixture(deployStack);
      const validatorAddress = await validator.getAddress();

      const agentId = await demo.registerAgent.staticCall("ipfs://QmDemo", "Demo", "model");
      await (await demo.registerAgent("ipfs://QmDemo", "Demo", "model")).wait();

      await expectRevert(
        async () =>
          demo
            .connect(alice)
            .requestValidation(agentId, validatorAddress, "ipfs://QmRequest", ethers.keccak256(ethers.toUtf8Bytes("x"))),
        "not owner",
      );
    });
  });
});
