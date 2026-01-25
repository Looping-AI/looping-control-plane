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
  let workspaceAdminIdentity: ReturnType<typeof generateRandomIdentity>;
  let ownerIdentity: ReturnType<typeof generateRandomIdentity>;
  let userIdentity: ReturnType<typeof generateRandomIdentity>;
  let agentId: bigint;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    canisterId = testEnv.canisterId;
    ownerIdentity = testEnv.ownerIdentity;

    // Set up workspace admin for agent operations
    ({ adminIdentity: workspaceAdminIdentity } = await setupAdminUser(actor));

    // Create a test agent using workspace admin
    actor.setIdentity(workspaceAdminIdentity);
    agentId = await createTestAgent(
      actor,
      "Encryption Test Agent",
      { groq: null },
      "mixtral",
    );

    // Set up a regular user
    ({ userIdentity } = await setupRegularUser(actor));
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  it("should store workspace API keys and populate cache", async () => {
    // Check initial cache size as owner (org admin)
    actor.setIdentity(ownerIdentity);
    const initialResult = await actor.getKeyCacheStats();
    const initialSize = expectOk(initialResult).size;

    // Admin stores an API key for the workspace
    actor.setIdentity(workspaceAdminIdentity);
    const storeResult = await actor.storeApiKey(
      0n,
      agentId,
      { groq: null },
      "workspace-api-key",
    );
    expectOk(storeResult);

    // Check cache has an entry for the workspace
    actor.setIdentity(ownerIdentity);
    const cacheStats = await actor.getKeyCacheStats();
    const finalSize = expectOk(cacheStats).size;
    expect(finalSize).toBe(initialSize + 1n); // One workspace key derived
  });

  it("should share workspace API keys between admins", async () => {
    // First admin stores an API key
    actor.setIdentity(workspaceAdminIdentity);
    await actor.storeApiKey(0n, agentId, { groq: null }, "shared-key");

    // Create a second admin
    const admin2Identity = generateRandomIdentity();
    await actor.addWorkspaceAdmin(0n, admin2Identity.getPrincipal());

    // Second admin should see the same key
    actor.setIdentity(admin2Identity);
    const keysResult = await actor.getWorkspaceApiKeys(0n);
    const keys = expectOk(keysResult);
    expect(keys.length).toBe(1);
  });

  it("should reject non-admin users from viewing cache stats", async () => {
    actor.setIdentity(userIdentity);
    const result = await actor.getKeyCacheStats();
    expect(expectErr(result)).toEqual(
      "Only org admins can perform this action",
    );
  });

  it("should return cache stats for admin", async () => {
    actor.setIdentity(ownerIdentity);
    const result = await actor.getKeyCacheStats();
    const stats = expectOk(result);
    expect(typeof stats.size).toBe("bigint");
  });

  it("should reject non-admin users from clearing cache", async () => {
    actor.setIdentity(userIdentity);
    const result = await actor.clearKeyCache();
    expect(expectErr(result)).toEqual(
      "Only org admins can perform this action",
    );
  });

  it("should successfully clear cache as admin", async () => {
    // First store an API key to populate cache
    actor.setIdentity(workspaceAdminIdentity);
    const storeResult = await actor.storeApiKey(
      0n,
      agentId,
      { groq: null },
      "test-key-for-clear",
    );
    expectOk(storeResult);

    // Clear cache as owner (org admin)
    actor.setIdentity(ownerIdentity);
    const clearResult = await actor.clearKeyCache();
    expectOk(clearResult);

    // Verify cache is empty
    const statsResult = await actor.getKeyCacheStats();
    const stats = expectOk(statsResult);
    expect(stats.size).toBe(0n);
  });

  it("should re-derive encryption key after cache clear", async () => {
    // Create a Groq Agent with valid test API key stored at workspace level
    const groqAgentId = await createGroqAgent(actor, workspaceAdminIdentity);

    // Owner clears cache
    actor.setIdentity(ownerIdentity);
    await actor.clearKeyCache();

    // Create a deferred actor for the HTTP outcall test
    const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
      idlFactory,
      canisterId,
    );
    deferredActor.setIdentity(userIdentity);

    // User is able to use workspaceTalk,
    // which requires re-deriving the workspace key successfully,
    // so that the API key can be decrypted
    const { result } = await withCassette(
      pic,
      "integration-tests/open-org-backend/encryption/re-derive-key-after-cache-clear",
      () =>
        deferredActor.workspaceTalk(
          0n,
          groqAgentId,
          "What is capital of France?",
        ),
      { ticks: 5 }, // More ticks needed for key derivation before HTTP outcall
    );
    const response = expectOk(await result);
    expect(response).toContain("Paris");
  });
});
