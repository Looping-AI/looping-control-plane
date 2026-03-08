import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { createTestCanister, type TestCanisterService } from "../../../setup";
import { expectOk } from "../../../helpers";

// ============================================
// ConversationPruneRunner Unit Tests
//
// The runner calls ConversationModel.pruneAll which:
//   - Computes cutoff = Int.abs(Time.now() / 1_000_000_000) - CONVERSATION_RETENTION_SECS
//   - CONVERSATION_RETENTION_SECS = 2_592_000 (30 days in seconds)
//   - Removes channel timeline entries whose ts (Slack "SECONDS.MICROSECONDS")
//     parsed seconds are older than the cutoff
//
// We control the cutoff by setting pic.setTime() before running the runner,
// since Time.now() is read at runner-invocation time.
// The message ts strings we seed are plain text constants whose second-prefix
// determines whether each entry is above or below the cutoff.
// ============================================

const DAY_SECS = 24 * 60 * 60;

describe("Conversation Prune Runner Unit Tests", () => {
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

  it("should complete without error on empty conversation store", async () => {
    const result = await testCanister.testConversationPruneRunner();
    expect(result).toEqual({ ok: null });
  });

  it("should prune messages older than 30 days while retaining recent ones", async () => {
    const now = Date.now();
    const nowSecs = Math.floor(now / 1000);

    // ts strings: second-prefix determines age relative to the prune cutoff.
    // cutoff = nowSecs - 30 * DAY_SECS, so 35-day-old messages are stale.
    const oldTs = `${nowSecs - 35 * DAY_SECS}.000001`;
    const freshTs = `${nowSecs - 1 * DAY_SECS}.000001`;

    // Set pic clock to now so the runner computes cutoff = nowSecs - 30 days.
    await pic.setTime(now);
    await pic.tick(1);

    await testCanister.testSeedConversationMessage("C_OLD", oldTs, []);
    await testCanister.testSeedConversationMessage("C_FRESH", freshTs, []);

    // Sanity: both channels have 1 entry before the prune.
    expect(await testCanister.testGetConversationEntryCount("C_OLD")).toBe(1n);
    expect(await testCanister.testGetConversationEntryCount("C_FRESH")).toBe(
      1n,
    );

    expectOk(await testCanister.testConversationPruneRunner());

    // C_OLD is fully pruned; C_FRESH is untouched.
    expect(await testCanister.testGetConversationEntryCount("C_OLD")).toBe(0n);
    expect(await testCanister.testGetConversationEntryCount("C_FRESH")).toBe(
      1n,
    );
  });

  it("should retain messages within the 30-day window", async () => {
    const now = Date.now();
    const nowSecs = Math.floor(now / 1000);

    // 29-day-old message — just inside the retention window.
    const recentTs = `${nowSecs - 29 * DAY_SECS}.000001`;

    await pic.setTime(now);
    await pic.tick(1);

    await testCanister.testSeedConversationMessage("C_RECENT", recentTs, []);

    expectOk(await testCanister.testConversationPruneRunner());

    // Message is within the window — must not be pruned.
    expect(await testCanister.testGetConversationEntryCount("C_RECENT")).toBe(
      1n,
    );
  });
});
