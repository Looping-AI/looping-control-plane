import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import {
  createBackendCanister,
  setupAdminUser,
  type _SERVICE,
} from "../../setup.ts";
import { expectOk, expectErr } from "../../helpers.ts";

describe("MCP Tool Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;

  beforeEach(async () => {
    const testEnv = await createBackendCanister();
    pic = testEnv.pic;
    actor = testEnv.actor;

    // Set up an admin for testing MCP tool operations
    await setupAdminUser(actor);
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  const createTestTool = (name: string) => ({
    definition: {
      tool_type: "function",
      function: {
        name,
        description: [`Test tool: ${name}`] as [] | [string],
        parameters: [
          JSON.stringify({
            type: "object",
            properties: {
              input: {
                type: "string",
                description: "Input parameter",
              },
            },
            required: ["input"],
          }),
        ] as [] | [string],
      },
    },
    serverId: "test-server",
    remoteName: [] as [] | [string],
  });

  describe("registerMcpTool", () => {
    it("should reject registration from non-admin and non-workspace-admin user", async () => {
      const nonAdminIdentity = generateRandomIdentity();
      actor.setIdentity(nonAdminIdentity);

      const tool = createTestTool("test_tool");
      const result = await actor.registerMcpTool(tool);
      expect(expectErr(result)).toContain("Only org");
    });

    it("should allow workspace admin to register an MCP tool", async () => {
      const { adminIdentity } = await setupAdminUser(actor);
      actor.setIdentity(adminIdentity);

      const tool = createTestTool("workspace_admin_tool");
      const result = await actor.registerMcpTool(tool);
      expectOk(result);
    });

    it("should successfully register an MCP tool", async () => {
      const tool = createTestTool("calculate");
      const result = await actor.registerMcpTool(tool);
      expectOk(result);
    });

    it("should reject registration of duplicate tool name", async () => {
      const tool1 = createTestTool("duplicate_tool");
      const result1 = await actor.registerMcpTool(tool1);
      expectOk(result1);

      const tool2 = createTestTool("duplicate_tool");
      const result2 = await actor.registerMcpTool(tool2);
      expect(expectErr(result2)).toEqual(
        "Tool with name 'duplicate_tool' already exists",
      );
    });

    it("should allow registration of multiple unique tools", async () => {
      const tool1 = createTestTool("tool_one");
      const result1 = await actor.registerMcpTool(tool1);
      expectOk(result1);

      const tool2 = createTestTool("tool_two");
      const result2 = await actor.registerMcpTool(tool2);
      expectOk(result2);

      const tool3 = createTestTool("tool_three");
      const result3 = await actor.registerMcpTool(tool3);
      expectOk(result3);
    });
  });

  describe("unregisterMcpTool", () => {
    it("should reject unregistration from non-admin and non-workspace-admin user", async () => {
      const nonAdminIdentity = generateRandomIdentity();
      actor.setIdentity(nonAdminIdentity);

      const result = await actor.unregisterMcpTool("test_tool");
      expect(expectErr(result)).toContain("Only org");
    });

    it("should return false when unregistering non-existent tool", async () => {
      const result = await actor.unregisterMcpTool("non_existent_tool");
      expect(expectOk(result)).toEqual(false);
    });

    it("should successfully unregister an existing tool", async () => {
      const tool = createTestTool("removable_tool");
      await actor.registerMcpTool(tool);

      const result = await actor.unregisterMcpTool("removable_tool");
      expect(expectOk(result)).toEqual(true);
    });

    it("should return false when unregistering an already removed tool", async () => {
      const tool = createTestTool("once_removable");
      await actor.registerMcpTool(tool);

      const result1 = await actor.unregisterMcpTool("once_removable");
      expect(expectOk(result1)).toEqual(true);

      const result2 = await actor.unregisterMcpTool("once_removable");
      expect(expectOk(result2)).toEqual(false);
    });
  });

  describe("listMcpTools", () => {
    it("should reject listing from non-admin and non-workspace-admin user", async () => {
      const anonymousIdentity = generateRandomIdentity();
      actor.setIdentity(anonymousIdentity);

      const result = await actor.listMcpTools();
      expect(expectErr(result)).toContain("Only org");
    });

    it("should return empty array when no tools registered", async () => {
      const result = await actor.listMcpTools();
      expect(expectOk(result)).toEqual([]);
    });

    it("should return all registered tools", async () => {
      const tool1 = createTestTool("tool_alpha");
      const tool2 = createTestTool("tool_beta");
      const tool3 = createTestTool("tool_gamma");

      await actor.registerMcpTool(tool1);
      await actor.registerMcpTool(tool2);
      await actor.registerMcpTool(tool3);

      const result = await actor.listMcpTools();
      const tools = expectOk(result);
      expect(tools.length).toEqual(3);

      const toolNames = tools.map((t) => t.definition.function.name).sort();
      expect(toolNames).toEqual(["tool_alpha", "tool_beta", "tool_gamma"]);
    });

    it("should reflect changes after unregistering tools", async () => {
      const tool1 = createTestTool("persistent_tool");
      const tool2 = createTestTool("temporary_tool");

      await actor.registerMcpTool(tool1);
      await actor.registerMcpTool(tool2);

      await actor.unregisterMcpTool("temporary_tool");

      const result = await actor.listMcpTools();
      const tools = expectOk(result);
      expect(tools.length).toEqual(1);
      expect(tools[0].definition.function.name).toEqual("persistent_tool");
    });
  });

  describe("tool consistency", () => {
    it("should maintain tool state correctly across operations", async () => {
      // Register multiple tools
      await actor.registerMcpTool(createTestTool("tool_1"));
      await actor.registerMcpTool(createTestTool("tool_2"));
      await actor.registerMcpTool(createTestTool("tool_3"));

      // Verify all are listed
      let listResult = await actor.listMcpTools();
      expect(expectOk(listResult).length).toEqual(3);

      // Remove one
      await actor.unregisterMcpTool("tool_2");

      // Verify updated list
      listResult = await actor.listMcpTools();
      const tools = expectOk(listResult);
      expect(tools.length).toEqual(2);

      // Verify correct tools remain
      const toolNames = tools.map((t) => t.definition.function.name).sort();
      expect(toolNames).toEqual(["tool_1", "tool_3"]);
    });

    it("should handle complete lifecycle of tool registration", async () => {
      // Start with empty registry
      let result = await actor.listMcpTools();
      expect(expectOk(result).length).toEqual(0);

      // Register a tool
      const tool = createTestTool("lifecycle_tool");
      await actor.registerMcpTool(tool);

      // Verify it's there
      result = await actor.listMcpTools();
      const tools = expectOk(result);
      expect(tools.length).toEqual(1);
      expect(tools[0].definition.function.name).toEqual("lifecycle_tool");
      expect(tools[0].serverId).toEqual("test-server");

      // Remove it
      const removeResult = await actor.unregisterMcpTool("lifecycle_tool");
      expect(expectOk(removeResult)).toEqual(true);

      // Verify it's gone
      result = await actor.listMcpTools();
      expect(expectOk(result).length).toEqual(0);
    });
  });
});
