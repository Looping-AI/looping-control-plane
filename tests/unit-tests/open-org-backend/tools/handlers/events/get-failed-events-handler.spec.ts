import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import {
  createTestCanister,
  type TestCanisterService,
} from "../../../../../setup";

// ============================================
// GetFailedEventsHandler Unit Tests
//
// This handler:
//   1. Authorizes the caller via UserAuthContext (#IsPrimaryOwner or #IsOrgAdmin)
//   2. Returns all failed events with eventId, source, enqueuedAt, failedAt, failedError
//
// Tests use testSeedFailedEvent to inject state, then call
// testGetFailedEventsHandler to verify the returned events.
// ============================================

interface FailedEvent {
  eventId: string;
  source: string;
  enqueuedAt: number;
  failedAt: number | null;
  failedError: string;
}

interface FailedEventsResponse {
  success: boolean;
  events?: FailedEvent[];
  error?: string;
}

function parseResponse(json: string): FailedEventsResponse {
  return JSON.parse(json);
}

const NO_AUTH = { isPrimaryOwner: false, isOrgAdmin: false };
const PRIMARY_OWNER = { isPrimaryOwner: true, isOrgAdmin: false };
const ORG_ADMIN = { isPrimaryOwner: false, isOrgAdmin: true };

describe("GetFailedEventsHandler", () => {
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
      const result = await testCanister.testGetFailedEventsHandler(
        "{}",
        NO_AUTH,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(false);
      expect(response.error).toContain("Unauthorized");
    });

    it("should allow primary owner to list failed events", async () => {
      const result = await testCanister.testGetFailedEventsHandler(
        "{}",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });

    it("should allow org admin to list failed events", async () => {
      const result = await testCanister.testGetFailedEventsHandler(
        "{}",
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
    });
  });

  describe("list behavior", () => {
    it("should return empty array when no failed events", async () => {
      const result = await testCanister.testGetFailedEventsHandler(
        "{}",
        PRIMARY_OWNER,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.events).toEqual([]);
    });

    it("should return seeded failed events", async () => {
      await testCanister.testSeedFailedEvent("evt_abc", "timeout error");

      const result = await testCanister.testGetFailedEventsHandler(
        "{}",
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.events?.length).toBe(1);
      expect(response.events?.[0].eventId).toBe("slack_evt_abc");
      expect(response.events?.[0].source).toBe("slack");
      expect(response.events?.[0].failedError).toBe("timeout error");
    });

    it("should return all seeded failed events", async () => {
      await testCanister.testSeedFailedEvent("evt001", "error one");
      await testCanister.testSeedFailedEvent("evt002", "error two");
      await testCanister.testSeedFailedEvent("evt003", "error three");

      const result = await testCanister.testGetFailedEventsHandler(
        "{}",
        ORG_ADMIN,
      );
      const response = parseResponse(result);
      expect(response.success).toBe(true);
      expect(response.events?.length).toBe(3);
      const ids = response.events?.map((e) => e.eventId).sort();
      expect(ids).toEqual(["slack_evt001", "slack_evt002", "slack_evt003"]);
    });
  });
});
