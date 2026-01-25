import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import {
  createTestEnvironment,
  setupAdminUser,
  type _SERVICE,
} from "../../setup.ts";
import { expectOk, expectNone, expectSome, expectErr } from "../../helpers.ts";

describe("Agent Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;

    // Set up an admin for testing agent operations
    await setupAdminUser(actor);
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("create_agent", () => {
    it("should reject agent creation from non-admin user", async () => {
      const nonAdminIdentity = generateRandomIdentity();
      actor.setIdentity(nonAdminIdentity);

      const result = await actor.createAgent(
        0n,
        "Test Agent",
        { openai: null },
        "gpt-4",
      );
      expect(expectErr(result)).toEqual(
        "Only workspace admins can perform this action.",
      );
    });

    it("should reject agent creation with empty name", async () => {
      const result = await actor.createAgent(0n, "", { openai: null }, "gpt-4");
      expect(expectErr(result)).toEqual("Agent name cannot be empty");
    });

    it("should successfully create an agent with admin user and all params", async () => {
      const result = await actor.createAgent(
        0n,
        "OpenAI Agent",
        { openai: null },
        "gpt-4",
      );
      expect(expectOk(result)).toEqual(0n);
    });

    it("should create multiple agents with incrementing IDs", async () => {
      const result1 = await actor.createAgent(
        0n,
        "Agent 1",
        { openai: null },
        "gpt-4",
      );
      const id1 = expectOk(result1);

      const result2 = await actor.createAgent(
        0n,
        "Agent 2",
        { llmcanister: null },
        "llama",
      );
      const id2 = expectOk(result2);

      expect(id1).toEqual(0n);
      expect(id2).toEqual(1n);
    });
  });

  describe("get_agent", () => {
    it("should return null for non-existent agent", async () => {
      const agent = await actor.getAgent(0n, 999n);
      // Candid handles an optional custom type as an array with 0 or 1 elements
      // an empty array means null in Motoko
      expectNone(agent);
    });

    it("should return an agent that exists", async () => {
      const agentId = expectOk(
        await actor.createAgent(0n, "Test Agent", { openai: null }, "gpt-4"),
      );

      const agentResult = await actor.getAgent(0n, agentId);
      const agent = expectOk(agentResult);
      const agentData = expectSome(agent);
      expect(agentData.id).toEqual(agentId);
      expect(agentData.name).toEqual("Test Agent");
      expect(agentData.provider).toEqual({ openai: null });
      expect(agentData.model).toEqual("gpt-4");
    });
  });

  describe("update_agent", () => {
    it("should reject update from non-admin user", async () => {
      // Try to update as non-admin
      const nonAdminIdentity = generateRandomIdentity();
      actor.setIdentity(nonAdminIdentity);

      const updateResult = await actor.updateAgent(
        0n,
        0n, // agentId
        ["Updated Name"],
        [],
        [],
      );
      expect(expectErr(updateResult)).toEqual(
        "Only workspace admins can perform this action.",
      );
    });

    it("should reject update of non-existent agent", async () => {
      const result = await actor.updateAgent(0n, 999n, [], [], []);
      expect(expectErr(result)).toEqual("Agent not found");
    });

    it("should update agent name only", async () => {
      const agentId = expectOk(
        await actor.createAgent(0n, "Original", { openai: null }, "gpt-4"),
      );

      const updateResult = await actor.updateAgent(
        0n,
        agentId,
        ["Updated Name"],
        [],
        [],
      );
      expectOk(updateResult);

      const agentResult = await actor.getAgent(0n, agentId);
      const agent = expectOk(agentResult);
      const agentData = expectSome(agent);
      expect(agentData.name).toEqual("Updated Name");
      expect(agentData.model).toEqual("gpt-4");
    });

    it("should update all agent fields", async () => {
      const agentId = expectOk(
        await actor.createAgent(0n, "Original", { openai: null }, "gpt-3.5"),
      );

      const updateResult = await actor.updateAgent(
        0n,
        agentId,
        ["New Agent Name"],
        [{ llmcanister: null }],
        ["llama2"],
      );
      expectOk(updateResult);

      const agentResult = await actor.getAgent(0n, agentId);
      const agent = expectOk(agentResult);
      const agentData = expectSome(agent);
      expect(agentData.name).toEqual("New Agent Name");
      expect(agentData.provider).toEqual({ llmcanister: null });
      expect(agentData.model).toEqual("llama2");
    });
  });

  describe("delete_agent", () => {
    it("should reject deletion from non-admin user", async () => {
      // Try to delete as non-admin
      const nonAdminIdentity = generateRandomIdentity();
      actor.setIdentity(nonAdminIdentity);

      const deleteResult = await actor.deleteAgent(0n, 0n);
      expect(expectErr(deleteResult)).toEqual(
        "Only workspace admins can perform this action.",
      );
    });

    it("should reject deletion of non-existent agent", async () => {
      const result = await actor.deleteAgent(0n, 999n);
      expect(expectErr(result)).toEqual("Agent not found");
    });

    it("should successfully delete an agent", async () => {
      const agentId = expectOk(
        await actor.createAgent(
          0n,
          "Agent to Delete",
          { openai: null },
          "gpt-4",
        ),
      );

      const deleteResult = await actor.deleteAgent(0n, agentId);
      expectOk(deleteResult);

      const agent = await actor.getAgent(0n, agentId);
      expectNone(agent);
    });
  });

  describe("list_agents", () => {
    it("should return all created agents", async () => {
      await actor.createAgent(0n, "Agent 1", { openai: null }, "gpt-4");
      await actor.createAgent(0n, "Agent 2", { groq: null }, "mixtral");
      await actor.createAgent(0n, "Agent 3", { llmcanister: null }, "llama2");

      const result = await actor.listAgents(0n);
      const agents = expectOk(result);
      expect(agents.length).toEqual(3);
      expect(agents[1].id).toEqual(1n);
      expect(agents[1].name).toEqual("Agent 2");
      expect(agents[1].provider).toEqual({ groq: null });
      expect(agents[1].model).toEqual("mixtral");
    });
  });
});
