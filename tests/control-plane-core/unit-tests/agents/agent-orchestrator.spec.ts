import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { Actor, PocketIc } from "@dfinity/pic";
import {
  createTestCanister,
  freshTestCanister,
  type TestCanisterService,
} from "../../../setup";

describe("AgentOrchestrator", () => {
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

  it("routes #_system(#admin) into the admin loop", async () => {
    const result = await testCanister.testOrchestrateSystemAdminNoApiKey();

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err.message).toContain(
        "No OpenRouter API key found for agent talk",
      );
      expect(result.err.steps).toEqual([]);
    }
  });

  it("routes #_system(#onboarding) into the deferred onboarding loop", async () => {
    const result = await testCanister.testOrchestrateSystemOnboarding();

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err.message).toContain(
        "category service not yet implemented",
      );
      expect(result.err.steps).toHaveLength(1);
      expect(result.err.steps[0]?.action).toBe("orchestrate");
    }
  });

  it("routes #custom into the deferred custom loop", async () => {
    const result = await testCanister.testOrchestrateCustom();

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err.message).toContain(
        "category service not yet implemented",
      );
      expect(result.err.steps).toHaveLength(1);
      expect(result.err.steps[0]?.action).toBe("orchestrate");
    }
  });
});
