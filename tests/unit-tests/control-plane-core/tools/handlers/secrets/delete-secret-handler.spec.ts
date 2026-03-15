import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// DeleteSecretHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext
//      - Slack secrets (slackBotToken, slackSigningSecret): #IsPrimaryOwner or #IsOrgAdmin only
//      - LLM keys (openRouterApiKey, openaiApiKey): #IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin
//   2. Parses JSON args for { workspaceId: number, secretId: string }
//   3. Deletes the specified secret from the secrets map
//
// The test canister starts with an empty secrets map.
// ============================================

function parseResponse(json: string): {
  success: boolean;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

const NO_AUTH = {
  isPrimaryOwner: false,
  isOrgAdmin: false,
  workspaceAdminFor: [] as [] | [bigint],
};
const PRIMARY_OWNER = {
  isPrimaryOwner: true,
  isOrgAdmin: false,
  workspaceAdminFor: [] as [] | [bigint],
};
const ORG_ADMIN = {
  isPrimaryOwner: false,
  isOrgAdmin: true,
  workspaceAdminFor: [] as [] | [bigint],
};
const WORKSPACE_ADMIN_0 = {
  isPrimaryOwner: false,
  isOrgAdmin: false,
  workspaceAdminFor: [0n] as [] | [bigint],
};

describe("DeleteSecretHandler", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("authorization", () => {
    it("should reject unauthorized callers for LLM key deletion", async () => {
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "openRouterApiKey" }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should reject unauthorized callers for Slack secret deletion", async () => {
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "slackBotToken" }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should reject workspace admin from deleting Slack secrets", async () => {
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "slackSigningSecret" }),
        WORKSPACE_ADMIN_0,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow workspace admin to delete LLM keys", async () => {
      // First store a key
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "sk-test",
        }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "openRouterApiKey" }),
        WORKSPACE_ADMIN_0,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testDeleteSecretHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when workspaceId is missing", async () => {
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ secretId: "openRouterApiKey" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("workspaceId");
    });

    it("should return error for invalid secretId", async () => {
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "notAValidSecret" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("secretId");
    });
  });

  describe("not-found errors", () => {
    it("should return error when workspace has no secrets", async () => {
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "openRouterApiKey" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("No secrets found");
    });

    it("should return error when the specific secret does not exist", async () => {
      // Store a different secret first
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openaiApiKey",
          secretValue: "sk-openai",
        }),
        PRIMARY_OWNER,
      );
      // Try to delete openRouterApiKey which was never stored
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "openRouterApiKey" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("openRouterApiKey");
    });
  });

  describe("happy path", () => {
    it("should delete a stored secret successfully", async () => {
      // Store two secrets
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "sk-test",
        }),
        PRIMARY_OWNER,
      );
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openaiApiKey",
          secretValue: "sk-openai-test",
        }),
        ORG_ADMIN,
      );

      // Delete one
      const deleteResult = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "openRouterApiKey" }),
        PRIMARY_OWNER,
      );
      const deleteResponse = parseResponse(deleteResult);
      expect(deleteResponse.success).toBe(true);

      // Verify only openaiApiKey remains
      const listResult = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        PRIMARY_OWNER,
      );
      const listResponse = JSON.parse(listResult) as {
        success: boolean;
        secretIds: string[];
      };
      expect(listResponse.success).toBe(true);
      expect(listResponse.secretIds).toHaveLength(1);
      expect(listResponse.secretIds).toContain("openaiApiKey");
      expect(listResponse.secretIds).not.toContain("openRouterApiKey");
    });

    it("should only delete the specified secret (not all secrets)", async () => {
      // Store all four secrets
      for (const secretId of [
        "openRouterApiKey",
        "openaiApiKey",
        "slackBotToken",
        "slackSigningSecret",
      ] as const) {
        await testCanister.testStoreSecretHandler(
          JSON.stringify({ workspaceId: 0, secretId, secretValue: "test-val" }),
          PRIMARY_OWNER,
        );
      }

      // Delete only one
      await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "openaiApiKey" }),
        ORG_ADMIN,
      );

      // Verify three remain
      const listResult = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        PRIMARY_OWNER,
      );
      const listResponse = JSON.parse(listResult) as {
        success: boolean;
        secretIds: string[];
      };
      expect(listResponse.secretIds).toHaveLength(3);
      expect(listResponse.secretIds).not.toContain("openaiApiKey");
    });

    it("should delete a slackSigningSecret successfully (org admin)", async () => {
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "slackSigningSecret",
          secretValue: "signing-secret-value",
        }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "slackSigningSecret" }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should delete a slackSigningSecret successfully (primary owner)", async () => {
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "slackSigningSecret",
          secretValue: "signing-secret-value",
        }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "slackSigningSecret" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow storing the same secretId again after deletion", async () => {
      // Store and delete
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "old-key",
        }),
        PRIMARY_OWNER,
      );
      await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "openRouterApiKey" }),
        PRIMARY_OWNER,
      );

      // Store again
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "new-key",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should delete an anthropicApiKey successfully", async () => {
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "anthropicApiKey",
          secretValue: "sk-ant-test",
        }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "anthropicApiKey" }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(result).success).toBe(true);
    });

    it("should delete an anthropicSetupToken successfully", async () => {
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "anthropicSetupToken",
          secretValue: "setup-token",
        }),
        ORG_ADMIN,
      );
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "anthropicSetupToken" }),
        ORG_ADMIN,
      );
      expect(parseResponse(result).success).toBe(true);
    });

    it("should delete a custom:<name> secret successfully", async () => {
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "custom:team-key",
          secretValue: "custom-value",
        }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "custom:team-key" }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(result).success).toBe(true);
    });

    it("should allow workspace admin to delete anthropicApiKey", async () => {
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "anthropicApiKey",
          secretValue: "sk-ant-ws",
        }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testDeleteSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "anthropicApiKey" }),
        WORKSPACE_ADMIN_0,
      );
      expect(parseResponse(result).success).toBe(true);
    });
  });
});
