import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// ListAgentsHandler Unit Tests
//
// This handler:
//   1. Requires no authorization (read-only)
//   2. Returns all registered agents as a JSON array
//
// Tests use testRegisterAgentHandler to seed state, then call
// testListAgentsHandler to verify the results.
// ============================================

const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };

describe("ListAgentsHandler", () => {
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

  it("should return an empty agents array when the registry is empty", async () => {
    const result = await testCanister.testListAgentsHandler("{}");
    const response = JSON.parse(result) as {
      success: boolean;
      agents: unknown[];
    };
    expect(response.success).toBe(true);
    expect(response.agents).toEqual([]);
  });

  it("should return all registered agents after seeding", async () => {
    await testCanister.testRegisterAgentHandler(
      JSON.stringify({
        name: "admin-bot",
        category: "admin",
        executionType: { type: "api" },
      }),
      PRIMARY_OWNER,
    );
    await testCanister.testRegisterAgentHandler(
      JSON.stringify({
        name: "plan-bot",
        category: "planning",
        executionType: { type: "api" },
      }),
      PRIMARY_OWNER,
    );

    const result = await testCanister.testListAgentsHandler("{}");
    const response = JSON.parse(result) as {
      success: boolean;
      agents: Array<{ id: number; name: string; category: string }>;
    };
    expect(response.success).toBe(true);
    expect(response.agents).toHaveLength(2);

    const names = response.agents.map((a) => a.name);
    expect(names).toContain("admin-bot");
    expect(names).toContain("plan-bot");
  });

  it("should include all expected fields on each agent record", async () => {
    await testCanister.testRegisterAgentHandler(
      JSON.stringify({
        name: "full-agent",
        category: "research",
        executionType: { type: "api" },
        llmModel: "gpt_oss_120b",
        toolsDisallowed: ["web_search"],
        sources: ["https://example.com"],
      }),
      PRIMARY_OWNER,
    );

    const result = await testCanister.testListAgentsHandler("{}");
    const response = JSON.parse(result) as {
      success: boolean;
      agents: Array<{
        id: number;
        name: string;
        category: string;
        llmModel: string;
        toolsDisallowed: string[];
        sources: string[];
        secretOverrides: unknown[];
      }>;
    };
    const agent = response.agents[0];
    expect(agent).toBeDefined();
    expect(agent.id).toBe(0);
    expect(agent.name).toBe("full-agent");
    expect(agent.category).toBe("research");
    expect(agent.llmModel).toBe("gpt_oss_120b");
    expect(agent.toolsDisallowed).toEqual(["web_search"]);
    expect(agent.sources).toEqual(["https://example.com"]);
    expect(agent.secretOverrides).toEqual([]);
  });
});
