import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { PocketIc, Actor, DeferredActor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import type { Principal } from "@dfinity/principal";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
  createTestAgent,
  createGroqAgent,
  idlFactory,
  type _SERVICE,
} from "../../setup.ts";
import { expectOk, expectErr } from "../../helpers.ts";
import { withCassette } from "../../lib/cassette";

describe("API Key Encryption & Cache Management", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let canisterId: Principal;
  let adminIdentity: ReturnType<typeof generateRandomIdentity>;
  let userIdentity: ReturnType<typeof generateRandomIdentity>;
  let user2Identity: ReturnType<typeof generateRandomIdentity>;
  let agentId: bigint;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    canisterId = testEnv.canisterId;

    // Set up an admin
    ({ adminIdentity } = await setupAdminUser(actor));

    // Create a test agent
    agentId = await createTestAgent(
      actor,
      "Encryption Test Agent",
      { groq: null },
      "mixtral",
    );

    // Set up two regular users
    ({ userIdentity } = setupRegularUser(actor));
    const user2 = setupRegularUser(actor);
    user2Identity = user2.userIdentity;
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  it("should isolate encrypted keys between users and populate cache", async () => {
    // Check initial cache size as admin
    actor.setIdentity(adminIdentity);
    const initialResult = await actor.getKeyCacheStats();
    const initialSize = expectOk(initialResult).size;

    // User 1 stores a key
    actor.setIdentity(userIdentity);
    const storeResult1 = await actor.storeApiKey(
      agentId,
      { groq: null },
      "user1-secret-key",
    );
    expectOk(storeResult1);

    // User 2 stores a key
    actor.setIdentity(user2Identity);
    const storeResult2 = await actor.storeApiKey(
      agentId,
      { groq: null },
      "user2-secret-key",
    );
    expectOk(storeResult2);

    // User 1 should only see their key
    actor.setIdentity(userIdentity);
    const user1Keys = await actor.getMyApiKeys();
    const keys1 = expectOk(user1Keys);
    expect(keys1.length).toBe(1);

    // User 2 should only see their key
    actor.setIdentity(user2Identity);
    const user2Keys = await actor.getMyApiKeys();
    const keys2 = expectOk(user2Keys);
    expect(keys2.length).toBe(1);

    // Check cache has entries for both users
    actor.setIdentity(adminIdentity);
    const cacheStats = await actor.getKeyCacheStats();
    const finalSize = expectOk(cacheStats).size;
    expect(finalSize).toBe(initialSize + 2n); // Two different users = two cached keys
  });

  it("should reject non-admin users from viewing cache stats", async () => {
    // User is not admin
    const result = await actor.getKeyCacheStats();
    expect(expectErr(result)).toEqual("Only admins can view cache stats");
  });

  it("should return cache stats for admin", async () => {
    actor.setIdentity(adminIdentity);
    const result = await actor.getKeyCacheStats();
    const stats = expectOk(result);
    expect(typeof stats.size).toBe("bigint");
  });

  it("should reject non-admin users from clearing cache", async () => {
    // User is not admin
    const result = await actor.clearKeyCache();
    expect(expectErr(result)).toEqual("Only admins can clear the key cache");
  });

  it("should successfully clear cache as admin", async () => {
    // First store an API key to populate cache
    const storeResult = await actor.storeApiKey(
      agentId,
      { groq: null },
      "test-key-for-clear",
    );
    expectOk(storeResult);

    // Clear cache as admin
    actor.setIdentity(adminIdentity);
    const clearResult = await actor.clearKeyCache();
    expectOk(clearResult);

    // Verify cache is empty
    const statsResult = await actor.getKeyCacheStats();
    const stats = expectOk(statsResult);
    expect(stats.size).toBe(0n);
  });

  it("should re-derive encryption key after cache clear", async () => {
    // Create a Groq Agent with valid test API key
    const agentId = await createGroqAgent(actor, adminIdentity, userIdentity);

    // Admin clears cache
    actor.setIdentity(adminIdentity);
    await actor.clearKeyCache();

    // Create a deferred actor for the HTTP outcall test
    const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
      idlFactory,
      canisterId,
    );
    deferredActor.setIdentity(userIdentity);

    // User is able to use talkTo again,
    // which requires re-deriving the same key successfully,
    // so that API key can be decrypted
    const { result } = await withCassette(
      pic,
      "integration-tests/bot-agent-backend/encryption/re-derive-key-after-cache-clear",
      () => deferredActor.talkTo(agentId, "What is capital of France?"),
      { ticks: 5 }, // More ticks needed for key derivation before HTTP outcall
    );
    const response = expectOk(await result);
    expect(response).toContain("Paris");
  });
});
