import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import type { _SERVICE } from "../../setup.ts";
import { createTestEnvironment } from "../../setup.ts";
import { expectOk } from "../../helpers.ts";
import type {
  MetricRegistrationInput,
  MetricSource,
} from "../../builds/open-org-backend.did.d.ts";

describe("Timer Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let ownerIdentity: ReturnType<typeof generateRandomIdentity>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    ownerIdentity = testEnv.ownerIdentity;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("Cache clearing timer", () => {
    it("should clear the key cache after 30 days", async () => {
      // Store a secret at the workspace
      const storeResult = await actor.storeSecret(
        0n,
        { groqApiKey: null },
        "test-api-key-for-timer",
      );
      expectOk(storeResult);

      // Verify cache now has 1 entry (using owner identity for cache operations)
      actor.setIdentity(ownerIdentity);
      const afterStoreStats = await actor.getKeyCacheStats();
      const afterStoreSize = expectOk(afterStoreStats).size;
      expect(afterStoreSize).toBe(1n);

      // Advance time by 30 days (2_592_000_000 milliseconds = 30 days)
      const thirtyDaysMs = 2_592_000_000;
      await pic.advanceTime(thirtyDaysMs);

      // Tick to trigger timers
      await pic.tick();

      // Check cache size - should be cleared (0)
      const finalStats = await actor.getKeyCacheStats();
      const finalSize = expectOk(finalStats).size;
      expect(finalSize).toBe(0n);
    });
  });

  describe("Metric retention cleanup timer", () => {
    it("should purge old datapoints after 30 days", async () => {
      const thirtyDaysMs = 30 * 24 * 60 * 60 * 1000;

      // Register a metric with 30 day retention
      const input: MetricRegistrationInput = {
        name: "TimerTestMetric",
        description: "Metric for timer test",
        unit: "count",
        retentionDays: 30n,
      };
      const regResult = await actor.registerMetric(input);
      const metric = expectOk(regResult);

      // Record a datapoint
      const source: MetricSource = { manual: "test" };
      await actor.recordMetricDatapoint(metric.id, 100.0, source);

      // Verify datapoint exists
      const dpBefore = await actor.getMetricDatapoints(metric.id, []);
      expect(expectOk(dpBefore).length).toBe(1);

      // Advance time by 30 days to trigger the timer
      await pic.advanceTime(thirtyDaysMs);

      // Tick to trigger the retention cleanup timer
      await pic.tick();

      // Datapoint should have been purged by the timer
      const dpAfter = await actor.getMetricDatapoints(metric.id, []);
      expect(expectOk(dpAfter).length).toBe(0);
    });
  });
});
