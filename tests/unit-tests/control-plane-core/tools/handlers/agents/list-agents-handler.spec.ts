import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor, DeferredActor } from "@dfinity/pic";
import {
  createTestCanister,
  createDeferredTestCanister,
  type TestCanisterService,
} from "../../../../../setup";
import { withCassette } from "../../../../../lib/cassette";

// ============================================
// ListAgentsHandler Unit Tests
//
// This handler:
//   1. Requires no authorization (read-only)
//   2. Returns all registered agents as a JSON array
//
// Tests are split into two groups:
//   (A) Fast tests — no HTTP outcalls, use regular actor.
//   (B) Cassette tests — seeding via RegisterAgentHandler makes an OpenRouter
//       HTTPS outcall to validate the model, so we use a deferred actor + cassette.
//
// Re-record cassettes with:
//   RECORD_CASSETTES=true bun test tests/unit-tests/control-plane-core/tools/handlers/agents/list-agents-handler.spec.ts
// ============================================

const CASSETTE_BASE =
  "unit-tests/control-plane-core/tools/handlers/agents/list-agents-handler";

const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };

// ============================================
// (A) Fast tests — no HTTP outcalls
// ============================================

describe("ListAgentsHandler — fast paths", () => {
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
});

// ============================================
// (B) Cassette tests — seeding requires HTTP outcalls
// ============================================

describe("ListAgentsHandler — with seeded agents (cassette)", () => {
  let pic: PocketIc;
  let testCanister: DeferredActor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createDeferredTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  it("should return all registered agents after seeding", async () => {
    await withCassette(
      pic,
      `${CASSETTE_BASE}/seed-admin-bot`,
      () =>
        testCanister.testRegisterAgentHandler(
          JSON.stringify({
            name: "admin-bot",
            category: "admin",
            executionType: { type: "api" },
          }),
          PRIMARY_OWNER,
        ),
      { ticks: 5, maxRounds: 2 },
    );
    await withCassette(
      pic,
      `${CASSETTE_BASE}/seed-plan-bot`,
      () =>
        testCanister.testRegisterAgentHandler(
          JSON.stringify({
            name: "plan-bot",
            category: "planning",
            executionType: { type: "api" },
          }),
          PRIMARY_OWNER,
        ),
      { ticks: 5, maxRounds: 2 },
    );

    const execute = await testCanister.testListAgentsHandler("{}");
    await pic.tick(2);
    const response = JSON.parse(await execute()) as {
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
    await withCassette(
      pic,
      `${CASSETTE_BASE}/seed-full-agent`,
      () =>
        testCanister.testRegisterAgentHandler(
          JSON.stringify({
            name: "full-agent",
            category: "research",
            executionType: { type: "api", model: "openai/gpt-oss-120b" },
            toolsDisallowed: ["web_search"],
            sources: ["https://example.com"],
          }),
          PRIMARY_OWNER,
        ),
      { ticks: 5, maxRounds: 2 },
    );

    const execute = await testCanister.testListAgentsHandler("{}");
    await pic.tick(2);
    const response = JSON.parse(await execute()) as {
      success: boolean;
      agents: Array<{
        id: number;
        name: string;
        category: string;
        executionType: { type: string; model: string };
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
    expect(agent.executionType).toEqual({
      type: "api",
      model: "openai/gpt-oss-120b",
    });
    expect(agent.toolsDisallowed).toEqual(["web_search"]);
    expect(agent.sources).toEqual(["https://example.com"]);
    expect(agent.secretOverrides).toEqual([]);
  });
});
