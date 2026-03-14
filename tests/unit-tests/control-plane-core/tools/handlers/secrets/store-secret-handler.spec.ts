import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// StoreSecretHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext
//      - Slack secrets (slackBotToken, slackSigningSecret): #IsPrimaryOwner or #IsOrgAdmin only
//      - LLM keys (openRouterApiKey, openaiApiKey): #IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin
//   2. Validates input: workspaceId (number), secretId (string enum), secretValue (non-empty string)
//   3. Verifies the workspace exists
//   4. Derives encryption key from the key cache (pre-seeded with dummy key)
//   5. Stores the encrypted secret in the secrets map
//
// The test canister starts with an empty secrets map.
// testWorkspacesState has workspaces 0, 1, and 2 pre-seeded.
// testSecretsKeyCache is pre-seeded with all-zeros dummy key for workspaces 0, 1, 2.
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

describe("StoreSecretHandler", () => {
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
    it("should reject unauthorized callers for LLM key", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "sk-test",
        }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should reject unauthorized callers for Slack secret", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "slackBotToken",
          secretValue: "xoxb-test",
        }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to store any secret", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "sk-test",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to store any secret", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openaiApiKey",
          secretValue: "sk-openai-test",
        }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow workspace admin to store LLM keys", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "sk-test",
        }),
        WORKSPACE_ADMIN_0,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should reject workspace admin from storing Slack secrets", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "slackSigningSecret",
          secretValue: "signing-secret",
        }),
        WORKSPACE_ADMIN_0,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testStoreSecretHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when workspaceId is missing", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          secretId: "openRouterApiKey",
          secretValue: "sk-test",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("workspaceId");
    });

    it("should return error for invalid secretId", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "invalidSecret",
          secretValue: "value",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("secretId");
    });

    it("should return error when secretValue is missing", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({ workspaceId: 0, secretId: "openRouterApiKey" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("secretValue");
    });

    it("should return error for empty secret value", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("empty");
    });

    it("should return error for whitespace-only secret value", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "   ",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("empty");
    });

    it("should return error when workspace does not exist", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 999,
          secretId: "openRouterApiKey",
          secretValue: "sk-test",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Workspace not found");
    });

    it("should reject slackBotToken on non-zero workspace", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 1,
          secretId: "slackBotToken",
          secretValue: "xoxb-test",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("workspace 0");
    });

    it("should reject slackSigningSecret on non-zero workspace", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 1,
          secretId: "slackSigningSecret",
          secretValue: "signing-secret",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("workspace 0");
    });

    it("should allow LLM keys on non-zero workspaces", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 1,
          secretId: "openRouterApiKey",
          secretValue: "sk-test",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("happy path", () => {
    it("should store an openRouterApiKey successfully", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "gsk-test-key-1",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.message).toContain("stored");
    });

    it("should store a slackBotToken successfully (org admin)", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "slackBotToken",
          secretValue: "xoxb-test-bot-token",
        }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should store a slackSigningSecret successfully (org admin)", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "slackSigningSecret",
          secretValue: "signing-secret-value",
        }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should store a slackSigningSecret successfully (primary owner)", async () => {
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "slackSigningSecret",
          secretValue: "signing-secret-value",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow updating an existing secret (same secretId)", async () => {
      // Store first value
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "first-value",
        }),
        PRIMARY_OWNER,
      );
      // Overwrite with new value
      const result = await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "second-value",
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      // Verify only one secretId remains
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
    });
  });
});
