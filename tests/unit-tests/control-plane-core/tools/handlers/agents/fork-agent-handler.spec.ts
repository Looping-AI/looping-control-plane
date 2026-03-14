import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// ForkAgentHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Parses JSON args for { originalId, newName, targetWorkspaceId,
//      secretsAllowed?, executionType? }
//   3. Forks the agent in AgentRegistryState, inheriting the original's
//      executionType when the field is omitted, or applying the override
//      when supplied.
//
// A source agent is seeded via testRegisterAgentHandler (gets ID 0) before
// the fork calls are made.
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

/** Register a source agent and return its assigned ID. */
async function seedAgent(
  testCanister: Actor<TestCanisterService>,
  name = "source-agent",
): Promise<number> {
  const result = await testCanister.testRegisterAgentHandler(
    JSON.stringify({
      name,
      category: "admin",
      executionType: { type: "api" },
    }),
    PRIMARY_OWNER,
  );
  return parseResponse(result).id!;
}

describe("ForkAgentHandler", () => {
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

  // ------------------------------------------------------------------
  // Authorization
  // ------------------------------------------------------------------

  describe("authorization", () => {
    it("should return error when caller has no permissions", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "forked-agent",
          targetWorkspaceId: 1,
        }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to fork an agent", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "forked-by-owner",
          targetWorkspaceId: 1,
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to fork an agent", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "forked-by-admin",
          targetWorkspaceId: 2,
        }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  // ------------------------------------------------------------------
  // Argument validation
  // ------------------------------------------------------------------

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testForkAgentHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when originalId field is missing", async () => {
      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({ newName: "forked", targetWorkspaceId: 1 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: originalId");
    });

    it("should return error when newName field is missing", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({ originalId, targetWorkspaceId: 1 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: newName");
    });

    it("should return error when targetWorkspaceId field is missing", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({ originalId, newName: "forked" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain(
        "Missing required field: targetWorkspaceId",
      );
    });

    it("should return error when originalId is negative", async () => {
      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId: -1,
          newName: "forked",
          targetWorkspaceId: 1,
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain(
        "originalId must be a non-negative integer",
      );
    });

    it("should return error when targetWorkspaceId is negative", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "forked",
          targetWorkspaceId: -5,
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain(
        "targetWorkspaceId must be a non-negative integer",
      );
    });

    it("should return error for an invalid executionType value", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "forked",
          targetWorkspaceId: 1,
          executionType: { type: "unknown" },
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Invalid executionType");
    });

    it("should return error for a malformed secretsAllowed entry", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "forked",
          targetWorkspaceId: 1,
          // missing required secretId field
          secretsAllowed: [{ workspaceId: 1 }],
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Invalid secretsAllowed");
    });

    it("should return error when originalId does not exist", async () => {
      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId: 999,
          newName: "forked",
          targetWorkspaceId: 1,
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
    });
  });

  // ------------------------------------------------------------------
  // Happy path
  // ------------------------------------------------------------------

  describe("happy path", () => {
    it("should fork an agent and return a new id with the given name", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "forked-agent",
          targetWorkspaceId: 1,
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.id).toBeDefined();
      expect(response.id).not.toBe(originalId);
      expect(response.name).toBe("forked-agent");
    });

    it("should include the original id and new id in the message", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "described-fork",
          targetWorkspaceId: 1,
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.message).toContain("described-fork");
      expect(response.message).toContain(String(originalId));
    });

    it("should inherit executionType from original when omitted", async () => {
      // Register original with an explicit api executionType
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "api-agent",
          category: "admin",
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );
      // api-agent is id 0

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId: 0,
          newName: "api-agent-fork",
          targetWorkspaceId: 1,
          // no executionType → inherits #api from original
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.name).toBe("api-agent-fork");
    });

    it("should override executionType when explicitly provided", async () => {
      // Register original with default (#runtime / openClaw) executionType
      const originalId = await seedAgent(testCanister, "runtime-agent");

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "api-override-fork",
          targetWorkspaceId: 1,
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.name).toBe("api-override-fork");
    });

    it("should override executionType with runtime when explicitly provided", async () => {
      // Register original with api executionType
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "plain-api-agent",
          category: "planning",
          executionType: { type: "api" },
        }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId: 0,
          newName: "runtime-override-fork",
          targetWorkspaceId: 2,
          executionType: {
            type: "runtime",
            hosting: "codespace",
            framework: "openClaw",
          },
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.name).toBe("runtime-override-fork");
    });

    it("should accept secretsAllowed entries for the forked agent", async () => {
      const originalId = await seedAgent(testCanister);

      const result = await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "fork-with-secrets",
          targetWorkspaceId: 1,
          secretsAllowed: [
            { workspaceId: 1, secretId: "openRouterApiKey" },
            { workspaceId: 2, secretId: "openaiApiKey" },
          ],
        }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should make the forked agent independently retrievable by name", async () => {
      const originalId = await seedAgent(testCanister, "original-agent");

      await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "retrievable-fork",
          targetWorkspaceId: 1,
        }),
        PRIMARY_OWNER,
      );

      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ name: "retrievable-fork" }),
      );
      const getResponse = JSON.parse(getResult);
      expect(getResponse.success).toBe(true);
      expect(getResponse.agent.name).toBe("retrievable-fork");
    });

    it("should leave the original agent intact after forking", async () => {
      const originalId = await seedAgent(testCanister, "intact-original");

      await testCanister.testForkAgentHandler(
        JSON.stringify({
          originalId,
          newName: "does-not-affect-original",
          targetWorkspaceId: 1,
        }),
        PRIMARY_OWNER,
      );

      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ id: originalId }),
      );
      const getResponse = JSON.parse(getResult);
      expect(getResponse.success).toBe(true);
      expect(getResponse.agent.name).toBe("intact-original");
    });

    it("should allow the same original to be forked multiple times with different names", async () => {
      const originalId = await seedAgent(testCanister);

      const fork1 = parseResponse(
        await testCanister.testForkAgentHandler(
          JSON.stringify({
            originalId,
            newName: "fork-one",
            targetWorkspaceId: 1,
          }),
          PRIMARY_OWNER,
        ),
      );
      const fork2 = parseResponse(
        await testCanister.testForkAgentHandler(
          JSON.stringify({
            originalId,
            newName: "fork-two",
            targetWorkspaceId: 2,
          }),
          PRIMARY_OWNER,
        ),
      );

      expect(fork1.success).toBe(true);
      expect(fork2.success).toBe(true);
      expect(fork1.id).not.toBe(fork2.id);
    });
  });
});
