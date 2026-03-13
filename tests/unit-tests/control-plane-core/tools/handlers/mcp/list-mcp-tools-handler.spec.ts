import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// ListMcpToolsHandler Unit Tests
//
// This handler:
//   1. Requires no authorization (read-only; only accessible through agents
//      that already require org-admin level to invoke)
//   2. Returns all registered MCP tools with their metadata
//
// Tests use testRegisterMcpToolHandler to seed state, then call
// testListMcpToolsHandler to verify returned data.
// ============================================

interface McpToolItem {
  name: string;
  description: string | null;
  parameters: string | null;
  serverId: string;
  remoteName: string | null;
}

interface ListResponse {
  success: boolean;
  tools: McpToolItem[];
  error?: string;
}

function parseResponse(json: string): ListResponse {
  return JSON.parse(json);
}

const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };
const ORG_ADMIN = { isPrimaryOwner: false, isOrgAdmin: true };

describe("ListMcpToolsHandler", () => {
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

  it("should return empty tools array when no tools are registered", async () => {
    const result = await testCanister.testListMcpToolsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.tools).toEqual([]);
  });

  it("should return all registered tools", async () => {
    for (const name of ["tool_alpha", "tool_beta", "tool_gamma"]) {
      await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name, serverId: "server-1" }),
        PRIMARY_OWNER,
      );
    }
    const result = await testCanister.testListMcpToolsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.tools.length).toBe(3);
    const names = response.tools.map((t) => t.name).sort();
    expect(names).toEqual(["tool_alpha", "tool_beta", "tool_gamma"]);
  });

  it("should include serverId in returned tool data", async () => {
    await testCanister.testRegisterMcpToolHandler(
      JSON.stringify({ name: "my_tool", serverId: "my-server" }),
      PRIMARY_OWNER,
    );
    const result = await testCanister.testListMcpToolsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.tools[0].serverId).toBe("my-server");
  });

  it("should include description when provided", async () => {
    await testCanister.testRegisterMcpToolHandler(
      JSON.stringify({
        name: "described_tool",
        serverId: "server-1",
        description: "A useful tool",
      }),
      PRIMARY_OWNER,
    );
    const result = await testCanister.testListMcpToolsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.tools[0].description).toBe("A useful tool");
  });

  it("should return null description when not provided", async () => {
    await testCanister.testRegisterMcpToolHandler(
      JSON.stringify({ name: "no_desc_tool", serverId: "server-1" }),
      PRIMARY_OWNER,
    );
    const result = await testCanister.testListMcpToolsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.tools[0].description).toBeNull();
  });

  it("should reflect state after unregistering a tool", async () => {
    for (const name of ["persistent_tool", "temporary_tool"]) {
      await testCanister.testRegisterMcpToolHandler(
        JSON.stringify({ name, serverId: "server-1" }),
        PRIMARY_OWNER,
      );
    }
    await testCanister.testUnregisterMcpToolHandler(
      JSON.stringify({ name: "temporary_tool" }),
      ORG_ADMIN,
    );
    const result = await testCanister.testListMcpToolsHandler("{}");
    const response = parseResponse(result);
    expect(response.success).toBe(true);
    expect(response.tools.length).toBe(1);
    expect(response.tools[0].name).toBe("persistent_tool");
  });

  it("should handle full lifecycle of tool registration", async () => {
    // Start empty
    let result = await testCanister.testListMcpToolsHandler("{}");
    expect(parseResponse(result).tools.length).toBe(0);

    // Register
    await testCanister.testRegisterMcpToolHandler(
      JSON.stringify({ name: "lifecycle_tool", serverId: "test-server" }),
      PRIMARY_OWNER,
    );

    // Verify present
    result = await testCanister.testListMcpToolsHandler("{}");
    const after = parseResponse(result);
    expect(after.tools.length).toBe(1);
    expect(after.tools[0].name).toBe("lifecycle_tool");
    expect(after.tools[0].serverId).toBe("test-server");

    // Unregister
    await testCanister.testUnregisterMcpToolHandler(
      JSON.stringify({ name: "lifecycle_tool" }),
      PRIMARY_OWNER,
    );

    // Verify gone
    result = await testCanister.testListMcpToolsHandler("{}");
    expect(parseResponse(result).tools.length).toBe(0);
  });
});
