import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { Actor, DeferredActor, PocketIc } from "@dfinity/pic";
import {
  TEST_API_KEY,
  createDeferredTestCanister,
  createTestCanister,
  freshDeferredTestCanister,
  freshTestCanister,
  type TestCanisterService,
} from "../../../../setup";
import { withCassette } from "../../../../lib/cassette";

const CASSETTE_TEST_TIMEOUT_MS = 120_000;

describe("ToolExecutor", () => {
  describe("deterministic branches", () => {
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

    it("returns an error for an unknown tool name", async () => {
      const results = await testCanister.testToolExecutorExecute(
        "",
        "does_not_exist",
        "{}",
      );

      expect(results).toHaveLength(1);
      if (results[0] && "err" in results[0].result) {
        expect(results[0].result.err).toContain("Unknown tool");
      } else {
        throw new Error("Expected unknown tool execution to fail");
      }
    });

    it("formats tool results for the next LLM round", async () => {
      const formatted = await testCanister.testToolExecutorFormatFixture();

      expect(formatted).toContain("Tool call call-1 result:");
      expect(formatted).toContain('{"ok":true}');
      expect(formatted).toContain("Tool call call-2 result:");
      expect(formatted).toContain("boom");
    });
  });

  describe("cassette-backed branches", () => {
    let pic: PocketIc;
    let testCanister: DeferredActor<TestCanisterService>;

    beforeAll(async () => {
      const testEnv = await createDeferredTestCanister();
      pic = testEnv.pic;
    });

    beforeEach(async () => {
      testCanister = (await freshDeferredTestCanister(pic)).actor;
    });

    afterAll(async () => {
      await pic.tearDown();
    });

    it(
      "executes a tool and returns a success result",
      async () => {
        const { result } = await withCassette(
          pic,
          "control-plane-core/unit-tests/agents/tools/tool-executor/web-search",
          () =>
            testCanister.testToolExecutorExecute(
              TEST_API_KEY,
              "web_search",
              '{"query":"What is 1+1?"}',
            ),
          { ticks: 5, maxRounds: 5 },
        );

        const results = await result;

        expect(results).toHaveLength(1);
        expect(results[0]?.callId).toBe("call-1");
        expect(results[0]?.durationMs).toBeGreaterThanOrEqual(0n);
        if (results[0] && "ok" in results[0].result) {
          expect(results[0].result.ok.length).toBeGreaterThan(0);
        } else {
          throw new Error("Expected web_search tool execution to succeed");
        }
      },
      { timeout: CASSETTE_TEST_TIMEOUT_MS },
    );
  });
});
