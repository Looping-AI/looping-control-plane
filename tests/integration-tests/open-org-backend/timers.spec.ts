import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor } from "@dfinity/pic";
import type { _SERVICE } from "../../../.dfx/local/canisters/open-org-backend/service.did.js";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
  createTestAgent,
} from "../../setup.ts";
import { expectOk } from "../../helpers.ts";

describe("Timer Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe("Cache clearing timer", () => {
    it("should clear the key cache after 30 days", async () => {
      // Set up admin (first caller becomes admin automatically)
      const { adminIdentity } = await setupAdminUser(actor);

      // Create an agent as admin
      const agentId = await createTestAgent(
        actor,
        "Timer Test Agent",
        { groq: null },
        "llama-3.3-70b-versatile",
      );

      // Store an API key as user (this will derive and cache an encryption key)
      const { userIdentity } = setupRegularUser(actor);
      actor.setIdentity(userIdentity);
      const storeResult = await actor.storeApiKey(
        agentId,
        { groq: null },
        "test-api-key-for-timer",
      );
      expectOk(storeResult);

      // Verify cache now has 1 entry
      actor.setIdentity(adminIdentity);
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
});
