import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";
import { expectOk } from "../../../helpers";

// ============================================
// ProcessedEventsCleanupRunner Unit Tests
//
// The runner performs three operations in order:
//   1. failStaleUnprocessed  — moves unprocessed events sitting >1h to failed
//   2. purgeProcessed        — deletes processed events whose processedAt >7 days
//   3. purgeOldFailed        — deletes failed events whose failedAt >30 days
//
// We control timestamps by setting pic.setTime() before seeding events,
// since enqueuedAt / processedAt / failedAt are stamped by EventStoreModel
// using Time.now() at the moment of each operation.
// ============================================

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

interface EventStoreStats {
  success: boolean;
  unprocessedEvents: number;
  processedEvents: number;
  failedEvents: number;
}

async function getStats(
  testCanister: Actor<TestCanisterService>,
): Promise<EventStoreStats> {
  const raw = await testCanister.testGetEventStoreStatsHandler("{}", {
    isPrimaryOwner: true,
    isOrgAdmin: true,
  });
  return JSON.parse(raw) as EventStoreStats;
}

describe("Processed Events Cleanup Runner Unit Tests", () => {
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

  it("should complete without error on empty event store", async () => {
    const result = await testCanister.testProcessedEventsCleanupRunner();
    expect(result).toEqual({ ok: null });
  });

  it("should purge processed events older than 7 days while retaining recent ones", async () => {
    const now = Date.now();

    // Seed an old processed event (8 days ago — outside the 7-day window).
    await pic.setTime(now - 8 * DAY_MS);
    await pic.tick(1);
    await testCanister.testSeedProcessedEvent("old-processed");

    // Seed a fresh processed event (at now — inside the window).
    await pic.setTime(now);
    await pic.tick(1);
    await testCanister.testSeedProcessedEvent("fresh-processed");

    // Sanity: 2 processed events before the run.
    const before = await getStats(testCanister);
    expect(before.processedEvents).toBe(2);

    expectOk(await testCanister.testProcessedEventsCleanupRunner());

    // Only the fresh event survives.
    const after = await getStats(testCanister);
    expect(after.processedEvents).toBe(1);
  });

  it("should move stale unprocessed events (>1h) to failed", async () => {
    const now = Date.now();

    // Enqueue an event 2 hours ago — enqueuedAt is stamped by EventStoreModel
    // as Time.now() = now - 2h via the intake service.
    await pic.setTime(now - 2 * HOUR_MS);
    await pic.tick(1);

    const body = JSON.stringify({
      token: "test",
      team_id: "T_TEST",
      context_team_id: "T_TEST",
      context_enterprise_id: null,
      api_app_id: "A_TEST",
      type: "event_callback",
      event_id: "Ev_STALE_UNPROCESSED",
      event_time: Math.floor((now - 2 * HOUR_MS) / 1000),
      event: {
        type: "message",
        user: "U_TEST",
        ts: "1700000001.000001",
        text: "stale message",
        channel: "C_TEST",
      },
    });
    const enqueueResult = await testCanister.testSlackEventIntakeService(body);
    expect(enqueueResult).toContain("enqueued:");

    // Sanity: 1 unprocessed, 0 failed before the run.
    const before = await getStats(testCanister);
    expect(before.unprocessedEvents).toBe(1);
    expect(before.failedEvents).toBe(0);

    // Advance to now and run the cleanup.
    await pic.setTime(now);
    await pic.tick(1);

    expectOk(await testCanister.testProcessedEventsCleanupRunner());

    // The stale event must have been moved from unprocessed to failed.
    const after = await getStats(testCanister);
    expect(after.unprocessedEvents).toBe(0);
    expect(after.failedEvents).toBe(1);
  });

  it("should purge failed events older than 30 days while retaining recent ones", async () => {
    const now = Date.now();

    // Seed an old failed event (31 days ago — outside the 30-day window).
    await pic.setTime(now - 31 * DAY_MS);
    await pic.tick(1);
    await testCanister.testSeedFailedEvent("old-failed", "old error");

    // Seed a fresh failed event (at now — inside the window).
    await pic.setTime(now);
    await pic.tick(1);
    await testCanister.testSeedFailedEvent("fresh-failed", "recent error");

    // Sanity: 2 failed events before the run.
    const before = await getStats(testCanister);
    expect(before.failedEvents).toBe(2);

    expectOk(await testCanister.testProcessedEventsCleanupRunner());

    // Only the fresh failure survives.
    const after = await getStats(testCanister);
    expect(after.failedEvents).toBe(1);
  });
});
