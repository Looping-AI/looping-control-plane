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
  type TestCanisterService,
  freshTestCanister,
} from "../../../setup";

// ============================================
// TurnCleanupRunner Unit Tests
//
// The runner calls SessionModel.deleteTurnsOlderThan which:
//   - Computes cutoff = Time.now() - TURN_CLEANUP_RETENTION_NS
//   - TURN_CLEANUP_RETENTION_NS = 7_776_000_000_000_000 (90 days in ns)
//   - Hard-deletes turns (and their traces) whose startedAtNs < cutoff
//   - Also collects stale #running turns that never reached a terminal state
//
// We control the cutoff by setting pic.setTime() before seeding turns
// (startedAtNs = Time.now() at createTurn time) and before running the runner
// (cutoff = Time.now() - 90 days at run time).
// ============================================

const DAY_MS = 24 * 60 * 60 * 1000;

describe("Turn Cleanup Runner Unit Tests", () => {
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

  it("should return 0 deleted on empty session stores", async () => {
    const result = await testCanister.testTurnCleanupRunner();
    expect(result).toEqual({ ok: 0n });
  });

  it("should delete turns older than 90 days while retaining recent ones", async () => {
    // Use a "now" guaranteed to be ahead of PocketIC's current clock.
    const picNowMs = await pic.getTime();
    const now = picNowMs + 120 * DAY_MS;

    // Seed an old turn (95 days ago — outside the 90-day window).
    await pic.setTime(now - 95 * DAY_MS);
    await pic.tick(1);
    await testCanister.testSeedTurn(0n);

    // Seed a recent turn (1 day ago — inside the window).
    await pic.setTime(now - 1 * DAY_MS);
    await pic.tick(1);
    await testCanister.testSeedTurn(0n);

    expect(await testCanister.testGetTurnCount(0n)).toBe(2n);

    // Advance to "now" so the runner computes cutoff = now - 90 days.
    await pic.setTime(now);
    await pic.tick(1);

    const result = await testCanister.testTurnCleanupRunner();
    expect(result).toEqual({ ok: 1n });

    // Old turn deleted, recent turn retained.
    expect(await testCanister.testGetTurnCount(0n)).toBe(1n);
  });

  it("should delete stale #running turns older than 90 days", async () => {
    // The runner targets startedAtNs regardless of status, so orphaned
    // #running turns that never reached a terminal state are also collected.
    const picNowMs = await pic.getTime();
    const now = picNowMs + 120 * DAY_MS;

    // Seed a #running turn from 91 days ago (never completed).
    await pic.setTime(now - 91 * DAY_MS);
    await pic.tick(1);
    await testCanister.testSeedTurn(1n);

    expect(await testCanister.testGetTurnCount(1n)).toBe(1n);

    await pic.setTime(now);
    await pic.tick(1);

    const result = await testCanister.testTurnCleanupRunner();
    expect(result).toEqual({ ok: 1n });

    expect(await testCanister.testGetTurnCount(1n)).toBe(0n);
  });

  it("should retain turns within the 90-day window", async () => {
    const picNowMs = await pic.getTime();
    const now = picNowMs + 120 * DAY_MS;

    // Seed a turn from 89 days ago — just inside the retention window.
    await pic.setTime(now - 89 * DAY_MS);
    await pic.tick(1);
    await testCanister.testSeedTurn(2n);

    await pic.setTime(now);
    await pic.tick(1);

    const result = await testCanister.testTurnCleanupRunner();
    expect(result).toEqual({ ok: 0n });

    expect(await testCanister.testGetTurnCount(2n)).toBe(1n);
  });
});
