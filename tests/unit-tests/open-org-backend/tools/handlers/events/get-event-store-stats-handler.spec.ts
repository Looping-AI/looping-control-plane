import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetEventStoreStatsHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Returns unprocessedEvents, processedEvents, and failedEvents counts
//
// Tests use testSeedFailedEvent to inject state, then call
// testGetEventStoreStatsHandler to verify the returned counts.
// ============================================

interface StatsResponse {
  success: boolean;
  unprocessedEvents?: number;
  processedEvents?: number;
  failedEvents?: number;
  error?: string;
}

function parseResponse(json: string): StatsResponse {
  return JSON.parse(json);
}

const NO_AUTH = { isPrimaryOwner: false, isOrgAdmin: false };
const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };
const ORG_ADMIN = { isPrimaryOwner: false, isOrgAdmin: true };

describe("GetEventStoreStatsHandler", () => {
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

  describe("authorization", () => {
    it("should reject unauthorized callers", async () => {
      const result = await testCanister.testGetEventStoreStatsHandler(
        "{}",
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to get stats", async () => {
      const result = await testCanister.testGetEventStoreStatsHandler(
        "{}",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to get stats", async () => {
      const result = await testCanister.testGetEventStoreStatsHandler(
        "{}",
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("stats behavior", () => {
    it("should return zero counts on empty event store", async () => {
      const result = await testCanister.testGetEventStoreStatsHandler(
        "{}",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.unprocessedEvents).toBe(0);
      expect(response.processedEvents).toBe(0);
      expect(response.failedEvents).toBe(0);
    });

    it("should reflect failed events after seeding", async () => {
      await testCanister.testSeedFailedEvent("evt001", "processing error");
      await testCanister.testSeedFailedEvent("evt002", "another error");

      const result = await testCanister.testGetEventStoreStatsHandler(
        "{}",
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.failedEvents).toBe(2);
      expect(response.unprocessedEvents).toBe(0);
      expect(response.processedEvents).toBe(0);
    });
  });
});
