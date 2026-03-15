import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// RegisterAgentHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Parses JSON args for { name, category, llmModel?, secretsAllowed?,
//      toolsDisallowed?, toolsMisconfigured?, sources? }
//   3. Registers the agent in AgentRegistryState
//
// The test canister starts with an empty agent registry so the first
// registered agent gets ID 0.
// ============================================

function parseResponse(json: string): {
  success: boolean;
  id?: number;
  name?: string;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

const NO_AUTH = { isPrimaryOwner: false, isOrgAdmin: false };
const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };
const ORG_ADMIN = { isPrimaryOwner: false, isOrgAdmin: true };

describe("RegisterAgentHandler", () => {
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
    it("should return error when caller has no permissions", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "test-agent", category: "admin" }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to register an agent", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "test-agent",
          category: "admin",
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to register an agent", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "research-agent",
          category: "research",
          executionType: { type: "api" },
        }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when name field is missing", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({ category: "admin" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: name");
    });

    it("should return error when category field is missing", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "TestAgent" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: category");
    });

    it("should return error for an invalid category value", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "TestAgent", category: "unknown" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Invalid category");
    });
  });

  describe("happy path", () => {
    it("should register an agent and return id 0 for the first agent", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "admin-bot",
          category: "admin",
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBe(0);
      expect(response.name).toBe("admin-bot");
      expect(response.message).toContain("admin-bot");
    });

    it("should assign incrementing IDs to successive agents", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "first-agent",
          category: "admin",
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "second-agent",
          category: "planning",
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBe(1);
    });

    it("should accept all optional fields without error", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "research-bot",
          category: "research",
          executionType: { type: "api" },
          llmModel: "gpt_oss_120b",
          toolsDisallowed: ["web_search"],
          sources: ["https://example.com"],
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("duplicate name", () => {
    it("should return error when registering an agent with an existing name", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "unique-agent",
          category: "admin",
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "unique-agent",
          category: "planning",
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toBeDefined();
    });
  });

  describe("secretOverrides", () => {
    it("should register with secretOverrides and persist them", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "override-bot",
          category: "admin",
          executionType: { type: "api" },
          secretsAllowed: [{ workspaceId: 0, secretId: "openRouterApiKey" }],
          secretOverrides: [
            { secretId: "openRouterApiKey", customKeyName: "my-custom-key" },
          ],
        }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(result).success).toBe(true);

      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ name: "override-bot" }),
      );
      const agent = (
        JSON.parse(getResult) as {
          agent: {
            secretOverrides: Array<{
              secretId: string;
              customKeyName: string;
            }>;
          };
        }
      ).agent;
      expect(agent.secretOverrides).toHaveLength(1);
      expect(agent.secretOverrides[0].secretId).toBe("openRouterApiKey");
      expect(agent.secretOverrides[0].customKeyName).toBe("my-custom-key");
    });

    it("should default secretOverrides to empty array when omitted", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "no-overrides-bot",
          category: "research",
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );
      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ name: "no-overrides-bot" }),
      );
      const agent = (
        JSON.parse(getResult) as {
          agent: { secretOverrides: unknown[] };
        }
      ).agent;
      expect(agent.secretOverrides).toEqual([]);
    });

    it("should NOT accept custom:<name> secretId in secretOverrides", async () => {
      const result = await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "custom-override-bot",
          category: "planning",
          executionType: { type: "api" },
          secretOverrides: [
            {
              secretId: "custom:anthropicApiKey",
              customKeyName: "team-anthropic",
            },
          ],
        }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(result).success).toBe(false);
    });
  });
});
