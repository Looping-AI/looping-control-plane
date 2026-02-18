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

describe("Secrets Management", () => {
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

  it("should reject anonymous users from secret operations", async () => {
    actor.setPrincipal(Principal.anonymous());

    const storeResult = await actor.storeSecret(
      0n,
      { openaiApiKey: null },
      "test-key",
    );
    expect(expectErr(storeResult)).toEqual(
      "Please login before calling this function.",
    );

    const getResult = await actor.getWorkspaceSecrets(0n);
    expect(expectErr(getResult)).toEqual(
      "Please login before calling this function.",
    );

    const deleteResult = await actor.deleteSecret(0n, {
      openaiApiKey: null,
    });
    expect(expectErr(deleteResult)).toEqual(
      "Please login before calling this function.",
    );
  });

  describe("storeSecret", () => {
    it("should reject non-admins from storing LLM API keys", async () => {
      actor.setIdentity(userIdentity);
      const result = await actor.storeSecret(
        0n,
        { openaiApiKey: null },
        "test-key",
      );
      expect(expectErr(result)).toEqual(
        "Only org owner, org admins, workspace admins can perform this action.",
      );
    });

    it("should reject storing empty or whitespace only secret", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.storeSecret(0n, { openaiApiKey: null }, "");
      expect(expectErr(result)).toEqual("Secret cannot be empty.");

      const result2 = await actor.storeSecret(
        0n,
        { openaiApiKey: null },
        "   ",
      );
      expect(expectErr(result2)).toEqual("Secret cannot be empty.");
    });

    it("should allow storing secrets for any secret ID", async () => {
      actor.setIdentity(adminIdentity);
      // Store secrets for different IDs - all should succeed
      const result1 = await actor.storeSecret(
        0n,
        { openaiApiKey: null },
        "openai-key",
      );
      expectOk(result1);

      const result2 = await actor.storeSecret(
        0n,
        { groqApiKey: null },
        "groq-key",
      );
      expectOk(result2);
    });

    it("should allow updating a secret (replace existing)", async () => {
      actor.setIdentity(adminIdentity);

      // Store first secret
      const storeResult1 = await actor.storeSecret(
        0n,
        { openaiApiKey: null },
        "first-api-key",
      );
      expectOk(storeResult1);

      // Update with new value (same secret ID)
      const storeResult2 = await actor.storeSecret(
        0n,
        { openaiApiKey: null },
        "updated-api-key",
      );
      expectOk(storeResult2);

      // Should still only have one entry
      const secretsResult = await actor.getWorkspaceSecrets(0n);
      const secrets = expectOk(secretsResult);
      expect(secrets.length).toBe(1);
    });

    it("should require org-level auth for Slack secrets", async () => {
      // Workspace admin (not org admin) should be rejected for Slack secrets
      actor.setIdentity(userIdentity);
      const result = await actor.storeSecret(
        0n,
        { slackSigningSecret: null },
        "slack-secret",
      );
      expect(expectErr(result)).toEqual(
        "Only org owner, org admins can perform this action.",
      );
    });
  });

  describe("getWorkspaceSecrets", () => {
    it("should reject non-admins from viewing secrets", async () => {
      actor.setIdentity(userIdentity);
      const result = await actor.getWorkspaceSecrets(0n);
      expect(expectErr(result)).toEqual(
        "Only org owner, org admins, workspace admins can perform this action.",
      );
    });

    it("should return empty array when workspace has no secrets", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.getWorkspaceSecrets(0n);
      const secrets = expectOk(result);
      expect(secrets).toEqual([]);
    });

    it("should maintain secret list after storing multiple secrets", async () => {
      actor.setIdentity(adminIdentity);

      // Store secrets for multiple IDs
      await actor.storeSecret(0n, { openaiApiKey: null }, "key-1");
      await actor.storeSecret(0n, { groqApiKey: null }, "key-2");

      // Retrieve and verify all are present
      const result = await actor.getWorkspaceSecrets(0n);
      const secrets = expectOk(result);
      expect(secrets.length).toEqual(2);

      // Verify all IDs are present
      expect(secrets.some((s) => "openaiApiKey" in s)).toBe(true);
      expect(secrets.some((s) => "groqApiKey" in s)).toBe(true);
    });
  });

  describe("deleteSecret", () => {
    it("should reject non-admins from deleting secrets", async () => {
      actor.setIdentity(userIdentity);
      const result = await actor.deleteSecret(0n, { openaiApiKey: null });
      expect(expectErr(result)).toEqual(
        "Only org owner, org admins, workspace admins can perform this action.",
      );
    });

    it("should return error when trying to delete secret for workspace with no secrets", async () => {
      actor.setIdentity(adminIdentity);
      const result = await actor.deleteSecret(0n, { openaiApiKey: null });
      expect(expectErr(result)).toEqual("No secrets found for this workspace.");
    });

    it("should successfully delete a secret", async () => {
      actor.setIdentity(adminIdentity);

      // Store a secret first
      const storeResult = await actor.storeSecret(
        0n,
        { openaiApiKey: null },
        "test-key-to-delete",
      );
      expectOk(storeResult);

      // Verify it's stored
      const secretsBeforeDelete = await actor.getWorkspaceSecrets(0n);
      const secretsBefore = expectOk(secretsBeforeDelete);
      expect(secretsBefore.length).toEqual(1);

      // Delete it
      const deleteResult = await actor.deleteSecret(0n, {
        openaiApiKey: null,
      });
      expectOk(deleteResult);

      // Verify it's gone
      const secretsAfterDelete = await actor.getWorkspaceSecrets(0n);
      const secretsAfter = expectOk(secretsAfterDelete);
      expect(secretsAfter.length).toEqual(0);
    });

    it("should only delete the specified secret, not all secrets", async () => {
      actor.setIdentity(adminIdentity);

      // Store secrets for multiple IDs
      await actor.storeSecret(0n, { openaiApiKey: null }, "key-1");
      await actor.storeSecret(0n, { groqApiKey: null }, "key-2");

      // Verify both exist
      const secretsBefore = await actor.getWorkspaceSecrets(0n);
      const secretsBeforeArray = expectOk(secretsBefore);
      expect(secretsBeforeArray.length).toEqual(2);

      // Delete only one
      const deleteResult = await actor.deleteSecret(0n, {
        openaiApiKey: null,
      });
      expectOk(deleteResult);

      // Verify only one remains
      const secretsAfter = await actor.getWorkspaceSecrets(0n);
      const secretsAfterArray = expectOk(secretsAfter);
      expect(secretsAfterArray.length).toEqual(1);
      expect(secretsAfterArray[0]).toHaveProperty("groqApiKey");
    });

    it("should return error when deleting a non-existent secret", async () => {
      actor.setIdentity(adminIdentity);

      // Store a secret first
      await actor.storeSecret(0n, { openaiApiKey: null }, "test-key");

      // Try to delete a different secret ID (non-existent)
      const deleteResult = await actor.deleteSecret(0n, { groqApiKey: null });
      const errorMsg = expectErr(deleteResult);
      expect(errorMsg).toContain("No secret found for");
      expect(errorMsg).toContain("groqApiKey");

      // Original secret should still exist
      const secretsResult = await actor.getWorkspaceSecrets(0n);
      const secrets = expectOk(secretsResult);
      expect(secrets.length).toEqual(1);
      expect(secrets[0]).toHaveProperty("openaiApiKey");
    });
  });

  describe("workspace-level secret sharing", () => {
    it("should allow all admins to see workspace secrets", async () => {
      actor.setIdentity(adminIdentity);

      // Store a secret
      await actor.storeSecret(0n, { openaiApiKey: null }, "shared-key");

      // Create another admin
      const admin2Identity = generateRandomIdentity();
      await actor.addWorkspaceAdmin(0n, admin2Identity.getPrincipal());

      // Second admin should also see the secret
      actor.setIdentity(admin2Identity);
      const secretsResult = await actor.getWorkspaceSecrets(0n);
      const secrets = expectOk(secretsResult);
      expect(secrets.length).toEqual(1);
      expect(secrets[0]).toHaveProperty("openaiApiKey");
    });
  });
});
