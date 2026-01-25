import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@dfinity/principal";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import type { _SERVICE } from "../../setup.ts";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
} from "../../setup.ts";
import { expectOk, expectErr } from "../../helpers.ts";

describe("API Key Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let adminIdentity: ReturnType<typeof generateRandomIdentity>;
  let userIdentity: ReturnType<typeof generateRandomIdentity>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;

    // Set up an admin
    ({ adminIdentity } = await setupAdminUser(actor));

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
      { openai: null },
      "test-key",
    );
    expect(expectErr(storeResult)).toEqual(
      "Please login before calling this function.",
    );

    const getResult = await actor.getWorkspaceApiKeys(0n);
    expect(expectErr(getResult)).toEqual(
      "Please login before calling this function.",
    );

    const deleteResult = await actor.deleteApiKey(0n, {
      openai: null,
    });
    expect(expectErr(deleteResult)).toEqual(
      "Please login before calling this function.",
    );
  });

  describe("store_api_key", () => {
    it("should reject non-admins from storing API keys", async () => {
      actor.setIdentity(userIdentity);
      const result = await actor.storeApiKey(0n, { openai: null }, "test-key");
      expect(expectErr(result)).toEqual(
        "Only workspace admins can perform this action.",
      );
    });

    it("should reject storing empty or whitespace only API key", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.storeApiKey(0n, { openai: null }, "");
      expect(expectErr(result)).toEqual("API key cannot be empty.");

      const result2 = await actor.storeApiKey(0n, { openai: null }, "   ");
      expect(expectErr(result2)).toEqual("API key cannot be empty.");
    });

    it("should allow storing API keys for any provider", async () => {
      actor.setIdentity(adminIdentity);
      // Store keys for different providers - all should succeed
      const result1 = await actor.storeApiKey(
        0n,
        { openai: null },
        "openai-key",
      );
      expectOk(result1);

      const result2 = await actor.storeApiKey(0n, { groq: null }, "groq-key");
      expectOk(result2);
    });

    it("should allow updating API key (replace existing)", async () => {
      actor.setIdentity(adminIdentity);

      // Store first API key
      const storeResult1 = await actor.storeApiKey(
        0n,
        { openai: null },
        "first-api-key",
      );
      expectOk(storeResult1);

      // Update with new key (same provider)
      const storeResult2 = await actor.storeApiKey(
        0n,
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
        "Only workspace admins can perform this action.",
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

      // Store keys for multiple providers
      await actor.storeApiKey(0n, { openai: null }, "key-1");
      await actor.storeApiKey(0n, { groq: null }, "key-2");

      // Retrieve and verify all keys are present
      const result = await actor.getWorkspaceApiKeys(0n);
      const keys = expectOk(result);
      expect(keys.length).toEqual(2);

      // Verify all providers are present
      expect(keys.some((k) => "openai" in k)).toBe(true);
      expect(keys.some((k) => "groq" in k)).toBe(true);
    });
  });

  describe("delete_api_key", () => {
    it("should reject non-admins from deleting API keys", async () => {
      actor.setIdentity(userIdentity);
      const result = await actor.deleteApiKey(0n, { openai: null });
      expect(expectErr(result)).toEqual(
        "Only workspace admins can perform this action.",
      );
    });

    it("should return error when trying to delete API key for workspace with no keys", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.deleteApiKey(0n, { openai: null });
      expect(expectErr(result)).toEqual(
        "No API keys found for this workspace.",
      );
    });

    it("should successfully delete an API key", async () => {
      actor.setIdentity(adminIdentity);

      // Store an API key first
      const storeResult = await actor.storeApiKey(
        0n,
        { openai: null },
        "test-key-to-delete",
      );
      expectOk(storeResult);

      // Verify key is stored
      const keysBeforeDelete = await actor.getWorkspaceApiKeys(0n);
      const keysBefore = expectOk(keysBeforeDelete);
      expect(keysBefore.length).toEqual(1);

      // Delete the key
      const deleteResult = await actor.deleteApiKey(0n, {
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

      // Store keys for multiple providers
      await actor.storeApiKey(0n, { openai: null }, "key-1");
      await actor.storeApiKey(0n, { groq: null }, "key-2");

      // Verify both keys exist
      const keysBefore = await actor.getWorkspaceApiKeys(0n);
      const keysBeforeArray = expectOk(keysBefore);
      expect(keysBeforeArray.length).toEqual(2);

      // Delete only one key
      const deleteResult = await actor.deleteApiKey(0n, { openai: null });
      expectOk(deleteResult);

      // Verify only one key remains
      const keysAfter = await actor.getWorkspaceApiKeys(0n);
      const keysAfterArray = expectOk(keysAfter);
      expect(keysAfterArray.length).toEqual(1);
      expect(keysAfterArray[0]).toHaveProperty("groq");
    });

    it("should return error when deleting a non-existent key", async () => {
      actor.setIdentity(adminIdentity);

      // Store an API key first
      await actor.storeApiKey(0n, { openai: null }, "test-key");

      // Try to delete a key for a different provider (non-existent)
      const deleteResult = await actor.deleteApiKey(0n, { groq: null });
      const errorMsg = expectErr(deleteResult);
      expect(errorMsg).toContain("No API key found for provider");
      expect(errorMsg).toContain("groq");

      // Original key should still exist
      const keysResult = await actor.getWorkspaceApiKeys(0n);
      const keys = expectOk(keysResult);
      expect(keys.length).toEqual(1);
      expect(keys[0]).toHaveProperty("openai");
    });
  });

  describe("workspace-level API key sharing", () => {
    it("should allow all admins to see workspace API keys", async () => {
      actor.setIdentity(adminIdentity);

      // Store an API key
      await actor.storeApiKey(0n, { openai: null }, "shared-key");

      // Create another admin
      const admin2Identity = generateRandomIdentity();
      await actor.addWorkspaceAdmin(0n, admin2Identity.getPrincipal());

      // Second admin should also see the key
      actor.setIdentity(admin2Identity);
      const keysResult = await actor.getWorkspaceApiKeys(0n);
      const keys = expectOk(keysResult);
      expect(keys.length).toEqual(1);
      expect(keys[0]).toHaveProperty("openai");
    });
  });
});
