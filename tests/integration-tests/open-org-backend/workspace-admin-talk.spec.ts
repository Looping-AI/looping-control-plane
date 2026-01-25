import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Principal } from "@dfinity/principal";
import type { PocketIc, Actor, DeferredActor } from "@dfinity/pic";
import { generateRandomIdentity } from "@dfinity/pic";
import {
  createTestEnvironment,
  setupAdminUser,
  setupRegularUser,
  createGroqAgent,
  idlFactory,
  type _SERVICE,
} from "../../setup.ts";
import { expectOk, expectErr } from "../../helpers.ts";
import { withCassette } from "../../lib/cassette";

describe("workspaceAdminTalk", () => {
  let pic: PocketIc;
  let actor: Actor<_SERVICE>;
  let canisterId: Principal;
  let adminIdentity: ReturnType<typeof generateRandomIdentity>;
  let userIdentity: ReturnType<typeof generateRandomIdentity>;
  let agentId: bigint;

  beforeEach(async () => {
    const testEnv = await createTestEnvironment();
    pic = testEnv.pic;
    actor = testEnv.actor;
    canisterId = testEnv.canisterId;

    // Set up an admin
    ({ adminIdentity } = await setupAdminUser(actor));

    // Create a Groq agent with real API key for HTTP outcall tests
    ({ userIdentity } = await setupRegularUser(actor));
    agentId = await createGroqAgent(actor, adminIdentity);
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  it("should reject anonymous users from sending messages", async () => {
    actor.setPrincipal(Principal.anonymous());

    const result = await actor.workspaceAdminTalk(0n, agentId, "Hello Agent");
    expect(expectErr(result)).toEqual(
      "Please login before calling this function."
    );
  });

  it("should reject regular members from sending messages", async () => {
    actor.setIdentity(userIdentity);

    const result = await actor.workspaceAdminTalk(0n, agentId, "Hello Agent");
    expect(expectErr(result)).toEqual(
      "Only workspace admins can perform this action."
    );
  });

  it("should accept message from workspace admin", async () => {
    // Create a deferred actor for the HTTP outcall test
    const deferredActor: DeferredActor<_SERVICE> = pic.createDeferredActor(
      idlFactory,
      canisterId,
    );
    deferredActor.setIdentity(adminIdentity);

    const { result } = await withCassette(
      pic,
      "integration-tests/open-org-backend/workspace-admin-talk/accept-message-authenticated-admin",
      () => deferredActor.workspaceAdminTalk(0n, agentId, "Hello Agent"),
      { ticks: 5 },
    );
    expectOk(await result);
  });
});
