import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// UnregisterMcpToolHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Parses JSON args for { name }
//   3. Removes the MCP tool from McpToolRegistryState
//   4. Returns { success, removed } indicating whether the tool was found
//
// Tests use testRegisterMcpToolHandler to seed state, then call
// testUnregisterMcpToolHandler to verify removal behavior.
// ============================================

function parseResponse(json: string): {
  success: boolean;
  removed?: boolean;
  message?: string;
  error?: string;
} {
  return JSON.parse(json);
}

const NO_AUTH = { isPrimaryOwner: false, isOrgAdmin: false };
const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };
const ORG_ADMIN = { isPrimaryOwner: false, isOrgAdmin: true };

describe("UnregisterMcpToolHandler", () => {
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
      const result = await testCanister.testUnregisterMcpToolHandler(
        JSON.stringify({ name: "test_tool" }),
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to unregister a tool", async () => {
      await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "owned_tool", serverId: "server-1" }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testUnregisterMcpToolHandler(
        JSON.stringify({ name: "owned_tool" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.removed).toBe(true);
    });

    it("should allow org admin to unregister a tool", async () => {
      await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "admin_tool", serverId: "server-1" }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testUnregisterMcpToolHandler(
        JSON.stringify({ name: "admin_tool" }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.removed).toBe(true);
    });
  });

  describe("argument validation", () => {
    it("should return error for invalid JSON", async () => {
      const result = await testCanister.testUnregisterMcpToolHandler(
        "not-valid-json",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Failed to parse arguments");
    });

    it("should return error when name field is missing", async () => {
      const result = await testCanister.testUnregisterMcpToolHandler(
        JSON.stringify({}),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Missing required field: name");
    });
  });

  describe("removal behavior", () => {
    it("should return removed=false when tool does not exist", async () => {
      const result = await testCanister.testUnregisterMcpToolHandler(
        JSON.stringify({ name: "nonexistent_tool" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.removed).toBe(false);
    });

    it("should return removed=true when tool exists and is removed", async () => {
      await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "removable_tool", serverId: "server-1" }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testUnregisterMcpToolHandler(
        JSON.stringify({ name: "removable_tool" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.removed).toBe(true);
    });

    it("should return removed=false on second removal of the same tool", async () => {
      await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name: "once_only", serverId: "server-1" }),
        PRIMARY_OWNER,
      );
      await testCanister.testUnregisterMcpToolHandler(
        JSON.stringify({ name: "once_only" }),
        PRIMARY_OWNER,
      );
      const result = await testCanister.testUnregisterMcpToolHandler(
        JSON.stringify({ name: "once_only" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.removed).toBe(false);
    });

    it("should remove the correct tool when multiple tools exist", async () => {
      for (const name of ["keep_tool", "remove_tool", "also_keep"]) {
        await testCanister.testRegisterMcpToolHandler(
          JSON.stringify({ name, serverId: "server-1" }),
          PRIMARY_OWNER,
        );
      }
      const unregResult = await testCanister.testUnregisterMcpToolHandler(
        JSON.stringify({ name: "remove_tool" }),
        PRIMARY_OWNER,
      );
      expect(parseResponse(unregResult).removed).toBe(true);

      const listResult = await testCanister.testListMcpToolsHandler("{}");
      const listResponse = JSON.parse(listResult) as {
        success: boolean;
        tools: Array<{ name: string }>;
      };
      expect(listResponse.success).toBe(true);
      expect(listResponse.tools.length).toBe(2);
      const names = listResponse.tools.map((t) => t.name).sort();
      expect(names).toEqual(["also_keep", "keep_tool"]);
    });
  });
});
