import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { Principal } from "@icp-sdk/core/principal";
import {
  createTestCanister,
  type TestCanisterService,
  freshTestCanister,
} from "../../../setup";

// ============================================
// EngineTopupRunner Unit Tests
//
// The runner wraps both ic.canister_status and ic.deposit_cycles in try/catch
// and converts any rejection/trap into a structured #err(Text).
//
// These tests exercise:
//   1. null enginePrincipal → #ok (no-op; engine not yet spawned)
//   2. engine with sufficient cycles → #ok (no top-up triggered)
//   3. engine with low cycles → #ok (top-up fires; balance verified after)
//   4. unknown canister principal → #err (canister_status rejects; caught)
// ============================================

describe("Engine Topup Runner Unit Tests", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;
  let testCanisterId: Principal;

  beforeAll(async () => {
    const testEnv = await createTestCanister();
    pic = testEnv.pic;
  });

  beforeEach(async () => {
    const env = await freshTestCanister(pic);
    testCanister = env.actor;
    testCanisterId = env.canisterId as unknown as Principal;
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  it("should return #ok when engine principal is null (engine not yet spawned)", async () => {
    const result = await testCanister.testEngineTopupRunner([]);
    expect(result).toEqual({ ok: null });
  });

  it("should return #ok when the engine canister is healthy and has sufficient cycles", async () => {
    // Use the test canister itself as the "engine" — PocketIC provisions it with
    // far more than ENGINE_MIN_CYCLES (500B), so canister_status succeeds and
    // no top-up is triggered, exercising the full happy path.
    const result = await testCanister.testEngineTopupRunner([testCanisterId]);
    expect(result).toEqual({ ok: null });
  });

  it("should deposit cycles and return #ok when engine balance is below the threshold", async () => {
    // Create an empty canister with 100B cycles (below ENGINE_MIN_CYCLES of 500B).
    // Setting the test canister as its controller allows it to call canister_status
    // on behalf of the engine (the IC requires the caller to be a controller).
    const engineCanisterId = await pic.createCanister({
      cycles: 100_000_000_000n, // 100B < ENGINE_MIN_CYCLES (500B)
      controllers: [testCanisterId],
    });

    const result = await testCanister.testEngineTopupRunner([engineCanisterId]);
    expect(result).toEqual({ ok: null });

    // The runner deposited ENGINE_TOPUP_CYCLES (1T) — balance must have grown.
    const balanceAfter = await pic.getCyclesBalance(engineCanisterId);
    expect(balanceAfter).toBeGreaterThan(500_000_000_000n);
  });

  it("should return #err when canister_status fails for a non-existent canister", async () => {
    // Use a well-known principal that is never deployed in PocketIC — calling
    // canister_status on it will reject, which the runner should catch and
    // return as a structured #err rather than propagating as a rejection.
    const nonExistentPrincipal = Principal.fromText(
      "aaaaa-aa", // management canister — canister_status on itself will reject
    );

    const result = await testCanister.testEngineTopupRunner([
      nonExistentPrincipal,
    ]);

    expect("err" in result).toBe(true);
    if ("err" in result) {
      expect(result.err).toContain("canister_status failed");
    }
  });
});
