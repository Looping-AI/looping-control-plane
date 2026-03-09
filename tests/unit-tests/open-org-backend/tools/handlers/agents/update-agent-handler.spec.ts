import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// UpdateAgentHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Parses JSON args for { id, name?, category?, llmModel?, secretsAllowed?,
//      toolsDisallowed?, toolsMisconfigured?, sources? }
//   3. Applies the patch to the agent record in AgentRegistryState
// ============================================

function parseResponse(json: string): {
  success: boolean;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

const NO_AUTH = { isPrimaryOwner: false, isOrgAdmin: false };
const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };
const ORG_ADMIN = { isPrimaryOwner: false, isOrgAdmin: true };

describe("UpdateAgentHandler", () => {
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
      // Register first so there is something to update
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "AdminBot", category: "admin" }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, name: "UpdatedBot" }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to update an agent", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "AdminBot", category: "admin" }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, name: "NewName" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to update an agent", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "AdminBot", category: "admin" }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, category: "planning" }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testUpdateAgentHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when id field is missing", async () => {
      const result = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ name: "NoId" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: id");
    });

    it("should return error when agent id does not exist", async () => {
      const result = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 999, name: "Ghost" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
    });
  });

  describe("field updates", () => {
    beforeEach(async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "original-name", category: "admin" }),
        PRIMARY_OWNER,
      );
    });

    it("should update the agent name and confirm via get", async () => {
      const updateResult = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, name: "renamed-agent" }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(updateResult).success).toBe(true);

      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ id: 0 }),
      );
      const agent = (JSON.parse(getResult) as { agent: { name: string } })
        .agent;
      expect(agent.name).toBe("renamed-agent");
    });

    it("should update the agent category and confirm via get", async () => {
      const updateResult = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, category: "research" }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(updateResult).success).toBe(true);

      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ id: 0 }),
      );
      const agent = (JSON.parse(getResult) as { agent: { category: string } })
        .agent;
      expect(agent.category).toBe("research");
    });

    it("should return success message on successful update", async () => {
      const result = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, name: "Patched" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.message).toContain("updated");
    });
  });
});
