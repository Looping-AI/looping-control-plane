import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@dfinity/principal";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import type { _SERVICE } from "../../setup.ts";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
  createTestAgent,
} from "../../setup.ts";
import { expectOk, expectErr } from "../../helpers.ts";

describe("API Key Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let adminIdentity: ReturnType<typeof generateRandomIdentity>;
  let userIdentity: ReturnType<typeof generateRandomIdentity>;
  let agentId: bigint;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;

    // Set up an admin
    ({ adminIdentity } = await setupAdminUser(actor));

    // Create a test agent
    agentId = await createTestAgent(
      actor,
      "Test API Key Agent",
      { openai: null },
      "gpt-4",
    );

    // Set up a regular user
    ({ userIdentity } = await setupRegularUser(actor));
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  it("should reject anonymous users from API key operations", async () => {
    actor.setPrincipal(Principal.anonymous());

    const storeResult = await actor.storeApiKey(
      0n,
      agentId,
      { openai: null },
      "test-key",
    );
    expect(expectErr(storeResult)).toEqual(
      "Please login before calling this function",
    );

    const getResult = await actor.getWorkspaceApiKeys(0n);
    expect(expectErr(getResult)).toEqual(
      "Please login before calling this function",
    );

    const deleteResult = await actor.deleteApiKey(0n, agentId, {
      openai: null,
    });
    expect(expectErr(deleteResult)).toEqual(
      "Please login before calling this function",
    );
  });

  describe("store_api_key", () => {
    it("should reject non-admins from storing API keys", async () => {
      actor.setIdentity(userIdentity);
      const result = await actor.storeApiKey(
        0n,
        agentId,
        { openai: null },
        "test-key",
      );
      expect(expectErr(result)).toEqual(
        "Only workspace admins can store API keys",
      );
    });

    it("should reject storing API key for non-existent agent", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.storeApiKey(
        0n,
        999n,
        { openai: null },
        "test-key-123",
      );
      expect(expectErr(result)).toEqual("Agent not found");
    });

    it("should reject storing empty or whitespace only API key", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.storeApiKey(0n, agentId, { openai: null }, "");
      expect(expectErr(result)).toEqual("API key cannot be empty");

      const result2 = await actor.storeApiKey(
        0n,
        agentId,
        { openai: null },
        "   ",
      );
      expect(expectErr(result2)).toEqual("API key cannot be empty");
    });

    it("should reject storing API key when provider does not match agent's provider", async () => {
      actor.setIdentity(adminIdentity);
      // Agent was created with OpenAI provider
      // Try to store a Groq API key for it
      const result = await actor.storeApiKey(
        0n,
        agentId,
        { groq: null },
        "test-groq-key",
      );
      const errorMsg = expectErr(result);
      expect(errorMsg).toContain("Provider mismatch");
      expect(errorMsg).toContain("openai");
      expect(errorMsg).toContain("groq");
    });

    it("should allow updating API key (replace existing)", async () => {
      actor.setIdentity(adminIdentity);

      // Store first API key
      const storeResult1 = await actor.storeApiKey(
        0n,
        agentId,
        { openai: null },
        "first-api-key",
      );
      expectOk(storeResult1);

      // Update with new key (same agent, same provider)
      const storeResult2 = await actor.storeApiKey(
        0n,
        agentId,
        { openai: null },
        "updated-api-key",
      );
      expectOk(storeResult2);

      // Should still only have one key entry
      const keysResult = await actor.getWorkspaceApiKeys(0n);
      const keys = expectOk(keysResult);
      expect(keys.length).toBe(1);
    });
  });

  describe("get_workspace_api_keys", () => {
    it("should reject non-admins from viewing API keys", async () => {
      actor.setIdentity(userIdentity);
      const result = await actor.getWorkspaceApiKeys(0n);
      expect(expectErr(result)).toEqual(
        "Only workspace admins can view which API keys exist",
      );
    });

    it("should return empty array when workspace has no API keys", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.getWorkspaceApiKeys(0n);
      const keys = expectOk(result);
      expect(keys).toEqual([]);
    });

    it("should maintain API key list after storing multiple keys", async () => {
      actor.setIdentity(adminIdentity);

      // Create multiple agents
      const agent1 = agentId;
      const agent2 = await createTestAgent(
        actor,
        "Agent 2",
        { groq: null },
        "mixtral",
      );
      const agent3 = await createTestAgent(
        actor,
        "Agent 3",
        { groq: null },
        "llama",
      );

      // Store keys as admin
      await actor.storeApiKey(0n, agent1, { openai: null }, "key-1");
      await actor.storeApiKey(0n, agent2, { groq: null }, "key-2");
      await actor.storeApiKey(0n, agent3, { groq: null }, "key-3");

      // Retrieve and verify all keys are present
      const result = await actor.getWorkspaceApiKeys(0n);
      const keys = expectOk(result);
      expect(keys.length).toEqual(3);

      // Verify specific keys
      expect(
        keys.some(
          (k: [bigint, string]) => k[0] === agent1 && k[1] === "openai",
        ),
      ).toBe(true);
      expect(
        keys.some((k: [bigint, string]) => k[0] === agent2 && k[1] === "groq"),
      ).toBe(true);
      expect(
        keys.some((k: [bigint, string]) => k[0] === agent3 && k[1] === "groq"),
      ).toBe(true);
    });
  });

  describe("delete_api_key", () => {
    it("should reject non-admins from deleting API keys", async () => {
      actor.setIdentity(userIdentity);
      const result = await actor.deleteApiKey(0n, agentId, { openai: null });
      expect(expectErr(result)).toEqual(
        "Only workspace admins can delete API keys",
      );
    });

    it("should return error when trying to delete API key for workspace with no keys", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.deleteApiKey(0n, agentId, { openai: null });
      expect(expectErr(result)).toEqual("No API keys found for this workspace");
    });

    it("should successfully delete an API key", async () => {
      actor.setIdentity(adminIdentity);

      // Store an API key first
      const storeResult = await actor.storeApiKey(
        0n,
        agentId,
        { openai: null },
        "test-key-to-delete",
      );
      expectOk(storeResult);

      // Verify key is stored
      const keysBeforeDelete = await actor.getWorkspaceApiKeys(0n);
      const keysBefore = expectOk(keysBeforeDelete);
      expect(keysBefore.length).toEqual(1);

      // Delete the key
      const deleteResult = await actor.deleteApiKey(0n, agentId, {
        openai: null,
      });
      expectOk(deleteResult);

      // Verify key is deleted
      const keysAfterDelete = await actor.getWorkspaceApiKeys(0n);
      const keysAfter = expectOk(keysAfterDelete);
      expect(keysAfter.length).toEqual(0);
    });

    it("should only delete the specified key, not all keys", async () => {
      actor.setIdentity(adminIdentity);

      // Create multiple agents
      const agent1 = agentId;
      const agent2 = await createTestAgent(
        actor,
        "Agent 2",
        { groq: null },
        "mixtral",
      );

      // Store keys for both agents
      await actor.storeApiKey(0n, agent1, { openai: null }, "key-1");
      await actor.storeApiKey(0n, agent2, { groq: null }, "key-2");

      // Verify both keys exist
      const keysBefore = await actor.getWorkspaceApiKeys(0n);
      const keysBeforeArray = expectOk(keysBefore);
      expect(keysBeforeArray.length).toEqual(2);

      // Delete only one key
      const deleteResult = await actor.deleteApiKey(0n, agent1, {
        openai: null,
      });
      expectOk(deleteResult);

      // Verify only one key remains
      const keysAfter = await actor.getWorkspaceApiKeys(0n);
      const keysAfterArray = expectOk(keysAfter);
      expect(keysAfterArray.length).toEqual(1);
      expect(keysAfterArray[0][0]).toEqual(agent2);
      expect(keysAfterArray[0][1]).toEqual("groq");
    });

    it("should return error when deleting a non-existent key", async () => {
      actor.setIdentity(adminIdentity);

      // Store an API key first
      await actor.storeApiKey(0n, agentId, { openai: null }, "test-key");

      // Try to delete a key for a different provider (non-existent)
      const deleteResult = await actor.deleteApiKey(0n, agentId, {
        groq: null,
      });
      const errorMsg = expectErr(deleteResult);
      expect(errorMsg).toContain("No API key found for agent");
      expect(errorMsg).toContain("groq");

      // Original key should still exist
      const keysResult = await actor.getWorkspaceApiKeys(0n);
      const keys = expectOk(keysResult);
      expect(keys.length).toEqual(1);
      expect(keys[0][0]).toEqual(agentId);
      expect(keys[0][1]).toEqual("openai");
    });
  });

  describe("workspace-level API key sharing", () => {
    it("should allow all admins to see workspace API keys", async () => {
      actor.setIdentity(adminIdentity);

      // Store an API key
      await actor.storeApiKey(0n, agentId, { openai: null }, "shared-key");

      // Create another admin
      const admin2Identity = generateRandomIdentity();
      await actor.addWorkspaceAdmin(0n, admin2Identity.getPrincipal());

      // Second admin should also see the key
      actor.setIdentity(admin2Identity);
      const keysResult = await actor.getWorkspaceApiKeys(0n);
      const keys = expectOk(keysResult);
      expect(keys.length).toEqual(1);
      expect(keys[0][0]).toEqual(agentId);
      expect(keys[0][1]).toEqual("openai");
    });
  });
});
