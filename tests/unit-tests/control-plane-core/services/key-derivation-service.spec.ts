import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createSchnorrTestCanister,
  type TestCanisterService,
} from "../../../setup";

/**
 * Key Derivation Service Unit Tests (via Test Canister)
 *
 * These tests exercise the key derivation service through the test canister's
 * dedicated key-cache endpoints using live sign_with_schnorr calls.
 * PocketIC is configured with a fiduciary subnet so threshold Schnorr signing
 * is fully supported without a real IC deployment.
 *
 * What is tested:
 *  - Cache starts empty before any derivation
 *  - A live sign_with_schnorr call populates the cache
 *  - The derived key has the expected 32-byte length (SHA256 of the signature)
 *  - Multiple distinct workspaces each receive their own cache entry
 *  - Seeding the same workspace twice does not grow the cache (idempotency)
 *  - Clearing the cache resets its size to zero
 *  - Re-deriving after a clear produces a key of the same length (determinism)
 */
describe("Key Derivation Service", () => {
  let pic: PocketIc;
  let testCanister: Actor<TestCanisterService>;

  beforeEach(async () => {
    const testEnv = await createSchnorrTestCanister();
    pic = testEnv.pic;
    testCanister = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  // -------------------------------------------------------------------------
  // Initial state
  // -------------------------------------------------------------------------

  describe("initial cache state", () => {
    it("should have an empty key cache before any derivation", async () => {
      const size = await testCanister.testGetKeyCacheSize();
      expect(size).toBe(0n);
    });

    it("should return null for a key that has not been derived yet", async () => {
      const keyLength = await testCanister.testGetCachedKeyLength(0n);
      expect(keyLength).toEqual([]);
    });
  });

  // -------------------------------------------------------------------------
  // Key seeding / derivation
  // -------------------------------------------------------------------------

  describe("deriveKeyFromSchnorr", () => {
    it("should populate the cache after seeding a workspace key", async () => {
      await testCanister.testSeedKeyForWorkspace(0n);

      const size = await testCanister.testGetKeyCacheSize();
      expect(size).toBe(1n);
    });

    it("should store a 32-byte key matching the expected SHA256 output length", async () => {
      await testCanister.testSeedKeyForWorkspace(0n);

      const keyLength = await testCanister.testGetCachedKeyLength(0n);
      // Optional<bigint> is encoded as [value] in Candid
      expect(keyLength).toEqual([32n]);
    });

    it("should create separate cache entries for different workspaces", async () => {
      await testCanister.testSeedKeyForWorkspace(0n);
      await testCanister.testSeedKeyForWorkspace(1n);
      await testCanister.testSeedKeyForWorkspace(42n);

      const size = await testCanister.testGetKeyCacheSize();
      expect(size).toBe(3n);
    });

    it("should have a distinct cache entry per workspace", async () => {
      await testCanister.testSeedKeyForWorkspace(0n);
      await testCanister.testSeedKeyForWorkspace(1n);

      // Both workspaces have a cached key
      expect(await testCanister.testGetCachedKeyLength(0n)).toEqual([32n]);
      expect(await testCanister.testGetCachedKeyLength(1n)).toEqual([32n]);

      // A workspace that was never seeded has no entry
      expect(await testCanister.testGetCachedKeyLength(99n)).toEqual([]);
    });
  });

  // -------------------------------------------------------------------------
  // Cache idempotency
  // -------------------------------------------------------------------------

  describe("getOrDeriveKey (cache hit)", () => {
    it("should not grow the cache when the same workspace is seeded twice", async () => {
      await testCanister.testSeedKeyForWorkspace(0n);
      await testCanister.testSeedKeyForWorkspace(0n);

      // Map.add does not add a second entry for an existing key
      const size = await testCanister.testGetKeyCacheSize();
      expect(size).toBe(1n);
    });
  });

  // -------------------------------------------------------------------------
  // Cache management (clearCache)
  // -------------------------------------------------------------------------

  describe("clearCache", () => {
    it("should reset the cache size to zero", async () => {
      await testCanister.testSeedKeyForWorkspace(0n);
      await testCanister.testSeedKeyForWorkspace(1n);

      const populated = await testCanister.testGetKeyCacheSize();
      expect(populated).toBeGreaterThan(0n);

      await testCanister.testClearKeyCache();

      const cleared = await testCanister.testGetKeyCacheSize();
      expect(cleared).toBe(0n);
    });

    it("should remove all per-workspace entries after clearing", async () => {
      await testCanister.testSeedKeyForWorkspace(0n);
      await testCanister.testClearKeyCache();

      const keyLength = await testCanister.testGetCachedKeyLength(0n);
      expect(keyLength).toEqual([]);
    });

    it("should allow re-seeding after a clear (key derivation is deterministic)", async () => {
      await testCanister.testSeedKeyForWorkspace(0n);
      await testCanister.testClearKeyCache();

      // Re-seed — simulates re-derivation via sign_with_schnorr
      await testCanister.testSeedKeyForWorkspace(0n);

      const size = await testCanister.testGetKeyCacheSize();
      expect(size).toBe(1n);

      // Key length is still 32 bytes — same deterministic key
      expect(await testCanister.testGetCachedKeyLength(0n)).toEqual([32n]);
    });
  });
});
