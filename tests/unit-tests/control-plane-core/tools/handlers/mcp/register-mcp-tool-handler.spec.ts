import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// RegisterMcpToolHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Parses JSON args for { name, serverId, description?, parameters?, remoteName? }
//   3. Registers the MCP tool in McpToolRegistryState
//
// The test canister starts with an empty MCP tool registry.
// ============================================

function parseResponse(json: string): {
  success: boolean;
  name?: string;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

const NO_AUTH = { isPrimaryOwner: false, isOrgAdmin: false };
const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };
const ORG_ADMIN = { isPrimaryOwner: false, isOrgAdmin: true };

describe("RegisterMcpToolHandler", () => {
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
      const result = await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "test_tool", serverId: "server-1" }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to register a tool", async () => {
      const result = await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "owner_tool", serverId: "server-1" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to register a tool", async () => {
      const result = await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "admin_tool", serverId: "server-1" }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testRegisterMcpToolHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when name field is missing", async () => {
      const result = await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ serverId: "server-1" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: name");
    });

    it("should return error when serverId field is missing", async () => {
      const result = await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "my_tool" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: serverId");
    });
  });

  describe("duplicate prevention", () => {
    it("should return error when registering a tool with a duplicate name", async () => {
      await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "dup_tool", serverId: "server-1" }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "dup_tool", serverId: "server-2" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("already exists");
    });
  });

  describe("happy path", () => {
    it("should register a tool with only required fields", async () => {
      const result = await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "calculate", serverId: "math-server" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.name).toBe("calculate");
      expect(response.message).toContain("calculate");
    });

    it("should register a tool with all optional fields", async () => {
      const result = await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({
          name: "full_tool",
          serverId: "server-1",
          description: "A fully specified tool",
          parameters: JSON.stringify({
            type: "object",
            properties: { input: { type: "string" } },
            required: ["input"],
          }),
          remoteName: "full_tool_remote",
        }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.name).toBe("full_tool");
    });

    it("should allow registration of multiple unique tools", async () => {
      for (const name of ["tool_a", "tool_b", "tool_c"]) {
        const result = await testCanister.testRegisterMcpToolHandler(
          JSON.stringify({ name, serverId: "server-1" }),
          PRIMARY_OWNER,
        );
        expect(parseResponse(result).success).toBe(true);
      }
    });
  });
});
