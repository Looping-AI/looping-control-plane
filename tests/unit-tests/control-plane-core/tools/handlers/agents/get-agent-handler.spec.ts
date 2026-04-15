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
// GetAgentHandler Unit Tests
//
// This handler:
//   1. Requires no authorization (read-only)
//   2. Looks up an agent by { id: number } or { name: string }
//   3. Returns the full agent record or a not-found error
// ============================================

const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };

describe("GetAgentHandler", () => {
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

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testGetAgentHandler("not-valid-json");
      const response = JSON.parse(result) as {
        success: boolean;
        error?: string;
      };
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return not-found when neither id nor name is provided", async () => {
      const result = await testCanister.testGetAgentHandler("{}");
      const response = JSON.parse(result) as {
        success: boolean;
        error?: string;
      };
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });
  });

  describe("lookup by id", () => {
    it("should return the agent when found by id", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "admin-bot",
          executionEngines: ["api"],
          allowedChannelIds: ["C_TEST"],
        }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testGetAgentHandler(
        JSON.stringify({ id: 0 }),
      );
      const response = JSON.parse(result) as {
        success: boolean;
        agent?: {
          id: number;
          ownedBy: number;
          category: string;
          config: {
            name: string;
            model: string;
            allowedChannelIds: string[];
            secrets: { allowed: unknown[]; overrides: unknown[] };
          };
        };
      };
      expect(response.success).toBe(true);
      expect(response.agent?.id).toBe(0);
      expect(response.agent?.config?.name).toBe("admin-bot");
      expect(response.agent?.category).toBe("custom");
      expect(response.agent?.config?.secrets?.overrides).toEqual([]);
      expect(response.agent?.config?.allowedChannelIds).toEqual(["C_TEST"]);
    });

    it("should return not-found for an id that does not exist", async () => {
      const result = await testCanister.testGetAgentHandler(
        JSON.stringify({ id: 999 }),
      );
      const response = JSON.parse(result) as {
        success: boolean;
        error?: string;
      };
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });
  });

  describe("lookup by name", () => {
    it("should return the agent when found by name", async () => {
      await testCanister.testRegisterAgentHandler(
        JSON.stringify({
          name: "plan-bot",
          executionEngines: ["canister"],
          allowedChannelIds: ["C_TEST"],
        }),
        PRIMARY_OWNER,
      );

      const result = await testCanister.testGetAgentHandler(
        JSON.stringify({ name: "plan-bot" }),
      );
      const response = JSON.parse(result) as {
        success: boolean;
        agent?: { id: number; category: string; config: { name: string } };
      };
      expect(response.success).toBe(true);
      expect(response.agent?.config?.name).toBe("plan-bot");
      expect(response.agent?.category).toBe("custom");
    });

    it("should return not-found for a name that does not exist", async () => {
      const result = await testCanister.testGetAgentHandler(
        JSON.stringify({ name: "NonExistent" }),
      );
      const response = JSON.parse(result) as {
        success: boolean;
        error?: string;
      };
      expect(response.success).toBe(false);
      expect(response.error).toContain("not found");
    });
  });
});
