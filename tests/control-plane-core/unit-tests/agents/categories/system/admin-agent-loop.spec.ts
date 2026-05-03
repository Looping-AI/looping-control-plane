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
} from "../../../../../setup";
import { withCassette } from "../../../../../lib/cassette";

const DEFAULT_MODEL = "openai/gpt-oss-120b";

describe("AdminAgentLoop", () => {
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

    it("returns a direct error when the admin loop has no OpenRouter API key", async () => {
      const result = await testCanister.testAdminAgentLoopProcess(
        "",
        DEFAULT_MODEL,
        "hello",
      );

      expect("err" in result).toBe(true);
      if ("err" in result) {
        expect(result.err.message).toContain(
          "No OpenRouter API key found for agent",
        );
        expect(result.err.steps).toEqual([]);
      }
    });

    it("returns an admin-loop error when the configured model is invalid", async () => {
      const result = await testCanister.testAdminAgentLoopProcess(
        TEST_API_KEY,
        "",
        "Say hello in one sentence.",
      );

      expect("err" in result).toBe(true);
      if ("err" in result) {
        expect(result.err.message).toContain("Core LLM call failed");
        expect(result.err.steps).toEqual([]);
      }
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

    it("returns a direct text response when the admin loop completes without tool calls", async () => {
      const { result } = await withCassette(
        pic,
        "control-plane-core/unit-tests/agents/categories/system/admin-agent-loop/text-response",
        () =>
          testCanister.testAdminAgentLoopProcess(
            TEST_API_KEY,
            DEFAULT_MODEL,
            "Say hello in one short sentence without using tools.",
          ),
        { ticks: 5, maxRounds: 5 },
      );

      const response = await result;

      expect("ok" in response).toBe(true);
      if ("ok" in response) {
        expect(response.ok.response.length).toBeGreaterThan(0);
        expect(response.ok.steps).toEqual([]);
      }
    });
  });
});
