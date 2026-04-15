import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
  freshTestCanister,
} from "../../../../../setup";

// ============================================
// UpdateAgentHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Parses JSON args for { id, name?, executionEngines?, model?,
//      secretsAllowed?, secretOverrides?, allowedChannelIds? }
//   3. Applies the patch to the agent record in AgentRegistryState
//      (Note: category is immutable after creation)
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

  beforeAll(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
  });

  beforeEach(async () => {
    testCanister = (await freshTestCanister(pic)).actor;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  describe("authorization", () => {
    it("should return error when caller has no permissions", async () => {
      // Register first so there is something to update
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "AdminBot",
          executionEngines: ["api"],
          allowedChannelIds: ["C_TEST"],
        }),
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
        JSON.stringify({
          name: "AdminBot",
          executionEngines: ["api"],
          allowedChannelIds: ["C_TEST"],
        }),
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
        JSON.stringify({
          name: "AdminBot",
          executionEngines: ["api"],
          allowedChannelIds: ["C_TEST"],
        }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, executionEngines: ["canister"] }),
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
        JSON.stringify({
          name: "original-name",
          executionEngines: ["api"],
          allowedChannelIds: ["C_TEST"],
        }),
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
      const agent = (
        JSON.parse(getResult) as { agent: { config: { name: string } } }
      ).agent;
      expect(agent.config.name).toBe("renamed-agent");
    });

    it("should update executionEngines and confirm via get", async () => {
      const updateResult = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, executionEngines: ["canister"] }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(updateResult).success).toBe(true);

      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ id: 0 }),
      );
      const agent = (
        JSON.parse(getResult) as {
          agent: { config: { executionEngines: string[] } };
        }
      ).agent;
      expect(agent.config.executionEngines).toEqual(["canister"]);
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

    it("should return error when executionEngines array is empty", async () => {
      const result = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, executionEngines: [] }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain(
        "executionEngines must be non-empty when provided",
      );
    });

    it("should update secretOverrides and confirm via get", async () => {
      const updateResult = await testCanister.testUpdateAgentHandler(
        JSON.stringify({
          id: 0,
          secretOverrides: [
            { secretId: "openRouterApiKey", customKeyName: "ws-key" },
          ],
        }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(updateResult).success).toBe(true);

      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ id: 0 }),
      );
      const agent = (
        JSON.parse(getResult) as {
          agent: {
            config: {
              secrets: {
                overrides: Array<{
                  secretId: string;
                  customKeyName: string;
                }>;
              };
            };
          };
        }
      ).agent;
      expect(agent.config.secrets.overrides).toHaveLength(1);
      expect(agent.config.secrets.overrides[0].secretId).toBe(
        "openRouterApiKey",
      );
      expect(agent.config.secrets.overrides[0].customKeyName).toBe("ws-key");
    });

    it("should clear secretOverrides when updated to empty array", async () => {
      // Seed an agent that has an override
      await testCanister.testUpdateAgentHandler(
        JSON.stringify({
          id: 0,
          secretOverrides: [
            { secretId: "anthropicApiKey", customKeyName: "to-clear" },
          ],
        }),
        PRIMARY_OWNER,
      );

      // Now clear overrides
      const clearResult = await testCanister.testUpdateAgentHandler(
        JSON.stringify({ id: 0, secretOverrides: [] }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(clearResult).success).toBe(true);

      const getResult = await testCanister.testGetAgentHandler(
        JSON.stringify({ id: 0 }),
      );
      const agent = (
        JSON.parse(getResult) as {
          agent: { config: { secrets: { overrides: unknown[] } } };
        }
      ).agent;
      expect(agent.config.secrets.overrides).toEqual([]);
    });
  });
});
