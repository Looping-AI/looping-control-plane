import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetWorkspaceSecretsHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext
//      (#IsPrimaryOwner, #IsOrgAdmin, or #IsWorkspaceAdmin)
//   2. Parses JSON args for { workspaceId: number }
//   3. Returns the list of stored secretId name strings (no values)
//
// The test canister starts with an empty secrets map.
// ============================================

function parseResponse(json: string): {
  success: boolean;
  secretIds?: string[];
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

describe("GetWorkspaceSecretsHandler", () => {
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
    it("should reject unauthorized callers", async () => {
      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to list secrets", async () => {
      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to list secrets", async () => {
      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow workspace admin to list their workspace secrets", async () => {
      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        WORKSPACE_ADMIN_0,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testGetWorkspaceSecretsHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when workspaceId is missing", async () => {
      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({}),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("workspaceId");
    });
  });

  describe("empty state", () => {
    it("should return empty array when no secrets are stored", async () => {
      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.secretIds).toEqual([]);
    });
  });

  describe("after storing secrets", () => {
    it("should list a single stored secret", async () => {
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue: "sk-test",
        }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.secretIds).toHaveLength(1);
      expect(response.secretIds).toContain("openRouterApiKey");
    });

    it("should list multiple stored secrets", async () => {
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

      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.secretIds).toHaveLength(2);
      expect(response.secretIds).toContain("openRouterApiKey");
      expect(response.secretIds).toContain("openaiApiKey");
    });

    it("should not expose secret values — only identifiers", async () => {
      const secretValue = "super-secret-key-12345";
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 0,
          secretId: "openRouterApiKey",
          secretValue,
        }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        PRIMARY_OWNER,
      );
      expect(result).not.toContain(secretValue);
    });

    it("should return empty array for a workspace with no secrets (different workspace)", async () => {
      // Store secret in workspace 1
      await testCanister.testStoreSecretHandler(
        JSON.stringify({
          workspaceId: 1,
          secretId: "openRouterApiKey",
          secretValue: "sk-ws1",
        }),
        PRIMARY_OWNER,
      );

      // Workspace 0 should still be empty
      const result = await testCanister.testGetWorkspaceSecretsHandler(
        JSON.stringify({ workspaceId: 0 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.secretIds).toEqual([]);
    });
  });
});
