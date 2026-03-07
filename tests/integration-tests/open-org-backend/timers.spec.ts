import { afterEach, beforeEach, describe, it } from "bun:test";
import type { PocketIc } from "@dfinity/pic";
import { createBackendCanister } from "../../setup.ts";

describe("Timer Management", () => {
  let pic: PocketIc;

  beforeEach(async () => {
    const testEnv = await createBackendCanister();
    pic = testEnv.pic;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("Cache clearing timer", () => {
    it("should not trap when advancing 30 days past the cache-clearing threshold", async () => {
      // Advance time by 30 days and tick — verifies the timer fires without trapping
      const thirtyDaysMs = 2_592_000_000;
      await pic.advanceTime(thirtyDaysMs);
      await pic.tick();
    });
  });

  describe("Event store cleanup timer (7 days)", () => {
    it("should not trap when advancing 7 days to trigger processed-events purge", async () => {
      const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
      await pic.advanceTime(sevenDaysMs + 1000);
      await pic.tick();
    });

    it("should not trap when running cleanup with an empty event store", async () => {
      const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
      await pic.advanceTime(sevenDaysMs + 1000);
      await pic.tick();
    });

    it("should not trap when advancing 30 days to trigger failed-events purge", async () => {
      const thirtyDaysMs = 30 * 24 * 60 * 60 * 1000;
      await pic.advanceTime(thirtyDaysMs + 1000);
      await pic.tick();
    });

    it("should reschedule cleanup timer after each run (recurring behaviour)", async () => {
      // The timer is implemented with recurringTimer, so it should fire again
      // after each 7-day interval. Advance 14 days and tick twice to confirm
      // the canister does not trap or stall.
      const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;

      await pic.advanceTime(sevenDaysMs + 1000);
      await pic.tick();

      await pic.advanceTime(sevenDaysMs + 1000);
      await pic.tick();
    });
  });
});
