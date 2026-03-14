import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// DeleteFailedEventsHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Parses JSON args for { eventId?: string }
//   3. Deletes one specific failed event (when eventId provided) or all (when omitted)
//   4. Returns { deleted: number }
//
// Tests use testSeedFailedEvent to inject state, then call
// testDeleteFailedEventsHandler to verify deletion behavior.
// ============================================

interface DeleteResponse {
  success: boolean;
  deleted?: number;
  error?: string;
}

interface StatsResponse {
  success: boolean;
  failedEvents?: number;
}

function parseResponse(json: string): DeleteResponse {
  return JSON.parse(json);
}

function parseStatsResponse(json: string): StatsResponse {
  return JSON.parse(json);
}

const NO_AUTH = { isPrimaryOwner: false, isOrgAdmin: false };
const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };
const ORG_ADMIN = { isPrimaryOwner: false, isOrgAdmin: true };

describe("DeleteFailedEventsHandler", () => {
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
      const result = await testCanister.testDeleteFailedEventsHandler(
        "{}",
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to delete failed events", async () => {
      const result = await testCanister.testDeleteFailedEventsHandler(
        "{}",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to delete failed events", async () => {
      const result = await testCanister.testDeleteFailedEventsHandler(
        "{}",
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("delete all behavior", () => {
    it("should return deleted=0 when no failed events", async () => {
      const result = await testCanister.testDeleteFailedEventsHandler(
        "{}",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.deleted).toBe(0);
    });

    it("should delete all failed events when no eventId provided", async () => {
      await testCanister.testSeedFailedEvent("evt001", "error one");
      await testCanister.testSeedFailedEvent("evt002", "error two");
      await testCanister.testSeedFailedEvent("evt003", "error three");

      const result = await testCanister.testDeleteFailedEventsHandler(
        "{}",
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.deleted).toBe(3);

      // Confirm store is now empty
      const stats = parseStatsResponse(
        await testCanister.testGetEventStoreStatsHandler("{}", ORG_ADMIN),
      );
      expect(stats.failedEvents).toBe(0);
    });
  });

  describe("delete specific event behavior", () => {
    it("should return deleted=0 for non-existent event ID", async () => {
      const result = await testCanister.testDeleteFailedEventsHandler(
        JSON.stringify({ eventId: "slack_nonexistent" }),
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.deleted).toBe(0);
    });

    it("should delete only the specified event", async () => {
      await testCanister.testSeedFailedEvent("evt001", "error one");
      await testCanister.testSeedFailedEvent("evt002", "error two");

      const result = await testCanister.testDeleteFailedEventsHandler(
        JSON.stringify({ eventId: "slack_evt001" }),
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.deleted).toBe(1);

      // Confirm only evt002 remains
      const stats = parseStatsResponse(
        await testCanister.testGetEventStoreStatsHandler("{}", ORG_ADMIN),
      );
      expect(stats.failedEvents).toBe(1);
    });
  });
});
