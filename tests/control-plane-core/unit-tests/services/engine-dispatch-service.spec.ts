import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  freshTestCanister,
  type TestCanisterService,
} from "../../../setup";

// ============================================
// EngineDispatchService Unit Tests
//
// Exercises the four dispatch paths by calling testEngineDispatchService on
// the test-canister, which owns a real InternalEngine actor and routes calls
// through EngineDispatchService.dispatch.
//
// testEngineDispatchService(seedVersion, includeApiKey)
//   seedVersion:   [] = no seed (service defaults to "v1")
//                  ["v0"] = pre-seed a stale version to trigger negotiation
//   includeApiKey: true  = envelope carries the "openrouter" key (engine accepts)
//                  false = "openrouter" key absent → engine API-key error
//
// The real InternalEngine is used so the version-negotiation round-trip is
// exercised end-to-end (no mocks for the engine).
// ============================================

// Candid optional shorthands
const NO_SEED = [] as [] | [string];

function seed(version: string): [] | [string] {
  return [version];
}

describe("EngineDispatchService", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeAll(async () => {
    pic = (await createTestCanister()).pic;
  });

  beforeEach(async () => {
    testCanister = (await freshTestCanister(pic)).actor;
    // Advance time so the zero-delay engine-spawn timer fires before each test.
    await pic.tick(5);
  });

  afterAll(async () => {
    await pic.tearDown();
  });

  // ──────────────────────────────────────────────────────────────────
  // Happy path
  // ──────────────────────────────────────────────────────────────────

  describe("happy path", () => {
    it("dispatches successfully when knownEngineVersions is empty (default v1)", async () => {
      const result = await testCanister.testEngineDispatchService(
        NO_SEED,
        true,
      );
      expect(result.dispatched).toBe(true);
      expect(result.error).toEqual([]);
      // No negotiation needed — knownEngineVersions remains unset
      expect(result.knownVersionAfter).toEqual([]);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // Version negotiation
  // ──────────────────────────────────────────────────────────────────

  describe("version negotiation", () => {
    it("succeeds after correcting a stale cached version and updates knownEngineVersions", async () => {
      // Seed "v0" → engine rejects with {"envelopeVersionRequired":"v1"}
      // → service stores "v1" in knownEngineVersions and retries → engine accepts
      const result = await testCanister.testEngineDispatchService(
        seed("v0"),
        true,
      );
      expect(result.dispatched).toBe(true);
      expect(result.error).toEqual([]);
      // Service persisted the correct version from the engine's response
      expect(result.knownVersionAfter).toEqual(["v1"]);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // Error propagation
  // ──────────────────────────────────────────────────────────────────

  describe("error propagation", () => {
    it("propagates a non-version engine error directly (no retry)", async () => {
      // Missing API key → engine returns a plain error, not a version-mismatch JSON
      // → service passes it through without retrying
      const result = await testCanister.testEngineDispatchService(
        NO_SEED,
        false,
      );
      expect(result.dispatched).toBe(false);
      expect(result.error[0]).toContain("openrouter");
      // No version negotiation occurred — knownEngineVersions unchanged
      expect(result.knownVersionAfter).toEqual([]);
    });

    it("propagates the retry error after version negotiation when retry also fails", async () => {
      // "v0" → engine rejects with version mismatch → service updates map to "v1" and retries
      // → retry fails because API key is missing → service returns #err
      const result = await testCanister.testEngineDispatchService(
        seed("v0"),
        false,
      );
      expect(result.dispatched).toBe(false);
      expect(result.error[0]).toContain("openrouter");
      // Version update still happened (map is updated before the retry)
      expect(result.knownVersionAfter).toEqual(["v1"]);
    });
  });
});
