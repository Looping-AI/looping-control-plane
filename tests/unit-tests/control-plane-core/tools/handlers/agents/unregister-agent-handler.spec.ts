import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// UnregisterAgentHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Parses JSON args for { id: number }
//   3. Permanently removes the agent from AgentRegistryState
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

describe("UnregisterAgentHandler", () => {
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
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "AdminBot", category: "admin" }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUnregisterAgentHandler(
        JSON.stringify({ id: 0 }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to unregister an agent", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "AdminBot", category: "planning" }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUnregisterAgentHandler(
        JSON.stringify({ id: 0 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to unregister an agent", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "AdminBot", category: "planning" }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUnregisterAgentHandler(
        JSON.stringify({ id: 0 }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testUnregisterAgentHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when id field is missing", async () => {
      const result = await testCanister.testUnregisterAgentHandler(
        JSON.stringify({}),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: id");
    });

    it("should return error for a non-existent id", async () => {
      const result = await testCanister.testUnregisterAgentHandler(
        JSON.stringify({ id: 999 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
    });
  });

  describe("happy path", () => {
    it("should remove the agent from the registry", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "to-be-deleted", category: "planning" }),
        PRIMARY_OWNER,
      );

      const unregisterResult = await testCanister.testUnregisterAgentHandler(
        JSON.stringify({ id: 0 }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(unregisterResult).success).toBe(true);

      // The agent should no longer be findable
      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ id: 0 }),
      );
      const getResponse = JSON.parse(getResult) as {
        success: boolean;
        error?: string;
      };
      expect(getResponse.success).toBe(false);
      expect(getResponse.error).toContain("not found");
    });

    it("should return success message on successful unregistration", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "removable-agent", category: "planning" }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUnregisterAgentHandler(
        JSON.stringify({ id: 0 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.message).toContain("unregistered");
    });

    it("should reduce the agent count in the list after unregistering", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "agent-one", category: "admin" }),
        PRIMARY_OWNER,
      );
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "agent-two", category: "planning" }),
        PRIMARY_OWNER,
      );

      // Delete the planning agent (id 1) — the admin agent must remain.
      await testCanister.testUnregisterAgentHandler(
        JSON.stringify({ id: 1 }),
        PRIMARY_OWNER,
      );

      const listResult = await testCanister.testListAgentsHandler("{}");
      const list = JSON.parse(listResult) as {
        success: boolean;
        agents: unknown[];
      };
      expect(list.agents).toHaveLength(1);
    });

    it("should prevent deleting the last admin agent", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "sole-admin", category: "admin" }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUnregisterAgentHandler(
        JSON.stringify({ id: 0 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("last admin agent");
    });

    it("should allow deleting a non-last admin agent when another admin exists", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "admin-a", category: "admin" }),
        PRIMARY_OWNER,
      );
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({ name: "admin-b", category: "admin" }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUnregisterAgentHandler(
        JSON.stringify({ id: 0 }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });
});
